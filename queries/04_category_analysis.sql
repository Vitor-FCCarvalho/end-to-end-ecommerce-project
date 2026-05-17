-- =============================================================================
-- Category revenue performance: full monthly history with share analysis.
-- One row per (category, month).
-- Use Power BI slicers to pin to a specific month for a snapshot view.
--
-- Replaces:
--   04_category_revenue_mix.sql  — latest-month snapshot with share delta
--   06_category_monthly_rank.sql — historical rank by month
-- =============================================================================

WITH
-- Base: daily revenue per category aggregated from staging
daily_category_revenue AS (
    SELECT
        COALESCE(ct.product_category_name_english,
                 p.product_category_name, 'uncategorized')  AS category_name_en,
        CAST(o.order_purchase_timestamp AS DATE)            AS order_date,
        SUM(oi.price + oi.freight_value)                    AS gross_revenue,
        COUNT(*)                                            AS items_sold,
        COUNT(DISTINCT oi.seller_id)                        AS active_sellers,
        ROUND(AVG(oi.price), 2)                             AS avg_item_price
    FROM staging.order_items oi
    JOIN staging.orders o   ON oi.order_id   = o.order_id
    JOIN staging.products p ON oi.product_id = p.product_id
    LEFT JOIN staging.category_translation ct
           ON p.product_category_name = ct.product_category_name
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY COALESCE(ct.product_category_name_english,
                      p.product_category_name, 'uncategorized'),
             CAST(o.order_purchase_timestamp AS DATE)
),

-- Collapse daily -> monthly, excluding the current partial month
monthly_category AS (
    SELECT
        category_name_en,
        DATE_TRUNC('month', order_date)     AS month,
        SUM(gross_revenue)                  AS monthly_revenue,
        SUM(items_sold)                     AS monthly_items,
        MAX(active_sellers)                 AS active_sellers,
        ROUND(AVG(avg_item_price), 2)       AS avg_item_price
    FROM daily_category_revenue
    GROUP BY category_name_en, DATE_TRUNC('month', order_date)
    HAVING (DATE_TRUNC('month', order_date) + INTERVAL '1 month')
               <= (SELECT MAX(order_date) FROM daily_category_revenue)
),

-- Add revenue share % and rank within each month
with_share AS (
    SELECT
        category_name_en,
        month,
        monthly_revenue,
        monthly_items,
        active_sellers,
        avg_item_price,
        ROUND(
            monthly_revenue * 100.0
            / NULLIF(SUM(monthly_revenue) OVER (PARTITION BY month), 0)
        , 2)                                                            AS revenue_share_pct,
        ROW_NUMBER() OVER (
            PARTITION BY month ORDER BY monthly_revenue DESC, category_name_en ASC
        )                                                               AS rank_in_month
    FROM monthly_category
),

-- Add MoM share delta and per-category lifetime summary (as window functions)
with_delta AS (
    SELECT
        *,
        ROUND(
            revenue_share_pct
            - LAG(revenue_share_pct, 1) OVER (PARTITION BY category_name_en ORDER BY month)
        , 2)                                                            AS share_delta_pp,
        LAG(revenue_share_pct, 1) OVER (
            PARTITION BY category_name_en ORDER BY month
        )                                                               AS prev_month_share_pct,
        -- Per-category lifetime stats — same value for every row of a given category
        COUNT(*) OVER (PARTITION BY category_name_en)                   AS months_active,
        ROUND(AVG(monthly_revenue) OVER (PARTITION BY category_name_en), 2) AS avg_monthly_revenue,
        ROUND(MAX(monthly_revenue) OVER (PARTITION BY category_name_en), 2) AS peak_monthly_revenue
    FROM with_share
)

SELECT
    title_case(REPLACE(category_name_en, '_', ' '))  AS category_name_en,
    CAST(month AS DATE)                              AS month,
    rank_in_month,
    ROUND(monthly_revenue, 2)                        AS monthly_revenue,
    monthly_items,
    active_sellers,
    revenue_share_pct,
    share_delta_pp,
    prev_month_share_pct,
    months_active,
    avg_monthly_revenue,
    peak_monthly_revenue,
    CASE
        WHEN prev_month_share_pct IS NULL AND months_active = 1 THEN 'New'
        WHEN prev_month_share_pct IS NULL AND months_active > 1  THEN 'Returned'
        WHEN share_delta_pp / prev_month_share_pct >=  0.20 THEN 'Gaining Share'
        WHEN share_delta_pp / prev_month_share_pct <= -0.20 THEN 'Losing Share'
        ELSE 'Stable'
    END AS share_trend,
    CASE
        WHEN monthly_revenue > avg_monthly_revenue * 1.1 THEN 'Above Average'
        WHEN monthly_revenue < avg_monthly_revenue * 0.9 THEN 'Below Average'
        ELSE 'On Track'
    END AS revenue_vs_avg
FROM with_delta
ORDER BY month, rank_in_month;
