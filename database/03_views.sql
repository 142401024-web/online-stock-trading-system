-- ============================================================
--  03_views_fixed.sql  — FULL UPDATED VERSION
--  Changes vs previous version:
--    1. user_portfolio_view — added unrealised_pnl + pnl_pct columns
--       (backend route also selects them; frontend displays them)
--    2. stock_market_overview — AAPL excluded via WHERE; but actual
--       removal should happen in seed data / DELETE statement below
--    3. All other views unchanged; comments clarified
-- ============================================================

-- ── CLEANUP: Remove AAPL completely ──────────────────────────
-- Run these statements ONCE to purge AAPL from the database.
-- They cascade correctly if FK constraints are defined with ON DELETE CASCADE.
-- If not, delete child rows first (orders → transactions → trades → portfolio → watchlist).
--
-- DO $$
-- DECLARE v_stock_id INT;
-- BEGIN
--     SELECT stock_id INTO v_stock_id FROM stocks WHERE symbol = 'AAPL';
--     IF v_stock_id IS NOT NULL THEN
--         -- Remove from watchlist
--         DELETE FROM watchlist     WHERE stock_id = v_stock_id;
--         -- Remove from portfolio
--         DELETE FROM portfolio     WHERE stock_id = v_stock_id;
--         -- Get all order IDs for AAPL
--         -- Remove trades linked to AAPL orders
--         DELETE FROM trades
--         WHERE buy_order_id  IN (SELECT order_id FROM orders WHERE stock_id = v_stock_id)
--            OR sell_order_id IN (SELECT order_id FROM orders WHERE stock_id = v_stock_id);
--         -- Remove transactions linked to AAPL orders
--         DELETE FROM transaction
--         WHERE order_id IN (SELECT order_id FROM orders WHERE stock_id = v_stock_id);
--         -- Remove orders
--         DELETE FROM orders        WHERE stock_id = v_stock_id;
--         -- Remove price history
--         DELETE FROM daily_prices  WHERE stock_id = v_stock_id;
--         -- Remove the stock itself
--         DELETE FROM stocks        WHERE stock_id = v_stock_id;
--         RAISE NOTICE 'AAPL (stock_id=%) removed.', v_stock_id;
--     ELSE
--         RAISE NOTICE 'AAPL not found — already removed.';
--     END IF;
-- END; $$;


-- ── View 1: user_portfolio_view  UPDATED ─────────────────────
-- CHANGE: Added unrealised_pnl and pnl_pct so portfolio page can show P&L.
--         COALESCE guards avg_buy_price=NULL edge case.
--         AAPL excluded at view level as a safety net (primary removal via DELETE above).
CREATE OR REPLACE VIEW user_portfolio_view AS
SELECT
    u.user_id,
    u.name                                                       AS user_name,
    s.stock_id,
    s.symbol,
    s.stock_name,
    p.quantity,
    COALESCE(p.avg_buy_price, 0)                                 AS avg_buy_price,
    dp.close_price                                               AS current_price,
    ROUND((p.quantity * dp.close_price)::NUMERIC, 2)             AS market_value,
    ROUND(
        ((dp.close_price - COALESCE(p.avg_buy_price, 0)) * p.quantity)::NUMERIC,
        2
    )                                                            AS unrealised_pnl,
    CASE
        WHEN COALESCE(p.avg_buy_price, 0) > 0
        THEN ROUND(
            ((dp.close_price - p.avg_buy_price) / p.avg_buy_price * 100)::NUMERIC,
            2
        )
        ELSE NULL
    END                                                          AS pnl_pct
FROM portfolio p
JOIN users  u ON u.user_id  = p.user_id
JOIN stocks s ON s.stock_id = p.stock_id
JOIN (
    SELECT DISTINCT ON (stock_id)
        stock_id, close_price
    FROM daily_prices
    ORDER BY stock_id, date DESC
) dp ON dp.stock_id = p.stock_id
WHERE p.quantity > 0
  AND s.symbol <> 'AAPL';   -- safety net in case DELETE was not run

GRANT SELECT ON user_portfolio_view TO trader_role, analyst_role, admin_role;


-- ── View 2: order_summary_view  no changes ────────────────────
CREATE OR REPLACE VIEW order_summary_view AS
SELECT
    o.order_id,
    u.user_id,
    u.name                                              AS user_name,
    s.symbol,
    s.stock_name,
    e.name                                              AS exchange_name,
    o.order_type,
    o.quantity,
    o.filled_qty,
    o.quantity - o.filled_qty                           AS remaining_qty,
    o.price,
    ROUND((o.filled_qty * o.price)::NUMERIC, 2)         AS filled_value,
    o.order_time,
    o.status_name
