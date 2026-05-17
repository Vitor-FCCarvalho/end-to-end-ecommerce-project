"""
Builds and exports a star schema from the staging layer for use in Power BI.

Schema:
    fact_orders:  one row per order item (grain)
    dim_seller:   one row per seller with geolocation
    dim_customer: one row per unique customer with geolocation
    dim_product:  one row per product SKU with English category
    dim_date:     one row per calendar date in the dataset range
"""

import duckdb
import os

DB_PATH   = "marketplace.duckdb"
EXPORT_DIR = "exports/star_schema"
os.makedirs(EXPORT_DIR, exist_ok=True)

con = duckdb.connect(DB_PATH)
con.create_function("title_case", lambda s: s.title() if s else None, return_type=str)

# Helper
def export(name, sql):
    path = f"{EXPORT_DIR}/{name}.csv"
    # Strip trailing semicolon before wrapping in COPY
    clean_sql = sql.strip().rstrip(";")
    con.execute(f"COPY ({clean_sql}) TO '{path}' (HEADER, DELIMITER ',')")
    n = con.execute(f"SELECT COUNT(*) FROM ({clean_sql})").fetchone()[0]
    print(f"  -> {name}.csv  ({n:,} rows)")

# --------------------------------------- fact_orders ---------------------------------------
# Contains one row per order item
# Combines order_items, orders, and payments into a single fact table
# Deduplicates payments by taking the first payment record per order
# (orders with split payments get the primary payment type and total value)

print("Building fact_orders...")
export("fact_orders", """
    WITH payments_deduped AS (
        SELECT DISTINCT ON (order_id)
            order_id,
            payment_type,
            payment_installments,
            SUM(payment_value) OVER (PARTITION BY order_id) AS total_payment_value
        FROM staging.order_payments
        ORDER BY order_id, payment_sequential
    )
    SELECT
        -- Keys
        oi.order_id,
        oi.order_item_id,
        oi.product_id,
        oi.seller_id,
        o.customer_id,
        -- Date key (links to dim_date)
        CAST(o.order_purchase_timestamp AS DATE)        AS order_date,
        -- Measures
        ROUND(oi.price, 2)                              AS price,
        ROUND(oi.freight_value, 2)                      AS freight_value,
        ROUND(oi.price + oi.freight_value, 2)           AS gross_revenue,
        ROUND(p.total_payment_value, 2)                 AS total_payment_value,
        -- Payment attributes
        p.payment_type,
        p.payment_installments,
        -- Order attributes
        o.order_status,
        o.order_purchase_timestamp,
        o.order_approved_at,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,
        -- Delivery performance flag
        CASE
            WHEN o.order_delivered_customer_date IS NOT NULL
               AND o.order_estimated_delivery_date IS NOT NULL
               AND o.order_delivered_customer_date <= o.order_estimated_delivery_date
            THEN TRUE
            ELSE FALSE
        END                                            AS delivered_on_time
    FROM staging.order_items oi
    INNER JOIN staging.orders o          ON oi.order_id  = o.order_id
    LEFT  JOIN payments_deduped p        ON oi.order_id  = p.order_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
""")

# --------------------------------------- dim_seller ---------------------------------------
# One row per seller
# Enriched with geolocation if available

print("Building dim_seller...")
export("dim_seller", """
    WITH geo AS (
        -- Geolocation has multiple rows per zip code — take the first
        SELECT DISTINCT ON (geolocation_zip_code_prefix)
            geolocation_zip_code_prefix AS zip_code,
            TRY_CAST(geolocation_lat AS DOUBLE) AS lat,
            TRY_CAST(geolocation_lng AS DOUBLE) AS lng
        FROM read_csv_auto('data/olist_geolocation_dataset.csv', header=true, all_varchar=true)
        ORDER BY geolocation_zip_code_prefix
    )
    SELECT
        s.seller_id,
        s.seller_zip_code,
        s.seller_city,
        s.seller_state,
        g.lat   AS seller_lat,
        g.lng   AS seller_lng
    FROM staging.sellers s
    LEFT JOIN geo g ON s.seller_zip_code = g.zip_code
""")

