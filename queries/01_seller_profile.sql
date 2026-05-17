-- =============================================================================
-- Comprehensive seller profile: lifetime performance + trailing 90-day activity.
-- One row per seller (all sellers with at least one order).
-- =============================================================================

WITH
-- Base: daily revenue per seller aggregated from staging
daily_seller_revenue AS (
    SELECT
        oi.seller_id,
        CAST(o.order_purchase_timestamp AS DATE)                    AS order_date,
        SUM(oi.price + oi.freight_value)                            AS gross_revenue,
        COUNT(*)                                                    AS items_sold,
        MODE(COALESCE(ct.product_category_name_english,
                      p.product_category_name, 'uncategorized'))    AS primary_category
    FROM staging.order_items oi
    JOIN staging.orders o   ON oi.order_id   = o.order_id
    JOIN staging.products p ON oi.product_id = p.product_id
    LEFT JOIN staging.category_translation ct
           ON p.product_category_name = ct.product_category_name
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY oi.seller_id, CAST(o.order_purchase_timestamp AS DATE)
),

-- Lifetime totals per seller
lifetime_totals AS (
    SELECT
        seller_id,
        ROUND(SUM(gross_revenue), 2)        AS total_revenue,
        SUM(items_sold)                     AS total_items_sold,
        COUNT(DISTINCT order_date)          AS active_days,
        MIN(order_date)                     AS first_sale_date,
        MAX(order_date)                     AS last_sale_date
    FROM daily_seller_revenue
    GROUP BY seller_id
),

-- Add lifetime Pareto ranking
lifetime_ranked AS (
    SELECT
        lt.*,
        s.seller_city,
        s.seller_state,
        RANK()   OVER (ORDER BY total_revenue DESC)                 AS lifetime_rank,
        NTILE(4) OVER (ORDER BY total_revenue DESC)                 AS lifetime_quartile,
        ROUND(
            SUM(total_revenue) OVER (ORDER BY total_revenue DESC
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
            / SUM(total_revenue) OVER () * 100
        , 1)                                                        AS cumulative_revenue_pct
    FROM lifetime_totals lt
    LEFT JOIN staging.sellers s USING (seller_id)
),

-- Trailing 90-day window
trailing_90d AS (
    SELECT seller_id, order_date, gross_revenue, items_sold, primary_category
    FROM daily_seller_revenue
    WHERE order_date >= (SELECT MAX(order_date) FROM daily_seller_revenue) - INTERVAL '90 days'
    AND   order_date  < (SELECT MAX(order_date) FROM daily_seller_revenue)
),

-- 90-day sub-period aggregation (recent 30d vs prior 30-60d)
seller_periods AS (
    SELECT
        seller_id,
        ROUND(SUM(gross_revenue), 2)                                AS revenue_90d,
        SUM(items_sold)                                             AS items_90d,

        ROUND(SUM(CASE
            WHEN order_date >= (SELECT MAX(order_date) FROM daily_seller_revenue) - INTERVAL '30 days'
            THEN gross_revenue ELSE 0 END), 2)                      AS revenue_l30d,

        ROUND(SUM(CASE
            WHEN order_date >= (SELECT MAX(order_date) FROM daily_seller_revenue) - INTERVAL '60 days'
            AND  order_date  < (SELECT MAX(order_date) FROM daily_seller_revenue) - INTERVAL '30 days'
            THEN gross_revenue ELSE 0 END), 2)                      AS revenue_p30d,

        title_case(REPLACE(MODE(primary_category), '_', ' '))       AS top_category,
        COUNT(DISTINCT order_date)                                  AS active_days_90d
    FROM trailing_90d
    GROUP BY seller_id
),

-- Derive MoM growth from 90-day sub-periods
seller_growth AS (
    SELECT
        *,
        CASE
            WHEN revenue_p30d = 0 AND revenue_l30d > 0 THEN NULL
            WHEN revenue_p30d = 0                      THEN 0.0
            ELSE ROUND((revenue_l30d - revenue_p30d) / revenue_p30d * 100, 1)
        END                                                         AS mom_growth_pct
    FROM seller_periods
)

SELECT
    lr.seller_id,
    lr.seller_city,
    lr.seller_state,
    -- Lifetime metrics
    lr.total_revenue,
    lr.total_items_sold,
    lr.active_days,
    lr.first_sale_date,
    lr.last_sale_date,
    -- Lifetime Pareto (based on full history — stable classification)
    lr.lifetime_rank,
    lr.lifetime_quartile,
    lr.cumulative_revenue_pct,
    CASE WHEN lr.cumulative_revenue_pct <= 80 THEN 1 ELSE 0 END    AS is_top80_seller,
    -- Trailing 90-day activity (NULL for sellers inactive in this window)
    sg.revenue_90d,
    sg.revenue_l30d,
    sg.revenue_p30d,
    sg.mom_growth_pct,
    sg.top_category,
    sg.items_90d,
    sg.active_days_90d
FROM lifetime_ranked lr
LEFT JOIN seller_growth sg USING (seller_id)
ORDER BY lr.lifetime_rank;
