"""
Sanity checks every layer of the pipeline after a full run.
"""

import duckdb
import sys

DB_PATH = "marketplace.duckdb"
PASS = "  [PASS]"
FAIL = "  [FAIL]"
errors = []

def check(label, result, expected=None, min_val=None):
    if expected is not None:
        ok = result == expected
    elif min_val is not None:
        ok = result >= min_val
    else:
        ok = bool(result)
    status = PASS if ok else FAIL
    print(f"{status}  {label}: {result}")
    if not ok:
        errors.append(label)

con = duckdb.connect(DB_PATH)

# Check if schemas exist 
print("\n------------------------- Schemas -------------------------")
schemas = [r[0] for r in con.execute("SELECT schema_name FROM information_schema.schemata").fetchall()]
check("staging schema exists", "staging" in schemas, expected=True)
check("warehouse schema exists", "warehouse" in schemas, expected=True)

# Staging row counts 
print("\n------------------------- Staging row counts -------------------------")
for table, min_rows in [
    ("sellers",        100),
    ("products",       500),
    ("orders",         1000),
    ("order_items",    1000),
    ("order_payments", 1000),
]:
    n = con.execute(f"SELECT COUNT(*) FROM staging.{table}").fetchone()[0]
    check(f"staging.{table}", n, min_val=min_rows)

# Warehouse row counts 
print("\n------------------------- Warehouse row counts -------------------------")
for table, min_rows in [
    ("wh_daily_seller_revenue",   100),
    ("wh_daily_category_revenue", 100),
    ("wh_seller_monthly_cohort",  100),
]:
    n = con.execute(f"SELECT COUNT(*) FROM warehouse.{table}").fetchone()[0]
    check(f"warehouse.{table}", n, min_val=min_rows)

# Data cleaning checks 
print("\n------------------------- Cleaning checks -------------------------")

# No null or negative prices survived
n = con.execute("""
    SELECT COUNT(*) FROM staging.order_items
    WHERE price IS NULL OR price <= 0
""").fetchone()[0]
check("No null/negative prices in staging.order_items", n, expected=0)

# No null purchase timestamps survived
n = con.execute("""
    SELECT COUNT(*) FROM staging.orders
    WHERE order_purchase_timestamp IS NULL
""").fetchone()[0]
check("No null purchase timestamps in staging.orders", n, expected=0)

# No item without a matching order
n = con.execute("""
    SELECT COUNT(*) 
    FROM staging.order_items oi
    LEFT JOIN staging.orders o ON oi.order_id = o.order_id
    WHERE o.order_id IS NULL
""").fetchone()[0]
check("No orphan order_items", n, expected=0)

# Seller IDs have no leading/trailing whitespace
n = con.execute("""
    SELECT COUNT(*) FROM staging.sellers
    WHERE seller_id != TRIM(seller_id)
""").fetchone()[0]
check("No whitespace in seller_id", n, expected=0)

# Zip codes are all 8 digits or NULL
n = con.execute("""
    SELECT COUNT(*) FROM staging.sellers
    WHERE seller_zip_code IS NOT NULL AND (LENGTH(seller_zip_code) != 8 OR seller_zip_code SIMILAR TO '%[^0-9]%')
""").fetchone()[0]
check("Zip codes are 8 digits or NULL", n, expected=0)

# No canceled/unavailable orders in warehouse
n = con.execute("""
    SELECT COUNT(DISTINCT oi.order_id)
    FROM staging.order_items oi
    INNER JOIN staging.orders o ON oi.order_id = o.order_id
    WHERE o.order_status IN ('canceled', 'unavailable')
""").fetchone()[0]
check("No canceled orders in warehouse", n, expected=0)

# Date partition checks 
print("\n Date partition checks")

partitions = con.execute("""
    SELECT COUNT(DISTINCT order_date) FROM warehouse.wh_daily_seller_revenue
""").fetchone()[0]
check("Date partitions built", partitions, min_val=100)

date_range = con.execute("""
    SELECT MIN(order_date), MAX(order_date)
    FROM warehouse.wh_daily_seller_revenue
""").fetchone()
check("Earliest partition is before 2017-06-01", str(date_range[0]) < "2017-06-01", expected=True)
check("Latest partition is after 2018-01-01",    str(date_range[1]) > "2018-01-01", expected=True)
print(f"         Date range: {date_range[0]} -> {date_range[1]}")

# Warehouse metric sanity 
print("\n------------------------- Warehouse metric sanity -------------------------")

total_rev = con.execute("""
    SELECT SUM(gross_revenue) 
    FROM warehouse.wh_daily_seller_revenue
""").fetchone()[0]
check("Total gross revenue > 0", total_rev, min_val=1)
print(f"         Total gross revenue: R$ {total_rev:,.2f}")

avg_price = con.execute("""
    SELECT AVG(avg_item_price) 
    FROM warehouse.wh_daily_seller_revenue
""").fetchone()[0]
check("Average item price is realistic (R$10–R$2000)", 10 <= avg_price <= 2000, expected=True)
print(f"         Avg item price: R$ {avg_price:,.2f}")

categories = con.execute("""
    SELECT COUNT(DISTINCT category_name_en) 
    FROM warehouse.wh_daily_category_revenue
""").fetchone()[0]
check("At least 5 categories in warehouse", categories, min_val=5)
print(f"         Distinct categories: {categories}")

# Summary 
print("\n")
if errors:
    print(f"  {len(errors)} check(s) failed:")
    for e in errors:
        print(f"    - {e}")
    sys.exit(1)
else:
    total = con.execute("""
    SELECT COUNT(*)  
    FROM warehouse.wh_daily_seller_revenue
    """).fetchone()[0]
    print(f"  All checks passed!")

con.close()