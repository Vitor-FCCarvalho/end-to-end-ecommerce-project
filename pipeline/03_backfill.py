"""
Backfills all date partitions for the daily warehouse tables and rebuilds the monthly cohort table
"""

import duckdb
import re
from datetime import date, timedelta

DB_PATH = "marketplace.duckdb"

def load_sql_template(path: str) -> str:
    with open(path) as f:
        return f.read()

def render(template: str, target_date: date) -> str:
    """Replace {{ target_date }} placeholder with the actual date string."""
    return template.replace("{{ target_date }}", str(target_date))

def get_date_range(con: duckdb.DuckDBPyConnection):
    """Return all distinct order dates present in staging.orders."""
    rows = con.execute("""
        SELECT DISTINCT CAST(order_purchase_timestamp AS DATE) AS order_date
        FROM staging.orders
        WHERE order_purchase_timestamp IS NOT NULL
        ORDER BY order_date
    """).fetchall()
    return [r[0] for r in rows]

def build_daily_partition(con, sql_template: str, target_date: date, table_name: str):
    sql = render(sql_template, target_date)
    con.execute(sql)

def build_monthly_cohort(con):
    sql = load_sql_template("pipeline/sql/seller_monthly_cohort.sql")
    con.execute(sql)

def main():
    con = duckdb.connect(DB_PATH)

    seller_sql   = load_sql_template("pipeline/sql/daily_seller_revenue.sql")
    category_sql = load_sql_template("pipeline/sql/daily_category_revenue.sql")

    print("Fetching date range from staging.orders...")
    dates = get_date_range(con)
    print(f"Found {len(dates)} distinct order dates: {dates[0]} -> {dates[-1]}")

    errors = []

    print("\nBackfilling wh_daily_seller_revenue...")
    for i, d in enumerate(dates):
        try:
            build_daily_partition(con, seller_sql, d, "wh_daily_seller_revenue")
            if (i + 1) % 50 == 0 or i == len(dates) - 1:
                print(f"  [{i+1}/{len(dates)}] {d}")
        except Exception as e:
            print(f"  [{i+1}/{len(dates)}] {d} ✗ {e}")
            errors.append(("wh_daily_seller_revenue", d, str(e)))

    print("\nBackfilling wh_daily_category_revenue...")
    for i, d in enumerate(dates):
        try:
            build_daily_partition(con, category_sql, d, "wh_daily_category_revenue")
            if (i + 1) % 50 == 0 or i == (len(dates) - 1):
                print(f"  [{i+1}/{len(dates)}] {d}")
        except Exception as e:
            print(f"  [{i+1}/{len(dates)}] {d} ✗ {e}")
            errors.append(("wh_daily_category_revenue", d, str(e)))

    print("\nBuilding wh_seller_monthly_cohort...")
    try:
        build_monthly_cohort(con)
        n = con.execute("SELECT COUNT(*) FROM warehouse.wh_seller_monthly_cohort").fetchone()[0]
        print(f"  -> {n:,} rows written")
    except Exception as e:
        print(f" ✗ {e}")
        errors.append(("wh_seller_monthly_cohort", None, str(e)))

    # Summary 
    print("\nBackfill complete!")
    for table in [
        "wh_daily_seller_revenue",
        "wh_daily_category_revenue",
        "wh_seller_monthly_cohort",
    ]:
        try:
            n = con.execute(f"SELECT COUNT(*) FROM warehouse.{table}").fetchone()[0]
            print(f"   warehouse.{table}: {n:,} rows")
        except Exception as e:
            print(f"   warehouse.{table}: ERROR — {e}")

    if errors:
        print(f"\n {len(errors)} partition(s) failed:")
        for table, d, msg in errors:
            print(f"   {table} / {d}: {msg}")
    else:
        print("\nAll partitions succeeded!")

    con.close()


if __name__ == "__main__":
    main()
