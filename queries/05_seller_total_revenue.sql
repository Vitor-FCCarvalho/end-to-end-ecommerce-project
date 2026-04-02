-- =============================================================================
-- Total revenue per seller across the full dataset timeframe (Oct 2016 – Sep 2018)
-- Used to compute top 20% seller revenue share in Power BI
-- =============================================================================

SELECT
    r.seller_id,
    s.seller_city,
    s.seller_state,
    ROUND(SUM(r.gross_revenue), 2)      AS total_revenue,
    SUM(r.items_sold)                   AS total_items_sold,
    COUNT(DISTINCT r.order_date)        AS active_days,
    MIN(r.order_date)                   AS first_sale_date,
    MAX(r.order_date)                   AS last_sale_date
FROM warehouse.wh_daily_seller_revenue r
LEFT JOIN staging.sellers s USING (seller_id)
GROUP BY r.seller_id, s.seller_city, s.seller_state
ORDER BY total_revenue DESC;
