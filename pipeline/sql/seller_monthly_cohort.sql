-- =============================================================================
-- pipeline/sql/seller_monthly_cohort.sql
-- =============================================================================
-- Warehouse table: wh_seller_monthly_cohort
-- Granularity: one row per (seller_id, year_month)
--
-- WHY THIS TABLE EXISTS:
--   Churn detection requires looking at a seller's revenue OVER TIME — whether
--   they're accelerating, flat, or declining. Month-over-month is the natural
--   cadence for this; daily data creates noise.
--   This table also captures the seller's cohort (first month they sold) so
--   we can compute "months since first sale" — critical for lifecycle analysis.
--   ~3,000 sellers × 24 months = 72K rows max (vs. 120K+ raw item rows).
--
-- This table is rebuilt monthly in full (no date partition parameter).
-- It replaces itself on each run.
-- =============================================================================

DROP TABLE IF EXISTS warehouse.wh_seller_monthly_cohort;

CREATE TABLE warehouse.wh_seller_monthly_cohort AS

WITH seller_first_sale AS (
    -- When did each seller make their first sale?
    SELECT
        seller_id,
        DATE_TRUNC('month', MIN(order_purchase_timestamp))  AS cohort_month
    FROM staging.order_items oi
    INNER JOIN staging.orders o USING (order_id)
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY seller_id
),

monthly_sales AS (
    SELECT
        oi.seller_id,
        DATE_TRUNC('month', o.order_purchase_timestamp)     AS year_month,
        COUNT(*)                                            AS items_sold,
        COUNT(DISTINCT o.order_id)                          AS orders,
        COUNT(DISTINCT oi.product_id)                       AS distinct_products,
        ROUND(SUM(oi.price), 2)                             AS product_revenue,
        ROUND(SUM(oi.freight_value), 2)                     AS freight_revenue,
        ROUND(SUM(oi.price + oi.freight_value), 2)          AS gross_revenue,
        ROUND(AVG(oi.price), 2)                             AS avg_item_price
    FROM staging.order_items oi
    INNER JOIN staging.orders o USING (order_id)
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
      AND oi.price > 0
    GROUP BY oi.seller_id, DATE_TRUNC('month', o.order_purchase_timestamp)
)

SELECT
    ms.seller_id,
    ms.year_month,
    -- Cohort fields
    sfs.cohort_month,
    -- Months since first sale (for lifecycle analysis)
    DATEDIFF('month', sfs.cohort_month, ms.year_month)  AS months_since_first_sale,
    -- Sales metrics
    ms.items_sold,
    ms.orders,
    ms.distinct_products,
    ms.product_revenue,
    ms.freight_revenue,
    ms.gross_revenue,
    ms.avg_item_price,
    -- Seller geography (join once here so queries don't need to join sellers)
    s.seller_city,
    s.seller_state
FROM monthly_sales ms
LEFT JOIN seller_first_sale sfs USING (seller_id)
LEFT JOIN staging.sellers     s  USING (seller_id)
ORDER BY ms.seller_id, ms.year_month;
