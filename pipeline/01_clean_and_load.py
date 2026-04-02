"""
Reads raw CSVs -> applies data cleaning -> writes to DuckDB staging schema

Cleaning operations performed:
  1. Deduplicate order_items and orders on natural key
  2. Normalize price / freight strings to DECIMAL (handles "R$ 1,234.56", "1.234,56", "N/A", "", "null", None)
  3. Normalize all date columns to TIMESTAMP (tries 4 formats)
  4. Strip whitespace from seller_id
  5. Titlecase + trim seller_city
  6. Validate seller_zip_code (8 digits, zero-padded, or NULL)
  7. Drop order_items having order_id not in orders
  8. Drop orders with NULL purchase_timestamp

"""

import re
import duckdb
from datetime import datetime

DB_PATH = "marketplace.duckdb"
DATA_DIR = "data"

# ------------------------------------------------ Parse price -------------------------------------------------------
NULL_VARIANTS = {"", "n/a", "null", "none", "na", "#n/a"}

def parse_price(raw) -> float | None:
    """Convert messy price string to float, or None if unparseable."""
    if raw is None:
        return None
    s = str(raw).strip()
    if s.lower() in NULL_VARIANTS:
        return None
    # Remove currency symbol and spaces
    s = re.sub(r"[R$\s]", "", s)
    # Brazilian format: 1.234,56  → detect by trailing comma-decimal
    if re.match(r"^\d{1,3}(\.\d{3})*(,\d{2})?$", s):
        s = s.replace(".", "").replace(",", ".")
    else:
        # Standard / already decimal
        s = s.replace(",", "")
    try:
        return float(s)
    except ValueError:
        return None

# ------------------------------------------------ Parse date --------------------------------------------------
DATE_FORMATS = [
    "%Y-%m-%d %H:%M:%S",
    "%Y/%m/%d %H:%M:%S",
    "%m/%d/%Y %H:%M",
    "%d-%m-%Y",
]

def parse_date(raw) -> str | None:
    
    if raw is None:
        return None
    s = str(raw).strip()
    if s.lower() in NULL_VARIANTS:
        return None
    for fmt in DATE_FORMATS:
        try:
            dt = datetime.strptime(s, fmt)
            return dt.strftime("%Y-%m-%d %H:%M:%S")
        except ValueError:
            continue
    return None

# -------------------------------------------- Clean Zip Code -----------------------------------------------
def clean_zip(raw) -> str | None:
    
    if raw is None:
        return None
    digits = re.sub(r"\D", "", str(raw))
    if len(digits) >= 8:
        return digits[:8]
    if len(digits) > 0:
        return digits.zfill(8)  # pad short zips with zeros
    return None

