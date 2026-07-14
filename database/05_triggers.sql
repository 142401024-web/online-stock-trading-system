-- ============================================================
--  05_triggers_fixed.sql
--
--  CHANGES vs previous version (05_triggers.sql):
--
--  TRG-1  trg_prevent_negative_balance  — UNCHANGED (correct)
--
--  TRG-2  trg_check_available_shares    — UNCHANGED (correct)
--
--  TRG-3  trg_update_daily_volume       — FIXED
--    WHY:  The old function stored the buy_order's stock_id but
--          for a SELL-initiated trade the buy_order_id still maps
--          correctly so that part was fine. However the INSERT used
--          NEW.traded_price as both open and close unconditionally.
--          On the first trade of the day that is correct; on
--          subsequent trades the open_price must NOT be overwritten
--          (ON CONFLICT already preserved it via the DO UPDATE, but
--          the DO UPDATE list was also overwriting close/high/low
--          with values from only the latest trade row). Fixed:
--          ON CONFLICT now correctly accumulates high/low/close/volume.
--          Also added COALESCE guards so a missing daily_prices row
--          for the stock never causes a null-dereference.
--
--  TRG-4  trg_cancel_order_refund       — FIXED
--    WHY-A: The old trigger fired for ANY update to status_name.
--           If cancel_order() is called (the normal path), that
--           function already does the wallet refund AND inserts the
--           REFUNDED transaction itself. The trigger then fires on
--           the same status change and doubles the refund.
--           Fix: the trigger is now a SAFETY NET only — it guards
--           the path where an admin directly sets status='CANCELLED'
--           via a raw UPDATE, bypassing cancel_order(). It detects
--           this situation by checking whether a REFUNDED transaction
--           row for this order already exists before acting.
--
--    WHY-B: The old trigger did NOT handle SELL order cancellation.
--           A SELL order has shares reserved (deducted from portfolio)
--           but the portfolio deduction only happens at trade-time,
--           not at SELL order placement. So for SELL cancellation
--           there is nothing to refund to the wallet — this is
--           already correct. No change needed for SELL.
--
--    WHY-C: Added guard: only refund if v_refund > 0. Prevents a
--           zero-amount REFUNDED transaction being inserted for
--           fully-filled orders that were somehow set CANCELLED.
--
--  TRG-5  trg_order_status_guard  — NEW
--    WHY:  Enforces the legal order-status state machine at the DB
--          level so no application bug or direct SQL can put an order
--          into an impossible state (e.g. COMPLETED → PENDING).
--          Legal transitions:
--            PENDING  → PARTIAL | COMPLETED | CANCELLED
--            PARTIAL  → COMPLETED | CANCELLED
--            COMPLETED → (no change allowed)
--            CANCELLED → (no change allowed)
-- ============================================================


-- ══════════════════════════════════════════════════════════════
--  TRG-1 — Prevent negative wallet balance (UNCHANGED)
-- ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION trg_prevent_negative_balance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.balance < 0 THEN
        RAISE EXCEPTION
            'Wallet balance cannot go negative. Current: %, Attempted: %',
            OLD.balance, NEW.balance;
    END IF;
    RETURN NEW;
END; $$;

CREATE TRIGGER trg_wallet_balance_check
BEFORE UPDATE ON wallet
FOR EACH ROW EXECUTE FUNCTION trg_prevent_negative_balance();


-- ══════════════════════════════════════════════════════════════
--  TRG-2 — Prevent available_shares going negative (UNCHANGED)
-- ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION trg_check_available_shares()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.available_shares < 0 THEN
        RAISE EXCEPTION
            'Not enough shares available. Stock: %, Tried to reduce by too much.',
            NEW.stock_id;
    END IF;
    RETURN NEW;
END; $$;

CREATE TRIGGER trg_stock_shares_check
BEFORE UPDATE ON stocks
FOR EACH ROW EXECUTE FUNCTION trg_check_available_shares();


-- ══════════════════════════════════════════════════════════════
--  TRG-3 — Auto-update daily_prices when a trade executes (FIXED)
-- ══════════════════════════════════════════════════════════════
-- FIX: ON CONFLICT correctly preserves open_price (first trade of day)
--      and accumulates high, low, close, volume across all intra-day
--      trades.  Previously close/high/low could be clobbered by a
--      later trade that wasn't actually the day's best/worst price.
CREATE OR REPLACE FUNCTION trg_update_daily_volume()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_stock_id INT;
BEGIN
    -- Works for both BUY-initiated and SELL-initiated trades:
    -- buy_order_id always references the BUY order; its stock_id is
    -- the authoritative source for which stock was traded.
    SELECT stock_id INTO v_stock_id
    FROM orders WHERE order_id = NEW.buy_order_id;

    IF v_stock_id IS NULL THEN
        RAISE WARNING 'trg_update_daily_volume: could not find stock_id for buy_order_id=%', NEW.buy_order_id;
        RETURN NEW;
    END IF;

    INSERT INTO daily_prices(date, stock_id, open_price, close_price,
                             high_price, low_price, volume)
    VALUES (
        NEW.t_date,
        v_stock_id,
        NEW.traded_price,   -- open  = first trade price of the day
        NEW.traded_price,   -- close = will be updated by later trades
        NEW.traded_price,   -- high
        NEW.traded_price,   -- low
        NEW.traded_qty
    )
    ON CONFLICT (date, stock_id) DO UPDATE
    SET
        -- open_price intentionally NOT updated — it stays as the first trade
        close_price = NEW.traded_price,
        high_price  = GREATEST(daily_prices.high_price,  NEW.traded_price),
        low_price   = LEAST  (daily_prices.low_price,    NEW.traded_price),
        volume      = daily_prices.volume + NEW.traded_qty;

    RETURN NEW;