FROM orders   o
JOIN users    u ON u.user_id    = o.user_id
JOIN stocks   s ON s.stock_id   = o.stock_id
JOIN exchange e ON e.exchange_id = s.exchange_id;

GRANT SELECT ON order_summary_view TO trader_role, analyst_role, admin_role;


-- ── View 3: wallet_transaction_view  no changes ───────────────
CREATE OR REPLACE VIEW wallet_transaction_view AS
SELECT
    u.user_id,
    u.name                AS user_name,
    w.wallet_id,
    w.balance             AS current_balance,
    t.transaction_id,
    t.amount,
    t.transaction_date,
    t.transaction_status,
    o.order_type,
    s.symbol
FROM wallet w
JOIN users            u ON u.user_id    = w.user_id
LEFT JOIN transaction t ON t.wallet_id  = w.wallet_id
LEFT JOIN orders      o ON o.order_id   = t.order_id
LEFT JOIN stocks      s ON s.stock_id   = o.stock_id;

GRANT SELECT ON wallet_transaction_view TO trader_role, admin_role;


-- ── View 4: stock_market_overview  UPDATED ───────────────────
-- FIX (original): Uses ROW_NUMBER per stock for correct rank-1/rank-2 per stock.
-- NEW: Added WHERE s.symbol <> 'AAPL' so AAPL never appears in market feed
--      even if residual rows exist in daily_prices.
CREATE OR REPLACE VIEW stock_market_overview AS
WITH ranked AS (
    SELECT
        stock_id,
        open_price,
        close_price,
        high_price,
        low_price,
        volume,
        date,
        ROW_NUMBER() OVER (PARTITION BY stock_id ORDER BY date DESC) AS rn
    FROM daily_prices
)
SELECT
    s.stock_id,
    s.symbol,
    s.stock_name,
    e.name                                                AS exchange_name,
    e.country,
    s.total_shares,
    s.available_shares,
    r1.open_price,
    r1.close_price                                        AS latest_price,
    r1.high_price,
    r1.low_price,
    r1.volume,
    r2.close_price                                        AS prev_close,
    CASE
        WHEN r2.close_price IS NULL OR r2.close_price = 0 THEN NULL
        ELSE ROUND(
            ((r1.close_price - r2.close_price) / r2.close_price * 100)::NUMERIC,
            2
        )
    END                                                   AS pct_change
FROM stocks  s
JOIN exchange e  ON e.exchange_id = s.exchange_id
LEFT JOIN ranked r1 ON r1.stock_id = s.stock_id AND r1.rn = 1
LEFT JOIN ranked r2 ON r2.stock_id = s.stock_id AND r2.rn = 2
WHERE s.symbol <> 'AAPL';   -- NEW: AAPL excluded from market overview

GRANT SELECT ON stock_market_overview TO trader_role, analyst_role, admin_role;


-- ── View 5: watchlist_with_prices  FIXED ─────────────────────
-- Original used INNER JOIN to daily_prices — newly watched stocks with no
-- price data would silently disappear from the watchlist.
-- Fixed: LEFT JOIN so every row is returned; latest_price = NULL is safe.
CREATE OR REPLACE VIEW watchlist_with_prices AS
SELECT
    wl.user_id,
    u.name       AS user_name,
    s.stock_id,
    s.symbol,
    s.stock_name,
    wl.added_date,
    dp.close_price AS latest_price,
    dp.date        AS price_date
FROM watchlist wl
JOIN users  u  ON u.user_id  = wl.user_id
JOIN stocks s  ON s.stock_id = wl.stock_id
LEFT JOIN (
    SELECT DISTINCT ON (stock_id) stock_id, close_price, date
    FROM daily_prices ORDER BY stock_id, date DESC
) dp ON dp.stock_id = wl.stock_id
WHERE s.symbol <> 'AAPL';   -- exclude AAPL from watchlist view

GRANT SELECT ON watchlist_with_prices TO trader_role, analyst_role, admin_role;


-- ── View 6: open_order_book  no changes ──────────────────────
CREATE OR REPLACE VIEW open_order_book AS
SELECT
    s.symbol,
    s.stock_name,
    o.order_type,
    o.price,
    SUM(o.quantity - o.filled_qty)  AS open_quantity,
    COUNT(*)                         AS num_orders
FROM orders o
JOIN stocks s ON s.stock_id = o.stock_id
WHERE o.status_name IN ('PENDING','PARTIAL')
GROUP BY s.symbol, s.stock_name, o.order_type, o.price
ORDER BY s.symbol, o.order_type,
    CASE o.order_type WHEN 'BUY'  THEN o.price END DESC,
    CASE o.order_type WHEN 'SELL' THEN o.price END ASC;

GRANT SELECT ON open_order_book TO trader_role, analyst_role, admin_role;