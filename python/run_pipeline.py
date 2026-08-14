import sqlite3, re, datetime

DB = "/home/claude/project/cleaning_project.db"

def normalize_phone(raw):
    if raw is None:
        return None
    digits = re.sub(r"\D", "", raw)
    if digits.startswith("1") and len(digits) == 11:
        digits = digits[1:]
    return digits if len(digits) == 10 else None

def normalize_date(raw):
    if raw is None or raw.strip() == "":
        return None
    raw = raw.strip()
    formats = ["%Y-%m-%d", "%m/%d/%Y", "%d-%m-%Y", "%m/%d/%y"]
    for fmt in formats:
        try:
            return datetime.datetime.strptime(raw, fmt).strftime("%Y-%m-%d")
        except ValueError:
            continue
    return None

def run_script(cur, path):
    with open(path) as f:
        cur.executescript(f.read())

conn = sqlite3.connect(DB)
conn.create_function("normalize_phone", 1, normalize_phone)
conn.create_function("normalize_date", 1, normalize_date)
cur = conn.cursor()

print("=== BEFORE (raw_orders) ===")
before_total = cur.execute("SELECT COUNT(*) FROM raw_orders").fetchone()[0]
print("Rows:", before_total)

run_script(cur, "/home/claude/project/01_schema.sql")
run_script(cur, "/home/claude/project/02_clean_staging.sql")
run_script(cur, "/home/claude/project/03_normalize_3nf.sql")
conn.commit()

print("\n=== AFTER staging/dedup ===")
after_business_key = cur.execute("SELECT COUNT(*) FROM staging_orders_deduped").fetchone()[0]
after_final = cur.execute("SELECT COUNT(*) FROM staging_final").fetchone()[0]
print("After business-key dedup (customer+product+date+qty):", after_business_key)
print("After final order_id QA pass:", after_final)
print("Total rows removed as duplicates:", before_total - after_final)

print("\n=== AFTER 3NF normalization ===")
for t in ["customers", "products", "orders", "order_items"]:
    n = cur.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
    print(f"{t}: {n} rows")

print("\n--- Redundancy check ---")
print("Distinct emails in customers table:", cur.execute("SELECT COUNT(DISTINCT email) FROM customers").fetchone()[0])
print("Distinct product identities in products table:", cur.execute("SELECT COUNT(*) FROM products").fetchone()[0])
print("Distinct status values now:", [r[0] for r in cur.execute("SELECT DISTINCT status FROM orders").fetchall()])
print("Orders with unparseable/flagged dates (1900-01-01):",
      cur.execute("SELECT COUNT(*) FROM orders WHERE order_date='1900-01-01'").fetchone()[0])

print("\n--- Sample joined output (proves the normalized data still answers business questions) ---")
rows = cur.execute("""
    SELECT c.full_name, c.email, o.order_date, p.product_name, oi.quantity, oi.unit_price
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    JOIN order_items oi ON oi.order_id = o.order_id
    JOIN products p ON p.product_id = oi.product_id
    ORDER BY o.order_id
    LIMIT 5
""").fetchall()
for r in rows:
    print(r)

print("\n--- Revenue by category (query only possible cleanly after normalization) ---")
for r in cur.execute("""
    SELECT p.category, ROUND(SUM(oi.quantity * oi.unit_price),2) AS revenue, COUNT(*) AS line_items
    FROM order_items oi JOIN products p ON p.product_id = oi.product_id
    GROUP BY p.category ORDER BY revenue DESC
"""):
    print(r)

conn.close()
