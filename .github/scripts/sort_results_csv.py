"""Sort a results CSV by key columns so BuildStockBatch row order does not change committed results.

Each record's original text is kept exactly (quoting included), so sorting only reorders rows.
Key values that parse as numbers sort numerically; others sort as text.
"""

import argparse
import csv
from pathlib import Path

DEFAULT_KEYS = ["bldg_id", "in.state"]


def sort_key(value: str):
    try:
        return (0, float(value), "")
    except ValueError:
        return (1, 0.0, value)


def read_records(text: str):
    """Yield (parsed fields, original text) for each CSV record, including quoted multi-line fields."""
    raw_lines = []

    def tracked_lines():
        for line in text.splitlines(keepends=True):
            raw_lines.append(line)
            yield line

    for fields in csv.reader(tracked_lines(), strict=True):
        record = "".join(raw_lines)
        raw_lines.clear()
        yield fields, record


def sort_results_csv(source: Path, destination: Path, keys: list[str]) -> None:
    with source.open(encoding="utf-8", newline="") as stream:
        records = list(read_records(stream.read()))
    if not records or not records[0][0]:
        raise ValueError(f"{source} must contain a header")

    (header, header_text), body = records[0], records[1:]
    missing = [key for key in keys if key not in header]
    if missing:
        raise ValueError(f"{source} is missing sort columns: {', '.join(missing)}")
    indexes = [header.index(key) for key in keys]
    for record_number, (fields, _) in enumerate(body, start=2):
        if len(fields) != len(header):
            raise ValueError(f"{source}: record {record_number} has {len(fields)} fields, expected {len(header)}")

    body.sort(key=lambda record: tuple(sort_key(record[0][index]) for index in indexes))
    seen = set()
    for fields, _ in body:
        record_key = tuple(fields[index] for index in indexes)
        if record_key in seen:
            raise ValueError(f"{source} has duplicate records for {dict(zip(keys, record_key))}")
        seen.add(record_key)

    texts = [header_text, *(text for _, text in body)]
    # The last record may lack a trailing newline; give every record one so reordering cannot join rows.
    texts = [text if text.endswith(("\n", "\r")) else text + "\n" for text in texts]
    with destination.open("w", encoding="utf-8", newline="") as stream:
        stream.write("".join(texts))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--keys", nargs="+", default=DEFAULT_KEYS, help="sort columns, in priority order")
    args = parser.parse_args()
    try:
        sort_results_csv(args.source, args.destination, args.keys)
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
