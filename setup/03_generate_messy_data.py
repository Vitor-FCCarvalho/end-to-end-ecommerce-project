"""
Appends synthetic messy rows (~10% of real data size) to the real Kaggle CSVs.
This ensures the majority of the data is real/correct, while a small portion
demonstrates the messiness that the cleaning pipeline handles:

  - Currency symbols in numeric fields ("R$ 1,234.56")
  - Mixed NULL representations ("", "N/A", "null", "NULL", None)
  - Duplicate rows
  - Inconsistent date formats (ISO, US, European, with/without time)
  - Mixed-case city names ("São Paulo", "SÃO PAULO", "sao paulo")
  - Malformed zip codes
  - Seller IDs with leading/trailing whitespace
  - Orders with no matching items
  - Items referencing nonexistent products

Output: data/olist_*.csv (real + synthetic rows combined)
"""

import csv
import random
import string
import os
from datetime import datetime, timedelta

random.seed(42)
os.makedirs("data", exist_ok=True)

# Source: original unmodified Kaggle files (read-only, never overwritten)
SOURCE_SELLERS_PATH    = "data/olist_sellers_dataset_original.csv"
SOURCE_ORDERS_PATH     = "data/olist_orders_dataset_original.csv"
SOURCE_ITEMS_PATH      = "data/olist_order_items_dataset_original.csv"
SOURCE_PAYMENTS_PATH   = "data/olist_order_payments_dataset_original.csv"
SOURCE_PRODUCTS_PATH   = "data/olist_products_dataset_original.csv"

# Output: combined real + synthetic files consumed by the pipeline
REAL_SELLERS_PATH    = "data/olist_sellers_dataset.csv"
REAL_ORDERS_PATH     = "data/olist_orders_dataset.csv"
REAL_ITEMS_PATH      = "data/olist_order_items_dataset.csv"
REAL_PAYMENTS_PATH   = "data/olist_order_payments_dataset.csv"
REAL_PRODUCTS_PATH   = "data/olist_products_dataset.csv"

# ----------------------------------- Helper functions -----------------------------------
def random_id(length=32):
    return "".join(random.choices(string.hexdigits[:16], k=length))

def random_date(start, end):
    delta = end - start
    time_delta = timedelta(
        days=random.randint(0, delta.days),
        hours=random.randint(0, 23),
        minutes=random.randint(0, 59)
    )
    return start + time_delta

def messy_date(dt):
    if dt is None:
        return random.choice(["", "N/A", "null"])
    fmt = random.choice([
        "%Y-%m-%d %H:%M:%S",
        "%m/%d/%Y %H:%M",
        "%d-%m-%Y",
        "%Y/%m/%d %H:%M:%S",
    ])
    return dt.strftime(fmt)

def messy_price(value):
    if random.random() < 0.05:
        return random.choice(["", "N/A", "null", "NULL"])
    style = random.choice(["plain", "currency", "comma", "currency_comma"])
    if style == "plain":
        return f"{value:.2f}"
    elif style == "currency":
        return f"R$ {value:.2f}"
    elif style == "comma":
        return f"{value:,.2f}".replace(",", "tmp").replace(".", ",").replace("tmp", ".")
    else:
        return f"R$ {value:,.2f}"

def messy_city(city):
    style = random.choice(["lower", "upper", "title", "mixed"])
    if style == "lower":
        return city.lower()
    elif style == "upper":
        return city.upper()
    elif style == "title":
        return city.title()
    else:
        return city

def messy_zip(zipcode):
    style = random.choice(["correct", "short", "with_dash", "letters", "blank"])
    if style == "correct":
        return zipcode
    elif style == "short":
        return zipcode[:4]
    elif style == "with_dash":
        return f"{zipcode[:5]}-{zipcode[5:]}"
    elif style == "letters":
        return zipcode[:3] + "XY" + zipcode[5:]
    else:
        return ""

def messy_seller_id(sid):
    if random.random() < 0.05:
        return f" {sid}  "
    return sid

def read_csv(path):
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))

def write_csv(path, rows, fieldnames):
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    print(f"  -> Wrote {len(rows):,} rows to {path}")

# ----------------------------------- Reference data -----------------------------------
CATEGORIES_PT = [
    "cama_mesa_banho", "beleza_saude", "esporte_lazer", "informatica_acessorios",
    "moveis_decoracao", "utilidades_domesticas", "relogios_presentes",
    "telefonia", "automotivo", "brinquedos", "cool_stuff", "ferramentas_jardim",
    "fashion_bolsas_e_acessorios", "eletroportateis", "livros_tecnicos",
    "perfumaria", "bebes", "pet_shop", "construcao_ferramentas_seguranca",
    "papelaria", "alimentos_bebidas",
]

