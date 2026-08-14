import csv
import random

random.seed(42)

first_names = ["James","Mary","Robert","Patricia","John","Jennifer","Michael","Linda",
               "David","Elizabeth","William","Barbara","Richard","Susan","Joseph","Jessica",
               "Priya","Arjun","Fatima","Wei","Sofia","Liam","Olivia","Noah"]
last_names = ["Smith","Johnson","Williams","Brown","Jones","Garcia","Miller","Davis",
              "Rodriguez","Martinez","Hernandez","Lopez","Gonzalez","Wilson","Anderson",
              "Sharma","Patel","Khan","Chen","Silva","Murphy","Kelly"]

cities_states = [
    ("New York","NY"), ("new york","ny"), ("Los Angeles","CA"), ("Chicago","IL"),
    ("Houston","TX"), ("houston","TX"), ("Phoenix","AZ"), ("Philadelphia","PA"),
    ("San Antonio","TX"), ("San Diego","CA"), ("Dallas","TX"), ("Austin ","TX"),
]

products = [
    ("Wireless Mouse", "Electronics", 19.99),
    ("wireless mouse", "electronics", 19.99),
    ("USB-C Cable 6ft", "Electronics", 9.50),
    ("Yoga Mat", "Fitness", 24.00),
    ("Yoga  Mat", "Fitness", 24.00),
    ("Stainless Water Bottle", "Fitness", 15.75),
    ("Bluetooth Speaker", "Electronics", 45.00),
    ("Office Chair", "Furniture", 129.99),
    ("Desk Lamp", "Furniture", 22.30),
    ("Notebook Set", "Office Supplies", 8.99),
    ("Ballpoint Pens (12pk)", "Office Supplies", 6.49),
    ("Standing Desk", "Furniture", 249.00),
]

def messy_phone():
    n = f"{random.randint(200,999)}{random.randint(200,999)}{random.randint(1000,9999)}"
    fmt = random.choice([
        f"({n[:3]}) {n[3:6]}-{n[6:]}",
        f"{n[:3]}-{n[3:6]}-{n[6:]}",
        f"{n[:3]}.{n[3:6]}.{n[6:]}",
        n,
        f"+1{n}",
        "",  # missing
    ])
    return fmt

def messy_date():
    m = random.randint(1,12); d = random.randint(1,28); y = random.choice([2023,2024])
    fmt = random.choice([
        f"{y}-{m:02d}-{d:02d}",
        f"{m}/{d}/{y}",
        f"{d:02d}-{m:02d}-{y}",
        f"{m}/{d}/{str(y)[2:]}",
    ])
    return fmt

def messy_email(fn, ln, dup_idx=0):
    base = f"{fn}.{ln}{dup_idx if dup_idx else ''}@{random.choice(['gmail.com','yahoo.com','outlook.com','company.co'])}"
    case_variant = random.choice([base, base.upper(), base.capitalize()])
    padded = random.choice([case_variant, f" {case_variant}", f"{case_variant} "])
    return padded

rows = []
customer_pool = []
for i in range(180):
    fn = random.choice(first_names)
    ln = random.choice(last_names)
    city, state = random.choice(cities_states)
    phone = messy_phone()
    email = messy_email(fn, ln, i)
    customer_pool.append({
        "name_variants": [f"{fn} {ln}", f"{fn.upper()} {ln.upper()}", f" {fn} {ln} ", f"{fn.lower()} {ln.lower()}"],
        "email": email,
        "phone": phone,
        "phone_variants": [phone, phone.replace("-","").replace("(","").replace(")","").replace(" ","").replace("+1","")],
        "city": city,
        "state": state,
    })

order_id = 1000
for _ in range(650):
    cust = random.choice(customer_pool)
    prod = random.choice(products)
    qty = random.randint(1,5)
    order_id += 1
    row = {
        "order_id": order_id,
        "customer_name": random.choice(cust["name_variants"]),
        "email": cust["email"],
        "phone": random.choice(cust["phone_variants"]),
        "city": cust["city"],
        "state": cust["state"],
        "product_name": prod[0],
        "category": prod[1],
        "unit_price": prod[2],
        "quantity": qty,
        "order_date": messy_date(),
        "status": random.choice(["Shipped","shipped","SHIPPED","Delivered","delivered","Pending","cancelled","Cancelled"]),
    }
    rows.append(row)
    # Inject exact duplicate rows (common export bug: re-sent/re-scraped record)
    if random.random() < 0.08:
        rows.append(dict(row))
    # Inject near-duplicate (same order, re-keyed with new order_id — double counted)
    if random.random() < 0.04:
        dup = dict(row)
        order_id += 1
        dup["order_id"] = order_id
        rows.append(dup)

# Inject some missing/null-ish values
for r in rows:
    if random.random() < 0.03:
        r["phone"] = ""
    if random.random() < 0.02:
        r["email"] = "N/A"
    if random.random() < 0.015:
        r["quantity"] = ""

random.shuffle(rows)

fields = ["order_id","customer_name","email","phone","city","state",
          "product_name","category","unit_price","quantity","order_date","status"]

with open("/home/claude/project/messy_orders.csv","w",newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    for r in rows:
        w.writerow(r)

print(f"Generated {len(rows)} rows -> messy_orders.csv")
