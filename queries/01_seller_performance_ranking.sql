-- =============================================================================
-- Answers the business questions:  
-- Who are the top sellers by gross revenue in the trailing 90 days
-- and how does their recent 30-day revenue compare to the prior 30 days?
-- =============================================================================


WITH
-- Pull trailing 90-day window from the warehouse
trailing_90d AS (
    SELECT
        seller_id,
        order_date,
        gross_revenue,
        items_sold,
        primary_category
    FROM warehouse.wh_daily_seller_revenue
   WHERE order_date >= (SELECT MAX(order_date) FROM warehouse.wh_daily_seller_revenue) - INTERVAL '90 days' 
   AND order_date   <  (SELECT MAX(order_date) FROM warehouse.wh_daily_seller_revenue)          
),

-- Compute per-seller totals for two sub-periods 
-- Recent 30 days vs. prior 30–60 days (momentum signal)
seller_periods AS (
    SELECT
        seller_id,
        -- Full 90-day total
        ROUND(SUM(gross_revenue), 2)                                AS revenue_90d,
        SUM(items_sold)                                             AS items_90d,

        -- Recent 30 days
        ROUND(SUM(CASE
            WHEN order_date >= (SELECT MAX(order_date) FROM warehouse.wh_daily_seller_revenue) - INTERVAL '30 days'
            THEN gross_revenue ELSE 0 END), 2)                      AS revenue_l30d,

        -- Prior 30 day period 
        ROUND(SUM(CASE
            WHEN order_date >= (SELECT MAX(order_date) FROM warehouse.wh_daily_seller_revenue) - INTERVAL '60 days'
            AND order_date <  (SELECT MAX(order_date) FROM warehouse.wh_daily_seller_revenue) - INTERVAL '30 days'
            THEN gross_revenue ELSE 0 END), 2)                      AS revenue_p30d,

        -- Most popular category (title-cased for display)
        title_case(REPLACE(MODE(primary_category), '_', ' '))       AS top_category,

        -- Days active in the window (seller health signal)
        COUNT(DISTINCT order_date)                                  AS active_days_90d
    FROM trailing_90d
    GROUP BY seller_id
),

-- Derive growth metrics 
seller_growth AS (
    SELECT
        *,
        -- MoM growth rate (handle division by zero for brand-new sellers)
        CASE
            WHEN revenue_p30d = 0 AND revenue_l30d > 0  THEN NULL  -- new seller, no prior
            WHEN revenue_p30d = 0                        THEN 0.0
            ELSE ROUND((revenue_l30d - revenue_p30d) / revenue_p30d * 100, 1)
        END                                                         AS mom_growth_pct,

        -- Revenue rank (dense so ties don't create gaps)
        RANK() OVER (ORDER BY revenue_90d DESC)                     AS revenue_rank,

        -- Quartile bucketing for segmentation (Q1 = top 25%)
        NTILE(4) OVER (ORDER BY revenue_90d DESC)                   AS revenue_quartile,

        -- Running cumulative share of total marketplace revenue
        ROUND(
            SUM(revenue_90d) OVER (ORDER BY revenue_90d DESC
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
            / SUM(revenue_90d) OVER () * 100
        , 1)                                                        AS cumulative_revenue_pct
    FROM seller_periods
),

-- Add seller metadata 
with_seller_info AS (
    SELECT
        sg.seller_id,
        s.seller_city,
        s.seller_state,
        sg.top_category,
        sg.revenue_rank,
        sg.revenue_quartile,
        COALESCE(sg.revenue_90d, 0)                                 AS revenue_90d,
        COALESCE(sg.revenue_l30d, 0)                                AS revenue_l30d,
        COALESCE(sg.revenue_p30d, 0)                                AS revenue_p30d,
        sg.mom_growth_pct,
        sg.items_90d,
        sg.active_days_90d,
        sg.cumulative_revenue_pct,
        CASE WHEN sg.cumulative_revenue_pct <= 80 THEN 1 ELSE 0 END AS is_top80_seller
    FROM seller_growth sg
    LEFT JOIN staging.sellers s USING (seller_id)
)

SELECT *
FROM with_seller_info
ORDER BY revenue_rank;