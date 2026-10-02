"""Characterise the buildings behind each failure signature of selected upgrades.

Usage: python s3_failed_building_characteristics.py 12,13,23,28,30,48,54,59,63
Reads building_id, completed_status and step_failures from each results_upNN.parquet through
ranged GETs, joins the failing ids to buildstock_csv/buildstock.csv, and prints, per signature,
the building ids and the distribution of building_type, hvac_system_type, size and other fields.
Needs a live resbldg SSO session.
"""
import io, re, sys
import boto3, polars as pl, pyarrow.parquet as pq
from s3_all_upgrades_scan import S3RangeFile, signature, BUCKET, PREFIX

FIELDS = ["building_type", "hvac_system_type", "rentable_area", "number_of_stories", "year_built", "climate_zone", "building_subtype", "heating_fuel", "service_water_heating_fuel"]


def main():
    ids = [int(x) for x in sys.argv[1].split(",")]
    s3 = boto3.client("s3", region_name="us-west-2")
    body = s3.get_object(Bucket=BUCKET, Key=PREFIX + "buildstock_csv/buildstock.csv")["Body"].read()
    bs = pl.read_csv(io.BytesIO(body), infer_schema_length=0)
    idc = [c for c in bs.columns if c.lower() in ("building", "building id", "building_id")][0]
    fields = [f for f in FIELDS if f in bs.columns]
    sig_ids = {}
    for i in ids:
        key = f"{PREFIX}upgrades/upgrade={i}/results_up{i:02d}.parquet"
        pf = pq.ParquetFile(S3RangeFile(s3, BUCKET, key))
        df = pl.from_arrow(pf.read(columns=["building_id", "completed_status", "step_failures"]))
        f = df.filter(pl.col("completed_status") == "Fail")
        for bid, v in zip(f["building_id"].to_list(), f["step_failures"].cast(pl.Utf8).to_list()):
            s = "(simulation-side, no measure error)" if (v is None or "step_errors': []" in v) else signature(v)
            if "create_custom_building_from_spec" in s:
                continue
            sig_ids.setdefault((i, s), set()).add(str(bid))
    for (i, s), bids in sorted(sig_ids.items()):
        sub = bs.filter(pl.col(idc).is_in(sorted(bids)))
        print(f"\n=== upgrade {i} | {s} | {len(bids)} buildings: {sorted(map(int, bids))[:40]}")
        for fld in fields:
            vc = sub.group_by(fld).len().sort("len", descending=True)
            top = ", ".join(f"{v} ({n})" for v, n in zip(vc[fld].to_list()[:6], vc["len"].to_list()[:6]))
            print(f"   {fld}: {top}")
    # overlap of simulation-side failures across upgrades
    sim = {k: v for k, v in sig_ids.items() if "simulation-side" in k[1]}
    if len(sim) > 1:
        allb = {}
        for (i, _), bids in sim.items():
            for b in bids:
                allb.setdefault(b, []).append(i)
        multi = {b: u for b, u in allb.items() if len(u) > 1}
        print(f"\nsimulation-side failures: {len(allb)} distinct buildings, {len(multi)} fail in more than one upgrade: " + ", ".join(f"{b}:{u}" for b, u in sorted(multi.items(), key=lambda x: int(x[0]))[:30]))


if __name__ == "__main__":
    main()
