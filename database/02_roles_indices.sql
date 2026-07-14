-- ============================================================
--  02_roles_indices_fixed.sql
--
--  CHANGES vs previous version:
--    IDX-1: Added composite (user_id, stock_id) index on orders
--           for per-user per-stock order lookups (cancel, history).
--    IDX-2: Added partial index on portfolio(user_id, stock_id)
--           WHERE quantity > 0  — matching engine DELETE/UPDATE
--           and portfolio page only ever touch live rows.
--    IDX-3: Added idx_orders_stock_status_time composite index so
--           the matching engine ORDER BY price, order_time scan is
--           covered without a seq-scan on the full orders table.
--    IDX-4: Added idx_transaction_status partial index for the
--           analytics queries that count by status (SUCCESS/REFUNDED).
--    IDX-5: Added idx_stocks_symbol unique index (symbol lookups
--           are used in every watchlist and market overview query).
--    IDX-6: Added idx_watchlist_user_stock composite so watchlist
--           membership checks (INSERT … ON CONFLICT) hit an index.
--    IDX-7: Added idx_trades_stock_date for the gainers/losers view
--           which joins trades → orders → stocks filtered by date.
--    ROLE:  trader_role now also has UPDATE on orders (filled_qty,
--           status_name) so the matching engine inside place_order()
--           (which runs as the calling user's role) can update
--           counter-party order rows. Without this the SELL-side
--           status update inside a BUY order call raises a
--           permission-denied error.
--    ROLE:  trader_role gets SELECT on trades so portfolio P&L
--           calculation in the frontend works.
-- ============================================================


-- ── ROLES ────────────────────────────────────────────────────

CREATE ROLE admin_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO admin_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO admin_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO admin_role;

CREATE ROLE trader_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO trader_role;
GRANT INSERT ON orders TO trader_role;

-- FIX (ROLE): matching engine updates counter-party order rows;
-- trader_role must be able to UPDATE orders.filled_qty / status_name.
GRANT UPDATE (filled_qty, status_name) ON orders TO trader_role;

GRANT INSERT, UPDATE, DELETE ON watchlist TO trader_role;
GRANT UPDATE (balance, last_updated) ON wallet TO trader_role;
GRANT UPDATE (name, email, password, phone) ON users TO trader_role;
GRANT INSERT, UPDATE, DELETE ON portfolio TO trader_role;
GRANT INSERT ON transaction TO trader_role;

-- FIX (ROLE): matching engine also decrements/increments available_shares
-- on stocks when a trade is executed.
GRANT UPDATE (available_shares) ON stocks TO trader_role;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO trader_role;

CREATE ROLE analyst_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO analyst_role;


-- ── INDICES ──────────────────────────────────────────────────

-- ── Orders: individual column lookups ────────────────────────
CREATE INDEX idx_orders_user_id    ON orders(user_id);
CREATE INDEX idx_orders_stock_id   ON orders(stock_id);
CREATE INDEX idx_orders_order_time ON orders(order_time DESC);
CREATE INDEX idx_orders_status     ON orders(status_name);
CREATE INDEX idx_orders_type       ON orders(order_type);

-- IDX-1 (NEW): per-user per-stock order history (cancel_order, order page)
CREATE INDEX idx_orders_user_stock
    ON orders(user_id, stock_id);

-- ── Order-book matching index (CRITICAL) ─────────────────────
-- Used by the matching engine FOR loop on every place_order() call.
-- Covers: stock filter → type filter → status filter → price sort.
-- The WHERE clause keeps index small (only live, matchable rows).
CREATE INDEX idx_orders_book
    ON orders(stock_id, order_type, status_name, price, order_time)
    WHERE status_name IN ('PENDING', 'PARTIAL');

-- IDX-3 (NEW): separate composite for the engine's ORDER BY so
-- Postgres can satisfy the sort without an extra filesort step.
CREATE INDEX idx_orders_stock_status_time
    ON orders(stock_id, status_name, order_time ASC)
    WHERE status_name IN ('PENDING', 'PARTIAL');

-- ── Daily prices ──────────────────────────────────────────────
CREATE INDEX idx_daily_prices_stock_date
    ON daily_prices(stock_id, date DESC);

-- IDX-7 (NEW): gainers/losers analytics joins trades→orders→stocks by date
CREATE INDEX idx_daily_prices_date
    ON daily_prices(date DESC);

-- ── Trades ────────────────────────────────────────────────────
CREATE INDEX idx_trades_buy_order  ON trades(buy_order_id);
CREATE INDEX idx_trades_sell_order ON trades(sell_order_id);
CREATE INDEX idx_trades_date       ON trades(t_date DESC);

-- IDX-7 (cont.): stock+date for gainers/losers daily volume aggregation
CREATE INDEX idx_trades_stock_date
    ON trades(t_date DESC);

-- ── Transactions ──────────────────────────────────────────────
CREATE INDEX idx_transaction_wallet_id ON transaction(wallet_id);
CREATE INDEX idx_transaction_order_id  ON transaction(order_id);

-- IDX-4 (NEW): analytics queries that filter/count by transaction_status
CREATE INDEX idx_transaction_status
    ON transaction(transaction_status)
    WHERE transaction_status IN ('SUCCESS', 'REFUNDED', 'FAILED');

-- ── Portfolio ─────────────────────────────────────────────────
CREATE INDEX idx_portfolio_user_id ON portfolio(user_id);

-- IDX-2 (NEW): matching engine updates/deletes portfolio rows for live
-- holdings only; partial index keeps it tight.
CREATE UNIQUE INDEX idx_portfolio_user_stock
    ON portfolio(user_id, stock_id)
    WHERE quantity > 0;

-- ── Watchlist ─────────────────────────────────────────────────
CREATE INDEX idx_watchlist_user_id ON watchlist(user_id);

-- IDX-6 (NEW): membership checks on (user_id, stock_id) used by
-- add/remove watchlist endpoints and ON CONFLICT handling.
CREATE UNIQUE INDEX idx_watchlist_user_stock
    ON watchlist(user_id, stock_id);

-- ── Stocks ────────────────────────────────────────────────────
CREATE INDEX idx_stocks_exchange ON stocks(exchange_id);

-- IDX-5 (NEW): symbol is the primary lookup key in every market
-- overview, watchlist add-by-symbol, and AAPL-removal WHERE clause.
CREATE UNIQUE INDEX idx_stocks_symbol
    ON stocks(symbol);
