"""
Downloads the Olist Brazilian e-commerce dataset from Kaggle and copies all CSVs into ./data/.
"""

import os
from pathlib import Path

import kagglehub
from dotenv import load_dotenv

load_dotenv()

os.environ["KAGGLE_USERNAME"] = os.getenv("KAGGLE_USERNAME", "")
os.environ["KAGGLE_KEY"]      = os.getenv("KAGGLE_KEY", "")

DATA_DIR = Path("./data")
DATA_DIR.mkdir(parents=True, exist_ok=True)

source_path = Path(kagglehub.dataset_download("olistbr/brazilian-ecommerce"))
print(f"Downloaded dataset to temporary cache: {source_path}")

for file in source_path.iterdir():
    if not file.is_file():
        continue
    target = DATA_DIR / file.name
    target.write_bytes(file.read_bytes())
    print(f"Copied: {file.name} -> {target}")

print(f"\nAll dataset files are available in: {DATA_DIR.resolve()}")
