"""Sort a results CSV by key columns so BuildStockBatch row order does not change committed results.

Each record's original text is kept exactly (quoting included), so sorting only reorders rows.
Key values that parse as numbers sort numerically; others sort as text.

With --previous (the committed copy of the same file), numeric values that match the previous value
within a tolerance keep the previous text. Floating-point noise between runs (differences in the
last digits from summing in a different order) then leaves the file unchanged, while any change
beyond the tolerance still shows up.
"""

import argparse
import csv
import math
import re
from collections import Counter
from pathlib import Path

DEFAULT_KEYS = ["bldg_id", "in.state"]
# Run-to-run noise in the committed results has stayed below 1e-10 relative.
DEFAULT_REL_TOL = 1e-9
LINE_END = re.compile(r"(\r\n|\n|\r)\Z")


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


def read_csv(path: Path, keys: list[str]):
    """Return (header, header text, body records) after validating the header, keys and field counts."""
    with path.open(encoding="utf-8", newline="") as stream:
        records = list(read_records(stream.read()))
    if not records or not records[0][0]:
        raise ValueError(f"{path} must contain a header")

    (header, header_text), body = records[0], records[1:]
    missing = [key for key in keys if key not in header]
    if missing:
        raise ValueError(f"{path} is missing sort columns: {', '.join(missing)}")
    for record_number, (fields, _) in enumerate(body, start=2):
        if len(fields) != len(header):
            raise ValueError(f"{path}: record {record_number} has {len(fields)} fields, expected {len(header)}")
    return header, header_text, body


def split_raw_fields(record: str) -> tuple[list[str], str]:
    """Split one record's original text into each field's original text, plus its line ending."""
    match = LINE_END.search(record)
    line_end = match.group(0) if match else ""
    body = record[: len(record) - len(line_end)]
    fields, start, quoted = [], 0, False
    for index, char in enumerate(body):
        if char == '"':
            quoted = not quoted
        elif char == "," and not quoted:
            fields.append(body[start:index])
            start = index + 1
    fields.append(body[start:])
    return fields, line_end


def within_tolerance(new: str, old: str, rel_tol: float, abs_tol: float) -> bool:
    try:
        new_value, old_value = float(new), float(old)
    except ValueError:
        return False
    if math.isnan(new_value) or math.isnan(old_value):
        return False
    return math.isclose(new_value, old_value, rel_tol=rel_tol, abs_tol=abs_tol)


def keep_previous_text(header, fields, record, previous, rel_tol, abs_tol, changed: Counter):
    """Rebuild a record using the previous text for every value that matches within tolerance."""
    previous_values, previous_raw = previous
    raw_fields, line_end = split_raw_fields(record)
    if len(raw_fields) != len(fields):
        return record, 0  # Cannot map raw text to fields safely; keep the new record as written.
    kept = 0
    for index, column in enumerate(header):
        if column not in previous_values:
            continue
        new, old = fields[index], previous_values[column]
        if new == old:
            raw_fields[index] = previous_raw[column]
        elif within_tolerance(new, old, rel_tol, abs_tol):
            raw_fields[index] = previous_raw[column]
            kept += 1
        else:
            changed[column] += 1
    return ",".join(raw_fields) + line_end, kept


def sort_results_csv(
    source: Path,
    destination: Path,
    keys: list[str],
    previous: Path | None = None,
    rel_tol: float = DEFAULT_REL_TOL,
    abs_tol: float = 0.0,
) -> dict:
    header, header_text, body = read_csv(source, keys)
    indexes = [header.index(key) for key in keys]
    body.sort(key=lambda record: tuple(sort_key(record[0][index]) for index in indexes))
    seen = set()
    for fields, _ in body:
        record_key = tuple(fields[index] for index in indexes)
        if record_key in seen:
            raise ValueError(f"{source} has duplicate records for {dict(zip(keys, record_key))}")
        seen.add(record_key)

    summary = {"kept_within_tolerance": 0, "changed": Counter(), "new_records": 0}
    texts = [header_text]
    previous_records = {}
    if previous is not None and previous.exists():
        previous_header, _, previous_body = read_csv(previous, keys)
        previous_indexes = [previous_header.index(key) for key in keys]
        for fields, record in previous_body:
            raw_fields, _ = split_raw_fields(record)
            if len(raw_fields) == len(fields):
                previous_records[tuple(fields[index] for index in previous_indexes)] = (
                    dict(zip(previous_header, fields)),
                    dict(zip(previous_header, raw_fields)),
                )
    for fields, record in body:
        record_key = tuple(fields[index] for index in indexes)
        if record_key in previous_records:
            record, kept = keep_previous_text(
                header, fields, record, previous_records[record_key], rel_tol, abs_tol, summary["changed"]
            )
            summary["kept_within_tolerance"] += kept
        elif previous_records:
            summary["new_records"] += 1
        texts.append(record)

    # The last record may lack a trailing newline; give every record one so reordering cannot join rows.
    texts = [text if text.endswith(("\n", "\r")) else text + "\n" for text in texts]
    with destination.open("w", encoding="utf-8", newline="") as stream:
        stream.write("".join(texts))
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--keys", nargs="+", default=DEFAULT_KEYS, help="sort columns, in priority order")
    parser.add_argument("--previous", type=Path, help="committed copy to keep values from when within tolerance")
    parser.add_argument("--rel-tol", type=float, default=DEFAULT_REL_TOL, help="relative tolerance (default %(default)g)")
    parser.add_argument("--abs-tol", type=float, default=0.0, help="absolute tolerance (default %(default)g)")
    args = parser.parse_args()
    try:
        summary = sort_results_csv(args.source, args.destination, args.keys, args.previous, args.rel_tol, args.abs_tol)
    except ValueError as error:
        parser.error(str(error))
    if args.previous is not None:
        changed = summary["changed"]
        print(
            f"{args.destination.name}: kept {summary['kept_within_tolerance']} values within rel_tol {args.rel_tol:g}; "
            f"{sum(changed.values())} values in {len(changed)} columns changed beyond it; "
            f"{summary['new_records']} new records"
        )
        for column, count in changed.most_common(10):
            print(f"  changed: {column} ({count})")


if __name__ == "__main__":
    main()
