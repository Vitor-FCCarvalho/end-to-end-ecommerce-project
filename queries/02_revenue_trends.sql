-- =============================================================================
-- Answers Business Questions:
--   What does the marketplace's revenue look like over the past
--   year? Identify seasonality for days of the week, 7-day and 30-day rolling
--   averages, and week-over-week growth.
-- =============================================================================

WITH
-- Date spine — generates every date in range, even days with $0
-- This prevents misleading "missing bar" gaps in charts.
RECURSIVE date_spine AS (
    SELECT
        MIN(CAST(order_date AS DATE))  AS d
    FROM warehouse.wh_daily_category_revenue

    UNION ALL

    SELECT d + INTERVAL '1 day'
    FROM date_spine
    WHERE d < (SELECT MAX(CAST(order_date AS DATE)) FROM warehouse.wh_daily_category_revenue)
),

-- Aggregate all categories to daily marketplace total 
daily_marketplace AS (
    SELECT
        CAST(order_date AS DATE)         AS order_date,
        ROUND(SUM(gross_revenue), 2)     AS daily_gross_revenue,
        SUM(items_sold)                  AS daily_items_sold,
        SUM(orders_with_category)        AS daily_orders,   -- may double-count multi-category; use MAX if needed
        COUNT(DISTINCT category_name_en) AS active_categories,
        SUM(active_sellers)              AS active_sellers
    FROM warehouse.wh_daily_category_revenue
    GROUP BY CAST(order_date AS DATE)
),

-- Left-join spine -> marketplace totals (fills missing days with 0) 
spine_joined AS (
    SELECT
        ds.d                                                    AS order_date,
        COALESCE(dm.daily_gross_revenue, 0)                     AS daily_gross_revenue,
        COALESCE(dm.daily_items_sold, 0)                        AS daily_items_sold,
        COALESCE(dm.daily_orders, 0)                            AS daily_orders,
        COALESCE(dm.active_sellers, 0)                          AS active_sellers,
        DAYOFWEEK(ds.d)                                         AS day_of_week,   -- 0=Sun, 6=Sat
        DAYNAME(ds.d)                                           AS day_name,    
        CASE WHEN DAYOFWEEK(ds.d) IN (0, 6) THEN 'Weekend' ELSE 'Weekday' END AS day_type
    FROM date_spine ds
    LEFT JOIN daily_marketplace dm ON ds.d = dm.order_date
),

-- Rolling averages and WoW comparison 
with_rolling AS (
    SELECT
        order_date,
        day_name,
        day_type,
        daily_gross_revenue,
        daily_orders,
        active_sellers,

        -- 7-day rolling average (smooths day-of-week noise)
        ROUND(AVG(daily_gross_revenue)
            OVER (ORDER BY order_date
                  ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2) AS revenue_7d_avg,

        -- 30-day rolling average 
        ROUND(AVG(daily_gross_revenue)
            OVER (ORDER BY order_date
                  ROWS BETWEEN 29 PRECEDING AND CURRENT ROW), 2) AS revenue_30d_avg,

        -- 7-day rolling sum (useful for "this week vs last week" cards)
        ROUND(SUM(daily_gross_revenue)
            OVER (ORDER BY order_date
                  ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2) AS revenue_7d_sum,

        -- Week-over-week: compare to same day 7 days ago (0 for first 7 days)
        COALESCE(LAG(daily_gross_revenue, 7) OVER (ORDER BY order_date), 0) AS revenue_same_day_last_week,

        -- Week-over-week growth pct
        CASE
            WHEN LAG(daily_gross_revenue, 7) OVER (ORDER BY order_date) = 0 THEN NULL
            ELSE ROUND( 
                (daily_gross_revenue - LAG(daily_gross_revenue, 7) OVER (ORDER BY order_date))
                / LAG(daily_gross_revenue, 7) OVER (ORDER BY order_date) * 100
            , 1)
        END AS wow_growth_pct,

        -- Cumulative YTD revenue 
        ROUND(SUM(daily_gross_revenue)
            OVER (PARTITION BY YEAR(order_date)
                  ORDER BY order_date
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS ytd_revenue
    FROM spine_joined
)

SELECT *
FROM with_rolling
ORDER BY order_date;
