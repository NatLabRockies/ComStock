# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""California: ComStock against the CalMAC non-residential granular profiles.

ComStock side. Buildings are selected by electric utility and grouped into the
granular-profile (GP) segments -- industry, CEC climate-zone group, size -- with the
run's LOCAL California weight table (comstockpostproc.california.weights), whose rows
are passed INLINE into the timeseries query as a VALUES list. Nothing new is created
in Athena: the run's existing `<run>_timeseries` table is the only object read.
Every segment gets a global integer code, so one query covers both utilities; the
weight rows are packed into as few queries as fit under MAX_SQL_BYTES (Athena's
limit is 256 KB), splitting only between buildings, so the per-chunk sums -- and the
distinct-building counts of the coverage probe -- add up exactly.

Truth side. `CalMAC long.parquet` (comstockpostproc.california.CalMAC): per-premise
hourly kWh and daily therms on Pacific standard time.

What is compared. ComStock kWh per WEIGHTED BUILDING against CalMAC kWh per PREMISE
(levels are indicative only -- a building can be many premises), and both
shape-normalized the way the AMI leg does (day sum = 1, annual sum = 1), which is
where the result lies. Pooled truth series (sizes combined, and the "All mapped"
segment) are weighted by the run under review's own weighted building counts per
cell, or equally (segments.POOL_WEIGHTS): the CalMAC files carry the ~200-premise
sample behind each profile, not the premise population.
"""

from __future__ import annotations

import logging
from pathlib import Path

import numpy as np
import pandas as pd

from ..california import segments as SEG
from . import athena
from .ami_shapes import MIN_COMSTOCK_MODELS, _daytype_norm
from .metrics_def import ENDUSE_STACK_ORDER
from .timeseries import enduse_sums, hour_trunc, time_expr, total_sum

logger = logging.getLogger(__name__)

MAX_SQL_BYTES = 200_000
UTIL_COL = "in.electric_utility_eia_code"
CEC_COL = "in.cec_climate_zone"
PEAK_COL = "out.electricity.total.peak_demand..kw"
BLDG_TYPE_COL = "in.comstock_building_type"
SQFT_COL = "in.sqft..ft2"
OVERNIGHT_HOURS = range(0, 6)
LDC_RANKS = 60      # plus the top 24 hours; a smooth monotonic curve needs no more


# ---------------------------------------------------------------------------
# segmentation (pure, local)
# ---------------------------------------------------------------------------

def classify(weights: pd.DataFrame, cfg: dict) -> pd.DataFrame:
    """Each weight row with its utility, CZ group ('other' outside the groups),
    industry (None for an unmapped type) and size class."""
    w = weights.copy()
    w = w[w[UTIL_COL].isin(list(cfg["utilities"]))].copy()
    w["utility_id"] = w[UTIL_COL].astype(int)
    w["cz_group"] = SEG.OTHER_ZONE
    for u, groups in cfg["cz_groups"].items():
        z2g = SEG.zone_to_group(groups)
        m = w["utility_id"] == int(u)
        w.loc[m, "cz_group"] = w.loc[m, CEC_COL].map(z2g).fillna(SEG.OTHER_ZONE)
    t2i = SEG.industry_of_type(cfg["industry_map"])
    w["industry"] = w[BLDG_TYPE_COL].map(t2i)
    sr = cfg["size_rule"]
    if sr["kind"] == "none":
        w["size"] = SEG.POOLED
    else:
        thr = w["utility_id"].map(lambda u: sr["thresholds_kw"][int(u)])
        small = w["utility_id"].map(lambda u: sr["labels"][int(u)][0])
        large = w["utility_id"].map(lambda u: sr["labels"][int(u)][1])
        w["size"] = np.where(w[PEAK_COL].to_numpy() < thr.to_numpy(), small, large)
    return w


def zone_summary(classified: pd.DataFrame) -> pd.DataFrame:
    """Weight and models per utility x CEC zone, with the group each zone falls in
    ('other' = reported, not compared)."""
    return (classified.groupby(["utility_id", CEC_COL, "cz_group"], as_index=False)
            .agg(weight=("weight", "sum"), models=("bldg_id", "nunique"))
            .sort_values(["utility_id", "weight"], ascending=[True, False]))


def segment_weights(classified: pd.DataFrame) -> pd.DataFrame:
    """Denominators and counts per segment: utility_id, cz_group, industry, size,
    weight_sum, model_count, sqft_weighted -- per size, pooled over sizes, and the
    All mapped segment (pooled over industries)."""
    c = classified[(classified["cz_group"] != SEG.OTHER_ZONE) & classified["industry"].notna()]
    c = c.assign(sqft_w=c["weight"] * c[SQFT_COL])

    def agg(df, keys):
        return (df.groupby(keys, as_index=False)
                .agg(weight_sum=("weight", "sum"), model_count=("bldg_id", "nunique"),
                     sqft_weighted=("sqft_w", "sum")))
    per = agg(c, ["utility_id", "cz_group", "industry", "size"])
    pooled = agg(c, ["utility_id", "cz_group", "industry"]).assign(size=SEG.POOLED)
    allm = agg(c, ["utility_id", "cz_group"]).assign(industry=SEG.ALL_MAPPED, size=SEG.POOLED)
    out = pd.concat([per[per["size"] != SEG.POOLED], pooled, allm], ignore_index=True)
    return out[["utility_id", "cz_group", "industry", "size", "weight_sum", "model_count",
                "sqft_weighted"]]


def segment_codes(classified: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    """(rows, codes). rows: bldg_id, seg, weight -- one per building x segment, for the
    inline VALUES list. codes: seg -> utility_id, cz_group, industry, size."""
    c = classified[(classified["cz_group"] != SEG.OTHER_ZONE) & classified["industry"].notna()]
    keys = ["utility_id", "cz_group", "industry", "size"]
    codes = c[keys].drop_duplicates().sort_values(keys).reset_index(drop=True)
    codes["seg"] = np.arange(len(codes), dtype=int)
    rows = (c.merge(codes, on=keys).groupby(["bldg_id", "seg"], as_index=False)["weight"].sum()
            .sort_values(["bldg_id", "seg"]).reset_index(drop=True))
    return rows, codes


def _weight_literal(w: float) -> str:
    """A DOUBLE literal: Athena reads 0.5 as DECIMAL, 0.5e0 as DOUBLE."""
    s = f"{float(w):.6g}"
    return s if "e" in s else f"{s}e0"


def values_ctes(rows: pd.DataFrame, max_bytes: int = MAX_SQL_BYTES) -> list[str]:
    """`WITH w (building_id, seg, weight) AS (VALUES ...)` chunks, each under
    `max_bytes`, split only between buildings."""
    out, cur, size = [], [], 0
    head = "WITH w (building_id, seg, weight) AS (VALUES\n"
    budget = max_bytes - len(head) - 2_000          # room for the query around it
    last_b = None
    for b, seg, wt in rows[["bldg_id", "seg", "weight"]].itertuples(index=False):
        lit = f"({int(b)},{int(seg)},{_weight_literal(wt)})"
        if cur and size + len(lit) + 2 > budget and b != last_b:
            out.append(head + ",\n".join(cur) + ")")
            cur, size = [], 0
        cur.append(lit)
        size += len(lit) + 2
        last_b = b
    if cur:
        out.append(head + ",\n".join(cur) + ")")
    return out


# ---------------------------------------------------------------------------
# SQL
# ---------------------------------------------------------------------------

def _ts_where(dialect: dict, alias: str = "t") -> str:
    d = dialect
    parts = [f"{alias}.upgrade = {athena.upgrade_literal(0, d.get('up_type'))}"]
    if d.get("state"):
        # A published table keeps one copy of a building per state folder; the
        # California copy is the one these California weights describe.
        parts.append(f"{alias}.\"{d['state']}\" = 'CA'")
    return " AND ".join(parts)


def build_hourly_sql(ts_table: str, cte: str, dialect: dict) -> str:
    """Weighted hourly electricity (total + end uses) and natural gas per segment."""
    d = dialect
    return (
        f"{cte}\n"
        "SELECT\n"
        "    w.seg,\n"
        f"    {hour_trunc(d)} AS hour_ts,\n"
        f"    {total_sum(d, 'electricity', 'kwh_weighted', weight='w.weight')},\n"
        f"    {total_sum(d, 'natural_gas', 'gas_kwh_weighted', weight='w.weight')},\n"
        f"{enduse_sums(d, weight='w.weight')}\n"
        f"FROM {ts_table} t\n"
        f"JOIN w ON t.\"{d['bldg']}\" = w.building_id\n"
        f"WHERE {_ts_where(d)}\n"
        "GROUP BY 1, 2"
    )


def build_membership_sql(ts_table: str, cte: str, dialect: dict) -> str:
    """Do the weighted buildings all HAVE timeseries rows? One day is enough."""
    d = dialect
    return (
        f"{cte}\n"
        "SELECT COUNT(DISTINCT w.building_id) AS md_bldgs,\n"
        "    COUNT(DISTINCT CASE WHEN t.b IS NOT NULL THEN w.building_id END) AS ts_bldgs,\n"
        "    SUM(w.weight) AS weight_all,\n"
        "    SUM(CASE WHEN t.b IS NOT NULL THEN w.weight END) AS weight_with_ts\n"
        "FROM w\n"
        f"LEFT JOIN (SELECT DISTINCT t.\"{d['bldg']}\" AS b FROM {ts_table} t\n"
        f"           WHERE {_ts_where(d)}\n"
        f"             AND {time_expr(d, 't')} < from_iso8601_timestamp('2018-01-02T00:00:00')) t\n"
        "  ON t.b = w.building_id"
    )


# ---------------------------------------------------------------------------
# ComStock profiles
# ---------------------------------------------------------------------------

def fetch_comstock_profiles(ts_table: str, weights: pd.DataFrame, cfg: dict, dialect: dict,
                            no_cache: bool = False, query_dir: Path | None = None,
                            label: str = "") -> tuple[pd.DataFrame, pd.DataFrame, dict]:
    """(hourly, segment weights, info).

    hourly: utility_id, cz_group, industry, size, hour_ts, kwh_weighted,
            gas_kwh_weighted, eu_<enduse> (weighted kWh) -- per size, pooled, and All
            mapped. Divide by segment weights' weight_sum for per-building values.
    info:   queries, sql_bytes, membership gap, zone summary, timeseries clock.
    """
    cls = classify(weights, cfg)
    segw = segment_weights(cls)
    rows, codes = segment_codes(cls)
    ctes = values_ctes(rows)
    parts, mem = [], []
    for i, cte in enumerate(ctes):
        sql = build_hourly_sql(ts_table, cte, dialect)
        if len(sql.encode()) > MAX_SQL_BYTES + 5_000:
            raise ValueError(f"CalMAC query {i} is {len(sql):,} bytes; Athena's limit is 256 KB")
        if query_dir is not None:
            (query_dir / f"calmac_{label}_hourly_{i}.sql").write_text(sql, encoding="utf-8")
        parts.append(athena.query(sql, no_cache=no_cache, label=f"calmac {label} chunk {i}"))
        try:
            mem.append(athena.query(build_membership_sql(ts_table, cte, dialect),
                                    no_cache=no_cache, label=f"calmac {label} membership {i}"))
        except Exception as exc:                                  # noqa: BLE001
            logger.warning("CalMAC membership probe %d could not run (%s); timeseries coverage "
                           "of the weighted buildings is unverified", i, exc)
    raw = pd.concat(parts, ignore_index=True)
    eu_cols = [e for e in ENDUSE_STACK_ORDER if e in raw.columns]
    val_cols = ["kwh_weighted", "gas_kwh_weighted"] + eu_cols
    raw[val_cols] = raw[val_cols].apply(pd.to_numeric, errors="coerce")
    raw = raw.groupby(["seg", "hour_ts"], as_index=False)[val_cols].sum(min_count=1)
    raw = raw.merge(codes, on="seg").drop(columns="seg")
    raw = raw.rename(columns={e: f"eu_{e}" for e in eu_cols})
    vcols = ["kwh_weighted", "gas_kwh_weighted"] + [f"eu_{e}" for e in eu_cols]
    pooled = (raw.groupby(["utility_id", "cz_group", "industry", "hour_ts"], as_index=False)
              [vcols].sum(min_count=1).assign(size=SEG.POOLED))
    allm = (pooled.groupby(["utility_id", "cz_group", "hour_ts"], as_index=False)[vcols]
            .sum(min_count=1).assign(industry=SEG.ALL_MAPPED, size=SEG.POOLED))
    keep_sized = raw[raw["size"] != SEG.POOLED]
    hourly = pd.concat([keep_sized, pooled, allm], ignore_index=True)
    hourly["hour_ts"] = pd.to_datetime(hourly["hour_ts"])
    gap = {}
    if mem:
        m = pd.concat(mem, ignore_index=True).apply(pd.to_numeric, errors="coerce").sum()
        md, ts = float(m["md_bldgs"]), float(m["ts_bldgs"])
        wa, wt = float(m["weight_all"]), float(m["weight_with_ts"] or 0)
        if wa and abs(wa - wt) > wa * 1e-6:
            gap = {"md_bldgs": int(md), "ts_bldgs": int(ts),
                   "weight_covered_pct": round(100.0 * wt / wa, 2),
                   "note": (f"{int(md - ts)} of {int(md)} weighted California buildings have no "
                            f"timeseries rows, so kWh per building is biased LOW by "
                            f"{100.0 * (1 - wt / wa):.1f}%.")}
            logger.warning("CalMAC %s: %s", label, gap["note"])
    info = {"queries": len(ctes), "sql_bytes": [len(c) for c in ctes],
            "weight_rows": int(len(rows)), "membership_gap": gap,
            "zone_summary": zone_summary(cls), "tz": dialect.get("tz", "local"),
            "classified": cls}
    return hourly, segw, info


# ---------------------------------------------------------------------------
# truth series per segment
# ---------------------------------------------------------------------------

def season_daytype(ts: pd.Series, seasons: dict) -> tuple[pd.Series, pd.Series]:
    month_to_season = {m: s for s, ms in seasons.items() for m in ms}
    season = ts.dt.month.map(month_to_season)
    day = pd.Series(np.where(ts.dt.dayofweek < 5, "Weekday", "Weekend"), index=ts.index)
    return season, day


def truth_segments(truth: pd.DataFrame, utility: int, fuel: str, cfg: dict,
                   segw_primary: pd.DataFrame) -> tuple[dict, pd.DataFrame]:
    """{(industry, cz_group, size): DataFrame(timestamp, value)} and a description
    table (one row per segment: components, weights, basis, premises, comparable).

    `truth` is this utility and fuel, every basis. SDG&E prefers
    cfg['truth_basis']; a pooled or All mapped series uses that basis only when
    EVERY component has it, else raw for all components, so one series never mixes
    calendars.
    """
    want = cfg["truth_basis"] if utility == SEG.SDGE else "raw"
    t = truth[~truth["merged_hour"]].copy()
    # plain strings: the parquet's categorical columns make groupby aggregations
    # try to cast their results back into the categories
    for c in ("gp", "basis"):
        t[c] = t[c].astype(str)
    by_gp = {g: d[["basis", "timestamp", "value"]] for g, d in t.groupby("gp")}
    prem = t.groupby("gp")["premise_count"].first().to_dict()
    bases = {g: set(d["basis"].unique()) for g, d in by_gp.items()}
    labels = cfg["size_rule"]["labels"].get(int(utility), ["S", "M"])
    w_of = {(r.cz_group, r.industry, r.size): r.weight_sum
            for r in segw_primary[segw_primary["utility_id"] == int(utility)].itertuples()}

    def norm_weights(ws) -> np.ndarray:
        """Composition weights: a cell ComStock has no buildings in weighs zero (the
        truth series for it then drops out of the pooled mean); equal weights only
        when no cell has any."""
        ws = np.nan_to_num(np.asarray(ws, float), nan=0.0)
        return ws / ws.sum() if ws.sum() > 0 else np.full(len(ws), 1.0 / len(ws))

    def series(gp, basis):
        d = by_gp[gp]
        return d[d["basis"] == basis][["timestamp", "value"]].set_index("timestamp")["value"]

    def combine(components: list[tuple[str, float]]):
        """Weighted mean of component GPs on one basis."""
        basis = want if all(want in bases[g] for g, _ in components) else "raw"
        ws = norm_weights([w for _, w in components])
        frame = pd.concat([series(g, basis) for g, _ in components], axis=1, join="inner")
        val = (frame.to_numpy() * ws).sum(axis=1)
        return pd.DataFrame({"timestamp": frame.index, "value": val}), basis, ws

    out, desc = {}, []
    gps = sorted(by_gp)
    by_seg = {}
    for gp in gps:
        ind, size, cz = SEG.parse_gp(gp)
        by_seg.setdefault((ind, cz), {})[size] = gp
    pooled_parts = {}
    for (ind, cz), sizes in sorted(by_seg.items()):
        if ind not in cfg["industry_map"]:
            continue
        comparable_ind = ind not in cfg["size_not_comparable"]
        # per-size series
        for size in labels:
            gp = sizes.get(size)
            if not gp:
                continue
            s, basis, _ = combine([(gp, 1.0)])
            out[(ind, cz, size)] = s
            desc.append({"industry": ind, "cz_group": cz, "size": size, "components": gp,
                         "pool_weights": "", "basis": basis, "premises": prem.get(gp),
                         "size_comparable": bool(comparable_ind
                                                 and cfg["size_rule"]["kind"] != "none")})
        # pooled
        if "A" in sizes:
            comps = [(sizes["A"], 1.0)]
        else:
            comps = [(sizes[s], (w_of.get((cz, ind, s), np.nan)
                                 if cfg["pool_weights"] == "comstock" else 1.0))
                     for s in labels if s in sizes]
        if not comps:
            continue
        s, basis, ws = combine(comps)
        out[(ind, cz, SEG.POOLED)] = s
        pooled_parts[(ind, cz)] = s
        desc.append({"industry": ind, "cz_group": cz, "size": SEG.POOLED,
                     "components": "+".join(g for g, _ in comps),
                     "pool_weights": ",".join(f"{w:.3f}" for w in ws),
                     "basis": basis, "premises": sum(prem.get(g) or 0 for g, _ in comps),
                     "size_comparable": True})
    # All mapped: the mapped industries' pooled series per CZ group
    for cz in sorted({cz for (_, cz) in pooled_parts}):
        inds = [i for (i, c) in pooled_parts if c == cz]
        comps_gp = []
        for i in inds:
            sizes = by_seg[(i, cz)]
            comps_gp += ([sizes["A"]] if "A" in sizes else [sizes[s] for s in labels if s in sizes])
        basis = want if all(want in bases[g] for g in comps_gp) else "raw"
        ws = norm_weights([(w_of.get((cz, i, SEG.POOLED), np.nan)
                            if cfg["pool_weights"] == "comstock" else 1.0) for i in inds])
        # Rebuild the industries' pooled series on the common basis.
        parts = []
        for i in inds:
            sizes = by_seg[(i, cz)]
            if "A" in sizes:
                parts.append(series(sizes["A"], basis))
            else:
                sw = norm_weights([(w_of.get((cz, i, s), np.nan) if cfg["pool_weights"] == "comstock"
                                    else 1.0) for s in labels if s in sizes])
                f = pd.concat([series(sizes[s], basis) for s in labels if s in sizes],
                              axis=1, join="inner")
                parts.append(pd.Series((f.to_numpy() * sw).sum(axis=1), index=f.index))
        frame = pd.concat(parts, axis=1, join="inner")
        val = (frame.to_numpy() * ws).sum(axis=1)
        out[(SEG.ALL_MAPPED, cz, SEG.POOLED)] = pd.DataFrame({"timestamp": frame.index, "value": val})
        desc.append({"industry": SEG.ALL_MAPPED, "cz_group": cz, "size": SEG.POOLED,
                     "components": "+".join(inds),
                     "pool_weights": ",".join(f"{w:.3f}" for w in ws),
                     "basis": basis, "premises": sum(prem.get(g) or 0 for g in comps_gp),
                     "size_comparable": True})
    return out, pd.DataFrame(desc)


# ---------------------------------------------------------------------------
# comparison
# ---------------------------------------------------------------------------

def _per_bldg(hourly: pd.DataFrame, segw: pd.DataFrame, utility: int) -> pd.DataFrame:
    h = hourly[hourly["utility_id"] == int(utility)].merge(
        segw[segw["utility_id"] == int(utility)],
        on=["utility_id", "cz_group", "industry", "size"], how="inner")
    vcols = [c for c in h.columns if c == "kwh_weighted" or c.startswith("eu_")
             or c == "gas_kwh_weighted"]
    for c in vcols:
        h[c] = h[c] / h["weight_sum"]
    return h.rename(columns={"kwh_weighted": "kwh_per_bldg",
                             "gas_kwh_weighted": "gas_kwh_per_bldg"})


def _mean_profile(ts: pd.Series, vals: pd.DataFrame, seasons: dict) -> pd.DataFrame:
    season, day = season_daytype(ts, seasons)
    df = vals.assign(season=season.to_numpy(), day_type=day.to_numpy(), hour=ts.dt.hour.to_numpy())
    df = df.dropna(subset=["season"])
    return df.groupby(["season", "day_type", "hour"], as_index=False).mean(numeric_only=True)


def _shape_row(a: np.ndarray, c: np.ndarray) -> dict:
    """The AMI leg's per-panel metrics (ami_shapes.compare_region), truth = a."""
    night = np.isin(np.arange(24), list(OVERNIGHT_HOURS))
    an, cn = _daytype_norm(a), _daytype_norm(c)
    return {
        "nmbe_pct": 100.0 * (c.mean() - a.mean()) / a.mean() if a.mean() else np.nan,
        "cvrmse_pct": 100.0 * np.sqrt(np.mean((c - a) ** 2)) / a.mean() if a.mean() else np.nan,
        "daytype_shape_rmse_pts": 100.0 * float(np.sqrt(np.mean((cn - an) ** 2))),
        "daytype_cvrmse_pct": (100.0 * float(np.sqrt(np.mean((cn - an) ** 2)) / an.mean())
                               if an.mean() else np.nan),
        "shape_corr": float(np.corrcoef(a, c)[0, 1]) if a.std() and c.std() else np.nan,
        "overnight_share_comstock": float(cn[night].sum()),
        "overnight_share_calmac": float(an[night].sum()),
        "peak_hour_comstock": int(np.argmax(c)), "peak_hour_calmac": int(np.argmax(a)),
        "peak_rel_err_pct": 100.0 * (c.max() - a.max()) / a.max() if a.max() else np.nan,
    }


