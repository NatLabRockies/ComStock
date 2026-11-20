import argparse
import csv
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description="Remove detailed electricity bills from the baseline CSV.")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()

    column = "utility_bills.electricity_utility_bill_results"
    with args.source.open(encoding="utf-8", newline="") as stream:
        rows = list(csv.reader(stream, strict=True))

    if not rows or rows[0].count(column) != 1:
        parser.error(f"{args.source} must contain exactly one {column!r} column")

    header = rows[0]
    index = header.index(column)
    for row_number, row in enumerate(rows, start=1):
        if len(row) != len(header):
            parser.error(f"{args.source}: row {row_number} has {len(row)} fields, expected {len(header)}")

    with args.destination.open("w", encoding="utf-8", newline="") as stream:
        csv.writer(stream).writerows(row[:index] + row[index + 1 :] for row in rows)


if __name__ == "__main__":
    main()
