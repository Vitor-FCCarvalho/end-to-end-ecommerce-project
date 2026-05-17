"""
End-to-end pipeline orchestration.

Usage:
  python dagger/pipeline.py

Steps:
  1. setup/01_import_data.py             -> download Kaggle data into data/
  2. pipeline/01_clean_and_load.py       -> staging schema
  3. pipeline/02_validate.py             -> data quality checks
  4. pipeline/03_export_query_results.py -> exports/star_schema/ analytical CSVs
  5. pipeline/04_export_star_schema.py   -> exports/star_schema/ fact + dim CSVs
"""

import subprocess
import sys


STEPS = [
    ("Step 1: Importing Kaggle data...",              [sys.executable, "setup/01_import_data.py"]),
    ("Step 2: Loading data into staging schema...",   [sys.executable, "pipeline/01_clean_and_load.py"]),
    ("Step 3: Validating data quality...",            [sys.executable, "pipeline/02_validate.py"]),
    ("Step 4: Exporting analytical query results...", [sys.executable, "pipeline/03_export_query_results.py"]),
    ("Step 5: Exporting star schema tables...",       [sys.executable, "pipeline/04_export_star_schema.py"]),
]


def run_step(label: str, cmd: list[str]) -> None:
    print(f"\n{'='*60}")
    print(label)
    print('='*60)
    result = subprocess.run(cmd, check=False)
    if result.returncode != 0:
        print(f"\nPipeline failed at: {label}")
        sys.exit(result.returncode)


if __name__ == "__main__":
    for label, cmd in STEPS:
        run_step(label, cmd)
    print("\nPipeline complete! Exports are ready for Power BI.")