def _ldc(cs: np.ndarray, tr: np.ndarray) -> list[dict]:
    """Load duration curves, each divided by its own annual mean (level-free)."""
    c = np.sort(cs[np.isfinite(cs)])[::-1]
    a = np.sort(tr[np.isfinite(tr)])[::-1]
    if len(c) < 100 or len(a) < 100 or not c.mean() or not a.mean():
        return []
    c, a = c / c.mean(), a / a.mean()
    n = min(len(c), len(a))
    ranks = np.unique(np.concatenate([np.arange(1, min(25, n + 1)),
                                      np.linspace(25, n, LDC_RANKS).astype(int)]))
    return [{"hours": int(r), "comstock_rel": float(c[r - 1]), "calmac_rel": float(a[r - 1])}
            for r in ranks if 1 <= r <= n]


def _monthly_shares(ts: pd.Series, v: np.ndarray) -> np.ndarray:
    m = pd.Series(v, index=pd.to_datetime(ts).to_numpy()).groupby(lambda x: x.month).sum()
    m = m.reindex(range(1, 13)).fillna(0.0)
    tot = m.sum()
    return (m / tot).to_numpy() if tot else np.full(12, np.nan)


def _season_ratio(ts: pd.Series, v: np.ndarray, seasons: dict, num: str, den: str) -> float:
    s, _ = season_daytype(pd.Series(pd.to_datetime(ts)), seasons)
    vs = pd.Series(v).groupby(s.to_numpy()).mean()
    return float(vs.get(num, np.nan) / vs.get(den, np.nan)) if vs.get(den) else np.nan


