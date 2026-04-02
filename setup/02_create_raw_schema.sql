-- =======================================================================================
-- Raw ingestion layer matching the structure of each csv file in the Olist dataset
-- =======================================================================================

-- Drop and recreate raw schema for idempotency
DROP SCHEMA IF EXISTS raw CASCADE;
CREATE SCHEMA raw;

-- -- ------------------------------------------------------------------------------------
-- Create orders table, which contains one order per row
-- -- ------------------------------------------------------------------------------------
CREATE TABLE raw.orders(
    order_id                          VARCHAR,
    customer_id                       VARCHAR,
    order_status                      VARCHAR,    
    order_purchase_timestamp          VARCHAR,     
    order_approved_at                 VARCHAR,
    order_delivered_carrier_date      VARCHAR,
    order_delivered_customer_date     VARCHAR,
    order_estimated_delivery_date     VARCHAR
);

-- -- ------------------------------------------------------------------------------------
-- Create order_items table, which contains one row per item within an order
-- A single order can contain multiple items from muliple sellers
-- -- ------------------------------------------------------------------------------------
CREATE TABLE raw.order_items(
    order_id              VARCHAR,
    order_item_id         INTEGER,    
    product_id            VARCHAR,
    seller_id             VARCHAR,
    shipping_limit_date   VARCHAR,
    price                 VARCHAR,    
    freight_value         VARCHAR
);

-- -- ------------------------------------------------------------------------------------
-- Creates order_payments table, which contains one row per payment method per order
-- Orders can have multiple payment types 
-- -- ------------------------------------------------------------------------------------
CREATE TABLE raw.order_payments(
    order_id              VARCHAR,
    payment_sequential    INTEGER,
    payment_type          VARCHAR,    
    payment_installments  INTEGER,
    payment_value         VARCHAR     
);

-- -- ------------------------------------------------------------------------------------
-- Create products table, containing one row per product SKU
-- -- ------------------------------------------------------------------------------------
CREATE TABLE raw.products(
    product_id                   VARCHAR,
    product_category_name        VARCHAR,    
    product_name_length          VARCHAR,
    product_description_length   VARCHAR,
    product_photos_qty           VARCHAR,
    product_weight_g             VARCHAR,
    product_length_cm            VARCHAR,
    product_height_cm            VARCHAR,
    product_width_cm             VARCHAR
);

-- -- ------------------------------------------------------------------------------------
-- Creates sellers table, containing one row per seller.
-- -- ------------------------------------------------------------------------------------
CREATE TABLE raw.sellers(
    seller_id          VARCHAR,
    seller_zip_code    VARCHAR,    
    seller_city        VARCHAR,    
    seller_state       VARCHAR
);

-- ------------------------------------------------------------------------------------
-- Creates category_translation table, which maps Portuguese category names to English.
-- ------------------------------------------------------------------------------------
CREATE TABLE raw.category_translation(
    product_category_name           VARCHAR,
    product_category_name_english   VARCHAR
);

-- ---------------------------------------------------------------------------
-- Load from CSVs (run after placing Kaggle files in data/)
-- ---------------------------------------------------------------------------
COPY raw.orders               FROM 'data/olist_orders_dataset.csv' (HEADER TRUE, DELIMITER ',');
COPY raw.order_items          FROM 'data/olist_order_items_dataset.csv' (HEADER TRUE, DELIMITER ',');
COPY raw.order_payments       FROM 'data/olist_order_payments_dataset.csv' (HEADER TRUE, DELIMITER ',');
COPY raw.products             FROM 'data/olist_products_dataset.csv' (HEADER TRUE, DELIMITER ',');
COPY raw.sellers              FROM 'data/olist_sellers_dataset.csv' (HEADER TRUE, DELIMITER ',');
COPY raw.category_translation FROM 'data/product_category_name_translation.csv' (HEADER TRUE, DELIMITER ',');
