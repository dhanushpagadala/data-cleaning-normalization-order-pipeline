-- ============================================================
-- 01_schema.sql
-- Target 3NF schema for the cleaned order data.
--
-- Design rationale:
--   raw_orders is a fully denormalized export: every row repeats
--   customer attributes (name, email, phone, city, state) and
--   product attributes (name, category, price) on every order line.
--   That violates 2NF (non-key attributes depend on customer/product,
--   not on the row's own key) and creates update anomalies: fixing
--   a customer's phone number means editing every order row they
--   ever placed.
--
--   We split into four tables so each fact is stored exactly once:
--     customers    - one row per real-world customer
--     products     - one row per real-world product/category/price
--     orders       - one row per order (header: who, when, status)
--     order_items  - one row per line item (what was bought, qty)
-- ============================================================

DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS customers;

CREATE TABLE customers (
    customer_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    full_name     TEXT NOT NULL,
    email         TEXT UNIQUE,            -- normalized, lowercased, trimmed; NULL if never captured
    phone         TEXT,                   -- normalized to digits only, NULL if unknown
    city          TEXT,
    state         TEXT,
    identity_key  TEXT NOT NULL UNIQUE    -- COALESCE(email, phone, name) -- guarantees every
                                           -- customer row, even email-less ones, has one stable
                                           -- dedup key. Documented limitation: an email-less
                                           -- customer is deduped on name, which is weaker and can
                                           -- over-merge two different people with the same name.
);

CREATE TABLE products (
    product_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    product_name  TEXT NOT NULL,
    category      TEXT NOT NULL,
    unit_price    NUMERIC NOT NULL,
    product_key   TEXT NOT NULL UNIQUE   -- normalized (lowercased, whitespace-collapsed) join key;
                                          -- product_name keeps a readable display spelling instead
);

CREATE TABLE orders (
    order_id      INTEGER PRIMARY KEY,     -- reuse source order_id as natural key
    customer_id   INTEGER NOT NULL REFERENCES customers(customer_id),
    order_date    TEXT NOT NULL,           -- normalized to ISO-8601 (YYYY-MM-DD)
    status        TEXT NOT NULL            -- normalized to a fixed vocabulary
        CHECK (status IN ('Pending','Shipped','Delivered','Cancelled'))
);

CREATE TABLE order_items (
    order_item_id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id      INTEGER NOT NULL REFERENCES orders(order_id),
    product_id    INTEGER NOT NULL REFERENCES products(product_id),
    quantity      INTEGER NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC NOT NULL         -- price AT TIME OF ORDER (historical, may differ from products.unit_price today)
);

CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_items_order ON order_items(order_id);
CREATE INDEX idx_items_product ON order_items(product_id);
