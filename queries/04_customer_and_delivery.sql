-- =============================================================================
-- Customer & delivery analysis.
-- One row per unique customer (customer_unique_id).
-- =============================================================================

WITH
customers_raw AS (
    SELECT
        customer_id,
        customer_unique_id,
        UPPER(TRIM(customer_state))             AS customer_state,
        title_case(TRIM(customer_city))         AS customer_city
    FROM read_csv_auto('data/olist_customers_dataset.csv',
                       header=true, all_varchar=true)
),

-- Include all customers so that even those that have an order status of canceled/unavailable
-- are still visible
all_customers AS (
    SELECT
        customer_unique_id,
        ANY_VALUE(customer_state)               AS customer_state,
        ANY_VALUE(customer_city)                AS customer_city
    FROM customers_raw
    GROUP BY customer_unique_id
),

-- All completed (non-canceled) orders enriched with customer identity
completed_orders AS (
    SELECT
        o.order_id,
        o.customer_id,
        c.customer_unique_id,
        CAST(o.order_purchase_timestamp AS DATE)            AS order_date,
        o.order_purchase_timestamp,
        o.order_approved_at,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,
        o.order_status,
        -- Delivery time in days (NULL if not yet delivered)
        DATEDIFF('day',
            o.order_purchase_timestamp,
            o.order_delivered_customer_date)                AS delivery_days,
        -- Approval lag in hours
        DATEDIFF('hour',
            o.order_purchase_timestamp,
            o.order_approved_at)                            AS approval_lag_hours,
        -- On-time flag
        CASE
            WHEN o.order_delivered_customer_date IS NOT NULL
             AND o.order_estimated_delivery_date IS NOT NULL
             AND o.order_delivered_customer_date
                 <= o.order_estimated_delivery_date THEN 1
            ELSE 0
        END                                                 AS on_time
    FROM staging.orders o
    JOIN customers_raw c ON o.customer_id = c.customer_id
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
),

-- All orders per customer regardless of status (denominator for incomplete rate)
all_orders AS (
    SELECT
        c.customer_unique_id,
        COUNT(DISTINCT o.order_id)                          AS total_orders_all
    FROM staging.orders o
    JOIN customers_raw c ON o.customer_id = c.customer_id
    GROUP BY c.customer_unique_id
),

-- Canceled / unavailable orders per customer count
incomplete_orders AS (
    SELECT
        c.customer_unique_id,
        COUNT(DISTINCT o.order_id)                          AS canceled_orders
    FROM staging.orders o
    JOIN customers_raw c ON o.customer_id = c.customer_id
    WHERE o.order_status IN ('canceled', 'unavailable')
    GROUP BY c.customer_unique_id
),

-- Revenue per order (order grain, joins back to items)
order_revenue AS (
    SELECT
        oi.order_id,
        SUM(oi.price + oi.freight_value)                    AS order_revenue,
        SUM(oi.freight_value)                               AS order_freight,
        COUNT(*)                                            AS items_in_order
    FROM staging.order_items oi
    GROUP BY oi.order_id
),

revenue_percentiles AS (
    SELECT
        PERCENTILE_CONT(0.80) WITHIN GROUP (ORDER BY total_revenue) AS p80,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY total_revenue) AS p50
    FROM (
        SELECT SUM(orv.order_revenue) AS total_revenue
        FROM completed_orders co
        JOIN order_revenue orv ON co.order_id = orv.order_id
        GROUP BY co.customer_unique_id
    )
),

------------------------------- Customer-level aggregation ---------------------------------------

-- Sequence purchases per customer to find first, second, last order dates
orders_ranked AS (
    SELECT
        co.customer_unique_id,
        co.order_date,
        orv.order_revenue,
        co.delivery_days,
        co.approval_lag_hours,
        co.on_time,
        ROW_NUMBER() OVER (PARTITION BY co.customer_unique_id ORDER BY co.order_date ASC) AS purchase_seq
    FROM completed_orders co
    JOIN order_revenue orv ON co.order_id = orv.order_id
),