# ----------------------------------------------- Main ------------------------------------------------------
def main():
    con = duckdb.connect(DB_PATH)

    print("Creating staging schema...")
    con.execute("DROP SCHEMA IF EXISTS staging CASCADE")
    con.execute("CREATE SCHEMA staging")

    # ----------------------------------------------- Sellers -----------------------------------------------
    print("Cleaning sellers...")
    con.create_function("title_case", lambda s: s.strip().title() if s else None, return_type=str)
    con.execute(f"""
        CREATE TABLE staging.sellers AS
        SELECT DISTINCT TRIM(seller_id) AS seller_id, 
                title_case(seller_city) AS seller_city, 
                UPPER(TRIM(seller_state)) AS seller_state,
            CASE
                WHEN LENGTH(REGEXP_REPLACE(seller_zip_code, '[^0-9]', '')) >= 8
                THEN LEFT(REGEXP_REPLACE(seller_zip_code, '[^0-9]', ''), 8)
                WHEN LENGTH(REGEXP_REPLACE(seller_zip_code, '[^0-9]', '')) > 0
                THEN LPAD(REGEXP_REPLACE(seller_zip_code, '[^0-9]', ''), 8, '0')
                ELSE NULL
            END AS seller_zip_code
        FROM read_csv_auto('{DATA_DIR}/olist_sellers_dataset.csv', header=true, types={{'seller_zip_code': 'VARCHAR'}})
        WHERE TRIM(seller_id) IS NOT NULL AND LENGTH(TRIM(seller_id)) > 0
    """)
    seller_count = con.execute("SELECT COUNT(*) FROM staging.sellers").fetchone()[0]
    print(f"  -> {seller_count:,} clean sellers")

    # --------------------------------------------- Clean Products -----------------------------------------------
    print("Cleaning products...")
    con.execute(f"""
        CREATE TABLE staging.products AS
        SELECT DISTINCT
            product_id,
            product_category_name,
            TRY_CAST(product_weight_g AS INTEGER)   AS product_weight_g,
            TRY_CAST(product_length_cm AS INTEGER)  AS product_length_cm,
            TRY_CAST(product_height_cm AS INTEGER)  AS product_height_cm,
            TRY_CAST(product_width_cm AS INTEGER)   AS product_width_cm,
            TRY_CAST(product_photos_qty AS INTEGER) AS product_photos_qty
        FROM read_csv_auto('{DATA_DIR}/olist_products_dataset.csv', header=true)
        WHERE product_id IS NOT NULL
    """)

    # Category translation 
    print("Loading category translation...")
    con.execute(f"""
        CREATE TABLE staging.category_translation AS
        SELECT * FROM read_csv_auto('{DATA_DIR}/product_category_name_translation.csv', header=true)
    """)

    # ----------------------------------------------- Clean Orders -----------------------------------------------
    print("Cleaning orders...")
    
    con.execute(f"""
        CREATE TABLE staging.orders AS
        WITH raw_orders AS (
            SELECT DISTINCT ON (order_id)
                order_id,
                customer_id,
                order_status,
                order_purchase_timestamp,
                order_approved_at,
                order_delivered_carrier_date,
                order_delivered_customer_date,
                order_estimated_delivery_date
            FROM read_csv_auto('{DATA_DIR}/olist_orders_dataset.csv', header=true, all_varchar=true)
            ORDER BY order_id, order_purchase_timestamp
        ),
        cleaned AS (
            SELECT
                order_id,
                customer_id,
                LOWER(TRIM(order_status)) AS order_status,
                -- Try 4 date formats and select first match
                COALESCE(
                    TRY_STRPTIME(order_purchase_timestamp, '%Y-%m-%d %H:%M:%S'),
                    TRY_STRPTIME(order_purchase_timestamp, '%Y/%m/%d %H:%M:%S'),
                    TRY_STRPTIME(order_purchase_timestamp, '%m/%d/%Y %H:%M'),
                    TRY_STRPTIME(order_purchase_timestamp, '%d-%m-%Y')
                ) AS order_purchase_timestamp,
                COALESCE(
                    TRY_STRPTIME(order_approved_at, '%Y-%m-%d %H:%M:%S'),
                    TRY_STRPTIME(order_approved_at, '%Y/%m/%d %H:%M:%S'),
                    TRY_STRPTIME(order_approved_at, '%m/%d/%Y %H:%M'),
                    TRY_STRPTIME(order_approved_at, '%d-%m-%Y')
                ) AS order_approved_at,
                COALESCE(
                    TRY_STRPTIME(order_delivered_customer_date, '%Y-%m-%d %H:%M:%S'),
                    TRY_STRPTIME(order_delivered_customer_date, '%Y/%m/%d %H:%M:%S'),
                    TRY_STRPTIME(order_delivered_customer_date, '%m/%d/%Y %H:%M'),
                    TRY_STRPTIME(order_delivered_customer_date, '%d-%m-%Y')
                )  AS order_delivered_customer_date,
                COALESCE(
                    TRY_STRPTIME(order_estimated_delivery_date, '%Y-%m-%d %H:%M:%S'),
                    TRY_STRPTIME(order_estimated_delivery_date, '%Y/%m/%d %H:%M:%S'),
                    TRY_STRPTIME(order_estimated_delivery_date, '%m/%d/%Y %H:%M'),
                    TRY_STRPTIME(order_estimated_delivery_date, '%d-%m-%Y')
                ) AS order_estimated_delivery_date
            FROM raw_orders
        )
        SELECT * FROM cleaned
        WHERE order_purchase_timestamp IS NOT NULL
    """)
    order_count = con.execute("SELECT COUNT(*) FROM staging.orders").fetchone()[0]
    print(f"  -> {order_count:,} clean orders")

    # ----------------------------------------------- Order_items -----------------------------------------------
    print("Cleaning order_items...")
    con.execute(f"""
        CREATE TABLE staging.order_items AS
        WITH raw_items AS (
            -- Deduplicate on natural key: (order_id, order_item_id, product_id, seller_id)
            SELECT DISTINCT ON (order_id, order_item_id, product_id, seller_id)
                order_id,
                order_item_id,
                product_id,
                TRIM(seller_id)  AS seller_id,
                price,
                freight_value
            FROM read_csv_auto('{DATA_DIR}/olist_order_items_dataset.csv',
                               header=true, all_varchar=true)
            ORDER BY order_id, order_item_id, product_id, seller_id
        ),
        price_parsed AS (
            SELECT
                order_id,
                order_item_id,
                product_id,
                seller_id,
                -- Clean price
                CASE
                    WHEN LOWER(TRIM(price)) IN ('', 'n/a', 'null', 'none') THEN NULL
                    -- European format: has period as thousands sep before comma decimal
                    WHEN REGEXP_MATCHES(
                        REGEXP_REPLACE(REGEXP_REPLACE(price, '[R$\\s]', '', 'g'), '\\.', '', 'g'),
                        '^\\d+,\\d{{2}}$'
                    )
                    THEN TRY_CAST(
                        REPLACE(
                            REGEXP_REPLACE(REGEXP_REPLACE(price, '[R$\\s]', '', 'g'), '\\.', ''),
                            ',', '.'
                        ) AS DOUBLE
                    )
                    ELSE TRY_CAST(
                        REGEXP_REPLACE(REGEXP_REPLACE(price, '[R$\\s,]', '', 'g'), ',', '')
                        AS DOUBLE
                    )
                END AS price,
                CASE
                    WHEN LOWER(TRIM(freight_value)) IN ('', 'n/a', 'null', 'none') THEN NULL
                    WHEN REGEXP_MATCHES(
                        REGEXP_REPLACE(REGEXP_REPLACE(freight_value, '[R$\\s]', '', 'g'), '\\.', '', 'g'),
                        '^\\d+,\\d{{2}}$'
                    )
                    THEN TRY_CAST(
                        REPLACE(
                            REGEXP_REPLACE(REGEXP_REPLACE(freight_value, '[R$\\s]', '', 'g'), '\\.', ''),
                            ',', '.'
                        ) AS DOUBLE
                    )
                    ELSE TRY_CAST(
                        REGEXP_REPLACE(REGEXP_REPLACE(freight_value, '[R$\\s,]', '', 'g'), ',', '')
                        AS DOUBLE
                    )
                END AS freight_value
            FROM raw_items
        )
        SELECT p.*
        FROM price_parsed p
        INNER JOIN staging.orders o ON p.order_id = o.order_id
        WHERE p.price IS NOT NULL AND p.price > 0 AND o.order_status NOT IN ('canceled', 'unavailable')
    """)
    item_count = con.execute("SELECT COUNT(*) FROM staging.order_items").fetchone()[0]
    print(f"  -> {item_count:,} clean order items")

    # ----------------------------------------------- Clean order_payments -----------------------------------------------
    print("Cleaning order_payments...")
    con.execute(f"""
        CREATE TABLE staging.order_payments AS
        WITH raw_pay AS (
            SELECT DISTINCT ON (order_id, payment_sequential)
                order_id,
                payment_sequential,
                LOWER(TRIM(payment_type))  AS payment_type,
                TRY_CAST(payment_installments AS INTEGER) AS payment_installments,
                payment_value
            FROM read_csv_auto('{DATA_DIR}/olist_order_payments_dataset.csv',
                               header=true, all_varchar=true, quote='"')
            ORDER BY order_id, payment_sequential
        )
        SELECT
            order_id,
            payment_sequential,
            payment_type,
            payment_installments,
            CASE
                WHEN LOWER(TRIM(payment_value)) IN ('', 'n/a', 'null', 'none') THEN NULL
                ELSE TRY_CAST(
                    REGEXP_REPLACE(REGEXP_REPLACE(payment_value, '[R$\\s]', '', 'g'), ',', '')
                    AS DOUBLE
                )
            END AS payment_value
        FROM raw_pay
        INNER JOIN staging.orders o USING (order_id)
        WHERE payment_value IS NOT NULL
    """)

    # Summary
    print("\nStaging layer complete.")
    for table in ["sellers", "products", "orders", "order_items", "order_payments"]:
        n = con.execute(f"SELECT COUNT(*) FROM staging.{table}").fetchone()[0]
        print(f"   staging.{table}: {n:,} rows")

    con.close()

if __name__ == "__main__":
    main()
