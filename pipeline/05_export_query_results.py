"""
Runs each analytical query and exports results as CSVs to be imported in Power BI.
"""

import duckdb
import os

DB_PATH = "marketplace.duckdb"
EXPORT_DIR = "exports"
os.makedirs(EXPORT_DIR, exist_ok=True)

con = duckdb.connect(DB_PATH)
con.create_function("title_case", lambda s: s.title() if s else None, return_type=str)

queries = [
    ("queries/01_seller_performance_ranking.sql", "seller_ranking"),
    ("queries/02_revenue_trends.sql",             "revenue_trends"),
    ("queries/03_churn_risk.sql",                 "churn_risk"),
    ("queries/04_category_revenue_mix.sql",       "category_mix"),
    ("queries/05_seller_total_revenue.sql",       "seller_total_revenue"),
    ("queries/06_category_monthly_rank.sql",      "category_monthly_rank"),
]

for path, name in queries:
    with open(path) as f:
        sql = f.read().strip().rstrip(";")
    out = f"{EXPORT_DIR}/{name}.csv"
    con.execute(f"COPY ({sql}) TO '{out}' (HEADER, DELIMITER ',')")
    n = con.execute(f"SELECT COUNT(*) FROM ({sql})").fetchone()[0]
    print(f"  {name}.csv -> {n:,} rows")

con.close()