def _weekend_ratio(ts: pd.Series, v: np.ndarray, daily: bool) -> float:
    t = pd.Series(pd.to_datetime(ts))
    day = t.dt.normalize()
    d = pd.Series(v).groupby(day.to_numpy()).sum() if not daily else pd.Series(v, index=day.to_numpy())
    wk = pd.Series(pd.to_datetime(d.index).dayofweek < 5, index=d.index)
    a, b = d[~wk.to_numpy()].mean(), d[wk.to_numpy()].mean()
    return float(a / b) if b else np.nan


def compare_electricity(cs_hourly: pd.DataFrame, segw: pd.DataFrame, truth: dict,
                        desc: pd.DataFrame, utility: int, cfg: dict, run_key: str):
    """(profiles, metrics, summary, ldc, monthly) for one run and utility."""
    seasons = cfg["seasons"]
    h = _per_bldg(cs_hourly, segw, utility)
    eu_cols = [c for c in h.columns if c.startswith("eu_")]
    prof, met, summ, ldc, mon = [], [], [], [], []
    for d in desc.itertuples(index=False):
        key = (d.industry, d.cz_group, d.size)
        cs = h[(h["industry"] == d.industry) & (h["cz_group"] == d.cz_group)
               & (h["size"] == d.size)].sort_values("hour_ts")
        tr = truth.get(key)
        if cs.empty or tr is None or tr.empty:
            continue
        sw = cs.iloc[0]
        base = {"run": run_key, "utility_id": int(utility), "industry": d.industry,
                "cz_group": d.cz_group, "size": d.size}
        cp = _mean_profile(cs["hour_ts"], cs[["kwh_per_bldg"] + eu_cols], seasons)
        tp = _mean_profile(tr["timestamp"], tr[["value"]].rename(columns={"value": "calmac"}), seasons)
        p = cp.merge(tp, on=["season", "day_type", "hour"], how="inner")
        cs_ann, tr_ann = float(cs["kwh_per_bldg"].sum()), float(tr["value"].sum())
        p = p.rename(columns={"kwh_per_bldg": "comstock_kwh_per_bldg",
                              "calmac": "calmac_kwh_per_premise"})
        p = p.assign(**base, comstock_annual_kwh_per_bldg=cs_ann,
                     calmac_annual_kwh_per_premise=tr_ann, model_count=int(sw["model_count"]),
                     weight_sum=float(sw["weight_sum"]), premise_count=d.premises,
                     size_comparable=bool(d.size_comparable), basis=d.basis)
        prof.append(p)
        for (season, day), g in p.groupby(["season", "day_type"]):
            g = g.sort_values("hour")
            if len(g) < 24 or not g["calmac_kwh_per_premise"].mean():
                continue
            row = _shape_row(g["calmac_kwh_per_premise"].to_numpy(),
                             g["comstock_kwh_per_bldg"].to_numpy())
            # season x day type load factor on the HOURLY series, each on its own calendar
            for side, ts, v in (("comstock", cs["hour_ts"], cs["kwh_per_bldg"].to_numpy()),
                                ("calmac", tr["timestamp"], tr["value"].to_numpy())):
                s, dd = season_daytype(pd.Series(pd.to_datetime(ts).to_numpy()), seasons)
                sel = v[(s.to_numpy() == season) & (dd.to_numpy() == day)]
                row[f"load_factor_{side}"] = float(sel.mean() / sel.max()) if len(sel) and sel.max() else np.nan
            met.append({**base, "season": season, "day_type": day, **row,
                        "size_comparable": bool(d.size_comparable)})
        cm, tm = _monthly_shares(cs["hour_ts"], cs["kwh_per_bldg"].to_numpy()), \
            _monthly_shares(tr["timestamp"], tr["value"].to_numpy())
        for i in range(12):
            mon.append({**base, "month": i + 1, "comstock_share": cm[i], "calmac_share": tm[i]})
        summ.append({
            **base, "fuel": "electricity", "model_count": int(sw["model_count"]),
            "weight_sum": float(sw["weight_sum"]), "premise_count": d.premises,
            "size_comparable": bool(d.size_comparable), "basis": d.basis,
            "thin_comstock": int(sw["model_count"]) < MIN_COMSTOCK_MODELS,
            "comstock_annual_per_bldg": cs_ann, "calmac_annual_per_premise": tr_ann,
            "comstock_sqft_per_bldg": float(sw["sqft_weighted"]) / float(sw["weight_sum"]),
            "load_factor_comstock": float(cs["kwh_per_bldg"].mean() / cs["kwh_per_bldg"].max()),
            "load_factor_calmac": float(tr["value"].mean() / tr["value"].max()),
            "summer_to_winter_comstock": _season_ratio(cs["hour_ts"], cs["kwh_per_bldg"].to_numpy(),
                                                       seasons, "Summer", "Winter"),
            "summer_to_winter_calmac": _season_ratio(tr["timestamp"], tr["value"].to_numpy(),
                                                     seasons, "Summer", "Winter"),
            "weekend_to_weekday_comstock": _weekend_ratio(cs["hour_ts"], cs["kwh_per_bldg"].to_numpy(), False),
            "weekend_to_weekday_calmac": _weekend_ratio(tr["timestamp"], tr["value"].to_numpy(), False),
            "monthly_share_rmse_pts": float(100 * np.sqrt(np.nanmean((cm - tm) ** 2))),
        })
        for r in _ldc(cs["kwh_per_bldg"].to_numpy(), tr["value"].to_numpy()):
            ldc.append({**base, **r})
    cat = lambda xs: pd.concat(xs, ignore_index=True) if xs else pd.DataFrame()  # noqa: E731
    return (cat(prof), pd.DataFrame(met), pd.DataFrame(summ), pd.DataFrame(ldc), pd.DataFrame(mon))


