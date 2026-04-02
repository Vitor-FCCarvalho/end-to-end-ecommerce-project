-- =============================================================================
-- pipeline/sql/daily_category_revenue.sql
-- =============================================================================
-- Warehouse table: wh_daily_category_revenue
-- Granularity: one row per (category_name_en, order_date)
--
-- WHY THIS TABLE EXISTS:
--   Revenue mix analysis ("which categories are growing?") requires
--   aggregating across all sellers — something neither the seller table
--   nor the raw items table can answer efficiently without a full scan.
--   This table is ~21 categories × 730 days ≈ 15K rows.
--   Any BI query on category trends hits this table instead of 120K+ rows.
--
-- NOTE: seller_id is intentionally OMITTED from GROUP BY.
--   Adding it would multiply the row count by ~3,000 (the number of sellers)
--   and make this table redundant with wh_daily_seller_revenue.
--   For category-level questions, seller granularity is noise.
-- =============================================================================

DELETE FROM warehouse.wh_daily_category_revenue
WHERE order_date = CAST('{{ target_date }}' AS DATE);

INSERT INTO warehouse.wh_daily_category_revenue

WITH base AS (
    SELECT
        COALESCE(ct.product_category_name_english, 'uncategorized') AS category_name_en,
        '{{ target_date }}'::DATE                                    AS order_date,
        oi.price,
        oi.freight_value,
        oi.seller_id,
        oi.order_id,
        oi.product_id
    FROM staging.order_items oi
    INNER JOIN staging.orders o   ON oi.order_id = o.order_id
                                 AND CAST(o.order_purchase_timestamp AS DATE) = CAST('{{ target_date }}' AS DATE)
                                 AND o.order_status NOT IN ('canceled', 'unavailable')
    LEFT  JOIN staging.products p ON oi.product_id = p.product_id
    LEFT  JOIN staging.category_translation ct
           ON p.product_category_name = ct.product_category_name
    WHERE oi.price > 0
),

aggregated AS (
    SELECT
        category_name_en,
        order_date,
        COUNT(*)                               AS items_sold,
        COUNT(DISTINCT order_id)               AS orders_with_category,
        COUNT(DISTINCT seller_id)              AS active_sellers,
        COUNT(DISTINCT product_id)             AS distinct_products,
        ROUND(SUM(price), 2)                   AS product_revenue,
        ROUND(SUM(freight_value), 2)           AS freight_revenue,
        ROUND(SUM(price + freight_value), 2)   AS gross_revenue,
        ROUND(AVG(price), 2)                   AS avg_item_price
    FROM base
    GROUP BY category_name_en, order_date
)

SELECT * FROM aggregated;
