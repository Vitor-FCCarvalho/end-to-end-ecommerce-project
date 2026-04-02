-- =============================================================================
-- pipeline/sql/daily_seller_revenue.sql
-- =============================================================================
-- Warehouse table: wh_daily_seller_revenue
-- Granularity: one row per (seller_id, order_date)
--
-- WHY THIS TABLE EXISTS:
--   The raw order_items table has one row per item (~120K rows for this
--   dataset). A revenue dashboard querying "last 30 days by seller" would
--   scan the entire table and join to orders, products, and sellers on every
--   execution. This table pre-aggregates that join into ~(sellers × days)
--   rows — roughly a 40–60× reduction — making BI queries run in milliseconds.
--
-- PARTITIONED BY: order_date (DATE)
--   The build pipeline writes one date at a time (see 03_backfill.py).
--   Each run deletes and replaces the target date, making it idempotent.
--
-- PARAMETERS (injected by the pipeline):
--   :target_date  — the date partition to build (e.g., '2018-01-15')
-- =============================================================================

-- Step 1: Delete existing partition (idempotency)
DELETE FROM warehouse.wh_daily_seller_revenue
WHERE order_date = CAST('{{ target_date }}' AS DATE);

-- Step 2: Insert fresh partition
INSERT INTO warehouse.wh_daily_seller_revenue

WITH orders_on_date AS (
    -- Filter to only the target date partition up front.
    -- In BigQuery/Snowflake, this prunes the partition scan automatically.
    SELECT order_id
    FROM staging.orders
    WHERE CAST(order_purchase_timestamp AS DATE) = CAST('{{ target_date }}' AS DATE)
      AND order_status NOT IN ('canceled', 'unavailable')  -- exclude non-revenue orders
),

items_joined AS (
    SELECT
        oi.seller_id,
        '{{ target_date }}'::DATE                       AS order_date,
        p.product_id,
        ct.product_category_name_english                AS category_name_en,
        oi.price,
        oi.freight_value,
        oi.price + oi.freight_value                     AS gross_revenue
    FROM staging.order_items oi
    INNER JOIN orders_on_date od   USING (order_id)
    LEFT  JOIN staging.products p  USING (product_id)
    LEFT  JOIN staging.category_translation ct
           ON p.product_category_name = ct.product_category_name
    -- Seller must exist in our clean sellers table (referential integrity)
    INNER JOIN staging.sellers s   USING (seller_id)
    WHERE oi.price > 0  -- sanity guard: no zero or negative prices
),

aggregated AS (
    SELECT
        seller_id,
        order_date,
        -- Revenue metrics
        COUNT(*)                                        AS items_sold,
        COUNT(DISTINCT product_id)                      AS distinct_products_sold,
        COUNT(DISTINCT category_name_en)                AS distinct_categories,
        ROUND(SUM(price), 2)                            AS product_revenue,
        ROUND(SUM(freight_value), 2)                    AS freight_revenue,
        ROUND(SUM(gross_revenue), 2)                    AS gross_revenue,
        ROUND(AVG(price), 2)                            AS avg_item_price,
        ROUND(MIN(price), 2)                            AS min_item_price,
        ROUND(MAX(price), 2)                            AS max_item_price,
        -- Top category for this seller on this day (for quick dashboarding)
        MODE(category_name_en)                          AS primary_category
    FROM items_joined
    GROUP BY seller_id, order_date
)

SELECT * FROM aggregated;
