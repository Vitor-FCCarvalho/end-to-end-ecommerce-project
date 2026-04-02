"""
Creates the warehouse schema and table definitions.
"""

import duckdb

DB_PATH = "marketplace.duckdb"

WAREHOUSE_DDL = """
DROP SCHEMA IF EXISTS warehouse CASCADE;
CREATE SCHEMA warehouse;

-- Daily seller revenue 
CREATE TABLE warehouse.wh_daily_seller_revenue (
    seller_id               VARCHAR         NOT NULL,
    order_date              DATE            NOT NULL,
    items_sold              INTEGER,
    distinct_products_sold  INTEGER,
    distinct_categories     INTEGER,
    product_revenue         DOUBLE,
    freight_revenue         DOUBLE,
    gross_revenue           DOUBLE,
    avg_item_price          DOUBLE,
    min_item_price          DOUBLE,
    max_item_price          DOUBLE,
    primary_category        VARCHAR,
    PRIMARY KEY (seller_id, order_date)
);

-- Daily category revenue 
CREATE TABLE warehouse.wh_daily_category_revenue (
    category_name_en        VARCHAR        NOT NULL,
    order_date              DATE           NOT NULL,
    items_sold              INTEGER,
    orders_with_category    INTEGER,
    active_sellers          INTEGER,
    distinct_products       INTEGER,
    product_revenue         DOUBLE,
    freight_revenue         DOUBLE,
    gross_revenue           DOUBLE,
    avg_item_price          DOUBLE,
    PRIMARY KEY (category_name_en, order_date)
);

-- Seller monthly cohort
CREATE TABLE warehouse.wh_seller_monthly_cohort (
    seller_id               VARCHAR,
    year_month              TIMESTAMP,
    cohort_month            TIMESTAMP,
    months_since_first_sale INTEGER,
    items_sold              INTEGER,
    orders                  INTEGER,
    distinct_products       INTEGER,
    product_revenue         DOUBLE,
    freight_revenue         DOUBLE,
    gross_revenue           DOUBLE,
    avg_item_price          DOUBLE,
    seller_city             VARCHAR,
    seller_state            VARCHAR
);
"""

def main():
    con = duckdb.connect(DB_PATH)
    print("Building warehouse schema and tables...")
    con.execute(WAREHOUSE_DDL)
    print("Warehouse DDL applied!")

    tables = con.execute("""
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'warehouse'
        ORDER BY table_name
    """).fetchall()

    for (t,) in tables:
        print(f"   warehouse.{t}")
    con.close()

if __name__ == "__main__":
    main()