# --------------------------------------- dim_customer ---------------------------------------
# One row per unique customer
# Note: Olist generates a new customer_id per order, so we deduplicate
# on customer_unique_id and take the most recent record

print("Building dim_customer...")
export("dim_customer", """
    WITH customers_raw AS (
        SELECT DISTINCT ON (customer_unique_id)
            customer_id,
            customer_unique_id,
            customer_zip_code_prefix                              AS customer_zip_code,
            title_case(TRIM(customer_city))                       AS customer_city,
            UPPER(TRIM(customer_state))                           AS customer_state
        FROM read_csv_auto('data/olist_customers_dataset.csv', header=true, all_varchar=true)
        ORDER BY customer_unique_id, customer_id
    ),
    geo AS (
        SELECT DISTINCT ON (geolocation_zip_code_prefix)
            geolocation_zip_code_prefix                           AS zip_code,
            TRY_CAST(geolocation_lat AS DOUBLE)                   AS lat,
            TRY_CAST(geolocation_lng AS DOUBLE)                   AS lng
        FROM read_csv_auto('data/olist_geolocation_dataset.csv', header=true, all_varchar=true)
        ORDER BY geolocation_zip_code_prefix
    )
    SELECT
        c.customer_id,
        c.customer_unique_id,
        c.customer_zip_code,
        c.customer_city,
        c.customer_state,
        g.lat                                                     AS customer_lat,
        g.lng                                                     AS customer_lng
    FROM customers_raw c
    LEFT JOIN geo g ON LEFT(c.customer_zip_code, 5) = g.zip_code
""")

# --------------------------------------- dim_product ---------------------------------------
# One row per product SKU with English category name

print("Building dim_product...")
export("dim_product", """
    SELECT
        p.product_id,
        title_case(REPLACE(
            COALESCE(ct.product_category_name_english, p.product_category_name, 'uncategorized'), 
            '_', ' ')
        )                                                        AS category_name_en,
        p.product_category_name                                  AS category_name_pt,
        p.product_weight_g,
        p.product_length_cm,
        p.product_height_cm,
        p.product_width_cm,
        p.product_photos_qty
    FROM staging.products p
    LEFT JOIN staging.category_translation ct ON p.product_category_name = ct.product_category_name
""")

# --------------------------------------- dim_date ---------------------------------------
# One row per calendar date in the dataset range

print("Building dim_date...")
export("dim_date", """
    WITH RECURSIVE date_spine AS (
        SELECT MIN(CAST(order_purchase_timestamp AS DATE)) AS d
        FROM staging.orders
       
        UNION ALL
       
        SELECT d + INTERVAL '1 day'
        FROM date_spine
        WHERE d < (SELECT MAX(CAST(order_purchase_timestamp AS DATE)) FROM staging.orders)
    )
    SELECT
        d                                               AS date,
        YEAR(d)                                         AS year,
        MONTH(d)                                        AS month,
        QUARTER(d)                                      AS quarter,
        DAY(d)                                          AS day,
        DAYOFWEEK(d)                                    AS day_of_week_num,
        DAYNAME(d)                                      AS day_name,
        MONTHNAME(d)                                    AS month_name,
        CASE 
            WHEN DAYOFWEEK(d) IN (0, 6) THEN TRUE 
            ELSE FALSE 
        END                                             AS is_weekend,
        DATE_TRUNC('week', d)                           AS week_start,
        DATE_TRUNC('month', d)                          AS month_start,
        DATE_TRUNC('quarter', d)                        AS quarter_start,
        -- ISO year-month label for axis display (e.g. "2018-01")
        STRFTIME(d, '%Y-%m')                            AS year_month_label
    FROM date_spine
    ORDER BY d
""")

# Summary 
print(f"Done. Files written to {EXPORT_DIR}")

con.close()