-- =============================================================================
-- Which sellers show early warning signs of churn?
-- Output: at-risk seller list for proactive outreach, with composite risk score.
-- =============================================================================

WITH
-- Base: aggregate to monthly grain per seller
order_months_raw AS (
    SELECT
        oi.seller_id,
        DATE_TRUNC('month', o.order_purchase_timestamp)     AS year_month,
        oi.price + oi.freight_value                         AS gross_revenue_item,
        oi.order_id
    FROM staging.order_items oi
    JOIN staging.orders o ON oi.order_id = o.order_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
),
seller_monthly_agg AS (
    SELECT
        seller_id,
        year_month,
        SUM(gross_revenue_item)  AS gross_revenue,
        COUNT(DISTINCT order_id) AS orders
    FROM order_months_raw
    GROUP BY seller_id, year_month
),
seller_monthly_cohort AS (
    SELECT
        sma.seller_id,
        sma.year_month,
        sma.gross_revenue,
        sma.orders,
        s.seller_state,
        MIN(sma.year_month) OVER (PARTITION BY sma.seller_id)       AS cohort_month,
        DATEDIFF('month',
            MIN(sma.year_month) OVER (PARTITION BY sma.seller_id),
            sma.year_month
        )                                                            AS months_since_first_sale
    FROM seller_monthly_agg sma
    JOIN staging.sellers s ON sma.seller_id = s.seller_id
),

-- Build time series per seller with month-over-month deltas
seller_timeseries AS (
    SELECT
        seller_id,
        year_month,
        cohort_month,
        months_since_first_sale,
        gross_revenue,
        orders,
        seller_state,

        LAG(gross_revenue, 1) OVER (PARTITION BY seller_id ORDER BY year_month) AS prev_month_revenue,
        LAG(gross_revenue, 3) OVER (PARTITION BY seller_id ORDER BY year_month) AS revenue_3m_ago,

        AVG(gross_revenue) OVER (
            PARTITION BY seller_id
            ORDER BY year_month
            ROWS BETWEEN 5 PRECEDING AND CURRENT ROW
        )                                                                       AS rolling_6m_avg,

        CASE WHEN gross_revenue = 0 THEN 1 ELSE 0 END                           AS is_zero_month,

        SUM(CASE WHEN gross_revenue = 0 THEN 1 ELSE 0 END)
            OVER (PARTITION BY seller_id ORDER BY year_month
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)             AS cumulative_zero_months
    FROM seller_monthly_cohort
),

-- Consecutive zero-month streak (gap-and-island)
zero_streaks AS (
    SELECT
        seller_id,
        year_month,
        is_zero_month,
        ROW_NUMBER() OVER (PARTITION BY seller_id ORDER BY year_month)
        - SUM(is_zero_month) OVER (PARTITION BY seller_id ORDER BY year_month
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS activity_group
    FROM seller_timeseries
),

streak_lengths AS (
    SELECT
        seller_id,
        MAX(year_month)    AS last_seen_month,
        COUNT(*)           AS streak_length,
        MIN(is_zero_month) AS all_zeros_in_streak
    FROM zero_streaks
    WHERE activity_group = (
        SELECT MAX(activity_group)
        FROM zero_streaks z2
        WHERE z2.seller_id = zero_streaks.seller_id
    )
    GROUP BY seller_id
),

-- Each seller's most recent month stats
latest_month AS (
    SELECT DISTINCT ON (seller_id)
        seller_id,
        CAST(year_month AS DATE)    AS latest_month,
        gross_revenue               AS latest_revenue,
        prev_month_revenue,
        revenue_3m_ago,
        rolling_6m_avg,
        months_since_first_sale,
        CAST(cohort_month AS DATE)  AS cohort_month,
        seller_state
    FROM seller_timeseries
    ORDER BY seller_id, year_month DESC
),

-- Compute churn signals
churn_signals AS (
    SELECT
        lm.seller_id,
        lm.seller_state,
        lm.cohort_month,
        lm.months_since_first_sale,
        lm.latest_month,
        ROUND(COALESCE(lm.latest_revenue, 0), 2)    AS latest_revenue,
        ROUND(lm.prev_month_revenue, 2)             AS prev_month_revenue,
        lm.revenue_3m_ago,
        ROUND(lm.rolling_6m_avg, 2)                 AS rolling_6m_avg_revenue,

        CASE
            WHEN lm.prev_month_revenue IS NULL OR lm.prev_month_revenue = 0 THEN NULL
            ELSE ROUND((lm.latest_revenue - lm.prev_month_revenue) / lm.prev_month_revenue * 100, 1)
        END AS mom_revenue_change_pct,

        CASE
            WHEN lm.rolling_6m_avg = 0 OR lm.rolling_6m_avg IS NULL THEN NULL
            ELSE ROUND((lm.latest_revenue - lm.rolling_6m_avg) / lm.rolling_6m_avg * 100, 1)
        END AS vs_baseline_pct,

        sl.streak_length            AS consecutive_zero_months,
        sl.all_zeros_in_streak,

        -- Composite risk score (0–100)
        --   S1 (0–25): MoM revenue drop severity
        --   S2 (0–25): 3-month revenue decay
        --   S3 (0–25): consecutive inactive months
        --   S4 (0–25): revenue below personal 6-month baseline
        ROUND(LEAST(100,
            GREATEST(0, LEAST(25,
                CASE WHEN lm.prev_month_revenue > 0
                     THEN (lm.prev_month_revenue - lm.latest_revenue) / lm.prev_month_revenue * 25
                     ELSE 0 END
            ))
            + GREATEST(0, LEAST(25,
                CASE WHEN lm.revenue_3m_ago > 0
                     THEN (lm.revenue_3m_ago - lm.latest_revenue) / lm.revenue_3m_ago * 25
                     ELSE 0 END
            ))
            + GREATEST(0, LEAST(25,
                CASE WHEN COALESCE(sl.streak_length, 0) >= 2
                     THEN (sl.streak_length - 1) * 25
                     ELSE 0 END
            ))
            + GREATEST(0, LEAST(25,
                CASE WHEN lm.rolling_6m_avg > 0
                     THEN (lm.rolling_6m_avg - lm.latest_revenue) / lm.rolling_6m_avg * 25
                     ELSE 0 END
            ))
        ), 1) AS churn_risk_score
    FROM latest_month lm
    LEFT JOIN streak_lengths sl USING (seller_id)
    WHERE lm.months_since_first_sale >= 3
)

SELECT
    seller_id,
    seller_state,
    cohort_month,
    months_since_first_sale,
    latest_month,
    latest_revenue,
    prev_month_revenue,
    rolling_6m_avg_revenue,
    mom_revenue_change_pct,
    vs_baseline_pct,
    consecutive_zero_months,
    churn_risk_score,

    CASE
        WHEN churn_risk_score >= 60 THEN 'Critical'
        WHEN churn_risk_score >= 40 THEN 'High'
        WHEN churn_risk_score >= 20 THEN 'Medium'
        ELSE 'Low'
    END AS churn_risk_tier,

    CASE
        WHEN churn_risk_score >= 60 THEN 'Immediate outreach (likely churned)'
        WHEN churn_risk_score >= 40 THEN 'Schedule check-in call this week'
        WHEN churn_risk_score >= 20 THEN 'Flag for monthly review'
        ELSE 'Monitor'
    END AS recommended_action

FROM churn_signals
ORDER BY churn_risk_score DESC, months_since_first_sale DESC;
