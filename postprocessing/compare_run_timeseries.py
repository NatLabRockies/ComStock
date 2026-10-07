# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Compare per-building timeseries between two ComStock runs that used the same
buildstock.csv, on a random sample of buildings, and summarize the differences by
column.

Runs on the HPC against the raw buildstockbatch output, before anything is
uploaded:  <run>/results/simulation_output/timeseries/<upgrade>/<building>.parquet

For each sampled building present in both runs, every value of every column is
compared with the matching timestep of the other run (B - A). Numeric columns get
difference magnitudes; text and time columns are checked for equality.

Outputs (in --out):
  column_summary.csv       one row per column, over all sampled buildings: how many
                           values and buildings differ, total and per-value
                           difference sizes, RMSE / CV(RMSE), the largest single
                           difference and where it is, and approximate quantiles
                           of |diff| among the values that differ
  column_histogram.csv     per column, counts of |diff| (absolute and relative to
                           run A's value) in decade bins: 0, [1e-12, 1e-11), ...
  building_column.csv      one row per building x column (only those that differ,
                           unless --all-rows)
  building_summary.csv     one row per building: columns that differ, largest
                           total-energy difference
  structure.json           files, columns and row counts present in only one run,
                           buildstock.csv check, settings

Usage (on a compute node; a login node is fine for a small --n):
  python compare_run_timeseries.py RUN_A RUN_B --n 500
  python compare_run_timeseries.py /kfs2/projects/cscore/runs/x/run_a /kfs2/projects/cscore/runs/x/run_b
  python compare_run_timeseries.py run_a.yml run_b.yml --upgrade up01 --n 1000 --workers 52

RUN_A / RUN_B may each be a run directory, a buildstockbatch .yml (its
output_directory is used), or a run name looked up under --runs-root (default
$COMSTOCK_RUNS_ROOT, else /kfs2/projects/cscore/runs) up to three folders deep.

Example sbatch script:
  #!/bin/bash
  #SBATCH --account=<allocation> --partition=short --time=01:00:00 --nodes=1
  source activate /kfs2/projects/cscore/envs/comstockpostproc_<myname>
  cd /kfs2/projects/cscore/repos/comstock_<myname>/postprocessing
  python compare_run_timeseries.py run_a run_b --n 1000 --out /scratch/$USER/ts_diff_a_vs_b
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
import polars as pl
import yaml

DEFAULT_RUNS_ROOT = os.environ.get("COMSTOCK_RUNS_ROOT", "/kfs2/projects/cscore/runs")
TIME_COLS = ("timestamp", "time")

# |diff| histogram: bin 0 holds exact zeros, then one bin per decade from 1e-12
# to 1e9, with the ends open (below 1e-12, at or above 1e9).
ABS_EXP = np.arange(-12, 10)            # lower edges 1e-12 .. 1e9
REL_EXP = np.arange(-12, 4)             # lower edges 1e-12 .. 1e3 (relative to |A|)


def _bin_labels(exps: np.ndarray) -> list[str]:
    labels = ["0", f"<1e{exps[0]}"]
    labels += [f"[1e{e},1e{e + 1})" for e in exps[:-1]]
    labels += [f">=1e{exps[-1]}"]
    return labels


def _decade_counts(x: np.ndarray, exps: np.ndarray) -> np.ndarray:
    """Counts of x (>= 0) in: exact 0, below the first edge, each decade, above."""
    out = np.zeros(len(exps) + 2, dtype=np.int64)
    out[0] = int(np.count_nonzero(x == 0))
    nz = x[x > 0]
    if len(nz):
        k = np.floor(np.log10(nz)).astype(np.int64)
        idx = np.clip(k - exps[0], -1, len(exps) - 1) + 2   # -1 -> below first edge
        out += np.bincount(idx, minlength=len(out))[: len(out)]
    return out


def _pct(diff: float, base: float) -> float:
    """100 * diff / base; a change from a zero total is +/-inf (it sorts first), no
    change from zero is NaN."""
    if base:
        return 100.0 * diff / base
    return math.copysign(math.inf, diff) if diff else np.nan


# ---------------------------------------------------------------------------
# locating runs
# ---------------------------------------------------------------------------

def resolve_run(spec: str, runs_root: str) -> Path:
    p = Path(spec)
    if p.suffix in (".yml", ".yaml") and p.is_file():
        with open(p) as f:
            p = Path(yaml.safe_load(f)["output_directory"].rstrip("/"))
    elif not p.is_dir():
        root = Path(runs_root)
        hits = [h for pat in (spec, f"*/{spec}", f"*/*/{spec}") for h in root.glob(pat) if h.is_dir()]
        hits = [h for h in hits if (h / "results" / "simulation_output").is_dir()] or hits
        if len(hits) != 1:
            raise SystemExit(f"run {spec!r}: {'no' if not hits else len(hits)} matching folders under "
                             f"{root}{': ' + ', '.join(map(str, hits)) if hits else ''}. "
                             "Pass the run directory or its .yml instead.")
        p = hits[0]
    if not (p / "results" / "simulation_output").is_dir():
        raise SystemExit(f"{p} has no results/simulation_output folder")
    return p


def _md5(path: Path) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_buildstock(run_a: Path, run_b: Path) -> dict:
    """buildstockbatch copies the sample to housing_characteristics/buildstock.csv;
    the same building ID only means the same building when the two samples match."""
    pa = run_a / "housing_characteristics" / "buildstock.csv"
    pb = run_b / "housing_characteristics" / "buildstock.csv"
    if not (pa.is_file() and pb.is_file()):
        return {"checked": False, "reason": "housing_characteristics/buildstock.csv missing in "
                + ", ".join(str(x.parent.parent) for x in (pa, pb) if not x.is_file())}
    ha, hb = _md5(pa), _md5(pb)
    return {"checked": True, "identical": ha == hb, "md5_a": ha, "md5_b": hb}


def list_parquet(d: Path) -> dict[str, Path]:
    with os.scandir(d) as it:
        return {e.name: Path(e.path) for e in it if e.name.endswith(".parquet") and e.is_file()}


# ---------------------------------------------------------------------------
# one building
# ---------------------------------------------------------------------------

def _align(a: pl.DataFrame, b: pl.DataFrame) -> tuple[pl.DataFrame, pl.DataFrame, str | None, dict]:
    """Rows of A and B at the same timestep. By position when the time column (if
    any) matches row for row; otherwise an inner join on it."""
    info = {"rows_a": a.height, "rows_b": b.height}
    tcol = next((c for c in TIME_COLS if c in a.columns and c in b.columns), None)
    if tcol is None:
        n = min(a.height, b.height)
        info["aligned_by"] = "position (no shared time column)"
        return a.head(n), b.head(n), None, info
    if a.height == b.height and a[tcol].equals(b[tcol]):
        info["aligned_by"] = f"position ({tcol} identical)"
        return a, b, tcol, info
    key = a.select(tcol).join(b.select(tcol), on=tcol, how="inner").unique(maintain_order=True)
    info["aligned_by"] = f"join on {tcol}"
    info["rows_matched"] = key.height
    a2 = key.join(a, on=tcol, how="left", maintain_order="left")
    b2 = key.join(b, on=tcol, how="left", maintain_order="left")
    return a2, b2, tcol, info


def compare_building(job: tuple) -> dict:
    name, path_a, path_b, atol, rtol, all_rows = job
    out = {"building": name, "rows": [], "hist_abs": {}, "hist_rel": {}, "error": None}
    try:
        a, b = pl.read_parquet(path_a), pl.read_parquet(path_b)
    except Exception as e:  # noqa: BLE001 -- a bad file is reported, not fatal
        out["error"] = f"{type(e).__name__}: {e}"
        return out
    out["only_a"] = [c for c in a.columns if c not in b.columns]
    out["only_b"] = [c for c in b.columns if c not in a.columns]
    a, b, tcol, info = _align(a, b)
    out.update(info)
    times = a[tcol].cast(pl.String).to_list() if tcol else None
    for col in [c for c in a.columns if c in b.columns]:
        sa, sb = a[col], b[col]
        row = {"building": name, "column": col, "n": a.height}
        if not (sa.dtype.is_numeric() and sb.dtype.is_numeric()):
            neq = int((sa.cast(pl.String) != sb.cast(pl.String)).fill_null(True).sum()
                      - (sa.is_null() & sb.is_null()).sum())
            row.update(kind="non-numeric", n_differ=neq)
            if neq or all_rows:
                out["rows"].append(row)
            else:
                out.setdefault("same_rows", []).append(row)   # kept for the column totals
            continue
        x = sa.cast(pl.Float64).fill_null(np.nan).to_numpy()
        y = sb.cast(pl.Float64).fill_null(np.nan).to_numpy()
        nan_a, nan_b = np.isnan(x), np.isnan(y)
        ok = ~nan_a & ~nan_b
        x, y = x[ok], y[ok]
        d = y - x
        ad = np.abs(d)
        differ = ad > (atol + rtol * np.abs(x))
        with np.errstate(divide="ignore", invalid="ignore"):
            rel = np.where(np.abs(x) > 0, ad / np.abs(x), np.where(ad > 0, np.inf, 0.0))
        imax = int(np.argmax(ad)) if len(ad) else -1
        sum_a, sum_b = float(x.sum()), float(y.sum())
        row.update(
            kind="numeric",
            n_compared=int(ok.sum()),
            nan_mismatch=int((nan_a ^ nan_b).sum()),
            n_differ=int(differ.sum()),
            sum_a=sum_a, sum_b=sum_b,
            total_diff=sum_b - sum_a,
            total_pct_diff=_pct(sum_b - sum_a, sum_a),
            sum_abs_a=float(np.abs(x).sum()),
            sum_abs_diff=float(ad.sum()),
            sum_sq_diff=float((d * d).sum()),
            max_abs_diff=float(ad[imax]) if imax >= 0 else 0.0,
            max_abs_diff_a=float(x[imax]) if imax >= 0 else np.nan,
            max_abs_diff_b=float(y[imax]) if imax >= 0 else np.nan,
            max_abs_diff_time=(np.asarray(times, dtype=object)[ok][imax] if times and imax >= 0
                               else (int(np.flatnonzero(ok)[imax]) if imax >= 0 else None)),
            max_rel_diff=float(rel[np.isfinite(rel)].max()) if np.isfinite(rel).any() else 0.0,
            n_rel_inf=int(np.isinf(rel).sum()),
        )
        out["hist_abs"][col] = _decade_counts(ad, ABS_EXP)
        out["hist_rel"][col] = _decade_counts(rel[np.isfinite(rel)], REL_EXP)
        if row["n_differ"] or row["nan_mismatch"] or all_rows:
            out["rows"].append(row)
        else:
            out.setdefault("same_rows", []).append(row)   # kept for the column totals
    return out


# ---------------------------------------------------------------------------
# summaries
# ---------------------------------------------------------------------------

def _quantile_upper(counts: np.ndarray, q: float, exps: np.ndarray) -> float:
    """Upper edge of the decade bin holding quantile q of the NONZERO differences."""
    nz = counts[1:]
    tot = nz.sum()
    if not tot:
        return 0.0
    k = int(np.searchsorted(np.cumsum(nz), q * tot))
    uppers = [10.0 ** exps[0]] + [10.0 ** (e + 1) for e in exps[:-1]] + [math.inf]
    return uppers[k]


def summarize(results: list[dict]) -> tuple[pl.DataFrame, pl.DataFrame, pl.DataFrame, pl.DataFrame]:
    rows = [r for res in results for r in res["rows"] + res.get("same_rows", [])]
    numeric = [r for r in rows if r["kind"] == "numeric"]
    nonnum = [r for r in rows if r["kind"] == "non-numeric"]

    hist_abs, hist_rel = {}, {}
    for res in results:
        for c, h in res["hist_abs"].items():
            hist_abs[c] = hist_abs.get(c, 0) + h
        for c, h in res["hist_rel"].items():
            hist_rel[c] = hist_rel.get(c, 0) + h

    col_rows = []
    by_col: dict[str, list[dict]] = {}
    for r in numeric:
        by_col.setdefault(r["column"], []).append(r)
    for col, rs in by_col.items():
        n = sum(r["n_compared"] for r in rs)
        n_diff = sum(r["n_differ"] for r in rs)
        sum_a, sum_b = sum(r["sum_a"] for r in rs), sum(r["sum_b"] for r in rs)
        rmse = math.sqrt(sum(r["sum_sq_diff"] for r in rs) / n) if n else np.nan
        mean_a = sum_a / n if n else np.nan
        worst = max(rs, key=lambda r: r["max_abs_diff"])
        bld_pct = np.array([abs(r["total_pct_diff"]) for r in rs if np.isfinite(r["total_pct_diff"])])
        ha = hist_abs.get(col, np.zeros(len(ABS_EXP) + 2, dtype=np.int64))
        col_rows.append({
            "column": col,
            "buildings": len(rs),
            "buildings_differ": sum(1 for r in rs if r["n_differ"] or r["nan_mismatch"]),
            "values": n,
            "values_differ": n_diff,
            "pct_values_differ": 100.0 * n_diff / n if n else np.nan,
            "nan_mismatch": sum(r["nan_mismatch"] for r in rs),
            "sum_a": sum_a, "sum_b": sum_b, "total_diff": sum_b - sum_a,
            "total_pct_diff": _pct(sum_b - sum_a, sum_a),
            "mean_abs_diff": sum(r["sum_abs_diff"] for r in rs) / n if n else np.nan,
            "mean_abs_diff_where_differ": (sum(r["sum_abs_diff"] for r in rs) / n_diff) if n_diff else 0.0,
            "abs_diff_pct_of_abs_a": (100.0 * sum(r["sum_abs_diff"] for r in rs)
                                      / sum(r["sum_abs_a"] for r in rs)) if sum(r["sum_abs_a"] for r in rs) else np.nan,
            "rmse": rmse,
            "cv_rmse_pct": 100.0 * rmse / abs(mean_a) if mean_a else np.nan,
            "max_abs_diff": worst["max_abs_diff"],
            "max_abs_diff_building": worst["building"],
            "max_abs_diff_time": worst["max_abs_diff_time"],
            "max_abs_diff_a": worst["max_abs_diff_a"],
            "max_abs_diff_b": worst["max_abs_diff_b"],
            "max_rel_diff": max(r["max_rel_diff"] for r in rs),
            "values_a_zero_b_nonzero": sum(r["n_rel_inf"] for r in rs),
            "building_abs_total_pct_diff_median": float(np.median(bld_pct)) if len(bld_pct) else np.nan,
            "building_abs_total_pct_diff_p95": float(np.percentile(bld_pct, 95)) if len(bld_pct) else np.nan,
            "building_abs_total_pct_diff_max": float(bld_pct.max()) if len(bld_pct) else np.nan,
            "abs_diff_p50_upper": _quantile_upper(ha, 0.50, ABS_EXP),
            "abs_diff_p90_upper": _quantile_upper(ha, 0.90, ABS_EXP),
            "abs_diff_p99_upper": _quantile_upper(ha, 0.99, ABS_EXP),
        })
    for col in sorted({r["column"] for r in nonnum}):
        rs = [r for r in nonnum if r["column"] == col]
        n, n_diff = sum(r["n"] for r in rs), sum(r["n_differ"] for r in rs)
        col_rows.append({"column": col, "buildings": len(rs),
                         "buildings_differ": sum(1 for r in rs if r["n_differ"]),
                         "values": n, "values_differ": n_diff,
                         "pct_values_differ": 100.0 * n_diff / n if n else np.nan})
    col_summary = pl.DataFrame(col_rows, infer_schema_length=None)
    if col_summary.height:
        col_summary = col_summary.with_columns(
            pl.col("total_pct_diff").abs().alias("_k1"), pl.col("pct_values_differ").alias("_k2")
        ).sort(["_k1", "_k2"], descending=True, nulls_last=True).drop("_k1", "_k2")

    abs_labels, rel_labels = _bin_labels(ABS_EXP), _bin_labels(REL_EXP)
    hist_rows = []
    for col in sorted(hist_abs):
        for lab, cnt in zip(abs_labels, hist_abs[col]):
            hist_rows.append({"column": col, "measure": "abs_diff", "bin": lab, "count": int(cnt)})
        for lab, cnt in zip(rel_labels, hist_rel[col]):
            hist_rows.append({"column": col, "measure": "rel_diff_to_a", "bin": lab, "count": int(cnt)})
    hist = pl.DataFrame(hist_rows, schema={"column": pl.String, "measure": pl.String,
                                           "bin": pl.String, "count": pl.Int64})

    bc = pl.DataFrame([r for res in results for r in res["rows"]], infer_schema_length=None)

    bs_rows = []
    for res in results:
        num = [r for r in res["rows"] + res.get("same_rows", []) if r["kind"] == "numeric"]
        worst = max((r for r in num if np.isfinite(r["total_pct_diff"])),
                    key=lambda r: abs(r["total_pct_diff"]), default=None)
        bs_rows.append({
            "building": res["building"], "error": res["error"],
            "rows_a": res.get("rows_a"), "rows_b": res.get("rows_b"), "aligned_by": res.get("aligned_by"),
            "columns_only_a": len(res.get("only_a", [])), "columns_only_b": len(res.get("only_b", [])),
            "columns_compared": len(num),
            "columns_differ": sum(1 for r in res["rows"] if r.get("n_differ") or r.get("nan_mismatch")),
            "worst_total_pct_column": worst["column"] if worst else None,
            "worst_total_pct_diff": worst["total_pct_diff"] if worst else None,
        })
    bsum = pl.DataFrame(bs_rows, infer_schema_length=None)
    return col_summary, hist, bc, bsum


# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("run_a", help="reference run: directory, .yml, or run name under --runs-root")
    ap.add_argument("run_b", help="run compared against A (differences are B - A)")
    ap.add_argument("--n", type=int, default=200, help="buildings to sample (default 200; 0 = all)")
    ap.add_argument("--seed", type=int, default=0, help="random seed for the sample")
    ap.add_argument("--upgrade", default="up00", help="timeseries upgrade folder (default up00)")
    ap.add_argument("--runs-root", default=DEFAULT_RUNS_ROOT,
                    help=f"where run names are looked up (default {DEFAULT_RUNS_ROOT})")
    ap.add_argument("--atol", type=float, default=0.0,
                    help="a value differs when |B-A| > atol + rtol*|A| (default exact: 0, 0)")
    ap.add_argument("--rtol", type=float, default=0.0)
    ap.add_argument("--workers", type=int,
                    default=int(os.environ.get("SLURM_CPUS_ON_NODE", 0)) or os.cpu_count() or 1)
    ap.add_argument("--out", type=Path, default=None,
                    help="output folder (default ./ts_diff_<A>_vs_<B>)")
    ap.add_argument("--all-rows", action="store_true",
                    help="write every building x column row, not only those that differ")
    ap.add_argument("--allow-different-buildstock", action="store_true",
                    help="compare even when the two runs' buildstock.csv files differ")
    args = ap.parse_args(argv)

    t0 = time.time()
    run_a, run_b = resolve_run(args.run_a, args.runs_root), resolve_run(args.run_b, args.runs_root)
    print(f"A: {run_a}\nB: {run_b}")
    bstock = check_buildstock(run_a, run_b)
    if bstock.get("checked") and not bstock["identical"]:
        msg = "the two runs' housing_characteristics/buildstock.csv files differ"
        if not args.allow_different_buildstock:
            raise SystemExit(f"{msg}: building IDs are different buildings. "
                             "Pass --allow-different-buildstock to compare anyway.")
        print(f"WARNING: {msg}")
    elif not bstock.get("checked"):
        print(f"WARNING: buildstock.csv not checked ({bstock['reason']})")

    ts_a = run_a / "results" / "simulation_output" / "timeseries" / args.upgrade
    ts_b = run_b / "results" / "simulation_output" / "timeseries" / args.upgrade
    for d in (ts_a, ts_b):
        if not d.is_dir():
            raise SystemExit(f"no timeseries folder {d}")
    files_a, files_b = list_parquet(ts_a), list_parquet(ts_b)
    common = sorted(set(files_a) & set(files_b))
    only_a, only_b = sorted(set(files_a) - set(files_b)), sorted(set(files_b) - set(files_a))
    print(f"timeseries files: A {len(files_a)}, B {len(files_b)}, both {len(common)}, "
          f"only A {len(only_a)}, only B {len(only_b)}")
    if not common:
        raise SystemExit("no building timeseries file is in both runs")
    sample = common if args.n <= 0 or args.n >= len(common) else sorted(
        random.Random(args.seed).sample(common, args.n))

    out = args.out or Path(f"ts_diff_{run_a.name}_vs_{run_b.name}")
    out.mkdir(parents=True, exist_ok=True)
    jobs = [(n, str(files_a[n]), str(files_b[n]), args.atol, args.rtol, args.all_rows) for n in sample]
    workers = max(1, min(args.workers, len(jobs)))
    print(f"comparing {len(jobs)} buildings with {workers} workers ...")
    results = []
    if workers == 1:
        results = [compare_building(j) for j in jobs]
    else:
        with ProcessPoolExecutor(max_workers=workers) as ex:
            for i, r in enumerate(ex.map(compare_building, jobs, chunksize=max(1, len(jobs) // (workers * 4))), 1):
                results.append(r)
                if i % max(1, len(jobs) // 10) == 0:
                    print(f"  {i}/{len(jobs)}")

    col_summary, hist, bc, bsum = summarize(results)
    col_summary.write_csv(out / "column_summary.csv")
    hist.write_csv(out / "column_histogram.csv")
    bc.write_csv(out / "building_column.csv")
    bsum.write_csv(out / "building_summary.csv")

    cols_only_a = sorted({c for r in results for c in r.get("only_a", [])})
    cols_only_b = sorted({c for r in results for c in r.get("only_b", [])})
    structure = {
        "run_a": str(run_a), "run_b": str(run_b), "upgrade": args.upgrade,
        "buildstock_check": bstock,
        "files": {"a": len(files_a), "b": len(files_b), "both": len(common),
                  "only_a": len(only_a), "only_b": len(only_b),
                  "only_a_examples": only_a[:50], "only_b_examples": only_b[:50]},
        "sampled": len(sample), "seed": args.seed, "atol": args.atol, "rtol": args.rtol,
        "read_errors": {r["building"]: r["error"] for r in results if r["error"]},
        "columns_only_a": cols_only_a, "columns_only_b": cols_only_b,
        "row_count_mismatch": [{"building": r["building"], "rows_a": r["rows_a"], "rows_b": r["rows_b"],
                                "aligned_by": r["aligned_by"]}
                               for r in results if not r["error"] and r["rows_a"] != r["rows_b"]],
        "seconds": round(time.time() - t0, 1),
    }
    (out / "structure.json").write_text(json.dumps(structure, indent=2, default=str))

    # console summary
    num = col_summary.filter(pl.col("sum_a").is_not_null()) if "sum_a" in col_summary.columns else col_summary
    differ = num.filter(pl.col("values_differ") > 0)
    print(f"\n{num.height} numeric columns compared; {differ.height} have differences "
          f"(|B-A| > {args.atol} + {args.rtol}*|A|).")
    if cols_only_a or cols_only_b:
        print(f"columns only in A: {len(cols_only_a)}; only in B: {len(cols_only_b)} (see structure.json)")
    if structure["read_errors"]:
        print(f"{len(structure['read_errors'])} buildings could not be read (see structure.json)")
    if differ.height:
        with pl.Config(tbl_rows=25, tbl_cols=8, fmt_str_lengths=60, tbl_width_chars=200):
            print(differ.select("column", "buildings_differ", "pct_values_differ", "total_pct_diff",
                                "cv_rmse_pct", "max_abs_diff", "abs_diff_p90_upper").head(25))
    print(f"\nwrote {out}/ in {structure['seconds']} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