def compare_gas(cs_hourly: pd.DataFrame, segw: pd.DataFrame, truth: dict, desc: pd.DataFrame,
                utility: int, cfg: dict, run_key: str):
    """(daily, metrics, summary, monthly) for one run and utility; therms per
    building against therms per premise."""
    seasons = cfg["seasons"]
    h = _per_bldg(cs_hourly, segw, utility)
    h["date"] = h["hour_ts"].dt.normalize()
    keys = ["utility_id", "cz_group", "industry", "size", "date"]
    dd = h.groupby(keys, as_index=False)["gas_kwh_per_bldg"].sum()
    dd["therms_per_bldg"] = dd["gas_kwh_per_bldg"] / SEG.KWH_PER_THERM
    sw = segw[segw["utility_id"] == int(utility)].set_index(["cz_group", "industry", "size"])
    daily, met, summ, mon = [], [], [], []
    for d in desc.itertuples(index=False):
        key = (d.industry, d.cz_group, d.size)
        cs = dd[(dd["industry"] == d.industry) & (dd["cz_group"] == d.cz_group)
                & (dd["size"] == d.size)].sort_values("date")
        tr = truth.get(key)
        if cs.empty or tr is None or tr.empty:
            continue
        base = {"run": run_key, "utility_id": int(utility), "industry": d.industry,
                "cz_group": d.cz_group, "size": d.size}
        w = sw.loc[(d.cz_group, d.industry, d.size)]
        trd = tr.assign(date=pd.to_datetime(tr["timestamp"]).dt.normalize())
        # Calendars align when the truth is 2018 (PG&E, or normalized SDG&E); a raw
        # SDG&E series is 2025 and is joined by day of year only for display.
        same_cal = int(trd["date"].dt.year.iloc[0]) == int(cs["date"].dt.year.iloc[0])
        a = cs[["date", "therms_per_bldg"]].copy()
        b = trd[["date", "value"]].rename(columns={"value": "therms_per_premise"})
        if same_cal:
            j = a.merge(b, on="date", how="inner")
        else:
            a["doy"], b["doy"] = a["date"].dt.dayofyear, b["date"].dt.dayofyear
            j = a.merge(b.drop(columns="date"), on="doy", how="inner").drop(columns="doy")
        daily.append(j.assign(**base, basis=d.basis, same_calendar=same_cal))
        for side, ts, v in (("comstock", a["date"], a["therms_per_bldg"].to_numpy()),
                            ("calmac", trd["date"], trd["value"].to_numpy())):
            s, day = season_daytype(pd.Series(pd.to_datetime(ts).to_numpy()), seasons)
            for (season, dt_), g in pd.DataFrame({"s": s, "d": day, "v": v}).groupby(["s", "d"]):
                met.append({**base, "season": season, "day_type": dt_, "side": side,
                            "mean_daily_therms": float(g["v"].mean())})
        cm = _monthly_shares(a["date"], a["therms_per_bldg"].to_numpy())
        tm = _monthly_shares(trd["date"], trd["value"].to_numpy())
        for i in range(12):
            mon.append({**base, "month": i + 1, "comstock_share": cm[i], "calmac_share": tm[i]})
        heat = [11, 12, 1, 2, 3]
        cs_v, tr_v = a["therms_per_bldg"].to_numpy(), trd["value"].to_numpy()
        hs = lambda ts, v: float(v[pd.to_datetime(ts).dt.month.isin(heat).to_numpy()].sum() / v.sum()) if v.sum() else np.nan  # noqa: E731
        shape_cv = np.nan
        if same_cal and len(j) > 300:
            x = j["therms_per_bldg"] / j["therms_per_bldg"].sum()
            y = j["therms_per_premise"] / j["therms_per_premise"].sum()
            shape_cv = float(100 * np.sqrt(np.mean((x - y) ** 2)) / y.mean()) if y.mean() else np.nan
        summ.append({
            **base, "fuel": "natural_gas", "model_count": int(w["model_count"]),
            "weight_sum": float(w["weight_sum"]), "premise_count": d.premises,
            "size_comparable": bool(d.size_comparable), "basis": d.basis,
            "thin_comstock": int(w["model_count"]) < MIN_COMSTOCK_MODELS,
            "comstock_annual_per_bldg": float(cs_v.sum()), "calmac_annual_per_premise": float(tr_v.sum()),
            "heating_season_share_comstock": hs(a["date"], cs_v),
            "heating_season_share_calmac": hs(trd["date"], tr_v),
            "summer_to_winter_comstock": _season_ratio(a["date"], cs_v, seasons, "Summer", "Winter"),
            "summer_to_winter_calmac": _season_ratio(trd["date"], tr_v, seasons, "Summer", "Winter"),
            "weekend_to_weekday_comstock": _weekend_ratio(a["date"], cs_v, True),
            "weekend_to_weekday_calmac": _weekend_ratio(trd["date"], tr_v, True),
            "monthly_share_rmse_pts": float(100 * np.sqrt(np.nanmean((cm - tm) ** 2))),
            "daily_shape_cvrmse_pct": shape_cv, "same_calendar": same_cal,
        })
    cat = lambda xs: pd.concat(xs, ignore_index=True) if xs else pd.DataFrame()  # noqa: E731
    return cat(daily), pd.DataFrame(met), pd.DataFrame(summ), pd.DataFrame(mon)