CITY_STATE_PAIRS = [
    ("São Paulo",        "SP"),
    ("Campinas",         "SP"),
    ("Rio de Janeiro",   "RJ"),
    ("Belo Horizonte",   "MG"),
    ("Porto Alegre",     "RS"),
    ("Curitiba",         "PR"),
    ("Florianópolis",    "SC"),
    ("Salvador",         "BA"),
    ("Goiânia",          "GO"),
    ("Recife",           "PE"),
    ("Fortaleza",        "CE"),
    ("Manaus",           "AM"),
    ("Belém",            "PA"),
    ("Natal",            "RN"),
    ("Maceió",           "AL"),
]

PAYMENT_TYPES  = ["credit_card", "boleto", "voucher", "debit_card"]
ORDER_STATUSES = ["delivered", "delivered", "delivered", "shipped", "canceled", "invoiced", "processing", "unavailable"]

START = datetime(2016, 10, 1)
END   = datetime(2018, 9, 30)

# ----------------------------------- Load real data -----------------------------------
print("Loading real Kaggle data...")
real_sellers  = read_csv(SOURCE_SELLERS_PATH)
real_orders   = read_csv(SOURCE_ORDERS_PATH)
real_items    = read_csv(SOURCE_ITEMS_PATH)
real_payments = read_csv(SOURCE_PAYMENTS_PATH)
real_products = read_csv(SOURCE_PRODUCTS_PATH)

print(f"  Real sellers:  {len(real_sellers):,}")
print(f"  Real orders:   {len(real_orders):,}")
print(f"  Real items:    {len(real_items):,}")
print(f"  Real payments: {len(real_payments):,}")
print(f"  Real products: {len(real_products):,}")

# Rename seller_zip_code_prefix -> seller_zip_code to align with pipeline expectations
for s in real_sellers:
    if "seller_zip_code_prefix" in s:
        s["seller_zip_code"] = s.pop("seller_zip_code_prefix")

