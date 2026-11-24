import argparse
from collections import Counter
import csv
import gzip
import json
from pathlib import Path


parser = argparse.ArgumentParser(description="Validate baseline and optional upgrade simulation results.")
parser.add_argument("sample_file", type=Path)
parser.add_argument("result_file", type=Path)
parser.add_argument("--project-file", type=Path, help="Require results for all upgrades in this project.")
args = parser.parse_args()

upgrade_count = 0
if args.project_file:
    import yaml

    with args.project_file.open(encoding="utf-8") as stream:
        upgrade_count = len(yaml.safe_load(stream)["upgrades"])

with args.sample_file.open(newline="") as stream:
    expected = [int(row["Building"]) for row in csv.DictReader(stream)]
with gzip.open(args.result_file, "rt") as stream:
    results = json.load(stream)
actual = Counter((int(row["building_id"]), int(row["upgrade"])) for row in results)
wanted = Counter((building, upgrade) for building in expected for upgrade in range(upgrade_count + 1))
if not expected or actual != wanted:
    raise SystemExit(f"Simulation result IDs/counts differ: missing {wanted - actual}, unexpected {actual - wanted}")
for row in results:
    status = row.get("completed_status")
    if status == "Success" or (int(row["upgrade"]) > 0 and status == "Invalid"):
        continue
    raise SystemExit(f"Building {row['building_id']}, upgrade {row['upgrade']} failed: {row}")

if args.project_file:
    csv_dir = args.result_file.parent.parent / "results_csvs"
    expected_csvs = {f"results_up{upgrade:02d}.csv.gz" for upgrade in range(upgrade_count + 1)}
    actual_csvs = {path.name for path in csv_dir.glob("results_up*.csv.gz")}
    if actual_csvs != expected_csvs:
        raise SystemExit(f"Result CSVs differ: missing {expected_csvs - actual_csvs}, unexpected {actual_csvs - expected_csvs}")

print(f"Validated {len(results)} simulation results across {upgrade_count + 1} scenarios.")
