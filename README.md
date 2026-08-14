# Order Data Cleaning & 3NF Normalization Pipeline

Cleaned a 728-row denormalized order export, removed 78 duplicate/redundant
rows, and restructured it into a proper 3NF schema — cutting stored data
volume 28% while eliminating the update anomalies of the original flat file.
Entirely in SQL, with two small Python UDFs standing in for SQLite's missing
regex/date-parsing support.

## Results at a glance

| | Before | After |
|---|---|---|
| Rows | 728 (flat, denormalized) | 650 orders / 650 order_items |
| Customer records | 728 (repeated on every line) | 181 (172 by email, 8 by phone, 1 by name) |
| Product records | 728 (repeated on every line) | 10 |
| Distinct email spellings | 173 | 172 |
| Distinct phone spellings | 211 | 140 (normalized) |
| Distinct status spellings | 8 | 4, enforced by `CHECK` constraint |
| Duplicate rows removed | — | 78 (10.7% of the raw file) |
| Total stored cells | 8,736 | 6,326 (−28%, despite adding 2 dimension tables) |
| Orphaned foreign keys | — | 0 (verified) |

Everything above came from actually running the pipeline (`python/run_pipeline.py`),
not from counting SQL statements.

**Scope:** a synthetic-but-realistic flat CSV export (the kind you'd get from
a legacy order system or a third-party data dump) — cleaned, deduplicated, and
restructured into a 3NF relational schema, entirely in SQL.