# ----------------------------------- Generate synthetic messy rows (~10%) -----------------------------------
N_SYNTH_SELLERS  = max(1, len(real_sellers)  // 10)
N_SYNTH_PRODUCTS = max(1, len(real_products) // 10)
N_SYNTH_ORDERS   = max(1, len(real_orders)   // 10)
N_SYNTH_CUSTOMERS = 5_000

print(f"\nGenerating synthetic messy additions (~10% of real data)...")
print(f"  Sellers: {N_SYNTH_SELLERS}, Products: {N_SYNTH_PRODUCTS}, Orders: {N_SYNTH_ORDERS}")

synth_customers = [random_id() for _ in range(N_SYNTH_CUSTOMERS)]

print("Generating synthetic sellers...")
synth_sellers_clean = []
for _ in range(N_SYNTH_SELLERS):
    zipcode = "".join(random.choices(string.digits, k=8))
    city, state = random.choice(CITY_STATE_PAIRS)
    synth_sellers_clean.append({
        "seller_id":       random_id(),
        "seller_zip_code": zipcode,
        "seller_city":     city,
        "seller_state":    state,
    })

# Apply messy transformations to synthetic sellers
synth_sellers_messy = []
for s in synth_sellers_clean:
    synth_sellers_messy.append({
        "seller_id":       messy_seller_id(s["seller_id"]),
        "seller_zip_code": messy_zip(s["seller_zip_code"]),
        "seller_city":     messy_city(s["seller_city"]),
        "seller_state":    s["seller_state"],
    })

# Synthetic products
print("Generating synthetic products...")
synth_products = []
for _ in range(N_SYNTH_PRODUCTS):
    synth_products.append({
        "product_id":                  random_id(),
        "product_category_name":       random.choice(CATEGORIES_PT),
        "product_name_lenght":         random.randint(20, 60),
        "product_description_lenght":  random.randint(50, 500),
        "product_photos_qty":          random.randint(1, 8),
        "product_weight_g":            random.randint(100, 20000),
        "product_length_cm":           random.randint(10, 100),
        "product_height_cm":           random.randint(5, 80),
        "product_width_cm":            random.randint(10, 100),
    })

# Synthetic orders, items, payments
print("Generating synthetic orders...")
synth_orders   = []
synth_items    = []
synth_payments = []

for _ in range(N_SYNTH_ORDERS):
    order_id    = random_id()
    customer_id = random.choice(synth_customers)
    status      = random.choice(ORDER_STATUSES)
    purchase_dt = random_date(START, END)
    approved_dt = purchase_dt + timedelta(hours=random.randint(1, 48)) if random.random() > 0.02 else None
    delivered_dt = approved_dt + timedelta(days=random.randint(3, 30)) if approved_dt and status == "delivered" else None
    estimated_dt = purchase_dt + timedelta(days=random.randint(7, 45))

    synth_orders.append({
        "order_id":                      order_id,
        "customer_id":                   customer_id,
        "order_status":                  status,
        "order_purchase_timestamp":      messy_date(purchase_dt),
        "order_approved_at":             messy_date(approved_dt),
        "order_delivered_carrier_date":  messy_date(approved_dt + timedelta(days=1) if approved_dt else None),
        "order_delivered_customer_date": messy_date(delivered_dt),
        "order_estimated_delivery_date": messy_date(estimated_dt),
    })

    n_items = random.choices([1, 2, 3, 4], weights=[60, 25, 10, 5])[0]
    order_total = 0
    for seq in range(1, n_items + 1):
        product = random.choice(synth_products)
        seller  = random.choice(synth_sellers_clean)
        price   = round(random.uniform(9.90, 999.00), 2)
        freight = round(random.uniform(5.00, 80.00), 2)
        order_total += price + freight

        synth_items.append({
            "order_id":            order_id,
            "order_item_id":       seq,
            "product_id":          product["product_id"],
            "seller_id":           messy_seller_id(seller["seller_id"]),
            "shipping_limit_date": messy_date(approved_dt + timedelta(days=3) if approved_dt else None),
            "price":               messy_price(price),
            "freight_value":       messy_price(freight),
        })

    n_payments = random.choices([1, 2], weights=[85, 15])[0]
    remaining  = order_total
    for pay_seq in range(1, n_payments + 1):
        amount = round(remaining if pay_seq == n_payments else remaining * random.uniform(0.3, 0.7), 2)
        remaining -= amount
        synth_payments.append({
            "order_id":             order_id,
            "payment_sequential":   pay_seq,
            "payment_type":         random.choice(PAYMENT_TYPES),
            "payment_installments": random.randint(1, 12),
            "payment_value":        messy_price(amount),
        })

# Inject duplicate rows into synthetic batch
print("Injecting duplicates...")
dup_orders = random.sample(synth_orders, k=max(1, int(len(synth_orders) * 0.02)))
synth_orders.extend(dup_orders)
dup_items = random.sample(synth_items, k=max(1, int(len(synth_items) * 0.02)))
synth_items.extend(dup_items)
random.shuffle(synth_orders)
random.shuffle(synth_items)

# Inject orders with no items
print("Injecting orders with no items...")
for _ in range(5):
    purchase_dt = random_date(START, END)
    synth_orders.append({
        "order_id":                      random_id(),
        "customer_id":                   random.choice(synth_customers),
        "order_status":                  "processing",
        "order_purchase_timestamp":      messy_date(purchase_dt),
        "order_approved_at":             "",
        "order_delivered_carrier_date":  "",
        "order_delivered_customer_date": "",
        "order_estimated_delivery_date": messy_date(purchase_dt + timedelta(days=14)),
    })

# ----------------------------------- Combine and write -----------------------------------
print("\nWriting combined CSVs (real + synthetic)...")

combined_sellers  = real_sellers  + synth_sellers_messy
combined_orders   = real_orders   + synth_orders
combined_items    = real_items    + synth_items
combined_payments = real_payments + synth_payments
combined_products = real_products + synth_products

random.shuffle(combined_sellers)
random.shuffle(combined_orders)
random.shuffle(combined_items)

write_csv(REAL_SELLERS_PATH,  combined_sellers,
          ["seller_id", "seller_zip_code", "seller_city", "seller_state"])

write_csv(REAL_ORDERS_PATH, combined_orders,
          ["order_id", "customer_id", "order_status",
           "order_purchase_timestamp", "order_approved_at",
           "order_delivered_carrier_date", "order_delivered_customer_date",
           "order_estimated_delivery_date"])

write_csv(REAL_ITEMS_PATH, combined_items,
          ["order_id", "order_item_id", "product_id", "seller_id",
           "shipping_limit_date", "price", "freight_value"])

write_csv(REAL_PAYMENTS_PATH, combined_payments,
          ["order_id", "payment_sequential", "payment_type",
           "payment_installments", "payment_value"])

write_csv(REAL_PRODUCTS_PATH, combined_products,
          ["product_id", "product_category_name", "product_name_lenght",
           "product_description_lenght", "product_photos_qty",
           "product_weight_g", "product_length_cm",
           "product_height_cm", "product_width_cm"])

print("Done!")
