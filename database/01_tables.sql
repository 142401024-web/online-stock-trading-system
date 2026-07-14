-- ============================================================
--  REAL STOCK TRADING SYSTEM — TABLE CREATION
--  Key addition: company_shares (supply), order book matching
-- ============================================================

-- pgcrypto for password hashing
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── USERS ────────────────────────────────────────────────────
CREATE TABLE users (
    user_id   SERIAL PRIMARY KEY,
    name      VARCHAR(100) NOT NULL,
    email     VARCHAR(150) NOT NULL UNIQUE,
    password  VARCHAR(255) NOT NULL,
    phone     VARCHAR(20)  UNIQUE,
    user_role VARCHAR(20)  NOT NULL DEFAULT 'trader'
              CHECK (user_role IN ('admin', 'trader', 'analyst'))
);

-- ── WALLET ───────────────────────────────────────────────────
CREATE TABLE wallet (
    wallet_id    SERIAL PRIMARY KEY,
    user_id      INT NOT NULL UNIQUE,
    balance      DECIMAL(12,2) NOT NULL DEFAULT 0.00 CHECK (balance >= 0),
    last_updated TIMESTAMP DEFAULT NOW(),
    FOREIGN KEY (user_id) REFERENCES users(user_id)
);

-- ── EXCHANGE ─────────────────────────────────────────────────
CREATE TABLE exchange (
    exchange_id SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    country     VARCHAR(100) NOT NULL
);

-- ── STOCKS ── now has total_shares + available_shares ────────
--  total_shares    : fixed IPO supply (never changes)
--  available_shares: shares currently available in the market
--                    (decreases on BUY, increases on SELL)
CREATE TABLE stocks (
    stock_id         SERIAL PRIMARY KEY,
    stock_name       VARCHAR(100) NOT NULL,
    symbol           VARCHAR(10)  NOT NULL UNIQUE,
    exchange_id      INT NOT NULL,
    total_shares     BIGINT NOT NULL CHECK (total_shares > 0),
    available_shares BIGINT NOT NULL CHECK (available_shares >= 0),
    CONSTRAINT avail_lte_total CHECK (available_shares <= total_shares),
    FOREIGN KEY (exchange_id) REFERENCES exchange(exchange_id)
);

-- ── ORDERS ── status reflects real order-book lifecycle ──────
--  PENDING   : submitted, waiting for a matching counter-order
--  COMPLETED : fully matched and executed
--  PARTIAL   : partially matched (some qty filled, rest still open)
--  CANCELLED : cancelled by user or system (no match found)
CREATE TABLE orders (
    order_id    SERIAL PRIMARY KEY,
    user_id     INT NOT NULL,
    stock_id    INT NOT NULL,
    order_type  VARCHAR(10) NOT NULL CHECK (order_type IN ('BUY','SELL')),
    quantity    INT NOT NULL CHECK (quantity > 0),
    filled_qty  INT NOT NULL DEFAULT 0 CHECK (filled_qty >= 0),
    price       DECIMAL(12,2) NOT NULL CHECK (price > 0),
    order_time  TIMESTAMP DEFAULT NOW(),
    status_name VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                CHECK (status_name IN ('COMPLETED','PENDING','CANCELLED','PARTIAL')),
    FOREIGN KEY (user_id)  REFERENCES users(user_id),
    FOREIGN KEY (stock_id) REFERENCES stocks(stock_id)
);

-- ── TRADES ── one row per matched pair ───────────────────────
--  buy_order_id / sell_order_id : the two matched orders
--  traded_qty                   : how many shares exchanged
--  traded_price                 : price at which trade executed
CREATE TABLE trades (
    trade_id      SERIAL PRIMARY KEY,
    t_date        DATE NOT NULL DEFAULT CURRENT_DATE,
    buy_order_id  INT NOT NULL,
    sell_order_id INT NOT NULL,
    traded_qty    INT NOT NULL CHECK (traded_qty > 0),
    traded_price  DECIMAL(12,2) NOT NULL,
    FOREIGN KEY (buy_order_id)  REFERENCES orders(order_id),
    FOREIGN KEY (sell_order_id) REFERENCES orders(order_id)
);

-- ── TRANSACTION ──────────────────────────────────────────────
CREATE TABLE transaction (
    transaction_id     SERIAL PRIMARY KEY,
    wallet_id          INT NOT NULL,
    order_id           INT,
    amount             DECIMAL(12,2) NOT NULL,  -- negative = debit, positive = credit
    transaction_date   TIMESTAMP DEFAULT NOW(),
    transaction_status VARCHAR(20) NOT NULL
                       CHECK (transaction_status IN ('SUCCESS','FAILED','REFUNDED')),
    FOREIGN KEY (wallet_id) REFERENCES wallet(wallet_id),
    FOREIGN KEY (order_id)  REFERENCES orders(order_id)
);

-- ── PORTFOLIO ────────────────────────────────────────────────
CREATE TABLE portfolio (
    user_id  INT NOT NULL,
    stock_id INT NOT NULL,
    quantity INT NOT NULL CHECK (quantity >= 0),
    avg_buy_price DECIMAL(12,2),          -- tracks cost basis
    PRIMARY KEY (user_id, stock_id),
    FOREIGN KEY (user_id)  REFERENCES users(user_id),
    FOREIGN KEY (stock_id) REFERENCES stocks(stock_id)
);

-- ── WATCHLIST ────────────────────────────────────────────────
CREATE TABLE watchlist (
    user_id    INT NOT NULL,
    stock_id   INT NOT NULL,
    added_date TIMESTAMP DEFAULT NOW(),
    PRIMARY KEY (user_id, stock_id),
    FOREIGN KEY (user_id)  REFERENCES users(user_id),
    FOREIGN KEY (stock_id) REFERENCES stocks(stock_id)
);

-- ── DAILY PRICES ─────────────────────────────────────────────
CREATE TABLE daily_prices (
    date        DATE    NOT NULL,
    stock_id    INT     NOT NULL,
    open_price  NUMERIC NOT NULL CHECK (open_price  > 0),
    close_price NUMERIC NOT NULL CHECK (close_price > 0),
    high_price  NUMERIC NOT NULL CHECK (high_price  > 0),
    low_price   NUMERIC NOT NULL CHECK (low_price   > 0),
    volume      BIGINT  NOT NULL DEFAULT 0,
    PRIMARY KEY (date, stock_id),
    FOREIGN KEY (stock_id) REFERENCES stocks(stock_id)
);
