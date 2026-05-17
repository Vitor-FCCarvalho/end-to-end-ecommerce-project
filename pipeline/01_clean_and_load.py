"""
Loads Kaggle CSVs into DuckDB staging schema with type normalization.
"""

import duckdb

DB_PATH  = "marketplace.duckdb"
DATA_DIR = "data"


def main():
    con = duckdb.connect(DB_PATH)
    con.create_function("title_case", lambda s: s.title() if s else None, return_type=str)

    print("Creating staging schema...")
    con.execute("DROP SCHEMA IF EXISTS staging CASCADE")
    con.execute("CREATE SCHEMA staging")

    print("Loading sellers...")
    con.execute(f"""
        CREATE TABLE staging.sellers AS
        SELECT
            seller_id,
            LPAD(seller_zip_code_prefix, 5, '0') AS seller_zip_code,
            title_case(TRIM(seller_city))         AS seller_city,
            UPPER(TRIM(seller_state))             AS seller_state
        FROM read_csv_auto('{DATA_DIR}/olist_sellers_dataset.csv',
                           header=true, types={{'seller_zip_code_prefix': 'VARCHAR'}})
    """)

    print("Loading products...")
    con.execute(f"""
        CREATE TABLE staging.products AS
        SELECT
            product_id,
            product_category_name,
            TRY_CAST(product_weight_g   AS INTEGER) AS product_weight_g,
            TRY_CAST(product_length_cm  AS INTEGER) AS product_length_cm,
            TRY_CAST(product_height_cm  AS INTEGER) AS product_height_cm,
            TRY_CAST(product_width_cm   AS INTEGER) AS product_width_cm,
            TRY_CAST(product_photos_qty AS INTEGER) AS product_photos_qty
        FROM read_csv_auto('{DATA_DIR}/olist_products_dataset.csv', header=true)
        WHERE product_id IS NOT NULL
    """)

    print("Loading category translation...")
    con.execute(f"""
        CREATE TABLE staging.category_translation AS
        SELECT product_category_name, product_category_name_english
        FROM read_csv_auto('{DATA_DIR}/product_category_name_translation.csv', header=true)
    """)

    print("Loading orders...")
    con.execute(f"""
        CREATE TABLE staging.orders AS
        SELECT
            order_id,
            customer_id,
            order_status,
            TRY_CAST(order_purchase_timestamp      AS TIMESTAMP) AS order_purchase_timestamp,
            TRY_CAST(order_approved_at             AS TIMESTAMP) AS order_approved_at,
            TRY_CAST(order_delivered_carrier_date  AS TIMESTAMP) AS order_delivered_carrier_date,
            TRY_CAST(order_delivered_customer_date AS TIMESTAMP) AS order_delivered_customer_date,
            TRY_CAST(order_estimated_delivery_date AS TIMESTAMP) AS order_estimated_delivery_date
        FROM read_csv_auto('{DATA_DIR}/olist_orders_dataset.csv', header=true, all_varchar=true)
        WHERE order_purchase_timestamp IS NOT NULL
    """)

    print("Loading order items...")
    con.execute(f"""
        CREATE TABLE staging.order_items AS
        SELECT
            order_id,
            order_item_id,
            product_id,
            seller_id,
            TRY_CAST(price         AS DOUBLE) AS price,
            TRY_CAST(freight_value AS DOUBLE) AS freight_value
        FROM read_csv_auto('{DATA_DIR}/olist_order_items_dataset.csv', header=true, all_varchar=true)
        WHERE order_id IN (SELECT order_id FROM staging.orders)
    """)

    print("Loading order payments...")
    con.execute(f"""
        CREATE TABLE staging.order_payments AS
        SELECT
            order_id,
            payment_sequential,
            payment_type,
            TRY_CAST(payment_installments AS INTEGER) AS payment_installments,
            TRY_CAST(payment_value        AS DOUBLE)  AS payment_value
        FROM read_csv_auto('{DATA_DIR}/olist_order_payments_dataset.csv', header=true, all_varchar=true)
    """)

    print("\nStaging layer complete.")
    for table in ["sellers", "products", "orders", "order_items", "order_payments"]:
        n = con.execute(f"SELECT COUNT(*) FROM staging.{table}").fetchone()[0]
        print(f"   staging.{table}: {n:,} rows")

    con.close()


if __name__ == "__main__":
    main()
