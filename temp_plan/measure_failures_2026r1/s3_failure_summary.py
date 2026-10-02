"""Summarise the failing upgrades of the sdr_2026r1_all_measure_10k run from S3.

Run with the comstockpostproc2 env once the resbldg SSO session is live:
  python temp_plan/measure_failures_2026r1/s3_failure_summary.py [--ids 14,22,...] [--out DIR]

For each upgrade id it downloads results/results_up<NN>.parquet (or
parquet/upgrades/upgrade=<N>/*.parquet, whichever the run has), then prints
completed_status counts, apply_upgrade.applicable counts, the upgrade name,
and value counts of every column whose name contains error/fail/message/warn
(first 160 characters of each distinct value). It also looks for the run's
buildstock.csv and prints the hvac_system_type distribution, which is the first
check for the pump (26) and chiller (31) all-invalid question.
"""
import argparse, io, os, re, sys
import boto3, polars as pl

BUCKET = "eulp"
PREFIX = "euss_com/0_production_runs_2026R1/tests/sdr_2026r1_all_measure_10k/sdr_2026r1_all_measure_10k/"
DEFAULT_IDS = [14, 22, 26, 27, 29, 31, 43, 55, 56, 57, 64]


def list_keys(s3, prefix):
    keys = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=prefix):
        keys += [o["Key"] for o in page.get("Contents", [])]
    return keys


def read_parquet(s3, key):
    body = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    return pl.read_parquet(io.BytesIO(body))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ids", default=",".join(map(str, DEFAULT_IDS)))
    ap.add_argument("--out", default=None, help="directory for a markdown summary")
    a = ap.parse_args()
    ids = [int(x) for x in a.ids.split(",") if x.strip()]
    s3 = boto3.client("s3", region_name="us-west-2")

    top = s3.list_objects_v2(Bucket=BUCKET, Prefix=PREFIX, Delimiter="/")
    print("top-level prefixes:", [p["Prefix"].replace(PREFIX, "") for p in top.get("CommonPrefixes", [])])
    print("top-level objects:", [o["Key"].replace(PREFIX, "") for o in top.get("Contents", [])])

    keys = list_keys(s3, PREFIX)
    pq = [k for k in keys if k.endswith(".parquet")]
    print(f"{len(keys)} objects, {len(pq)} parquet files")

    lines = ["# S3 failure summary: sdr_2026r1_all_measure_10k", ""]
    for i in ids:
        cands = sorted({k for k in pq if re.search(rf"results_up0*{i}\.parquet$", k) or re.search(rf"upgrade=0*{i}/", k)})
        print("  files:", [k.replace(PREFIX, "") for k in cands])
        if not cands:
            print(f"--- upgrade {i}: no parquet found"); lines.append(f"## {i}: no parquet found"); continue
        df = pl.concat([read_parquet(s3, k) for k in cands], how="diagonal")
        name_col = next((c for c in df.columns if c.endswith("upgrade_name")), None)
        name = df[name_col].drop_nulls().unique().to_list() if name_col else "?"
        print(f"\n=== upgrade {i}: {name}  rows={df.height}  files={len(cands)}")
        lines.append(f"## {i}: {name} (rows={df.height})")
        for c in ("completed_status", "apply_upgrade.applicable"):
            if c in df.columns:
                vc = df.group_by(c).len().sort("len", descending=True)
                print(f"  {c}:", dict(zip(vc[c].to_list(), vc["len"].to_list())))
                lines.append(f"- {c}: {dict(zip(vc[c].to_list(), vc['len'].to_list()))}")
        msg_cols = [c for c in df.columns if re.search(r"error|fail|message|warn", c, re.I)]
        for c in msg_cols:
            vals = df[c].drop_nulls().cast(pl.Utf8)
            if vals.len() == 0:
                continue
            vc = vals.str.slice(0, 160).value_counts().sort("count", descending=True).head(8)
            print(f"  {c} (top distinct, first 160 chars):")
            for v, n in zip(vc[c].to_list(), vc["count"].to_list()):
                print(f"    {n:6d} | {v}")
                lines.append(f"- `{c}` x{n}: {v}")
        # one full message per distinct failure signature (file.rb:line or first 60 chars)
        if "step_failures" in df.columns:
            seen = {}
            for v in df["step_failures"].drop_nulls().cast(pl.Utf8).to_list():
                if "step_errors': []" in v:
                    continue
                m = re.search(r"([A-Za-z_]+\.rb:\d+)", v)
                sig = m.group(1) if m else v[:60]
                if sig not in seen:
                    seen[sig] = v
            for sig, v in seen.items():
                n = sum(1 for x in df["step_failures"].cast(pl.Utf8).to_list() if x and sig in x)
                print(f"  FULL [{sig}] x{n}: {v[:700]}")
                lines.append(f"- FULL `{sig}` x{n}: {v[:700]}")
        lines.append("")

    bs = [k for k in keys if k.endswith("buildstock.csv")]
    if bs:
        body = s3.get_object(Bucket=BUCKET, Key=bs[0])["Body"].read()
        b = pl.read_csv(io.BytesIO(body), infer_schema_length=0)
        col = next((c for c in b.columns if c.lower() == "hvac_system_type"), None)
        if col:
            vc = b.group_by(col).len().sort("len", descending=True)
            print(f"\nbuildstock.csv {bs[0]}: {b.height} rows; {col} distribution:")
            for v, n in zip(vc[col].to_list(), vc["len"].to_list()):
                print(f"  {n:6d}  {v}")
                lines.append(f"- hvac_system_type `{v}`: {n}")
    else:
        print("\nno buildstock.csv under the run prefix")

    if a.out:
        os.makedirs(a.out, exist_ok=True)
        p = os.path.join(a.out, "s3_failure_summary.md")
        open(p, "w", encoding="utf-8").write("\n".join(lines))
        print("wrote", p)


if __name__ == "__main__":
    sys.exit(main())