**Stack:** SQLite (via Python's `sqlite3`), two small Python UDFs registered into
SQL for date/phone parsing (SQLite has no native regex or multi-format date
parser), everything else pure SQL.

---

## 1. The problem

The source file, `data/raw/messy_orders.csv`, is a single flat table: every order line
repeats the full customer record (name, email, phone, city, state) and the full
product record (name, category, price) inline. This is the classic shape of an
unnormalized (1NF-only) export, and it has the classic symptoms:

| Issue | Example |
|---|---|
| Inconsistent casing | `JENNIFER.WILSON29@YAHOO.COM`, `Jennifer.wilson`, `jennifer.wilson` |
| Inconsistent phone formats | `(692) 418-7570`, `692-418-7570`, `+16924187570`, `6924187570` |
| Inconsistent date formats | `2023-11-06`, `11/6/2023`, `06-11-2023`, `11/6/23` (four formats, ambiguous without a fixed rule) |
| Inconsistent categorical values | `Shipped`, `shipped`, `SHIPPED` — 8 raw spellings for 4 real statuses |
| Stray whitespace | `"Yoga  Mat"` (double space), leading/trailing spaces on names and emails |
| Missing values | blank phone, `"N/A"` for email, blank quantity |
| Exact duplicate rows | the same order re-sent/re-scraped with an identical `order_id` |
| Re-keyed duplicates | the same real-world sale appearing twice under **two different** `order_id`s |
| Denormalization | customer and product attributes repeated on every single line — an update anomaly waiting to happen (fix one customer's phone number, miss 3 other rows with the old one) |

### Before, measured directly on the raw table

```
Total rows:                              728
Exact full-row duplicate copies:          69
Distinct email spellings:                173   (for what should be ~172 real customers)
Distinct phone spellings:                211
Distinct product name+category spellings: 12   (for 10 real products)
Distinct status spellings:                 8   (for 4 real states)
Rows with blank/N-A phone:                132
Rows with blank/N-A email:                 12
Rows with blank quantity:                  12
```

---

## 2. Approach

Three SQL scripts, run in order, plus a thin Python runner that registers two
scalar functions SQLite doesn't have natively:

- **`01_schema.sql`** — the target 3NF schema: `customers`, `products`, `orders`,
  `order_items`.
- **`02_clean_staging.sql`** — standardizes every field, then deduplicates.
- **`03_normalize_3nf.sql`** — splits the cleaned, deduplicated rows into the
  four normalized tables.

### 2.1 Field-level cleaning (`02_clean_staging.sql`)

- **Email** → `TRIM` + `LOWER`; blank or `'N/A'` → `NULL`. Lowercased email
  becomes the primary identity key for a customer.
- **Phone** → a Python UDF (`normalize_phone`) strips everything but digits,
  drops a leading US country-code `1`, and rejects anything that isn't a clean
  10-digit number (returns `NULL` rather than guessing).
- **Date** → a Python UDF (`normalize_date`) tries four known source formats in
  order and converts to ISO-8601. Unparseable dates are flagged (`1900-01-01`
  sentinel + kept, not silently dropped — see §4).
- **Status** → folded via `CASE` on `LOWER(TRIM(status))` into a fixed
  4-value vocabulary, enforced afterward with a `CHECK` constraint on the
  `orders` table so a 5th spelling can't sneak back in later.
- **Product identity** → a normalized `product_key` (lowercased,
  whitespace-collapsed) is computed *separately* from the display name, so
  `"Wireless Mouse"` and `"wireless mouse"` are recognized as the same
  product for joins, while the display table still stores one clean,
  readable spelling.

### 2.2 Deduplication — two passes, because one wasn't enough

**Pass 1 — business-key dedup.** Group by
`(customer identity, product, order date, quantity)` and keep the earliest
physical row per group. This is deliberately **not** a dedup on `order_id`:
some duplicate rows in the source share the *same* `order_id` (an exact
re-send), so filtering by `order_id IN (SELECT MIN(order_id) ...)` would let
every copy through — it needed to dedupe on SQLite's internal `rowid`
instead. This step took the row count from 728 → 655.

**Pass 2 — a QA finding, not a clean assumption.** After pass 1, 5 rows still
shared an `order_id` with a sibling row, because the "duplicate" copy had
drifted slightly — one had the email blanked out, another had the quantity
off by one. Real messy data does this: a re-send isn't always byte-identical
to the original. Since `order_id` is meant to identify a single order in the
source system, these were collapsed to one row per `order_id`, preferring
the more complete record (non-null email, then non-null phone). 655 → 650.

**Total: 78 duplicate/redundant rows removed (10.7% of the raw file).**

### 2.3 Splitting into 3NF (`03_normalize_3nf.sql`)

```
customers   (customer_id PK, full_name, email UNIQUE, phone, city, state, identity_key UNIQUE)
products    (product_id PK, product_name, category, unit_price, product_key UNIQUE)
orders      (order_id PK, customer_id FK -> customers, order_date, status)
order_items (order_item_id PK, order_id FK -> orders, product_id FK -> products, quantity, unit_price)
```

Why this shape: in the raw table, customer attributes depend only on the
customer, and product attributes depend only on the product — not on the
order line itself. Storing them on every order line is a **2NF/3NF
violation** (transitive/partial dependency on a non-key). Splitting them out
means a customer's phone number is stored and corrected in exactly one
place, and a price change doesn't require rewriting history.

`unit_price` is intentionally kept on **both** `products` (current price) and
`order_items` (price *at the time of that order*) — this isn't leftover
redundancy, it's a deliberate historical fact that must survive future price
changes.

One real join bug surfaced and got fixed during this step: joining
`order_items` to `products` on raw `product_name` text initially dropped 89
line items, because `"Wireless Mouse"` (products table) doesn't
string-equal `"wireless mouse"` (an order row). Switching the join to the
normalized `product_key` fixed it — a good illustration of why you normalize
*before* you trust your join keys, not after.

A second gap: joining `orders` to `customers` on email alone silently
dropped 9 orders from customers who had no email captured at all. Fixed by
building an `identity_key = COALESCE(email, phone, name)` so every customer
gets a stable key even without an email — documented as a known limitation
below, not hidden.

---

## 3. Results

```
                          BEFORE          AFTER
Rows                      728        →    650 order_items / 650 orders
Customer records        728 (repeated)→   181 (172 by email, 8 by phone, 1 by name-only)
Product records          728 (repeated)→  10
Distinct email spellings  173         →   172 (one true duplicate collapsed)
Distinct phone spellings  211         →   140 normalized values
Distinct status spellings   8         →   4 (enforced by CHECK constraint)
Total stored cells      8,736         →   6,326  (28% reduction, despite adding 2 surrogate-key tables)
```

Every number above came from querying the actual output tables, not from
counting the SQL statements.

### A query that was hard to trust before, easy after

```sql
SELECT p.category,
       ROUND(SUM(oi.quantity * oi.unit_price), 2) AS revenue,
       COUNT(*) AS line_items
FROM order_items oi
JOIN products p ON p.product_id = oi.product_id
GROUP BY p.category
ORDER BY revenue DESC;
```

```
Furniture         $64,156.40   164 line items
Electronics       $14,845.79   213 line items
Fitness            $9,176.25   144 line items
Office Supplies     $3,199.41  129 line items
                  -----------
Total revenue     $91,377.85
```

On the raw table, this same question would first require deciding whether
`"Yoga Mat"` and `"Yoga  Mat"` are the same product, whether `"shipped"` and
`"Shipped"` orders should both count, and whether the 69 duplicate rows
should be included — all silent judgment calls that change the answer. After
normalization, the query is just a `GROUP BY`.

---

## 4. Trade-offs and limitations (documented on purpose, not glossed over)

- **Name-only customer fallback.** 1 of the 181 customers had neither a
  usable email nor phone, so they were deduped on lowercased name alone.
  Two different real people with the same name would incorrectly merge
  into one customer record under this rule. In a production system this
  would be flagged for manual review rather than silently merged.
- **Unparseable dates are flagged, not dropped.** Any date that didn't match
  one of the four known source formats was set to a `1900-01-01` sentinel
  rather than discarded, so the order isn't lost — but a real pipeline
  would push these to a dead-letter table for review instead of a magic
  date. (In this dataset, 0 orders needed the sentinel — all dates matched
  a known format.)
- **Phone numbers that don't reduce to 10 digits become `NULL`** rather than
  guessed at — a deliberate choice to avoid fabricating contact data.
- **Business-key dedup can theoretically over-merge** two genuinely
  different orders placed by the same customer, for the same product, on
  the same day, for the same quantity. This is a real edge case in any
  key-based dedup strategy and is why pass 2's `order_id`-level QA pass
  exists as a second check rather than relying on the business key alone.

---

## 5. Files in this project

```
.
├── python/
│   ├── generate_messy_data.py   # generates the synthetic messy source data
│   └── run_pipeline.py          # registers UDFs, runs all 3 SQL scripts, prints before/after metrics
├── sql/
│   ├── 01_schema.sql            # target 3NF DDL
│   ├── 02_clean_staging.sql     # standardization + two-pass deduplication
│   └── 03_normalize_3nf.sql     # splits cleaned data into customers/products/orders/order_items
├── data/
│   ├── raw/messy_orders.csv     # the raw, denormalized, 728-row input
│   └── clean/*.csv              # final normalized tables, flat exports
└── cleaning_project.db          # resulting SQLite database, queryable directly
```

To reproduce end to end from the repo root:
```
python3 python/generate_messy_data.py
python3 python/run_pipeline.py
```
