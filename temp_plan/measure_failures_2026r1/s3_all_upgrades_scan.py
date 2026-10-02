"""Scan every upgrade of sdr_2026r1_all_measure_10k for completed_status and failure signatures.

Reads only building_id, completed_status, apply_upgrade.applicable and step_failures from each
upgrades/upgrade=N/results_upNN.parquet through ranged GETs, so the 60 MB files cost a few MB.
Writes s3_all_upgrades_scan.md next to this script. Needs a live resbldg SSO session.
"""
import io, os, re, sys
import boto3, polars as pl, pyarrow.parquet as pq

BUCKET = "eulp"
PREFIX = "euss_com/0_production_runs_2026R1/tests/sdr_2026r1_all_measure_10k/sdr_2026r1_all_measure_10k/"
COLS = ["building_id", "completed_status", "apply_upgrade.applicable", "apply_upgrade.upgrade_name", "step_failures"]


class S3RangeFile(io.RawIOBase):
    """Minimal seekable read-only file over an S3 object using ranged GETs."""

    def __init__(self, s3, bucket, key):
        self.s3, self.bucket, self.key = s3, bucket, key
        self._size = s3.head_object(Bucket=bucket, Key=key)["ContentLength"]
        self._pos = 0

    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self._pos
    def size(self): return self._size

    def seek(self, off, whence=0):
        self._pos = {0: off, 1: self._pos + off, 2: self._size + off}[whence]
        return self._pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self._size - self._pos
        if n == 0 or self._pos >= self._size:
            return b""
        end = min(self._pos + n, self._size) - 1
        body = self.s3.get_object(Bucket=self.bucket, Key=self.key, Range=f"bytes={self._pos}-{end}")["Body"].read()
        self._pos += len(body)
        return body


def signature(v):
    m = re.search(r"measures/([A-Za-z_0-9]+)/measure\.rb:(\d+)", v)
    if m:
        return f"{m.group(1)}:{m.group(2)}"
    m = re.search(r"step_errors': \[\"?'?(.{0,90})", v)
    return (m.group(1) if m else v[:90]).replace("|", "/")


def main():
    only = [int(x) for x in sys.argv[1].split(",")] if len(sys.argv) > 1 else None
    s3 = boto3.client("s3", region_name="us-west-2")
    keys = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=PREFIX + "upgrades/"):
        keys += [o["Key"] for o in page.get("Contents", []) if o["Key"].endswith(".parquet")]
    ups = sorted({(int(re.search(r"upgrade=(\d+)/", k).group(1)), k) for k in keys})
    print(f"{len(ups)} upgrade parquet files")
    rows = ["# All-upgrade scan: sdr_2026r1_all_measure_10k", "",
            "| id | name | rows | Success | Invalid | Fail | top failure signatures (count) |", "|---|---|---|---|---|---|---|"]
    for i, k in ups:
        if only and i not in only:
            continue
        f = S3RangeFile(s3, BUCKET, k)
        pf = pq.ParquetFile(f)
        cols = [c for c in COLS if c in pf.schema_arrow.names]
        df = pl.from_arrow(pf.read(columns=cols))
        n = df.height
        st = dict(zip(*[x.to_list() for x in df.group_by("completed_status").len().select(["completed_status", "len"]).get_columns()])) if "completed_status" in cols else {}
        name = ""
        if "apply_upgrade.upgrade_name" in cols:
            u = df["apply_upgrade.upgrade_name"].drop_nulls().unique().to_list()
            name = u[0] if u else ""
        sigs = {}
        if "step_failures" in cols:
            for v in df.filter(pl.col("completed_status") == "Fail")["step_failures"].cast(pl.Utf8).to_list():
                s = "(Fail with no measure error: simulation-side)" if (v is None or "step_errors': []" in v) else signature(v)
                sigs[s] = sigs.get(s, 0) + 1
        top = "; ".join(f"{s} ({c})" for s, c in sorted(sigs.items(), key=lambda x: -x[1])[:4])
        line = f"| {i} | {name} | {n} | {st.get('Success', 0)} | {st.get('Invalid', 0)} | {st.get('Fail', 0)} | {top} |"
        rows.append(line)
        print(line)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "s3_all_upgrades_scan.md")
    if only:
        print("subset run: not rewriting", out)
    else:
        open(out, "w", encoding="utf-8").write(chr(10).join(rows) + chr(10))
        print("wrote", out)

    body = s3.get_object(Bucket=BUCKET, Key=PREFIX + "buildstock_csv/buildstock.csv")["Body"].read()
    b = pl.read_csv(io.BytesIO(body), infer_schema_length=0)
    idc = [c for c in b.columns if c.lower() in ("building", "building id", "building_id", "bldg_id")][0]
    want = [c for c in b.columns if c in ("building_type", "building_subtype", "hvac_system_type", "rentable_area", "number_of_stories", "sqft", "year_built", "climate_zone", "county_id", "lighting_generation")]
    print(b.filter(pl.col(idc).is_in(["2537", "7223"])).select([idc] + want).to_pandas().to_string())


if __name__ == "__main__":
    sys.exit(main())
