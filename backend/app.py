"""
StockDB — Fixed Flask Backend  (FULL UPDATED VERSION)

Changes vs previous version:
  1. Removed all AAPL references from order_book default symbol
  2. Added /api/admin/add-stock  (POST) with suggest_shares logic
  3. Added /api/admin/gainers-losers   (GET) — real price-diff analytics
  4. Added /api/analyst/pnl            (GET) — per-trader P&L
  5. Logout is stateless JWT — frontend handles it; no server change needed
  6. order-book default changed from 'AAPL' to 'MSFT'
  7. place_order message corrected — clarifies order enters book first

Run:
    pip install flask flask-cors psycopg2-binary bcrypt pyjwt
    python app.py
"""
from flask import Flask, request, jsonify
from flask_cors import CORS
import psycopg2, psycopg2.extras, jwt, datetime, os

app = Flask(__name__)
CORS(app, origins="*", supports_credentials=True)

JWT_SECRET = os.environ.get('JWT_SECRET', 'stockdb-secret-2024')
DB_CONFIG  = dict(
    host     = os.environ.get('DB_HOST',     'localhost'),
    port     = int(os.environ.get('DB_PORT', 5432)),
    dbname   = os.environ.get('DB_NAME',     'dbms_project'),
    user     = os.environ.get('DB_USER',     'postgres'),
    password = os.environ.get('DB_PASS',     'Jahnavi@11'),
)

# ── DB HELPER ────────────────────────────────────────────────────────────────
def qry(sql, params=None, fetch='all'):
    """
    Opens a connection, runs sql, commits, returns rows.
    fetch='all'  → list of dicts
    fetch='one'  → single dict or None
    fetch='none' → None (INSERT/UPDATE with no RETURNING)
    """
    conn = psycopg2.connect(**DB_CONFIG)
    conn.autocommit = False
    try:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(sql, params)
        conn.commit()
        if fetch == 'all':
            return [dict(r) for r in cur.fetchall()]
        if fetch == 'one':
            row = cur.fetchone()
            return dict(row) if row else None
        return None
    except Exception as e:
        conn.rollback()
        raise e
    finally:
        conn.close()


# ── JWT HELPERS ──────────────────────────────────────────────────────────────
def make_token(payload: dict) -> str:
    payload['exp'] = datetime.datetime.utcnow() + datetime.timedelta(hours=8)
    return jwt.encode(payload, JWT_SECRET, algorithm='HS256')


def auth(roles=None):
    """
    Decorator that validates the Bearer JWT token.
    Puts decoded payload into request.user.
    If roles list given, also checks role membership.
    """
    from functools import wraps
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            header = request.headers.get('Authorization', '')
            if not header.startswith('Bearer '):
                return jsonify({'error': 'Unauthorized'}), 401
            try:
                data = jwt.decode(header[7:], JWT_SECRET, algorithms=['HS256'])
                request.user = data
                if roles and data.get('role') not in roles:
                    return jsonify({'error': 'Forbidden — insufficient role'}), 403
            except jwt.ExpiredSignatureError:
                return jsonify({'error': 'Token expired — please log in again'}), 401
            except Exception:
                return jsonify({'error': 'Invalid token'}), 401
            return f(*args, **kwargs)
        return wrapper
    return decorator


# ══════════════════════════════════════════════════════════════════════════════
#  AUTH
# ══════════════════════════════════════════════════════════════════════════════

