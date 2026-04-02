"""
End-to-end pipeline orchestration.

Runs all pipeline steps sequentially in the current Python environment.
Equivalent to running each script individually, but from a single entry point.

Usage:
  python dagger/pipeline.py

Steps:
  1. setup/01_import_data.py          -> download real Kaggle data
  2. setup/03_generate_messy_data.py  -> combine real + synthetic data
  3. pipeline/01_clean_and_load.py    -> staging schema
  4. pipeline/02_build_warehouse.py   -> warehouse DDL
  5. pipeline/03_backfill.py          -> all date partitions + monthly cohort
  6. pipeline/04_validate.py          -> data quality checks
  7. pipeline/05_export_query_results.py -> exports/ CSVs for Power BI
"""

import subprocess
import sys


STEPS = [
    ("Step 1: Importing Kaggle data...",             [sys.executable, "setup/01_import_data.py"]),
    ("Step 2: Generating synthetic messy data...",   [sys.executable, "setup/03_generate_messy_data.py"]),
    ("Step 3: Cleaning data into staging schema...", [sys.executable, "pipeline/01_clean_and_load.py"]),
    ("Step 4: Building warehouse tables...",         [sys.executable, "pipeline/02_build_warehouse.py"]),
    ("Step 5: Backfilling date partitions...",       [sys.executable, "pipeline/03_backfill.py"]),
    ("Step 6: Validating data quality...",           [sys.executable, "pipeline/04_validate.py"]),
    ("Step 7: Exporting query results to CSVs...",   [sys.executable, "pipeline/05_export_query_results.py"]),
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
    print("\nPipeline complete. marketplace.duckdb and exports/ are ready.")
