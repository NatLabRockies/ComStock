import argparse
from collections import Counter
import csv
import gzip
import json
from pathlib import Path


parser = argparse.ArgumentParser(description="Check every sampled baseline building succeeded.")
parser.add_argument("sample_file", type=Path)
parser.add_argument("result_file", type=Path)
args = parser.parse_args()

with args.sample_file.open(newline="") as stream:
    expected = [int(row["Building"]) for row in csv.DictReader(stream)]
with gzip.open(args.result_file, "rt") as stream:
    results = json.load(stream)
actual = Counter((int(row["building_id"]), int(row["upgrade"])) for row in results)
wanted = Counter((building, 0) for building in expected)
if not expected or actual != wanted:
    raise SystemExit(f"Baseline result IDs/counts differ: {actual} != {wanted}")
for row in results:
    if row.get("completed_status") != "Success":
        raise SystemExit(f"Building {row['building_id']} failed: {row}")
print(f"Validated {len(results)} successful baseline simulations.")