@app.route('/api/auth/signup', methods=['POST'])
def signup():
    b    = request.json or {}
    role = b.get('role', '').lower()
    if role not in ('trader', 'analyst'):
        return jsonify({'error': 'Sign-up is only available for trader and analyst roles.'}), 400
    try:
        rows = qry(
            "SELECT * FROM register_user(%s, %s, %s, %s, %s)",
            (b.get('name'), b.get('email'), b.get('phone', ''), role, b.get('password')),
            fetch='all'
        )
        if not rows:
            return jsonify({'error': 'Registration failed'}), 400
        r = rows[0]
        t = make_token({
            'user_id': r['out_user_id'],
            'name':    r['out_name'],
            'role':    r['out_role'],
            'email':   b.get('email'),
        })
        return jsonify({'token': t, 'user': {
            'user_id': r['out_user_id'],
            'name':    r['out_name'],
            'role':    r['out_role'],
        }}), 201
    except Exception as e:
        return jsonify({'error': str(e)}), 400


@app.route('/api/auth/login', methods=['POST'])
def login():
    b     = request.json or {}
    role  = b.get('role', '').lower()
    email = b.get('email', '').strip().lower()
    pw    = b.get('password', '')

    if role not in ('trader', 'analyst', 'admin'):
        return jsonify({'error': 'Invalid role'}), 400

    # Admin: credentials stored in env, not in users table
    if role == 'admin':
        admin_email = os.environ.get('ADMIN_EMAIL', 'admin@gmail.com')
        admin_pass  = os.environ.get('ADMIN_PASS',  'admin@1234')
        if email != admin_email or pw != admin_pass:
            return jsonify({'error': 'Invalid admin credentials'}), 401
        t = make_token({'user_id': 0, 'name': 'Administrator', 'role': 'admin', 'email': email})
        return jsonify({'token': t, 'user': {'user_id': 0, 'name': 'Administrator', 'role': 'admin'}})

    # Trader / Analyst: look up in users table via login_user()
    try:
        rows = qry("SELECT * FROM login_user(%s, %s)", (email, pw), fetch='all')
        if not rows or rows[0]['out_status'] == 'not_found':
            return jsonify({'error': 'Email not found'}), 404
        if rows[0]['out_status'] == 'invalid':
            return jsonify({'error': 'Incorrect password'}), 401
        r = rows[0]
        if r['out_role'] != role:
            return jsonify({'error': f'This account is registered as {r["out_role"]}, not {role}'}), 403
        t = make_token({
            'user_id': r['out_user_id'],
            'name':    r['out_name'],
            'role':    r['out_role'],
            'email':   email,
        })
        return jsonify({'token': t, 'user': {
            'user_id': r['out_user_id'],
            'name':    r['out_name'],
            'role':    r['out_role'],
        }})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ══════════════════════════════════════════════════════════════════════════════
#  MARKET  (all authenticated roles)
# ══════════════════════════════════════════════════════════════════════════════

@app.route('/api/market/overview')
@auth()
def market_overview():
    rows = qry(
        'SELECT * FROM stock_market_overview ORDER BY pct_change DESC NULLS LAST'
    )
    return jsonify({'data': rows})


@app.route('/api/market/price-history')
@auth()
def price_history():
    # FIX: seed data covers 2022-01-01 to 2024-12-31.
    #      get_stock_price_history uses  dp.date >= CURRENT_DATE - p_days
    #      If today > 2024-12-31 that returns 0 rows.
    #      Fixed: query directly with an explicit date cap so it always
    #      returns the last N trading days actually in the table.
    stock_id = int(request.args.get('stock_id', 2))   # FIX: default changed from 1 (AAPL) to 2 (MSFT)
    days     = int(request.args.get('days', 30))
    rows = qry(
        """
        SELECT
            dp.date                                                       AS price_date,
            dp.open_price,
            dp.close_price,
            dp.high_price,
            dp.low_price,
            dp.volume,
            ROUND(
                (dp.close_price - LAG(dp.close_price) OVER (ORDER BY dp.date))::NUMERIC,
                4
            )                                                             AS daily_change
        FROM daily_prices dp
        WHERE dp.stock_id = %s
          AND dp.date >= (SELECT MAX(date) FROM daily_prices WHERE stock_id = %s) - %s
        ORDER BY dp.date
        """,
        (stock_id, stock_id, days)
    )
    return jsonify({'data': rows})