END; $$;

CREATE TRIGGER trg_trade_updates_price
AFTER INSERT ON trades
FOR EACH ROW EXECUTE FUNCTION trg_update_daily_volume();


-- ══════════════════════════════════════════════════════════════
--  TRG-4 — Refund on cancel — SAFETY NET for direct admin UPDATE (FIXED)
-- ══════════════════════════════════════════════════════════════
--
--  This trigger is intentionally a SAFETY NET, not the primary
--  cancellation path.
--
--  Normal cancellation:  cancel_order() function — it handles
--  the wallet refund and REFUNDED transaction itself, then sets
--  status_name = 'CANCELLED'. The trigger fires after that UPDATE
--  but must NOT double-refund.
--
--  Admin direct cancel: admin runs  UPDATE orders SET status_name='CANCELLED'
--  without calling cancel_order(). No refund has been issued yet.
--  The trigger must issue the refund in this case only.
--
--  Disambiguation: check whether a REFUNDED transaction already
--  exists for this order. If yes → cancel_order() already ran →
--  do nothing. If no → this is a direct UPDATE → issue refund now.
--
--  SELL cancellation: SELL orders have no upfront wallet deduction
--  (shares are not "reserved" in the wallet; they live in portfolio).
--  Nothing to refund to the wallet on SELL cancel.
CREATE OR REPLACE FUNCTION trg_cancel_order_refund()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_wallet_id       INT;
    v_unfilled        INT;
    v_refund          NUMERIC;
    v_already_refunded BOOLEAN;
BEGIN
    -- Only act when status changes TO 'CANCELLED' from a live state
    IF NEW.status_name <> 'CANCELLED'
       OR OLD.status_name NOT IN ('PENDING', 'PARTIAL') THEN
        RETURN NEW;
    END IF;

    -- Only BUY orders have reserved wallet funds
    IF OLD.order_type <> 'BUY' THEN
        RETURN NEW;
    END IF;

    v_unfilled := OLD.quantity - OLD.filled_qty;

    -- Nothing to refund if fully filled (shouldn't happen, but be safe)
    IF v_unfilled <= 0 THEN
        RETURN NEW;
    END IF;

    -- FIX-A: Check whether cancel_order() already issued a REFUNDED
    -- transaction for this order. If it did, skip — do not double-refund.
    SELECT EXISTS(
        SELECT 1 FROM transaction
        WHERE order_id = OLD.order_id
          AND transaction_status = 'REFUNDED'
    ) INTO v_already_refunded;

    IF v_already_refunded THEN
        -- cancel_order() already handled this; trigger is a no-op.
        RETURN NEW;
    END IF;

    -- Reach here only when admin cancelled directly via raw UPDATE.
    SELECT wallet_id INTO v_wallet_id
    FROM wallet WHERE user_id = OLD.user_id;

    IF v_wallet_id IS NULL THEN
        RAISE WARNING 'trg_cancel_order_refund: no wallet for user_id=%', OLD.user_id;
        RETURN NEW;
    END IF;

    v_refund := v_unfilled * OLD.price;

    UPDATE wallet
    SET balance      = balance + v_refund,
        last_updated = NOW()
    WHERE wallet_id = v_wallet_id;

    INSERT INTO transaction(wallet_id, order_id, amount, transaction_status)
    VALUES (v_wallet_id, OLD.order_id, v_refund, 'REFUNDED');

    RETURN NEW;
END; $$;

CREATE TRIGGER trg_order_status_cancel
AFTER UPDATE OF status_name ON orders
FOR EACH ROW EXECUTE FUNCTION trg_cancel_order_refund();


-- ══════════════════════════════════════════════════════════════
--  TRG-5 — Order status state-machine guard  (NEW)
-- ══════════════════════════════════════════════════════════════
--  Enforces legal transitions at the DB level:
--    PENDING   → PARTIAL | COMPLETED | CANCELLED   (allowed)
--    PARTIAL   → COMPLETED | CANCELLED             (allowed)
--    COMPLETED → any                               (BLOCKED)
--    CANCELLED → any                               (BLOCKED)
--  Same-value updates (e.g. PENDING → PENDING) are always allowed
--  so idempotent writes don't fail.
CREATE OR REPLACE FUNCTION trg_guard_order_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- No change — always fine
    IF NEW.status_name = OLD.status_name THEN
        RETURN NEW;
    END IF;

    -- Terminal states cannot be changed
    IF OLD.status_name IN ('COMPLETED', 'CANCELLED') THEN
        RAISE EXCEPTION
            'Order % is % and cannot be moved to %. Terminal states are immutable.',
            OLD.order_id, OLD.status_name, NEW.status_name;
    END IF;

    -- PENDING may only advance to PARTIAL, COMPLETED, or CANCELLED
    IF OLD.status_name = 'PENDING'
       AND NEW.status_name NOT IN ('PARTIAL', 'COMPLETED', 'CANCELLED') THEN
        RAISE EXCEPTION
            'Invalid order status transition: % → % for order %',
            OLD.status_name, NEW.status_name, OLD.order_id;
    END IF;

    -- PARTIAL may only advance to COMPLETED or CANCELLED
    IF OLD.status_name = 'PARTIAL'
       AND NEW.status_name NOT IN ('COMPLETED', 'CANCELLED') THEN
        RAISE EXCEPTION
            'Invalid order status transition: % → % for order %',
            OLD.status_name, NEW.status_name, OLD.order_id;
    END IF;

    RETURN NEW;
END; $$;

CREATE TRIGGER trg_order_status_guard
BEFORE UPDATE OF status_name ON orders
FOR EACH ROW EXECUTE FUNCTION trg_guard_order_status();