second_order AS (
    SELECT
        customer_unique_id,
        order_date                                          AS second_purchase_date
    FROM orders_ranked
    WHERE purchase_seq = 2
),

-- Per-customer delivery experience (completed orders with a recorded delivery date)
customer_delivery AS (
    SELECT
        customer_unique_id,
        COUNT(*)                                            AS delivered_orders,
        SUM(co.on_time)                                     AS on_time_orders,
        ROUND(AVG(delivery_days), 1)                        AS avg_delivery_days,
        MIN(delivery_days)                                  AS min_delivery_days,
        MAX(delivery_days)                                  AS max_delivery_days
    FROM completed_orders co
    JOIN order_revenue orv ON co.order_id = orv.order_id
    WHERE co.delivery_days IS NOT NULL
    GROUP BY customer_unique_id
),

-- Completed-order metrics only 
customer_summary AS (
    SELECT
        customer_unique_id,
        COUNT(DISTINCT co.order_id)                         AS total_orders,
        ROUND(SUM(orv.order_revenue), 2)                    AS total_revenue,
        ROUND(AVG(orv.order_revenue), 2)                    AS avg_order_value,
        CASE
            WHEN ROUND(SUM(orv.order_revenue), 2) >= (SELECT p80 FROM revenue_percentiles)
            THEN 'High (80th pct)'
            WHEN ROUND(SUM(orv.order_revenue), 2) >= (SELECT p50 FROM revenue_percentiles)
            THEN 'Mid (50th pct)'
            ELSE 'Low'
        END                                                 AS revenue_tier,
        MIN(order_date)                                     AS first_purchase_date,
        MAX(order_date)                                     AS last_purchase_date,
        DATE_TRUNC('month', MIN(order_date))                AS cohort_month
    FROM completed_orders co
    JOIN order_revenue orv ON co.order_id = orv.order_id
    GROUP BY customer_unique_id
)

--------------------------------------- Final output --------------------------------------------

SELECT
    ac.customer_unique_id,
    ac.customer_state,
    ac.customer_city,
    CAST(cs.cohort_month AS DATE)                           AS cohort_month,

    -- Purchase behaviour (0 for cancel-only customers)
    COALESCE(cs.total_orders, 0)                            AS total_orders,
    CASE WHEN COALESCE(cs.total_orders, 0) > 1
         THEN 1 ELSE 0 END                                  AS is_repeat_customer,
    cs.first_purchase_date,
    cs.last_purchase_date,
    DATEDIFF('day',
        cs.first_purchase_date,
        cs.last_purchase_date)                              AS customer_lifespan_days,
    -- Days from first to second order (NULL for one-time customers)
    DATEDIFF('day',
        cs.first_purchase_date,
        so.second_purchase_date)                            AS days_to_repeat,

    -- Revenue (0 for cancel-only customers; avg_order_value NULL is intentional)
    COALESCE(cs.total_revenue, 0)                           AS total_revenue,
    cs.avg_order_value,
    COALESCE(cs.revenue_tier, 'No Completed Orders')        AS revenue_tier,

    -- Personal delivery experience (NULL for cancel-only customers)
    cd.delivered_orders,
    cd.on_time_orders,
    cd.avg_delivery_days,
    cd.min_delivery_days,
    cd.max_delivery_days,

    -- Cancellation
    ao.total_orders_all,
    COALESCE(inco.canceled_orders, 0)                       AS canceled_orders,
    CASE WHEN inco.canceled_orders > 0 THEN 1 ELSE 0 END    AS has_cancellation

FROM all_customers ac
LEFT JOIN customer_summary  cs   USING (customer_unique_id)
LEFT JOIN second_order      so   USING (customer_unique_id)
LEFT JOIN customer_delivery cd   USING (customer_unique_id)
LEFT JOIN all_orders        ao   USING (customer_unique_id)
LEFT JOIN incomplete_orders inco USING (customer_unique_id)
ORDER BY COALESCE(cs.total_revenue, 0) DESC;
