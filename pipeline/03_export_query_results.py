"""
Runs each analytical query and exports results as CSVs to exports/star_schema/.
"""

import duckdb
import os

DB_PATH    = "marketplace.duckdb"
EXPORT_DIR = "exports/star_schema"
os.makedirs(EXPORT_DIR, exist_ok=True)

con = duckdb.connect(DB_PATH)
con.create_function("title_case", lambda s: s.title() if s else None, return_type=str)

queries = [
    ("queries/01_seller_profile.sql",    "seller_profile"),
    ("queries/02_revenue_trends.sql",    "revenue_trends"),
    ("queries/03_churn_risk.sql",        "churn_risk"),
    ("queries/04_category_analysis.sql", "category_analysis"),
    ("queries/05_customer_and_delivery.sql", "customer_and_delivery"),
]

for path, name in queries:
    with open(path) as f:
        sql = f.read().strip().rstrip(";")
    out = f"{EXPORT_DIR}/{name}.csv"
    con.execute(f"COPY ({sql}) TO '{out}' (HEADER, DELIMITER ',')")
    n = con.execute(f"SELECT COUNT(*) FROM ({sql})").fetchone()[0]
    print(f"  {name}.csv -> {n:,} rows")

con.close()
