# 📈 Online Stock Trading System (TradeLedger)

A full-stack **Online Stock Trading System** that simulates real-world stock exchange operations using **PostgreSQL**, **Flask**, **Python**, **HTML**, **CSS**, and **JavaScript**. The application enables users to trade stocks through a secure platform while maintaining data integrity using advanced database concepts.

---

## 🚀 Features

### 👤 Trader
- Secure user registration and login (JWT Authentication)
- Buy and sell stocks using limit orders
- Portfolio management with unrealized P&L
- Wallet management and transaction history
- Watchlist management
- Live market overview
- Stock price history
- Order book visualization

### 📊 Analyst
- Market overview and analytics
- Top traded stocks
- Exchange statistics
- Profit & Loss analysis
- Read-only market access

### 🛡️ Admin
- Manage users
- Add new stocks
- Adjust wallet balances
- Monitor all orders and trades
- View market gainers and losers

---

## 🛠️ Tech Stack

### Frontend
- HTML
- CSS
- JavaScript

### Backend
- Python
- Flask

### Database
- PostgreSQL

### Authentication
- JWT (JSON Web Token)

---

## 🗄️ Database Concepts Used

- Relational Database Design
- SQL
- Joins
- Constraints
- Views
- Stored Procedures
- Functions
- Triggers
- Indexes
- Transactions (ACID Properties)
- Role-Based Access Control (RBAC)

---

## 📂 Project Structure

```
online-stock-trading-system/
│
├── backend/
│   └── app.py
│
├── database/
│   ├── tables.sql
│   ├── roles_indices.sql
│   ├── views.sql
│   ├── functions.sql
│   ├── triggers.sql
│   ├── seed_data.sql
│
├── frontend/
│   └── trading_dashboard.html
│
├── report/
│   └── DBMS Final Report.pdf
│
├── screenshots/
│
└── README.md
```

---

## 💡 Key Highlights

- Real-world stock trading simulation
- Automated order matching engine
- Secure authentication using JWT
- Database-driven application
- Optimized SQL queries using indexes
- Trigger-based automatic updates
- Role-based authorization
- Modular Flask REST API

---

## ⚙️ Getting Started

### Clone the Repository

```bash
git clone https://github.com/your-username/online-stock-trading-system.git
```

### Navigate to the Project

```bash
cd online-stock-trading-system
```

### Install Dependencies

```bash
pip install flask flask-cors psycopg2-binary bcrypt pyjwt
```

### Configure PostgreSQL

Create the database and execute the SQL scripts in the following order:

1. tables.sql
2. roles_indices.sql
3. views.sql
4. functions.sql
5. triggers.sql
6. seed_data.sql

### Run the Application

```bash
python app.py
```

Open the frontend in your browser and start exploring the application.

---

## 🎯 Learning Outcomes

Through this project, I gained practical experience in:

- Database Design
- PostgreSQL
- SQL Query Optimization
- Stored Procedures
- Triggers
- Views
- Indexing
- Flask REST APIs
- JWT Authentication
- Database Testing
- Version Control with Git & GitHub

---

## 📜 License

This project was developed for academic and learning purposes.
