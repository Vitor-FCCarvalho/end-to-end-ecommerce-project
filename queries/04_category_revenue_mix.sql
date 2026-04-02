-- =============================================================================
-- Answeres business questions:
--   Which categories are growing their share of marketplace revenue?
--   Which are losing share (even if their absolute revenue is growing)?
--
-- This distinction matters: a category can post record revenue while
-- simultaneously losing relevance because the rest of the marketplace
-- grew faster. Share analysis catches this; absolute analysis misses it.
--
-- Techniques used:
--   • Window functions: SUM OVER (partition by month) for share calculation
--   • LAG() for MoM share delta
--   • ARRAY_AGG for creating sparkline data (list of monthly revenues)
--   • CTE chaining
--   • Subquery in FROM clause for period comparison

-- =============================================================================

WITH
-- Monthly category revenue (collapse daily -> monthly) 
monthly_category AS (
    SELECT
        category_name_en,
        DATE_TRUNC('month', order_date)                     AS month,
        SUM(gross_revenue)                                  AS monthly_revenue,
        SUM(items_sold)                                     AS monthly_items,
        SUM(orders_with_category)                           AS monthly_orders,
        MAX(active_sellers)                                 AS peak_active_sellers,
        ROUND(AVG(avg_item_price), 2)                       AS avg_item_price
    FROM warehouse.wh_daily_category_revenue
    GROUP BY category_name_en, DATE_TRUNC('month', order_date)
),

-- Compute each category's share of total marketplace revenue 
with_share AS (
    SELECT
        category_name_en,
        month,
        monthly_revenue,
        monthly_items,
        peak_active_sellers,
        avg_item_price,
        -- Monthly marketplace total (same denominator for all categories in a month)
        SUM(monthly_revenue) OVER (PARTITION BY month)      AS marketplace_monthly_revenue,
        -- Revenue share (%)
        ROUND(
            monthly_revenue * 100.0
            / NULLIF(SUM(monthly_revenue) OVER (PARTITION BY month), 0)
        , 2)                                                AS revenue_share_pct,
        -- Rank within month
        RANK() OVER (PARTITION BY month ORDER BY monthly_revenue DESC) AS rank_in_month
    FROM monthly_category
),

-- Month-over-month share delta (gaining or losing share?)
with_share_delta AS (
    SELECT
        *,
        LAG(revenue_share_pct, 1) OVER (
            PARTITION BY category_name_en ORDER BY month
        )                                                   AS prev_month_share_pct,
        LAG(monthly_revenue, 1) OVER (
            PARTITION BY category_name_en ORDER BY month
        )                                                   AS prev_month_revenue,
        -- Share delta (positive = gaining share)
        ROUND(revenue_share_pct
        - LAG(revenue_share_pct, 1) OVER (
            PARTITION BY category_name_en ORDER BY month
        ), 2)                                               AS share_delta_pp   -- percentage points
    FROM with_share
),

-- Build sparkline arrays for the dashboard 
-- ARRAY_AGG creates a list of monthly revenues per category 

category_sparklines AS (
    SELECT
        category_name_en,
        COUNT(DISTINCT month)                                   AS months_active,
        ROUND(AVG(monthly_revenue), 2)                          AS avg_monthly_revenue,
        ROUND(MAX(monthly_revenue), 2)                          AS peak_monthly_revenue,
        ROUND(MIN(monthly_revenue), 2)                          AS trough_monthly_revenue
    FROM with_share_delta
    GROUP BY category_name_en
),

-- Global latest month (single value used as the snapshot date for all categories)
global_latest_month AS (
    SELECT MAX(DATE_TRUNC('month', order_date)) AS latest_month
    FROM warehouse.wh_daily_category_revenue
),

-- Latest month snapshot — all categories pinned to the same global latest month
-- Categories with no sales that month get 0 revenue and NULL share/rank
latest_month_snapshot AS (
    SELECT
        wsd.category_name_en,
        glm.latest_month,
        COALESCE(wsd.monthly_revenue, 0)    AS latest_revenue,
        wsd.revenue_share_pct               AS latest_share_pct,
        wsd.rank_in_month                   AS latest_rank,
        wsd.share_delta_pp,
        wsd.prev_month_share_pct,
        wsd.monthly_items,
        wsd.peak_active_sellers
    FROM global_latest_month glm
    -- Cross join to get all categories, then left join to actual data for that month
    CROSS JOIN (SELECT DISTINCT category_name_en FROM with_share_delta) cats
    LEFT JOIN with_share_delta wsd
        ON wsd.category_name_en = cats.category_name_en
        AND wsd.month = glm.latest_month
)

-- Final join: sparklines + latest snapshot 
SELECT
    title_case(REPLACE(lms.category_name_en, '_', ' '))  AS category_name_en,
    CAST(lms.latest_month AS DATE)                      AS latest_month,
    ROUND(lms.latest_revenue, 2)                        AS latest_revenue,
    lms.latest_share_pct,
    lms.latest_rank,
    lms.share_delta_pp,
    lms.prev_month_share_pct,
    lms.monthly_items,
    lms.peak_active_sellers,
    cs.months_active,
    cs.avg_monthly_revenue,
    cs.peak_monthly_revenue,
    -- Trend label for dashboard badges
    CASE
        WHEN lms.share_delta_pp >  1.0 THEN 'Gaining Share'
        WHEN lms.share_delta_pp < -1.0 THEN 'Losing Share'
        ELSE 'Stable'
    END                               AS share_trend,
    -- Absolute revenue trend
    CASE
        WHEN lms.latest_revenue > cs.avg_monthly_revenue * 1.1  THEN 'Above Average'
        WHEN lms.latest_revenue < cs.avg_monthly_revenue * 0.9  THEN 'Below Average'
        ELSE 'On Track'
    END                               AS revenue_vs_avg
FROM latest_month_snapshot lms
LEFT JOIN category_sparklines cs USING (category_name_en)
WHERE lms.latest_revenue > 0
ORDER BY lms.latest_share_pct DESC;
