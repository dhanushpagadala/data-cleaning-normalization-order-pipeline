-- ============================================================
-- 02_clean_staging.sql
-- Cleans raw_orders into a staging table: standardized values,
-- exact duplicates removed. This does NOT yet split into 3NF --
-- that happens in 03_normalize_3nf.sql.
--
-- Two scalar functions are registered from Python before this
-- script runs (sqlite has no native date-format parser / regex):
--   normalize_phone(text) -> digits-only phone, or NULL if blank
--   normalize_date(text)  -> ISO-8601 'YYYY-MM-DD', or NULL if unparseable
-- Everything else (trimming, casing, status vocabulary, dedup)
-- is plain SQL.
-- ============================================================

DROP TABLE IF EXISTS staging_orders;

CREATE TABLE staging_orders AS
SELECT
    order_id,

    -- Name: trim, collapse to Title Case for storage consistency
    TRIM(customer_name)                                        AS raw_name,

    -- Email: trim + lowercase = canonical identity key for a customer.
    -- 'N/A' and blank both mean "no email" -> NULL.
    CASE
        WHEN TRIM(email) = '' OR UPPER(TRIM(email)) = 'N/A' THEN NULL
        ELSE LOWER(TRIM(email))
    END                                                         AS clean_email,

    normalize_phone(phone)                                      AS clean_phone,

    TRIM(city)                                                  AS clean_city,
    UPPER(TRIM(state))                                          AS clean_state,

    -- Product identity: case-insensitive, whitespace-collapsed match.
    -- raw_product_name is also whitespace-collapsed so the display
    -- spelling we keep in products.product_name doesn't carry stray
    -- double-spaces through from source ("Yoga  Mat" -> "Yoga Mat").
    REPLACE(TRIM(product_name), '  ', ' ')                      AS raw_product_name,
    -- collapse "Yoga  Mat" (double space) and case variants to one form
    (SELECT p2 FROM (SELECT
        REPLACE(TRIM(LOWER(product_name)), '  ', ' ') AS p2) )  AS product_key,
    UPPER(SUBSTR(TRIM(category),1,1)) || LOWER(SUBSTR(TRIM(category),2)) AS clean_category,

    CAST(unit_price AS NUMERIC)                                 AS clean_unit_price,

    CASE WHEN TRIM(quantity) = '' THEN 1 ELSE CAST(quantity AS INTEGER) END AS clean_quantity,

    normalize_date(order_date)                                  AS clean_order_date,

    -- Status: fold casing variants down to one fixed vocabulary
    CASE LOWER(TRIM(status))
        WHEN 'pending'   THEN 'Pending'
        WHEN 'shipped'   THEN 'Shipped'
        WHEN 'delivered' THEN 'Delivered'
        WHEN 'cancelled' THEN 'Cancelled'
        ELSE 'Pending'
    END                                                          AS clean_status

FROM raw_orders;

-- Deduplication: the raw export contains
--   (a) exact re-sent copies of the same order_id/line, and
--   (b) re-keyed duplicates -- same customer+product+date+qty but a
--       *different* order_id, which double-counts a sale.
-- We keep one surviving row per genuine business event, defined as
-- (customer email, product, order date, quantity) -- not per order_id,
-- since order_id itself is what got duplicated.
-- NOTE: order_id is NOT a reliable dedup key here -- some duplicate
-- rows in the raw export are exact copies that share the SAME
-- order_id (a re-sent/re-scraped record), so filtering by
-- "order_id IN (SELECT MIN(order_id) ...)" would let every copy of
-- that id through. We dedupe on SQLite's internal rowid instead,
-- which is unique per physical row regardless of column values.
DROP TABLE IF EXISTS staging_orders_deduped;

CREATE TABLE staging_orders_deduped AS
SELECT * FROM staging_orders
WHERE rowid IN (
    SELECT MIN(rowid)
    FROM staging_orders
    GROUP BY
        COALESCE(clean_email, raw_name),
        product_key,
        clean_order_date,
        clean_quantity
);

-- QA finding: the business-key dedup above still leaves a handful of
-- rows that share the SAME order_id but drifted on a secondary field
-- (e.g. email blanked out on one copy, quantity off-by-one on another).
-- Since order_id is meant to be a single order in the source system,
-- these are the same event with a data-entry glitch on the re-send --
-- not two different orders. Final pass: collapse to one row per
-- order_id, preferring the most complete record (non-null email/phone),
-- then most recent rowid as a tiebreaker.
DROP TABLE IF EXISTS staging_final;

CREATE TABLE staging_final AS
SELECT * FROM staging_orders_deduped
WHERE rowid IN (
    SELECT rowid FROM (
        SELECT rowid,
               ROW_NUMBER() OVER (
                   PARTITION BY order_id
                   ORDER BY (clean_email IS NULL), (clean_phone IS NULL), rowid DESC
               ) AS rn
        FROM staging_orders_deduped
    )
    WHERE rn = 1
);
