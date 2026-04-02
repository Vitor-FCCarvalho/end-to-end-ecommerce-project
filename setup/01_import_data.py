"""
Downloads the Olist Brazilian e-commerce dataset from Kaggle and copies all CSVs into ./data/.
Also creates *_original.csv backups so that 03_generate_messy_data.py can append synthetic rows
without messing with the source files.
"""

import os
import shutil
from pathlib import Path

import kagglehub
from dotenv import load_dotenv

load_dotenv()

os.environ["KAGGLE_USERNAME"] = os.getenv("KAGGLE_USERNAME", "")
os.environ["KAGGLE_KEY"] = os.getenv("KAGGLE_KEY", "")

DATA_DIR = Path("./data")
DATA_DIR.mkdir(parents=True, exist_ok=True)

# Download the Olist dataset from Kaggle
source_path = Path(kagglehub.dataset_download("olistbr/brazilian-ecommerce"))
print(f"Downloaded dataset to temporary cache: {source_path}")

# Copy files into ./data and create _original backups for the messy-data generator
for file in source_path.iterdir():
    if not file.is_file():
        continue
    target_file = DATA_DIR / file.name
    target_file.write_bytes(file.read_bytes())
    print(f"Copied: {file.name} -> {target_file}")

    if file.suffix == ".csv":
        original = DATA_DIR / (file.stem + "_original.csv")
        shutil.copy2(target_file, original)
        print(f"  Backup: {original.name}")

print(f"\nAll dataset files are available in: {DATA_DIR.resolve()}")
