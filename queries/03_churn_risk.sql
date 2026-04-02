-- =============================================================================
-- Answers the business question:
--   Which sellers show early warning signs of churn? (sellers whose recent revenue is materially declining
--   relative to their own historical baseline, and who haven't sold recently)
-- Output: "At-risk seller list" for proactive outreach
-- =============================================================================

WITH
-- Build a time series per seller with month-over-month deltas 
seller_timeseries AS (
    SELECT
        seller_id,
        year_month,
        cohort_month,
        months_since_first_sale,
        gross_revenue,
        orders,
        seller_state,

        -- Revenue in the previous month
        LAG(gross_revenue, 1) OVER (PARTITION BY seller_id ORDER BY year_month)  AS prev_month_revenue,

        -- Revenue 3 months ago (3-month trend signal)
        LAG(gross_revenue, 3) OVER (PARTITION BY seller_id ORDER BY year_month)  AS revenue_3m_ago,

        -- Rolling 6-month average revenue for this seller (their personal baseline)
        AVG(gross_revenue)    OVER (
            PARTITION BY seller_id
            ORDER BY year_month
            ROWS BETWEEN 5 PRECEDING AND CURRENT ROW
        )                                                                         AS rolling_6m_avg,

        -- Is this month zero revenue? (flag inactivity)
        CASE WHEN gross_revenue = 0 THEN 1 ELSE 0 END                            AS is_zero_month,

        -- Running count of consecutive zero-revenue months
        SUM(CASE WHEN gross_revenue = 0 THEN 1 ELSE 0 END)
            OVER (PARTITION BY seller_id ORDER BY year_month
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)              AS cumulative_zero_months
    FROM warehouse.wh_seller_monthly_cohort
),

-- Consecutive zero-month streak (gap-and-island problem) 
-- For each seller, how many CONSECUTIVE zero-revenue months up to the latest?
zero_streaks AS (
    SELECT
        seller_id,
        year_month,
        is_zero_month,
        -- Assign a group ID to consecutive same-value blocks
        ROW_NUMBER() OVER (PARTITION BY seller_id ORDER BY year_month)
        - SUM(is_zero_month) OVER (PARTITION BY seller_id ORDER BY year_month
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                                                                  AS activity_group
    FROM seller_timeseries
),

streak_lengths AS (
    SELECT
        seller_id,
        MAX(year_month)     AS last_seen_month,
        -- Length of the most recent streak of zeros
        COUNT(*)            AS streak_length,
        MIN(is_zero_month)  AS all_zeros_in_streak  -- 1 if all zero, 0 if mixed
    FROM zero_streaks
    WHERE activity_group = (
        -- Get only the most recent group
        SELECT MAX(activity_group)
        FROM zero_streaks z2
        WHERE z2.seller_id = zero_streaks.seller_id
    )
    GROUP BY seller_id
),

-- Get each seller's most recent month stats 
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

        -- Signal 1: Revenue decline MoM (%)
        CASE
            WHEN lm.prev_month_revenue IS NULL OR lm.prev_month_revenue = 0 THEN NULL
            ELSE ROUND((lm.latest_revenue - lm.prev_month_revenue)/ lm.prev_month_revenue * 100, 1)
        END AS mom_revenue_change_pct,

        -- Signal 2: Revenue vs own 6-month baseline (deviation %)
        CASE
            WHEN lm.rolling_6m_avg = 0 OR lm.rolling_6m_avg IS NULL THEN NULL
            ELSE ROUND((lm.latest_revenue - lm.rolling_6m_avg)/ lm.rolling_6m_avg * 100, 1)
        END AS vs_baseline_pct,

        -- Signal 3: Consecutive inactive months
        sl.streak_length               AS consecutive_zero_months,
        sl.all_zeros_in_streak,

        -- Composite risk score (0–100), continuous:
        --   S1 (0–25): proportional to MoM revenue drop (full 25 at -100% drop)
        --   S2 (0–25): proportional to 3-month revenue decay (full 25 at 100% decay)
        --   S3 (0–25): proportional to consecutive inactive months from 2nd onward (max 25)
        --   S4 (0–25): proportional to revenue below personal 6-month baseline (full 25 at -100%)
        ROUND(LEAST(100,
            -- Signal 1: MoM revenue drop severity (0 = no drop, 25 = total loss)
            GREATEST(0, LEAST(25,
                CASE
                    WHEN lm.prev_month_revenue > 0
                    THEN (lm.prev_month_revenue - lm.latest_revenue) / lm.prev_month_revenue * 25
                    ELSE 0
                END
            ))
            -- Signal 2: 3-month revenue decay (how much has revenue fallen from 3m ago to now)
            + GREATEST(0, LEAST(25,
                CASE
                    WHEN lm.revenue_3m_ago > 0
                    THEN (lm.revenue_3m_ago - lm.latest_revenue) / lm.revenue_3m_ago * 25
                    ELSE 0
                END
            ))
            -- Signal 3: consecutive inactive months (only from 2nd month onward, max 25)
            + GREATEST(0, LEAST(25,
                CASE
                    WHEN COALESCE(sl.streak_length, 0) >= 2
                    THEN (sl.streak_length - 1) * 25
                    ELSE 0
                END
            ))
            -- Signal 4: revenue vs personal 6-month baseline (0 = at baseline, 25 = total loss)
            + GREATEST(0, LEAST(25,
                CASE
                    WHEN lm.rolling_6m_avg > 0
                    THEN (lm.rolling_6m_avg - lm.latest_revenue) / lm.rolling_6m_avg * 25
                    ELSE 0
                END
            ))
        ), 1) AS churn_risk_score
    FROM latest_month lm
    LEFT JOIN streak_lengths sl USING (seller_id)
    WHERE lm.months_since_first_sale >= 3
)

-- Final output with risk tier labeling 
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

    -- Tier for easy dashboard filtering (thresholds based on 0–100 continuous scale)
    CASE
        WHEN churn_risk_score >= 60 THEN 'Critical'
        WHEN churn_risk_score >= 40 AND churn_risk_score < 60 THEN 'High'
        WHEN churn_risk_score >= 20 AND churn_risk_score < 40 THEN 'Medium'
        ELSE 'Low'
    END AS churn_risk_tier,

    -- Recommended action for Partnerships team
    CASE
        WHEN churn_risk_score >= 60 THEN 'Immediate outreach (likely churned)'
        WHEN churn_risk_score >= 40 AND churn_risk_score < 60 THEN 'Schedule check-in call this week'
        WHEN churn_risk_score >= 20 AND churn_risk_score < 40 THEN 'Flag for monthly review'
        ELSE 'Monitor'
    END  AS recommended_action

FROM churn_signals
ORDER BY churn_risk_score DESC, months_since_first_sale DESC;
