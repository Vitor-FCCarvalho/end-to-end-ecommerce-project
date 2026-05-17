"""
Sanity checks the staging layer after ingest.
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

print("\n------------------------- Schema -------------------------")
schemas = [r[0] for r in con.execute("SELECT schema_name FROM information_schema.schemata").fetchall()]
check("staging schema exists", "staging" in schemas, expected=True)

print("\n------------------------- Row counts -------------------------")
for table, min_rows in [
    ("sellers",        100),
    ("products",       500),
    ("orders",        1000),
    ("order_items",   1000),
    ("order_payments", 1000),
]:
    n = con.execute(f"SELECT COUNT(*) FROM staging.{table}").fetchone()[0]
    check(f"staging.{table}", n, min_val=min_rows)

print("\n------------------------- Data integrity -------------------------")

n = con.execute("""
    SELECT COUNT(*) FROM staging.order_items
    WHERE price IS NULL OR price <= 0
""").fetchone()[0]
check("No null/negative prices in staging.order_items", n, expected=0)

n = con.execute("""
    SELECT COUNT(*) FROM staging.orders
    WHERE order_purchase_timestamp IS NULL
""").fetchone()[0]
check("No null purchase timestamps in staging.orders", n, expected=0)

n = con.execute("""
    SELECT COUNT(*)
    FROM staging.order_items oi
    LEFT JOIN staging.orders o ON oi.order_id = o.order_id
    WHERE o.order_id IS NULL
""").fetchone()[0]
check("No orphan order_items", n, expected=0)

print("\n")
if errors:
    print(f"  {len(errors)} check(s) failed:")
    for e in errors:
        print(f"    - {e}")
    sys.exit(1)
else:
    print("  All checks passed!")

con.close()
