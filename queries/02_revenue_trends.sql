-- =============================================================================
-- What does the marketplace's revenue look like over time?
-- Identifies seasonality, 7/30-day rolling averages, and week-over-week growth.
-- =============================================================================

WITH RECURSIVE
-- Base: daily revenue per category aggregated from staging
daily_category_revenue AS (
    SELECT
        COALESCE(ct.product_category_name_english,
                 p.product_category_name, 'uncategorized')  AS category_name_en,
        CAST(o.order_purchase_timestamp AS DATE)            AS order_date,
        SUM(oi.price + oi.freight_value)                    AS gross_revenue,
        COUNT(*)                                            AS items_sold,
        COUNT(DISTINCT oi.order_id)                         AS orders_with_category,
        COUNT(DISTINCT oi.seller_id)                        AS active_sellers
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

-- Date spine (generates every date in range, even days with no sales)
-- This prevents misleading gaps in plots

date_spine AS (
    SELECT MIN(order_date) AS d FROM daily_category_revenue
    UNION ALL
    SELECT d + INTERVAL '1 day'
    FROM date_spine
    WHERE d < (SELECT MAX(order_date) FROM daily_category_revenue)
),

-- Aggregate all categories to daily marketplace total
daily_marketplace AS (
    SELECT
        order_date,
        ROUND(SUM(gross_revenue), 2)        AS daily_gross_revenue,
        SUM(items_sold)                     AS daily_items_sold,
        SUM(orders_with_category)           AS daily_orders,
        COUNT(DISTINCT category_name_en)    AS active_categories,
        SUM(active_sellers)                 AS active_sellers
    FROM daily_category_revenue
    GROUP BY order_date
),

-- Left-join spine -> marketplace totals (fills missing days with 0)
spine_joined AS (
    SELECT
        ds.d                                                    AS order_date,
        COALESCE(dm.daily_gross_revenue, 0)                     AS daily_gross_revenue,
        COALESCE(dm.daily_items_sold, 0)                        AS daily_items_sold,
        COALESCE(dm.daily_orders, 0)                            AS daily_orders,
        COALESCE(dm.active_sellers, 0)                          AS active_sellers,
        DAYOFWEEK(ds.d)                                         AS day_of_week,
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

        ROUND(AVG(daily_gross_revenue)
            OVER (ORDER BY order_date
                  ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2)  AS revenue_7d_avg,

        ROUND(AVG(daily_gross_revenue)
            OVER (ORDER BY order_date
                  ROWS BETWEEN 29 PRECEDING AND CURRENT ROW), 2) AS revenue_30d_avg,

        ROUND(SUM(daily_gross_revenue)
            OVER (ORDER BY order_date
                  ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2)  AS revenue_7d_sum,

        COALESCE(LAG(daily_gross_revenue, 7) OVER (ORDER BY order_date), 0) AS revenue_same_day_last_week,

        CASE
            WHEN LAG(daily_gross_revenue, 7) OVER (ORDER BY order_date) = 0 THEN NULL
            ELSE ROUND(
                (daily_gross_revenue - LAG(daily_gross_revenue, 7) OVER (ORDER BY order_date))
                / LAG(daily_gross_revenue, 7) OVER (ORDER BY order_date) * 100
            , 1)
        END AS wow_growth_pct,

        ROUND(SUM(daily_gross_revenue)
            OVER (PARTITION BY YEAR(order_date)
                  ORDER BY order_date
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS ytd_revenue
    FROM spine_joined
)

SELECT *
FROM with_rolling
ORDER BY order_date;
