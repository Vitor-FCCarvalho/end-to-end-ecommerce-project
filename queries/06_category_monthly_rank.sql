-- =============================================================================
-- Monthly category rank over time
-- =============================================================================

WITH
monthly_category AS (
    SELECT
        category_name_en,
        DATE_TRUNC('month', order_date)             AS month,
        ROUND(SUM(gross_revenue), 2)                AS monthly_revenue,
        SUM(items_sold)                             AS monthly_items
    FROM warehouse.wh_daily_category_revenue
    GROUP BY category_name_en, DATE_TRUNC('month', order_date)
),

with_rank AS (
    SELECT
        category_name_en,
        month,
        monthly_revenue,
        monthly_items,
        ROW_NUMBER() OVER (PARTITION BY month ORDER BY monthly_revenue DESC, category_name_en ASC) AS rank_in_month,
        ROUND(
            monthly_revenue * 100.0
            / NULLIF(SUM(monthly_revenue) OVER (PARTITION BY month), 0)
        , 2)                                        AS revenue_share_pct
    FROM monthly_category
)

SELECT
    title_case(REPLACE(category_name_en, '_', ' ')) AS category_name_en,
    CAST(month AS DATE)                             AS month,
    rank_in_month,
    monthly_revenue,
    revenue_share_pct
FROM with_rank
ORDER BY month, rank_in_month;
