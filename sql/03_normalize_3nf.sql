-- ============================================================
-- 03_normalize_3nf.sql
-- Populates the 3NF schema (01_schema.sql) from the cleaned,
-- deduplicated staging table (staging_final).
-- ============================================================

-- 0. Give every staging row a stable customer identity key:
--    email if we have it, else normalized phone, else raw name.
--    (A name-only fallback is a known weak point -- see case study.)
DROP TABLE IF EXISTS staging_with_identity;
CREATE TABLE staging_with_identity AS
SELECT *,
       COALESCE(clean_email, clean_phone, LOWER(raw_name)) AS identity_key
FROM staging_final;

-- 1. CUSTOMERS: one row per distinct identity_key. Name/phone/city/state
--    are taken from that customer's most recent order (MAX(order_id))
--    so a customer who moved cities isn't accidentally split in two.
INSERT INTO customers (full_name, email, phone, city, state, identity_key)
SELECT
    UPPER(SUBSTR(raw_name,1,1)) || LOWER(SUBSTR(raw_name,2))  AS full_name,
    clean_email, clean_phone, clean_city, clean_state, identity_key
FROM staging_with_identity s
WHERE order_id = (
    SELECT MAX(order_id) FROM staging_with_identity s2
    WHERE s2.identity_key = s.identity_key
);

-- 2. PRODUCTS: one row per distinct product_key (normalized identity).
--    Keep the most frequently occurring surface spelling for display.
INSERT INTO products (product_name, category, unit_price, product_key)
SELECT product_name, clean_category, clean_unit_price, product_key
FROM (
    SELECT
        product_key, clean_category, clean_unit_price,
        raw_product_name AS product_name,
        COUNT(*) AS freq,
        ROW_NUMBER() OVER (PARTITION BY product_key ORDER BY COUNT(*) DESC) AS rn
    FROM staging_with_identity
    GROUP BY product_key, raw_product_name, clean_category, clean_unit_price
)
WHERE rn = 1;

-- 3. ORDERS: one header row per surviving order line, linked by identity_key.
INSERT INTO orders (order_id, customer_id, order_date, status)
SELECT
    s.order_id,
    c.customer_id,
    COALESCE(s.clean_order_date, '1900-01-01'),  -- flag unparseable dates instead of dropping the order
    s.clean_status
FROM staging_with_identity s
JOIN customers c ON c.identity_key = s.identity_key;

-- 4. ORDER_ITEMS: the line item itself, joined on the normalized product_key
--    (NOT on raw product_name text, which still has casing/spacing variants).
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT
    s.order_id,
    p.product_id,
    s.clean_quantity,
    s.clean_unit_price
FROM staging_with_identity s
JOIN products p ON p.product_key = s.product_key;