def composition(segw: pd.DataFrame, utility: int) -> pd.DataFrame:
    """ComStock's weighted building count by size within each industry x CZ group --
    the evidence for whether the size threshold is sensible. CalMAC publishes no
    premise population to set beside it (its counts are the ~200-premise samples)."""
    s = segw[(segw["utility_id"] == int(utility)) & (segw["industry"] != SEG.ALL_MAPPED)]
    sized = s[s["size"] != SEG.POOLED].copy()
    tot = sized.groupby(["cz_group", "industry"])["weight_sum"].transform("sum")
    sized["share_of_industry"] = sized["weight_sum"] / tot
    return sized.sort_values(["industry", "cz_group", "size"]).reset_index(drop=True)


def cross_segment_agreement(metrics: pd.DataFrame) -> pd.DataFrame:
    """Per utility x industry x CZ group (pooled size): mean shape RMSE and overnight
    delta; consistency across the CZ groups (same sign in >= 2/3, needs >= 2 groups --
    SDG&E has only two)."""
    if metrics is None or metrics.empty:
        return pd.DataFrame()
    m = metrics[metrics["size"] == SEG.POOLED]
    g = (m.groupby(["utility_id", "industry", "cz_group"], as_index=False)
         .agg(shape_rmse_pts=("daytype_shape_rmse_pts", "mean"),
              overnight_comstock=("overnight_share_comstock", "mean"),
              overnight_calmac=("overnight_share_calmac", "mean")))
    g["overnight_delta_pp"] = 100.0 * (g["overnight_comstock"] - g["overnight_calmac"])

    def flag(sub):
        n = len(sub)
        if n < 2:
            return "insufficient groups"
        pos = int((sub["overnight_delta_pp"] > 0).sum())
        return "systematic" if max(pos, n - pos) / n >= 2 / 3 else "mixed"
    flags = (g.groupby(["utility_id", "industry"]).apply(flag, include_groups=False)
             .rename("consistency").reset_index())
    return g.merge(flags, on=["utility_id", "industry"], how="left")