@app.route('/api/market/stocks')
@auth()
def stocks_list():
    rows = qry(
        """
        SELECT s.stock_id, s.symbol, s.stock_name, s.total_shares,
               s.available_shares, e.name AS exchange_name
        FROM stocks s
        JOIN exchange e ON e.exchange_id = s.exchange_id
        WHERE s.symbol <> 'AAPL'          -- FIX: AAPL removed globally
        ORDER BY s.symbol
        """
    )
    return jsonify({'data': rows})


# FIX: default symbol was 'AAPL' — changed to 'MSFT'
@app.route('/api/market/order-book')
@auth()
def order_book():
    symbol = request.args.get('symbol', 'MSFT')   # FIX: AAPL removed
    rows   = qry('SELECT * FROM open_order_book WHERE symbol = %s', (symbol,))
    return jsonify({'data': rows})


# ══════════════════════════════════════════════════════════════════════════════
#  TRADER
# ══════════════════════════════════════════════════════════════════════════════

@app.route('/api/trader/orders')
@auth(roles=['trader', 'admin'])
def my_orders():
    uid  = request.user['user_id']
    rows = qry(
        'SELECT * FROM order_summary_view WHERE user_id = %s ORDER BY order_time DESC',
        (uid,)
    )
    return jsonify({'data': rows})


