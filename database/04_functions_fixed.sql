
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── register_user() ── no changes needed ─────────────────────
CREATE OR REPLACE FUNCTION register_user(
    p_name     VARCHAR,
    p_email    VARCHAR,
    p_phone    VARCHAR,
    p_role     VARCHAR,
    p_password VARCHAR
)
RETURNS TABLE(out_user_id INT, out_name VARCHAR, out_role VARCHAR, out_status TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_user_id INT;
BEGIN
    IF p_role NOT IN ('trader','analyst') THEN
        RAISE EXCEPTION 'Sign-up only allowed for trader and analyst roles.';
    END IF;
    IF EXISTS (SELECT 1 FROM users WHERE email = p_email) THEN
        RAISE EXCEPTION 'Email already registered.';
    END IF;

    INSERT INTO users(name, email, phone, user_role, password)
    VALUES (p_name, p_email, p_phone, p_role, crypt(p_password, gen_salt('bf')))
    RETURNING user_id INTO v_user_id;

    IF p_role = 'trader' THEN
        INSERT INTO wallet(user_id, balance) VALUES(v_user_id, 0.00);
    END IF;

    RETURN QUERY
        SELECT v_user_id, p_name::VARCHAR, p_role::VARCHAR, 'Registration successful'::TEXT;
END; $$;
GRANT EXECUTE ON FUNCTION register_user(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR)
    TO trader_role, analyst_role;


-- ── login_user() ── no changes needed ────────────────────────
CREATE OR REPLACE FUNCTION login_user(p_email VARCHAR, p_password VARCHAR)
RETURNS TABLE(out_user_id INT, out_name VARCHAR, out_role VARCHAR, out_status TEXT)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT user_id, name, user_role,
        CASE WHEN password = crypt(p_password, password)
             THEN 'success'::TEXT
             ELSE 'invalid'::TEXT
        END
    FROM users
    WHERE email = p_email;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 0::INT, ''::VARCHAR, ''::VARCHAR, 'not_found'::TEXT;
    END IF;
END; $$;
GRANT EXECUTE ON FUNCTION login_user(VARCHAR,VARCHAR)
    TO trader_role, analyst_role, admin_role;

═══════════════════
CREATE OR REPLACE FUNCTION validate_order_inputs(
    p_type  VARCHAR,
    p_qty   INT,
    p_price DECIMAL
)
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    IF p_type NOT IN ('BUY', 'SELL') THEN
        RAISE EXCEPTION 'order_type must be BUY or SELL';
    END IF;
    IF p_qty   <= 0 THEN RAISE EXCEPTION 'Quantity must be positive'; END IF;
    IF p_price <= 0 THEN RAISE EXCEPTION 'Price must be positive';    END IF;
END;
$$;
CREATE OR REPLACE FUNCTION reserve_buy_funds(
    p_user_id    INT,
    p_stock_id   INT,
    p_qty        INT,
    p_price      DECIMAL,
    p_total_cost NUMERIC,
    OUT v_wallet_id INT
)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    v_avail_shares BIGINT;
    v_balance      NUMERIC;
BEGIN
    -- Stock availability check
    SELECT available_shares INTO v_avail_shares
    FROM stocks WHERE stock_id = p_stock_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock % not found', p_stock_id;
    END IF;
    IF v_avail_shares < p_qty THEN
        RAISE EXCEPTION 'Only % shares available for this stock', v_avail_shares;
    END IF;

    -- Wallet balance check
    SELECT wallet_id, balance INTO v_wallet_id, v_balance
    FROM wallet WHERE user_id = p_user_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Wallet not found for user %', p_user_id;
    END IF;
    IF v_balance < p_total_cost THEN
        RAISE EXCEPTION 'Insufficient balance: need %, have %', p_total_cost, v_balance;
    END IF;

    -- Debit full amount upfront (reserved/frozen)
    UPDATE wallet
    SET balance      = balance - p_total_cost,
        last_updated = NOW()
    WHERE wallet_id = v_wallet_id;
END;
$$;

CREATE OR REPLACE FUNCTION check_sell_shares(
    p_user_id  INT,
    p_stock_id INT,
    p_qty      INT,
    OUT v_wallet_id INT
)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    v_held INT := 0;
BEGIN
    SELECT quantity INTO v_held
    FROM portfolio
    WHERE user_id = p_user_id AND stock_id = p_stock_id FOR UPDATE;

    IF NOT FOUND OR v_held < p_qty THEN
        RAISE EXCEPTION 'Insufficient shares: need %, hold %',
            p_qty, COALESCE(v_held, 0);
    END IF;

    SELECT wallet_id INTO v_wallet_id
    FROM wallet WHERE user_id = p_user_id;
END;
$$;
CREATE OR REPLACE FUNCTION insert_pending_order(
    p_user_id    INT,
    p_stock_id   INT,
    p_type       VARCHAR,
    p_qty        INT,
    p_price      DECIMAL,
    p_wallet_id  INT,
    p_total_cost NUMERIC
)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    v_order_id INT;
BEGIN
    INSERT INTO orders(user_id, stock_id, order_type, quantity, filled_qty,
                       price, order_time, status_name)
    VALUES (p_user_id, p_stock_id, p_type, p_qty, 0, p_price, NOW(), 'PENDING')
    RETURNING order_id INTO v_order_id;
    IF p_type = 'BUY' THEN
        UPDATE transaction
        SET order_id = v_order_id
        WHERE wallet_id          = p_wallet_id
          AND order_id           IS NULL
          AND transaction_status = 'SUCCESS'
          AND amount             = -p_total_cost;
    END IF;

    RETURN v_order_id;
END;
$$;
CREATE OR REPLACE FUNCTION match_buy_order(
    p_order_id   INT,
    p_stock_id   INT,
    p_user_id    INT,
    p_wallet_id  INT,
    p_price      DECIMAL,
    p_qty        INT
)
RETURNS INT   -- returns v_remaining
LANGUAGE plpgsql AS $$
DECLARE
    rec            RECORD;
    v_match_qty    INT;
    v_trade_price  DECIMAL;
    v_trade_cost   NUMERIC;
    v_new_filled   INT;
    v_seller_wallet INT;
    v_remaining    INT := p_qty;
BEGIN
    FOR rec IN
        SELECT o.order_id                    AS o_id,
               o.user_id                     AS o_uid,
               o.quantity - o.filled_qty     AS open_qty,
               o.price                       AS o_price
        FROM   orders o
        WHERE  o.stock_id    = p_stock_id
          AND  o.order_type  = 'SELL'
          AND  o.status_name IN ('PENDING', 'PARTIAL')
          AND  o.price       <= p_price
          AND  o.user_id     <> p_user_id
        ORDER  BY o.price ASC, o.order_time ASC
        FOR UPDATE OF o
    LOOP
        EXIT WHEN v_remaining = 0;

        v_match_qty   := LEAST(v_remaining, rec.open_qty);
        v_trade_price := rec.o_price;
        v_trade_cost  := v_match_qty * v_trade_price;

        -- Record trade
        INSERT INTO trades(t_date, buy_order_id, sell_order_id, traded_qty, traded_price)
        VALUES (CURRENT_DATE, p_order_id, rec.o_id, v_match_qty, v_trade_price);

        -- FIX 2: compute new filled total first, then use it for status calc
        SELECT filled_qty + v_match_qty INTO v_new_filled
        FROM   orders WHERE order_id = rec.o_id;

        UPDATE orders
        SET filled_qty  = v_new_filled,
            status_name = CASE
                WHEN v_new_filled >= quantity THEN 'COMPLETED'
                ELSE 'PARTIAL'
            END
        WHERE order_id = rec.o_id;

        UPDATE orders
        SET filled_qty = filled_qty + v_match_qty
        WHERE order_id = p_order_id;

        -- Buyer portfolio: credit shares
        INSERT INTO portfolio(user_id, stock_id, quantity, avg_buy_price)
        VALUES (p_user_id, p_stock_id, v_match_qty, v_trade_price)
        ON CONFLICT (user_id, stock_id) DO UPDATE
        SET avg_buy_price = ROUND(
                ((portfolio.quantity * portfolio.avg_buy_price)
                 + (v_match_qty * v_trade_price))::NUMERIC
                / (portfolio.quantity + v_match_qty), 4),
            quantity = portfolio.quantity + v_match_qty;

        -- Seller portfolio: debit shares
        UPDATE portfolio
        SET quantity = quantity - v_match_qty
        WHERE user_id = rec.o_uid AND stock_id = p_stock_id;

        DELETE FROM portfolio
        WHERE user_id = rec.o_uid AND stock_id = p_stock_id AND quantity <= 0;

        -- Credit seller wallet
        SELECT wallet_id INTO v_seller_wallet
        FROM wallet WHERE user_id = rec.o_uid;

        UPDATE wallet
        SET balance      = balance + v_trade_cost,
            last_updated = NOW()
        WHERE wallet_id = v_seller_wallet;

        INSERT INTO transaction(wallet_id, order_id, amount, transaction_status)
        VALUES (v_seller_wallet, rec.o_id, v_trade_cost, 'SUCCESS');

        -- If buyer paid more than trade price, refund the per-share difference
        IF p_price > v_trade_price THEN
            UPDATE wallet
            SET balance      = balance + (v_match_qty * (p_price - v_trade_price)),
                last_updated = NOW()
            WHERE wallet_id = p_wallet_id;

            INSERT INTO transaction(wallet_id, order_id, amount, transaction_status)
            VALUES (p_wallet_id, p_order_id,
                    v_match_qty * (p_price - v_trade_price), 'REFUNDED');
        END IF;

        -- Decrease company available_shares by matched qty (primary-market deduction)
        UPDATE stocks
        SET available_shares = available_shares - v_match_qty
        WHERE stock_id = p_stock_id;

        -- PRICE TRACKING: update current_price to last traded price
        UPDATE stocks
        SET current_price = v_trade_price
        WHERE stock_id = p_stock_id;

        v_remaining := v_remaining - v_match_qty;
    END LOOP;

    RETURN v_remaining;
END;
$$;


-- ══════════════════════════════════════════════════════════════════════════════
-- HELPER 6: match_sell_order
-- Purpose : Matching engine for SELL orders.
--           Iterates eligible BUY orders (price DESC, time ASC), executes
--           trades, updates portfolios, wallets, and stock price.
--           NOTE: available_shares is NOT decremented here — it was already
--           decremented when the matching BUY order was reserved upfront.
-- Inputs  : new order id, stock id, seller user id, seller wallet id,
--           seller's limit price, qty to fill
-- Outputs : remaining unmatched qty
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION match_sell_order(
    p_order_id   INT,
    p_stock_id   INT,
    p_user_id    INT,
    p_wallet_id  INT,
    p_price      DECIMAL,
    p_qty        INT
)
RETURNS INT   -- returns v_remaining
LANGUAGE plpgsql AS $$
DECLARE
    rec             RECORD;
    v_match_qty     INT;
    v_trade_price   DECIMAL;
    v_trade_cost    NUMERIC;
    v_new_filled    INT;
    v_buyer_wallet  INT;
    v_remaining     INT := p_qty;
BEGIN
    FOR rec IN
        SELECT o.order_id                    AS o_id,
               o.user_id                     AS o_uid,
               o.quantity - o.filled_qty     AS open_qty,
               o.price                       AS o_price
        FROM   orders o
        WHERE  o.stock_id    = p_stock_id
          AND  o.order_type  = 'BUY'
          AND  o.status_name IN ('PENDING', 'PARTIAL')
          AND  o.price       >= p_price
          AND  o.user_id     <> p_user_id
        ORDER  BY o.price DESC, o.order_time ASC
        FOR UPDATE OF o
    LOOP
        EXIT WHEN v_remaining = 0;

        v_match_qty   := LEAST(v_remaining, rec.open_qty);
        v_trade_price := rec.o_price;
        v_trade_cost  := v_match_qty * v_trade_price;

        INSERT INTO trades(t_date, buy_order_id, sell_order_id, traded_qty, traded_price)
        VALUES (CURRENT_DATE, rec.o_id, p_order_id, v_match_qty, v_trade_price);

        -- FIX 2: compute new filled total first, then use it for status calc
        SELECT filled_qty + v_match_qty INTO v_new_filled
        FROM   orders WHERE order_id = rec.o_id;

        UPDATE orders
        SET filled_qty  = v_new_filled,
            status_name = CASE
                WHEN v_new_filled >= quantity THEN 'COMPLETED'
                ELSE 'PARTIAL'
            END
        WHERE order_id = rec.o_id;

        UPDATE orders
        SET filled_qty = filled_qty + v_match_qty
        WHERE order_id = p_order_id;

        -- Credit seller (this user)
        UPDATE wallet
        SET balance      = balance + v_trade_cost,
            last_updated = NOW()
        WHERE wallet_id = p_wallet_id;

        INSERT INTO transaction(wallet_id, order_id, amount, transaction_status)
        VALUES (p_wallet_id, p_order_id, v_trade_cost, 'SUCCESS');

        -- If buyer's limit price > trade price, refund buyer the difference
        IF rec.o_price > v_trade_price THEN
            SELECT wallet_id INTO v_buyer_wallet
            FROM wallet WHERE user_id = rec.o_uid;

            UPDATE wallet
            SET balance      = balance + (v_match_qty * (rec.o_price - v_trade_price)),
                last_updated = NOW()
            WHERE wallet_id = v_buyer_wallet;

            INSERT INTO transaction(wallet_id, order_id, amount, transaction_status)
            VALUES (v_buyer_wallet, rec.o_id,
                    v_match_qty * (rec.o_price - v_trade_price), 'REFUNDED');
        END IF;

        -- Buyer portfolio: credit shares
        SELECT wallet_id INTO v_buyer_wallet
        FROM wallet WHERE user_id = rec.o_uid;

        INSERT INTO portfolio(user_id, stock_id, quantity, avg_buy_price)
        VALUES (rec.o_uid, p_stock_id, v_match_qty, v_trade_price)
        ON CONFLICT (user_id, stock_id) DO UPDATE
        SET avg_buy_price = ROUND(
                ((portfolio.quantity * portfolio.avg_buy_price)
                 + (v_match_qty * v_trade_price))::NUMERIC
                / (portfolio.quantity + v_match_qty), 4),
            quantity = portfolio.quantity + v_match_qty;

        -- Seller portfolio: debit shares
        UPDATE portfolio
        SET quantity = quantity - v_match_qty
        WHERE user_id = p_user_id AND stock_id = p_stock_id;

        DELETE FROM portfolio
        WHERE user_id = p_user_id AND stock_id = p_stock_id AND quantity <= 0;

        -- NOTE: available_shares is NOT changed here.
        -- Shares move from seller's portfolio to buyer's portfolio.
        -- The stock pool was already decremented when the BUY was reserved.

        -- PRICE TRACKING: update current_price to last traded price
        UPDATE stocks
        SET current_price = v_trade_price
        WHERE stock_id = p_stock_id;

        v_remaining := v_remaining - v_match_qty;
    END LOOP;

    RETURN v_remaining;
END;
$$;


-- ══════════════════════════════════════════════════════════════════════════════
-- HELPER 7: finalize_order_status
-- Purpose : Sets the conclusive status on the submitted order after matching.
--           COMPLETED if fully filled, PARTIAL if partly filled, else PENDING.
-- Inputs  : order_id to update
-- Outputs : void (updates orders table in-place)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION finalize_order_status(p_order_id INT)
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    -- FIX 3: No unconditional REFUNDED block here.
    --        Refunds for unfilled BUY remainder are handled by cancel_order()
    --        or the trg_order_status_cancel trigger — never by place_order itself.
    UPDATE orders
    SET status_name = CASE
            WHEN filled_qty >= quantity THEN 'COMPLETED'
            WHEN filled_qty > 0         THEN 'PARTIAL'
            ELSE                             'PENDING'
        END
    WHERE order_id = p_order_id;
END;
$$;


-- ══════════════════════════════════════════════════════════════════════════════
-- MAIN FUNCTION: place_order  (clean orchestrator)
-- Purpose : Entry point for submitting a limit order (BUY or SELL).
--           Delegates every concern to a focused helper function.
-- Inputs  : p_user_id, p_stock_id, p_type ('BUY'|'SELL'), p_qty, p_price
-- Outputs : v_order_id (INT) — the newly created order's PK
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION place_order(
    p_user_id  INT,
    p_stock_id INT,
    p_type     VARCHAR,
    p_qty      INT,
    p_price    DECIMAL
)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    v_order_id   INT;
    v_wallet_id  INT;
    v_total_cost NUMERIC := p_qty * p_price;
BEGIN
    -- ── 1. Validate inputs ────────────────────────────────────
    PERFORM validate_order_inputs(p_type, p_qty, p_price);

    -- ── 2. Pre-order checks (reserves funds or verifies shares) ──
    IF p_type = 'BUY' THEN
        v_wallet_id := reserve_buy_funds(
            p_user_id, p_stock_id, p_qty, p_price, v_total_cost
        );
    ELSIF p_type = 'SELL' THEN
        v_wallet_id := check_sell_shares(p_user_id, p_stock_id, p_qty);
    END IF;

    -- ── 3. Insert order and link reservation transaction ─────
    v_order_id := insert_pending_order(
        p_user_id, p_stock_id, p_type, p_qty, p_price,
        v_wallet_id, v_total_cost
    );

    -- ── 4. Run matching engine ────────────────────────────────
    IF p_type = 'BUY' THEN
        PERFORM match_buy_order(
            v_order_id, p_stock_id, p_user_id, v_wallet_id, p_price, p_qty
        );
    ELSIF p_type = 'SELL' THEN
        PERFORM match_sell_order(
            v_order_id, p_stock_id, p_user_id, v_wallet_id, p_price, p_qty
        );
    END IF;

    -- ── 5. Set final order status ─────────────────────────────
    PERFORM finalize_order_status(v_order_id);

    RETURN v_order_id;
END;
$$;

GRANT EXECUTE ON FUNCTION validate_order_inputs(VARCHAR, INT, DECIMAL)        TO trader_role, admin_role;
GRANT EXECUTE ON FUNCTION reserve_buy_funds(INT, INT, INT, DECIMAL, NUMERIC)  TO trader_role, admin_role;
GRANT EXECUTE ON FUNCTION check_sell_shares(INT, INT, INT)                    TO trader_role, admin_role;
GRANT EXECUTE ON FUNCTION insert_pending_order(INT, INT, VARCHAR, INT, DECIMAL, INT, NUMERIC) TO trader_role, admin_role;
GRANT EXECUTE ON FUNCTION match_buy_order(INT, INT, INT, INT, DECIMAL, INT)   TO trader_role, admin_role;
GRANT EXECUTE ON FUNCTION match_sell_order(INT, INT, INT, INT, DECIMAL, INT)  TO trader_role, admin_role;
GRANT EXECUTE ON FUNCTION finalize_order_status(INT)                          TO trader_role, admin_role;
GRANT EXECUTE ON FUNCTION place_order(INT, INT, VARCHAR, INT, DECIMAL)        TO trader_role, admin_role;

-- ── cancel_order() ── no logic changes, minor clarity improvements ─────────
CREATE OR REPLACE FUNCTION cancel_order(p_order_id INT, p_user_id INT)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_order     RECORD;
    v_wallet_id INT;
    v_unfilled  INT;
    v_refund    NUMERIC;
BEGIN
    SELECT * INTO v_order FROM orders
    WHERE order_id = p_order_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order % not found', p_order_id;
    END IF;
    IF v_order.user_id <> p_user_id THEN
        RAISE EXCEPTION 'You can only cancel your own orders';
    END IF;
    IF v_order.status_name = 'COMPLETED' THEN
        RAISE EXCEPTION 'Completed orders cannot be cancelled';
    END IF;
    IF v_order.status_name = 'CANCELLED' THEN
        RAISE EXCEPTION 'Order is already cancelled';
    END IF;

    v_unfilled := v_order.quantity - v_order.filled_qty;

    -- For BUY only: refund the reserved unfilled amount.
    -- IMPORTANT: insert the REFUNDED transaction BEFORE changing status_name.
    -- The trg_order_status_cancel trigger fires on the status UPDATE and checks
    -- whether a REFUNDED row already exists to avoid double-refunding.
    -- If we insert it after the status UPDATE, the trigger fires first, sees no
    -- REFUNDED row, and issues its own refund — causing a double refund.
    IF v_order.order_type = 'BUY' AND v_unfilled > 0 THEN
        SELECT wallet_id INTO v_wallet_id FROM wallet WHERE user_id = p_user_id;
        v_refund := v_unfilled * v_order.price;

        UPDATE wallet
        SET balance = balance + v_refund, last_updated = NOW()
        WHERE wallet_id = v_wallet_id;

        INSERT INTO transaction(wallet_id, order_id, amount, transaction_status)
        VALUES (v_wallet_id, p_order_id, v_refund, 'REFUNDED');
    END IF;

    -- Mark cancelled — trigger trg_order_status_cancel fires here.
    -- Because the REFUNDED row is already inserted above, the trigger will
    -- detect v_already_refunded = TRUE and correctly skip the refund.
    UPDATE orders SET status_name = 'CANCELLED' WHERE order_id = p_order_id;

    RETURN 'Order ' || p_order_id || ' cancelled. Unfilled qty: ' || v_unfilled;
END; $$;
GRANT EXECUTE ON FUNCTION cancel_order(INT,INT) TO trader_role, admin_role;


-- ── deposit_funds() ── no changes needed ──────────────────────
CREATE OR REPLACE FUNCTION deposit_funds(p_user_id INT, p_amount NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_wallet_id   INT;
    v_new_balance NUMERIC;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Deposit amount must be positive';
    END IF;

    SELECT wallet_id INTO v_wallet_id FROM wallet WHERE user_id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Wallet not found for user %', p_user_id;
    END IF;

    UPDATE wallet
    SET balance = balance + p_amount, last_updated = NOW()
    WHERE user_id = p_user_id
    RETURNING balance INTO v_new_balance;

    INSERT INTO transaction(wallet_id, order_id, amount, transaction_status)
    VALUES (v_wallet_id, NULL, p_amount, 'SUCCESS');

    RETURN v_new_balance;
END; $$;
GRANT EXECUTE ON FUNCTION deposit_funds(INT,NUMERIC) TO trader_role, admin_role;


-- ── get_user_summary() ── FIXED ───────────────────────────────
-- FIX: Original function returns unrealised_pnl which is calculated
--      from user_portfolio_view.  The frontend requested removal of
--      unrealised_pnl from Portfolio page.  We keep it in this admin
--      function (admin still sees it) but make it safe when NULL.
--      Also: SECURITY DEFINER means it runs as the function owner.
--      If the owner doesn't have SELECT on user_portfolio_view the
--      correlated subquery silently returns NULL.
--      Fixed: changed correlated subquery to a LEFT JOIN for reliability.
CREATE OR REPLACE FUNCTION get_user_summary(p_user_id INT)
RETURNS TABLE(
    user_name        TEXT,
    wallet_balance   NUMERIC,
    portfolio_value  NUMERIC,
    total_orders     BIGINT,
    completed_orders BIGINT
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    RETURN QUERY
    SELECT
        u.name::TEXT,
        COALESCE(w.balance, 0),
        COALESCE(SUM(p.quantity * dp.close_price), 0)::NUMERIC,
        COUNT(o.order_id),
        COUNT(o.order_id) FILTER (WHERE o.status_name = 'COMPLETED')
    FROM users u
    LEFT JOIN wallet w ON w.user_id = u.user_id
    LEFT JOIN orders o ON o.user_id = u.user_id
    LEFT JOIN portfolio p ON p.user_id = u.user_id
    LEFT JOIN (
        SELECT DISTINCT ON (stock_id) stock_id, close_price
        FROM daily_prices ORDER BY stock_id, date DESC
    ) dp ON dp.stock_id = p.stock_id
    WHERE u.user_id = p_user_id
    GROUP BY u.name, w.balance;
END; $$;
GRANT EXECUTE ON FUNCTION get_user_summary(INT) TO admin_role;


-- ── get_stock_price_history() ── FIXED ────────────────────────
-- FIX: Original uses  dp.date >= CURRENT_DATE - p_days
--      Seed data ends at 2024-12-31.  If today is 2025 or 2026 this
--      returns zero rows, causing the Price History page to be blank.
--      Fixed: anchor the date range to the MAX date in the table for
--      this stock, not to CURRENT_DATE.
CREATE OR REPLACE FUNCTION get_stock_price_history(
    p_stock_id INT,
    p_days     INT DEFAULT 30
)
RETURNS TABLE(
    price_date   DATE,
    open_price   NUMERIC,
    close_price  NUMERIC,
    high_price   NUMERIC,
    low_price    NUMERIC,
    volume       BIGINT,
    daily_change NUMERIC
)
LANGUAGE plpgsql AS $$
DECLARE
    v_max_date DATE;
BEGIN
    -- Find the latest available date for this stock
    SELECT MAX(date) INTO v_max_date
    FROM daily_prices WHERE stock_id = p_stock_id;

    IF v_max_date IS NULL THEN
        RETURN;  -- no data for this stock
    END IF;

    RETURN QUERY
    SELECT
        dp.date,
        dp.open_price,
        dp.close_price,
        dp.high_price,
        dp.low_price,
        dp.volume,
        ROUND(
            (dp.close_price - LAG(dp.close_price) OVER (ORDER BY dp.date))::NUMERIC,
            4
        ) AS daily_change
    FROM daily_prices dp
    WHERE dp.stock_id = p_stock_id
      AND dp.date >= v_max_date - p_days
    ORDER BY dp.date;
END; $$;
GRANT EXECUTE ON FUNCTION get_stock_price_history(INT,INT)
    TO trader_role, analyst_role, admin_role;


-- ── get_top_traded_stocks() ── no changes needed ─────────────
CREATE OR REPLACE FUNCTION get_top_traded_stocks(p_n INT DEFAULT 10)
RETURNS TABLE(
    symbol              TEXT,
    stock_name          TEXT,
    total_trades        BIGINT,
    total_volume_shares BIGINT,
    total_volume_usd    NUMERIC
)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT
        s.symbol::TEXT,
        s.stock_name::TEXT,
        COUNT(t.trade_id),
        SUM(t.traded_qty)::BIGINT,
        ROUND(SUM(t.traded_qty * t.traded_price)::NUMERIC, 2)
    FROM trades t
    JOIN orders bo ON bo.order_id = t.buy_order_id
    JOIN stocks s  ON s.stock_id  = bo.stock_id
    GROUP BY s.symbol, s.stock_name
    ORDER BY total_volume_usd DESC
    LIMIT p_n;
END; $$;
GRANT EXECUTE ON FUNCTION get_top_traded_stocks(INT) TO analyst_role, admin_role;


-- ── get_exchange_stats() ── no changes needed ─────────────────
CREATE OR REPLACE FUNCTION get_exchange_stats()
RETURNS TABLE(
    exchange_name TEXT,
    country       TEXT,
    num_stocks    BIGINT,
    num_trades    BIGINT,
    total_traded  NUMERIC
)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.name::TEXT,
        e.country::TEXT,
        COUNT(DISTINCT s.stock_id),
        COUNT(t.trade_id),
        ROUND(COALESCE(SUM(t.traded_qty * t.traded_price), 0)::NUMERIC, 2)
    FROM exchange e
    LEFT JOIN stocks s   ON s.exchange_id  = e.exchange_id
    LEFT JOIN orders bo  ON bo.stock_id    = s.stock_id
    LEFT JOIN trades t   ON t.buy_order_id = bo.order_id
    GROUP BY e.name, e.country
    ORDER BY total_traded DESC;
END; $$;
GRANT EXECUTE ON FUNCTION get_exchange_stats() TO analyst_role, admin_role;


-- ── adjust_wallet_balance() ── no changes needed ──────────────
CREATE OR REPLACE FUNCTION adjust_wallet_balance(
    p_user_id INT,
    p_amount  NUMERIC,
    p_reason  TEXT DEFAULT 'Admin adjustment'
)
RETURNS NUMERIC
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_new_balance NUMERIC;
    v_wallet_id   INT;
BEGIN
    UPDATE wallet
    SET balance = balance + p_amount, last_updated = NOW()
    WHERE user_id = p_user_id
    RETURNING balance, wallet_id INTO v_new_balance, v_wallet_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User % not found', p_user_id;
    END IF;

    INSERT INTO transaction(wallet_id, order_id, amount, transaction_status)
    VALUES (v_wallet_id, NULL, p_amount, 'SUCCESS');

    RETURN v_new_balance;
END; $$;
GRANT EXECUTE ON FUNCTION adjust_wallet_balance(INT,NUMERIC,TEXT) TO admin_role;


CREATE OR REPLACE FUNCTION test_full_system(p_stock_id INT)
RETURNS TABLE (
    check_name TEXT,
    result TEXT
) AS
$$
BEGIN

-- 1. CHECK ORDERS EXIST
RETURN QUERY
SELECT 
    'Orders Exist',
    CASE 
        WHEN COUNT(*) > 0 THEN 'PASS'
        ELSE 'FAIL'
    END
FROM orders WHERE stock_id = p_stock_id;

-- 2. CHECK MATCHING (BUY ↔ SELL)
RETURN QUERY
SELECT 
    'Matching Exists',
    CASE 
        WHEN COUNT(*) > 0 THEN 'PASS'
        ELSE 'FAIL'
    END
FROM trades t
JOIN orders bo ON t.buy_order_id = bo.order_id
JOIN orders so ON t.sell_order_id = so.order_id
WHERE bo.stock_id = p_stock_id;

-- 3. CHECK TRADE QUANTITY VALID
RETURN QUERY
SELECT 
    'Trade Quantity Valid',
    CASE 
        WHEN COUNT(*) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END
FROM trades
WHERE traded_qty <= 0;

-- 4. CHECK PRICE MATCH LOGIC
RETURN QUERY
SELECT 
    'Price Logic Valid',
    CASE 
        WHEN COUNT(*) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END
FROM trades t
JOIN orders bo ON t.buy_order_id = bo.order_id
JOIN orders so ON t.sell_order_id = so.order_id
WHERE bo.price < so.price;

-- 5. CHECK PORTFOLIO UPDATE
RETURN QUERY
SELECT 
    'Portfolio Updated',
    CASE 
        WHEN COUNT(*) > 0 THEN 'PASS'
        ELSE 'FAIL'
    END
FROM portfolio
WHERE stock_id = p_stock_id;

-- 6. CHECK WALLET BALANCE VALID
RETURN QUERY
SELECT 
    'Wallet Balance Valid',
    CASE 
        WHEN COUNT(*) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END
FROM wallet
WHERE balance < 0;

-- 7. CHECK AVAILABLE SHARES CONSISTENCY
RETURN QUERY
SELECT 
    'Stock Consistency',
    CASE 
        WHEN s.available_shares <= s.total_shares THEN 'PASS'
        ELSE 'FAIL'
    END
FROM stocks s
WHERE s.stock_id = p_stock_id;

END;
$$ LANGUAGE plpgsql;







CREATE OR REPLACE FUNCTION test_full_system(p_stock_id INT)
RETURNS TABLE (
    check_name TEXT,
    result TEXT
) AS
$$
BEGIN

-- 1. CHECK ORDERS EXIST
RETURN QUERY
SELECT 
    'Orders Exist',
    CASE 
        WHEN COUNT(*) > 0 THEN 'PASS'
        ELSE 'FAIL'
    END
FROM orders WHERE stock_id = p_stock_id;

-- 2. CHECK MATCHING (BUY ↔ SELL)
RETURN QUERY
SELECT 
    'Matching Exists',
    CASE 
        WHEN COUNT(*) > 0 THEN 'PASS'
        ELSE 'FAIL'
    END
FROM trades t
JOIN orders bo ON t.buy_order_id = bo.order_id
JOIN orders so ON t.sell_order_id = so.order_id
WHERE bo.stock_id = p_stock_id;

-- 3. CHECK TRADE QUANTITY VALID
RETURN QUERY
SELECT 
    'Trade Quantity Valid',
    CASE 
        WHEN COUNT(*) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END
FROM trades
WHERE traded_qty <= 0;

-- 4. CHECK PRICE MATCH LOGIC
RETURN QUERY
SELECT 
    'Price Logic Valid',
    CASE 
        WHEN COUNT(*) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END
FROM trades t
JOIN orders bo ON t.buy_order_id = bo.order_id
JOIN orders so ON t.sell_order_id = so.order_id
WHERE bo.price < so.price;

-- 5. CHECK PORTFOLIO UPDATE
RETURN QUERY
SELECT 
    'Portfolio Updated',
    CASE 
        WHEN COUNT(*) > 0 THEN 'PASS'
        ELSE 'FAIL'
    END
FROM portfolio
WHERE stock_id = p_stock_id;

-- 6. CHECK WALLET BALANCE VALID
RETURN QUERY
SELECT 
    'Wallet Balance Valid',
    CASE 
        WHEN COUNT(*) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END
FROM wallet
WHERE balance < 0;

-- 7. CHECK AVAILABLE SHARES CONSISTENCY
RETURN QUERY
SELECT 
    'Stock Consistency',
    CASE 
        WHEN s.available_shares <= s.total_shares THEN 'PASS'
        ELSE 'FAIL'
    END
FROM stocks s
WHERE s.stock_id = p_stock_id;

END;
$$ LANGUAGE plpgsql;

SELECT setval('exchange_exchange_id_seq',         (SELECT MAX(exchange_id)       FROM exchange));
SELECT setval('stocks_stock_id_seq',         (SELECT MAX(stock_id)       FROM stocks));

SELECT setval('users_user_id_seq',           (SELECT MAX(user_id)        FROM users));
SELECT setval('wallet_wallet_id_seq',        (SELECT MAX(wallet_id)      FROM wallet));
SELECT setval('orders_order_id_seq',         (SELECT MAX(order_id)       FROM orders));
SELECT setval('trades_trade_id_seq',         (SELECT MAX(trade_id)       FROM trades));
SELECT setval('transaction_transaction_id_seq', (SELECT MAX(transaction_id) FROM transaction));
ALTER TABLE stocks ADD COLUMN IF NOT EXISTS current_price DECIMAL(12,2)
;