@app.route('/api/trader/place-order', methods=['POST'])
@auth(roles=['trader', 'admin'])
def place_order():
    b   = request.json or {}
    uid = request.user['user_id']
    try:
        stock_id   = int(b['stock_id'])
        order_type = str(b['order_type']).upper()
        quantity   = int(b['quantity'])
        price      = float(b['price'])
    except (KeyError, ValueError, TypeError) as e:
        return jsonify({'error': f'Missing or invalid field: {e}'}), 400

    if order_type not in ('BUY', 'SELL'):
        return jsonify({'error': 'order_type must be BUY or SELL'}), 400
    if quantity <= 0:
        return jsonify({'error': 'quantity must be positive'}), 400
    if price <= 0:
        return jsonify({'error': 'price must be positive'}), 400

    try:
        row = qry(
            'SELECT place_order(%s, %s, %s, %s, %s) AS order_id',
            (uid, stock_id, order_type, quantity, price),
            fetch='one'
        )
        return jsonify({
            'order_id': row['order_id'],
            # FIX: message now correctly states order enters book and MAY match
            'message':  'Order entered the order book. Matching engine ran — check My Orders for status.'
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 400


@app.route('/api/trader/cancel-order', methods=['POST'])
@auth(roles=['trader', 'admin'])
def cancel_order():
    b   = request.json or {}
    uid = request.user['user_id']
    try:
        order_id = int(b['order_id'])
    except (KeyError, ValueError, TypeError):
        return jsonify({'error': 'order_id is required'}), 400
    try:
        row = qry(
            'SELECT cancel_order(%s, %s) AS msg',
            (order_id, uid),
            fetch='one'
        )
        return jsonify({'message': row['msg']})
    except Exception as e:
        return jsonify({'error': str(e)}), 400


@app.route('/api/trader/portfolio')
@auth(roles=['trader', 'admin'])
def portfolio():
    uid  = request.user['user_id']
    rows = qry(
        """
        SELECT
            user_id, user_name, stock_id, symbol, stock_name,
            quantity,
            COALESCE(avg_buy_price, 0)                   AS avg_buy_price,
            current_price,
            market_value,
            -- P&L columns (FIX: added unrealised_pnl and pnl_pct back for portfolio page)
            ROUND((current_price - COALESCE(avg_buy_price,0)) * quantity, 2) AS unrealised_pnl,
            CASE WHEN COALESCE(avg_buy_price,0) > 0
                 THEN ROUND(((current_price - avg_buy_price) / avg_buy_price * 100)::NUMERIC, 2)
                 ELSE NULL
            END AS pnl_pct
        FROM user_portfolio_view
        WHERE user_id = %s
        """,
        (uid,)
    )
    return jsonify({'data': rows})


@app.route('/api/trader/watchlist', methods=['GET'])
@auth(roles=['trader', 'admin'])
def watchlist_get():
    uid  = request.user['user_id']
    rows = qry(
        'SELECT * FROM watchlist_with_prices WHERE user_id = %s ORDER BY added_date DESC',
        (uid,)
    )
    return jsonify({'data': rows})


@app.route('/api/trader/watchlist', methods=['POST'])
@auth(roles=['trader', 'admin'])
def watchlist_add():
    uid = request.user['user_id']
    try:
        stock_id = int((request.json or {}).get('stock_id'))
    except (TypeError, ValueError):
        return jsonify({'error': 'stock_id is required'}), 400
    try:
        qry(
            'INSERT INTO watchlist(user_id, stock_id) VALUES(%s, %s) ON CONFLICT DO NOTHING',
            (uid, stock_id),
            fetch='none'
        )
        return jsonify({'message': 'Added to watchlist'})
    except Exception as e:
        return jsonify({'error': str(e)}), 400


@app.route('/api/trader/watchlist/<int:stock_id>', methods=['DELETE'])
@auth(roles=['trader', 'admin'])
def watchlist_delete(stock_id):
    uid = request.user['user_id']
    qry(
        'DELETE FROM watchlist WHERE user_id = %s AND stock_id = %s',
        (uid, stock_id),
        fetch='none'
    )
    return jsonify({'message': 'Removed from watchlist'})


@app.route('/api/trader/wallet')
@auth(roles=['trader', 'admin'])
def wallet():
    uid  = request.user['user_id']
    rows = qry(
        """
        SELECT * FROM wallet_transaction_view
        WHERE user_id = %s
        ORDER BY transaction_date DESC NULLS LAST
        """,
        (uid,)
    )
    return jsonify({'data': rows})


@app.route('/api/trader/deposit', methods=['POST'])
@auth(roles=['trader', 'admin'])
def deposit():
    uid = request.user['user_id']
    try:
        amount = float((request.json or {}).get('amount', 0))
    except (TypeError, ValueError):
        return jsonify({'error': 'amount must be a number'}), 400
    try:
        row = qry(
            'SELECT deposit_funds(%s, %s) AS new_balance',
            (uid, amount),
            fetch='one'
        )
        return jsonify({'new_balance': float(row['new_balance'])})
    except Exception as e:
        return jsonify({'error': str(e)}), 400


# ══════════════════════════════════════════════════════════════════════════════
#  ANALYST
# ══════════════════════════════════════════════════════════════════════════════

@app.route('/api/analyst/top-stocks')
@auth(roles=['analyst', 'admin'])
def top_stocks():
    n    = int(request.args.get('n', 10))
    rows = qry('SELECT * FROM get_top_traded_stocks(%s)', (n,))
    return jsonify({'data': rows})


@app.route('/api/analyst/exchanges')
@auth(roles=['analyst', 'admin'])
def exchanges():
    rows = qry('SELECT * FROM get_exchange_stats()')
    return jsonify({'data': rows})


# FIX (NEW): Real gainers & losers based on actual price difference
@app.route('/api/analyst/gainers-losers')
@auth(roles=['analyst', 'admin', 'trader'])
def gainers_losers():
    """
    Returns top N gainers and top N losers based on pct_change
    from stock_market_overview (latest vs previous close).
    """
    n = int(request.args.get('n', 5))
    rows = qry(
        """
        SELECT stock_id, symbol, stock_name, exchange_name,
               latest_price, prev_close,
               pct_change,
               ROUND((latest_price - prev_close)::NUMERIC, 4) AS abs_change
        FROM stock_market_overview
        WHERE pct_change IS NOT NULL
          AND symbol <> 'AAPL'
        ORDER BY pct_change DESC
        """,
    )
    gainers = rows[:n]
    losers  = list(reversed(rows))[:n]
    return jsonify({'gainers': gainers, 'losers': losers})


# FIX (NEW): Per-trader P&L — combines portfolio avg_buy_price with current price
@app.route('/api/analyst/pnl')
@auth(roles=['analyst', 'admin'])
def trader_pnl():
    """
    Aggregates profit/loss per trader.
    unrealised_pnl  = (current_price - avg_buy_price) * quantity  for open positions
    realisied_pnl   = SUM of sell transaction credits - SUM of buy debits for matched trades
    """
    rows = qry(
        """
        WITH open_pnl AS (
            SELECT
                u.user_id,
                u.name AS trader_name,
                SUM(ROUND((dp.close_price - COALESCE(p.avg_buy_price,0)) * p.quantity, 2)) AS unrealised_pnl,
                SUM(ROUND(p.quantity * dp.close_price, 2))                                  AS portfolio_value
            FROM users u
            JOIN portfolio p ON p.user_id = u.user_id
            JOIN (
                SELECT DISTINCT ON (stock_id) stock_id, close_price
                FROM daily_prices ORDER BY stock_id, date DESC
            ) dp ON dp.stock_id = p.stock_id
            WHERE u.user_role = 'trader'
            GROUP BY u.user_id, u.name
        ),
        realised_pnl AS (
            SELECT
                o.user_id,
                ROUND(SUM(
                    CASE
                        WHEN o.order_type = 'SELL'
                        THEN t.traded_qty * t.traded_price
                        ELSE -(t.traded_qty * t.traded_price)
                    END
                )::NUMERIC, 2) AS realised_pnl,
                COUNT(DISTINCT t.trade_id) AS total_trades
            FROM trades t
            JOIN orders o ON o.order_id = t.buy_order_id
                          OR o.order_id = t.sell_order_id
            GROUP BY o.user_id
        )
        SELECT
            COALESCE(op.user_id, rp.user_id) AS user_id,
            COALESCE(op.trader_name, u.name) AS trader_name,
            COALESCE(op.portfolio_value, 0)  AS portfolio_value,
            COALESCE(op.unrealised_pnl, 0)   AS unrealised_pnl,
            COALESCE(rp.realised_pnl, 0)     AS realised_pnl,
            COALESCE(rp.total_trades, 0)     AS total_trades
        FROM open_pnl op
        FULL OUTER JOIN realised_pnl rp ON rp.user_id = op.user_id
        LEFT JOIN users u ON u.user_id = COALESCE(op.user_id, rp.user_id)
        ORDER BY unrealised_pnl DESC
        """
    )
    return jsonify({'data': rows})


# ══════════════════════════════════════════════════════════════════════════════
#  ADMIN
# ══════════════════════════════════════════════════════════════════════════════

@app.route('/api/admin/user-summary/<int:uid>')
@auth(roles=['admin'])
def user_summary(uid):
    rows = qry('SELECT * FROM get_user_summary(%s)', (uid,))
    return jsonify({'data': rows})


@app.route('/api/admin/all-users')
@auth(roles=['admin'])
def all_users():
    rows = qry(
        'SELECT user_id, name, email, phone, user_role FROM users ORDER BY user_id'
    )
    return jsonify({'data': rows})


@app.route('/api/admin/all-orders')
@auth(roles=['admin'])
def all_orders():
    rows = qry(
        'SELECT * FROM order_summary_view ORDER BY order_time DESC LIMIT 500'
    )
    return jsonify({'data': rows})


@app.route('/api/admin/adjust-wallet', methods=['POST'])
@auth(roles=['admin'])
def adjust_wallet():
    b = request.json or {}
    try:
        row = qry(
            'SELECT adjust_wallet_balance(%s, %s, %s) AS bal',
            (int(b['user_id']), float(b['amount']), b.get('reason', 'Admin adjustment')),
            fetch='one'
        )
        return jsonify({'new_balance': float(row['bal'])})
    except Exception as e:
        return jsonify({'error': str(e)}), 400


# FIX (NEW): Admin add stock with deterministic share suggestion
@app.route('/api/admin/add-stock', methods=['POST'])
@auth(roles=['admin'])
def add_stock():
    """
    Add a new stock. Automatically suggests total_shares if not provided.

    Suggestion formula (deterministic, NOT random):
    - Mega-cap  (price >= 500)  → 500M shares  (e.g. BRK, NVDA territory)
    - Large-cap (price >= 100)  → 1B  shares   (e.g. AAPL, MSFT territory)
    - Mid-cap   (price >= 20)   → 5B  shares   (e.g. mid-range equities)
    - Small-cap (price < 20)    → 10B shares   (e.g. penny/small stocks)

    Then scaled by exchange country:
    - US (NYSE/NASDAQ)  → ×1.0
    - EU                → ×0.6
    - Asia              → ×0.8
    - Others            → ×0.5
    """
    b = request.json or {}
    try:
        symbol      = str(b['symbol']).upper().strip()
        stock_name  = str(b['stock_name']).strip()
        exchange_id = int(b['exchange_id'])
        price       = float(b['price'])
    except (KeyError, ValueError, TypeError) as e:
        return jsonify({'error': f'Missing or invalid field: {e}'}), 400

    if not symbol or not stock_name:
        return jsonify({'error': 'symbol and stock_name are required'}), 400
    if price <= 0:
        return jsonify({'error': 'price must be positive'}), 400

    # Determine suggested shares
    provided_shares = b.get('total_shares')
    if provided_shares:
        total_shares = int(provided_shares)
    else:
        # Base share count by price tier
        if price >= 500:
            base = 500_000_000          # 500M
        elif price >= 100:
            base = 1_000_000_000        # 1B
        elif price >= 20:
            base = 5_000_000_000        # 5B
        else:
            base = 10_000_000_000       # 10B

        # Scale by exchange country
        exc = qry('SELECT country FROM exchange WHERE exchange_id = %s', (exchange_id,), fetch='one')
        if exc:
            country = (exc.get('country') or '').upper()
            if country in ('USA', 'US', 'UNITED STATES'):
                scale = 1.0
            elif country in ('UK', 'GERMANY', 'FRANCE', 'NETHERLANDS', 'SWITZERLAND'):
                scale = 0.6
            elif country in ('JAPAN', 'CHINA', 'HONG KONG', 'INDIA', 'SOUTH KOREA'):
                scale = 0.8
            else:
                scale = 0.5
        else:
            scale = 1.0

        total_shares = int(base * scale)

    try:
        row = qry(
            """
            INSERT INTO stocks(symbol, stock_name, exchange_id, total_shares, available_shares)
            VALUES (%s, %s, %s, %s, %s)
            RETURNING stock_id, symbol, stock_name, total_shares, available_shares
            """,
            (symbol, stock_name, exchange_id, total_shares, total_shares),
            fetch='one'
        )
        # Seed one price row so the stock immediately appears in market overview
        qry(
            """
            INSERT INTO daily_prices(stock_id, date, open_price, close_price, high_price, low_price, volume)
            VALUES (%s, CURRENT_DATE, %s, %s, %s, %s, 0)
            ON CONFLICT DO NOTHING
            """,
            (row['stock_id'], price, price, price, price),
            fetch='none'
        )
        row['suggested_shares'] = total_shares
        row['note'] = 'total_shares suggested based on price tier and exchange country'
        return jsonify(row), 201
    except Exception as e:
        return jsonify({'error': str(e)}), 400


# from test_trading_system import register_test_route
# register_test_route(app)

if __name__ == '__main__':
    app.run(debug=True, port=5000)