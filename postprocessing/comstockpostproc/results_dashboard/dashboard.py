# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Build a self-contained results dashboard from an assessment directory.

    dashboard.build(<assessment dir>, <dashboard.html>)    # called by cspp.ResultsDashboard

Reads metrics/*.csv + coverage.json + manifest.json and writes one HTML file with
no external dependencies (charts are hand-rolled SVG). Open it in any browser; no
server needed.
"""

from __future__ import annotations

import json
import math
from pathlib import Path, PurePath

import pandas as pd

from ._version import __version__
from .distributions import DIST_DIMENSIONS, SIZE_BIN_LABELS
from .measures import MEASURE_SEASONS
from .metrics_def import (
    BLDG_TYPE_TO_SNAKE,
    DIMENSIONS,
    ENDUSE_COLORS,
    ENDUSE_STACK_ORDER,
    ORDERED_CATEGORIES,
)

CBECS_COLOR = "#009E73"
AMI_COLOR = "#CC79A7"   # COLOR_AMI in comstockpostproc

HEADLINE_METRICS = [
    ("electricity.total", "Electricity"),
    ("natural_gas.total", "Natural gas"),
    ("site_energy.total", "Site energy"),
    ("all_fuel.heating", "Heating (all fuel)"),
    ("electricity.cooling", "Cooling"),
    ("sqft", "Floor area"),
]

# Electricity end uses follow the canonical ENDUSE_STACK_ORDER so this chart reads
# in the same order as the stacked timeseries plots; other fuels follow after.
ANNUAL_END_USES = [
    f"electricity.{e}" for e in ENDUSE_STACK_ORDER
] + [
    "natural_gas.heating", "natural_gas.water_systems", "natural_gas.interior_equipment",
    "fuel_oil.heating", "propane.heating", "district_heating.heating",
]

FUEL_TOTALS_ORDER = [
    "electricity.total", "natural_gas.total", "fuel_oil.total", "propane.total",
    "district_heating.total", "district_cooling.total", "site_energy.total",
]


def _clean(v):
    if v is None:
        return None
    if isinstance(v, float) and (math.isnan(v) or math.isinf(v)):
        return None
    try:
        if pd.isna(v):
            return None
    except (TypeError, ValueError):
        pass
    if hasattr(v, "item"):
        v = v.item()
    if isinstance(v, float):
        # Six significant figures is far beyond any displayed precision and
        # roughly halves the embedded payload.
        return float(f"{v:.6g}")
    return v


def _records(df: pd.DataFrame) -> list[dict]:
    return [{k: _clean(v) for k, v in row.items()} for row in df.to_dict("records")]


def _read(path: Path) -> list[dict]:
    return _records(pd.read_csv(path)) if path.exists() else []


def _read_json(path: Path) -> dict:
    """A small sidecar dict, or {} when the leg did not run.

    Returns {} rather than None so the page can test its keys without a null
    guard at every use, and so an assessment produced before this leg existed
    renders the panel's "not computed" state instead of throwing.
    """
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        # This module has no logger; a malformed sidecar must not take the whole
        # build down, and the panel already renders an honest absent state.
        return {}


def _ami_profiles(path: Path, primary: str) -> list[dict]:
    """Profiles with comparison-run rows slimmed to the columns actually drawn.

    Only the primary run's rows feed the end-use stack; a comparison run
    contributes just its total line, so its eu_* and AMI columns would double
    the embedded payload for nothing.
    """
    df = pd.read_csv(path)
    if "run" not in df.columns:
        return _records(df)
    keep = ["run", "building_type", "season", "day_type", "hour",
            "comstock_kwh_per_sf", "comstock_annual_kwh_per_sf"]
    sec = df[df["run"] != primary][[c for c in keep if c in df.columns]]
    return _records(pd.concat([df[df["run"] == primary], sec], ignore_index=True))


def _references_label(payload: dict) -> str:
    """The subtitle's reference list: what was ACTUALLY compared against.

    This used to be the literal string "references: CBECS 2018, AMI {region}",
    which claimed CBECS on every run whether or not one was supplied, and
    rendered "AMI no value" when the AMI leg had not run -- reading as a broken
    field rather than as an absence. Both references are optional, so the line
    has to be built from what happened.
    """
    cov = payload.get("coverage") or {}
    refs = payload.get("manifest", {}).get("references") or {}
    parts = []
    if any("cbecs" in k.lower() for k in refs):
        parts.append("CBECS 2018")
    compared = cov.get("ami_regions_compared") or []
    if compared:
        parts.append(f"AMI {compared[0]}" if len(compared) == 1
                     else f"AMI ({len(compared)} regions)")
    if not parts:
        return "no external reference — ComStock only"
    return "references: " + ", ".join(parts)


def _pack_frame(rows: list[dict], str_cols: list[str], num_cols: list[str]) -> dict:
    """Columnar, dictionary-encoded packing for the one frame big enough to care.

    The design-parameter table is ~40,000 rows. As an array of objects its
    repeated KEY NAMES alone came to about 2.8 MB -- more than the numbers.
    Storing it column-wise, with the five low-cardinality string columns encoded
    as indices into a dictionary, cuts it by roughly two thirds. The dashboard
    rehydrates it once at load into the array of objects the renderer expects,
    so nothing downstream changes.
    """
    if not rows:
        return {}
    dicts, idx, s_out = {}, {}, []
    for c in str_cols:
        vals = sorted({str(r.get(c)) for r in rows if r.get(c) is not None})
        dicts[c] = vals
        idx[c] = {v: i for i, v in enumerate(vals)}
        s_out.append([idx[c].get(str(r.get(c)), -1) for r in rows])
    n_out = []
    for c in num_cols:
        col = []
        for r in rows:
            v = r.get(c)
            if v is None or (isinstance(v, float) and v != v):
                col.append(None)
            else:
                try:
                    col.append(float(f"{float(v):.6g}"))
                except (TypeError, ValueError):
                    col.append(None)
        n_out.append(col)
    return {"n": len(rows), "sCols": str_cols, "nCols": num_cols,
            "dict": dicts, "s": s_out, "v": n_out}


def build_payload(assess: Path) -> dict:
    m = assess / "metrics"
    manifest = json.loads((assess / "manifest.json").read_text(encoding="utf-8"))
    coverage = json.loads((assess / "coverage.json").read_text(encoding="utf-8"))
    # Reference files enter the payload by NAME, not by absolute path. Which
    # reference was used is provenance worth keeping; the path is not, and this
    # HTML is one self-contained file that gets emailed around -- it was
    # carrying "C:/Users/<name>/Documents/..." with it. Stripped here, at the
    # point the payload is built, so the path never reaches the file at all
    # rather than merely being hidden from the rendered page.
    manifest = dict(manifest)
    manifest["references"] = {k: PurePath(str(v)).name
                              for k, v in (manifest.get("references") or {}).items()}
    runs = manifest.get("runs", [])
    primary = manifest.get("primary_run") or (runs[0]["key"] if runs else "run")
    region = manifest.get("region")

    by_dim = {d: _read(m / f"annual_vs_cbecs_by_{d}.csv") for d in DIMENSIONS}
    by_dim = {k: v for k, v in by_dim.items() if v}
    by_pair = {d: _read(m / f"annual_vs_cbecs_by_building_type_and_{d}.csv")
               for d in ("vintage", "census_division", "size_bin")}
    by_pair = {k: v for k, v in by_pair.items() if v}
    fuel_by_dim = {d: _read(m / f"fuel_mix_by_{d}.csv") for d in DIMENSIONS}
    fuel_by_dim = {k: v for k, v in fuel_by_dim.items() if v}

    bt_rows = by_dim.get("building_type", [])
    types = [t for t in ORDERED_CATEGORIES["building_type"]
             if t in {r["category"] for r in bt_rows}]

    return {
        "runs": runs,
        "primaryRun": primary,
        # The comparison run the delta annotations reference. Stated explicitly
        # so a multi-run dashboard does not leave the reader guessing which of
        # several comparison runs the arrows are measured against.
        "deltaRef": manifest.get("delta_ref"),
        "created": manifest.get("created"),
        "toolVersion": __version__,
        "sources": {r["key"]: r["md_table"] for r in runs},
        "manifest": manifest,
        "amiRegion": region,
        "buildingTypes": types,
        "typeToSnake": BLDG_TYPE_TO_SNAKE,
        "byDim": by_dim,
        "byPair": by_pair,
        "fuelByDim": fuel_by_dim,
        "dimensions": {d: {"label": s["label"], "cbecs": s["cbecs"]} for d, s in DIMENSIONS.items()},
        "ordered": ORDERED_CATEGORIES,
        "designParams": _pack_frame(
            _read(m / "design_params.csv"),
            ["run", "btype", "dimension", "category", "metric"],
            ["wmean", "p50", "p10", "p90", "n_models", "coverage_pct"]),
        "designParamsMeta": _read(m / "design_params_meta.csv"),
        # Packed like designParams: the frame is four scopes deep (btype x
        # dimension) so records-per-row JSON would cost several MB for what is
        # really a handful of repeated strings.
        "heatingFuel": _pack_frame(
            _read(m / "heating_fuel.csv"),
            ["dataset", "run", "btype", "dimension", "category", "fuel"],
            ["area", "area_share_pct", "n", "cell_n"]),
        "heatingFuelProv": _read_json(m / "heating_fuel_provenance.json"),
        # Packed like the design-parameter frame. Crossing every breakdown with
        # building type takes this table from ~750 rows to ~8,000, and as an
        # array of objects the repeated key names alone would cost more than the
        # numbers. `kde` and `outliers` are long JSON strings carried only on the
        # pooled rows, so they stay as plain columns rather than being
        # dictionary-encoded.
        "quantiles": _pack_frame(
            _read(m / "eui_quantiles.csv"),
            ["dataset", "dimension", "category", "btype", "metric", "basis",
             "kde", "outliers"],
            ["p05", "p25", "p50", "p75", "p95", "mean", "n_models",
             "weighted_total", "thin"]),
        "distDims": {k: {"label": v["label"]} for k, v in DIST_DIMENSIONS.items()},
        "sizeBinOrder": SIZE_BIN_LABELS,
        "histograms": _read(m / "eui_histograms.csv"),
        "amiProfiles": {k: v for k, v in
                        ((p.stem.replace("ami_profiles_", ""), _ami_profiles(p, primary))
                         for p in sorted(m.glob("ami_profiles_*.csv"))) if v},
        "amiShape": {p.stem.replace("ami_shape_metrics_", ""): _records(pd.read_csv(p))
                     for p in sorted(m.glob("ami_shape_metrics_*.csv"))},
        "amiAgreement": _read(m / "ami_cross_region_agreement.csv"),
        "amiLdc": {p.stem.replace("ami_ldc_", ""): _records(pd.read_csv(p))
                   for p in sorted(m.glob("ami_ldc_*.csv"))},
        # The season month lists travel with the payload so the chart caption is
        # generated from the same constant that groups the data, instead of a
        # hand-written sentence that can drift out of step with it.
        "measureSeasons": MEASURE_SEASONS,
        "measures": ({
            "summary": _read(m / "measures_summary.csv"),
            "endusePairs": _read(m / "measures_enduse_pairs.csv"),
            "enduseSavings": _read(m / "measures_enduse_savings.csv"),
            "dist": _read(m / "measures_savings_dist.csv"),
            "scenarios": _read(m / "measures_scenarios.csv"),
            "masks": _read(m / "measures_masks.csv"),
            "categories": _read(m / "measures_categories.csv"),
            "ts": {p.stem.replace("measures_ts_", ""): _records(pd.read_csv(p))
                   for p in sorted(m.glob("measures_ts_*.csv"))
                   if not p.stem.startswith("measures_ts_mask_")},
            "tsMask": {p.stem.replace("measures_ts_mask_", ""): _records(pd.read_csv(p))
                       for p in sorted(m.glob("measures_ts_mask_*.csv"))},
        } if (m / "measures_summary.csv").exists() else None),
        "coverage": coverage,
        "headline": HEADLINE_METRICS,
        "endUses": ANNUAL_END_USES,
        "fuelTotals": FUEL_TOTALS_ORDER,
        "enduseColors": ENDUSE_COLORS,
        "enduseOrder": ENDUSE_STACK_ORDER,
        "cbecsColor": CBECS_COLOR,
        "amiColor": AMI_COLOR,
    }


CSS = """
:root{
  --surface:#fcfcfb; --panel:#ffffff; --ink:#1a1d1f; --ink-2:#4a5157; --ink-3:#767f87;
  --line:#e3e6e8; --grid:#eef1f2;
  --cb:#009E73; --ami:#CC79A7;
  --good:#1a7f5a; --bad:#a8412a;
}
:root:not([data-theme="light"]){ @media (prefers-color-scheme: dark){
  --surface:#16191c; --panel:#1e2225; --ink:#eef1f3; --ink-2:#b9c1c7; --ink-3:#8b949b;
  --line:#2e3438; --grid:#262b2f;
  --cb:#3fbf98; --ami:#e59ec4;
  --good:#4cbf90; --bad:#e0765c;
}}
:root[data-theme="dark"]{
  --surface:#16191c; --panel:#1e2225; --ink:#eef1f3; --ink-2:#b9c1c7; --ink-3:#8b949b;
  --line:#2e3438; --grid:#262b2f;
  --cb:#3fbf98; --ami:#e59ec4;
  --good:#4cbf90; --bad:#e0765c;
}
*{box-sizing:border-box}
body{margin:0;background:var(--surface);color:var(--ink);
  font:15px/1.55 ui-sans-serif,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;}
.wrap{max-width:1180px;margin:0 auto;padding:26px 22px 72px}
h1{font-size:24px;margin:0 0 4px;letter-spacing:-.01em}
/* A panel TITLE is an h2 and a sub-heading inside it is an h3, and the two must
   not look alike: panel titles used to be h3 as well, identical in size, weight
   and colour to their own children, so nothing marked where one section ended
   and the next began. The title is now heavier, larger, full-strength ink and
   rides a rule across the top of its panel, which is what makes a section
   findable while scrolling a long tab. */
h2{font-size:18px;font-weight:700;margin:0 0 10px;letter-spacing:-.01em;color:var(--ink)}
h3{font-size:13px;margin:16px 0 7px;color:var(--ink-2);font-weight:600;
  letter-spacing:.01em}
.sub{color:var(--ink-3);font-size:13px;margin:0 0 16px}
.controls{position:sticky;top:0;z-index:20;background:var(--surface);
  border-bottom:1px solid var(--line);padding:10px 0 11px;margin-bottom:18px;
  display:flex;gap:10px;align-items:center;flex-wrap:wrap}
select,button{font:inherit;font-size:13px;color:var(--ink);background:var(--panel);
  border:1px solid var(--line);border-radius:7px;padding:6px 10px;cursor:pointer}
select:focus-visible,button:focus-visible{outline:2px solid var(--ink-2);outline-offset:1px}
.tabs{display:flex;gap:2px;background:var(--panel);border:1px solid var(--line);
  border-radius:8px;padding:3px}
.tab{border:0;background:transparent;border-radius:6px;padding:6px 12px;color:var(--ink-2)}
.tab[aria-selected="true"]{background:var(--ink);color:var(--surface);font-weight:600}
.spacer{flex:1}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:11px;
  padding:16px 18px;margin-bottom:16px}
.head{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:8px}
.legend{display:flex;gap:14px;align-items:center;flex-wrap:wrap;
  font-size:12.5px;color:var(--ink-2);margin:2px 0 12px}
.key{display:inline-flex;gap:6px;align-items:center}
.sw{width:11px;height:11px;border-radius:3px;display:inline-block;flex:none}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{text-align:right;padding:6px 9px;border-bottom:1px solid var(--grid);
  font-variant-numeric:tabular-nums;white-space:nowrap}
th:first-child,td:first-child{text-align:left}
thead th{color:var(--ink-3);font-weight:600;font-size:11.5px;text-transform:uppercase;
  letter-spacing:.04em;border-bottom:1px solid var(--line)}
table.wrap-cells td{white-space:normal;word-break:break-word;line-height:1.45}
table.wrap-cells td:last-child{text-align:left;padding-left:22px}
table.wrap-cells td:first-child{width:34%;color:var(--ink-2)}
tbody tr.clickable{cursor:pointer}
tbody tr.clickable:hover{background:var(--grid)}
.cell{border-radius:5px;padding:3px 7px;display:inline-block;min-width:62px;text-align:right}
/* verdict strip: the national answer, on the first screen */
.verdict{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;
  margin-top:12px}
.vcard{border:1px solid var(--line);border-radius:9px;padding:9px 11px;background:var(--panel)}
.vlabel{font-size:11.5px;color:var(--ink-3);text-transform:uppercase;letter-spacing:.03em}
.vval{font-size:22px;font-weight:650;line-height:1.25;margin:1px 0 2px}
.vsub{font-size:11.5px;color:var(--ink-3)}
/* section index for the long Annual tab — navigation, not a filter: every
   panel stays on the page */
a.jump{font-size:12px;color:var(--ink-2);text-decoration:none;border:1px solid var(--line);
  border-radius:12px;padding:2px 9px;background:var(--panel)}
a.jump:hover{color:var(--ink);border-color:var(--ink-3)}
.ci-out{font-weight:650}
/* "no CBECS interval, so untested" — deliberately distinct from both the bold
   (tested and outside) and the plain (tested and inside) states */
.ci-na{color:var(--ink-3);font-weight:600;margin-left:2px}
.scroll{overflow-x:auto}
.grid3{display:grid;grid-template-columns:repeat(auto-fit,minmax(255px,1fr));gap:12px}
/* Figure rows: wrap, never shrink, so every plot keeps its 1:1 size. Equal-
   fraction grid tracks forced a 760-unit waterfall into a 541px column (0.71)
   and a 570-unit distribution into 357px (0.63), scaling their labels down with
   them. Now a row simply takes as many figures as fit. */
.grid2{display:flex;flex-wrap:wrap;gap:14px;align-items:flex-start}
.grid-dist{display:flex;flex-wrap:wrap;gap:12px;align-items:flex-start}
.grid2>*,.grid-dist>*{flex:0 0 auto;max-width:100%;min-width:0}
/* Subplot rows: content-sized and tight, the way a row of matplotlib subplots
   sits. Equal-fraction grid columns held three fixed 1/3 slots whatever the
   figures needed, which is what spread a row of narrow panels across the page. */
/* WRAP, never shrink: each figure keeps its 1:1 size and the row packs as many
   as fit. `flex:0 1 auto` let three figures squeeze into three 300px slots and
   scaled their text down to 6px, which is the whole problem this avoids. */
.grid3fit{display:flex;flex-wrap:wrap;gap:10px;align-items:flex-start}
.grid3fit>*{flex:0 0 auto;max-width:100%;min-width:0}
/* the paired "applicable | whole stock" figures, likewise sized to the plots */
.chart-pair{display:flex;flex-wrap:wrap;gap:12px;align-items:flex-start}
.chart-pair>*{flex:0 0 auto;max-width:100%;min-width:0}
.ami-wrap{display:flex;gap:22px;align-items:flex-start;justify-content:center}
/* Flexible tracks, not a 315px cap. The cap could not hold a figure that
   fillRows had magnified to use the row's slack, so the panels overflowed their
   tracks and drew over each other's axes. */
.ami-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:6px 12px;
  min-width:0;flex:1 1 auto}
.ami-legend{width:168px;flex:none;display:flex;flex-direction:column;gap:7px;
  font-size:12px;color:var(--ink-2);position:sticky;top:70px}
.btn-mini{font-size:11.5px;padding:2px 9px;border-radius:6px;color:var(--ink-3)}
.btn-mini:hover{color:var(--ink)}
/* chart with its legend in a rail to the right — the layout the repo's figures
   use, and it stops a long end-use x fuel legend from wrapping across the top */
/* The chart column takes all the space the legend rail does not: with
   `flex:0 1 auto` it collapsed to its minimum, which both stacked the two
   charts vertically and dropped the rail on top of the plot. */
/* Content-sized, centred as a group. Each figure now carries a definite px
   width, so the chart column can shrink to it and the legend rail sits right
   beside the plot rather than pinned to the far right of the panel with a band
   of empty card between them. */
.chart-row{display:flex;gap:14px;align-items:flex-start;flex-wrap:nowrap}
.chart-row>.chart-main{flex:0 1 auto;min-width:0}
/* The rail may absorb slack the figures did not take, so the row has no gap
   sitting in front of the first plot. It never shrinks below the width the
   longest "end use, fuel" label needs. */
/* padding-top is set by alignLegendRails() from the measured plot-frame top */
.chart-row>.chart-side{flex:1 1 218px;min-width:218px;max-width:330px}
.chart-side .legend{flex-direction:column;align-items:flex-start;gap:4px 0;flex-wrap:nowrap}
.chart-side .key{white-space:nowrap;font-size:11.5px}
/* A legend chip carries its own pixel size inline (see hatchChip). This is the
   belt-and-braces guard: the `svg{width:100%;height:auto}` chart rule below
   must never get hold of a chip again. */
.key>svg{flex:none;display:inline-block;overflow:hidden}
/* the combined end-use x fuel key: one column, tight rows, long labels wrap
   under the label rather than past the panel edge */
.fe-key{flex-direction:column;align-items:flex-start;flex-wrap:nowrap;gap:2px 0;
  font-size:11px;line-height:1.35;margin:0}
.fe-key .key{align-items:flex-start;gap:6px;max-width:100%;cursor:pointer}
.fe-key .key>svg{margin-top:2px}
.fe-key .key>span{white-space:normal;padding-left:0;text-indent:0}
.chart-side .legend-title{font-size:11px;font-weight:650;color:var(--ink-2);
  text-transform:uppercase;letter-spacing:.04em;margin:0 0 3px}
.chart-side .legend+.legend-title{margin-top:12px}
@media (max-width:900px){
  .chart-row{flex-wrap:wrap}
  .chart-row>.chart-side{flex:1 1 100%;width:auto;padding-top:4px}
  .chart-side .legend{flex-direction:row;flex-wrap:wrap;gap:5px 12px}
}
/* clickable series keys: dim the swatch and strike the label when hidden */
.key[data-eu],.key[data-fe]{cursor:pointer;user-select:none}
.key[data-eu]:hover,.key[data-fe]:hover{color:var(--ink)}
.key[data-eu][aria-pressed="false"],
.key[data-fe][aria-pressed="false"]{opacity:.42;text-decoration:line-through}
/* multi-measure dropdown checklist: stays compact however many measures a run
   carries; the swatches double as the legend */
.mmulti{position:relative;display:inline-block}
.mmenu{position:absolute;right:0;top:calc(100% + 5px);z-index:40;background:var(--panel);
  border:1px solid var(--line);border-radius:9px;padding:8px;min-width:270px;
  box-shadow:0 8px 24px rgba(0,0,0,.14);max-height:330px;overflow:auto}
.mmenu-actions{display:flex;gap:6px;margin-bottom:6px;padding-bottom:6px;
  border-bottom:1px solid var(--line)}
.mmenu-item{display:flex;gap:7px;align-items:center;font-size:12.5px;color:var(--ink-2);
  padding:3px 5px;border-radius:5px;cursor:pointer;white-space:nowrap}
.mmenu-item:hover{background:var(--grid)}
.chartbox .head{margin:0 0 2px}
.chartbox h3{margin:0}
/* per-chart controls: always at the right end of the chart's title line */
.chart-ctl{display:flex;gap:6px;margin-left:auto;flex:none}
.chart-title-row{margin:0 0 2px}
.note{font-size:12.5px;color:var(--ink-3);margin-top:9px;line-height:1.5}
.tip{position:fixed;pointer-events:none;opacity:0;transition:opacity .09s;
  background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:8px 10px;
  font-size:12.5px;box-shadow:0 6px 22px rgba(0,0,0,.16);z-index:60;max-width:280px}
.tip b{font-weight:650}
.tip .row{display:flex;justify-content:space-between;gap:14px;color:var(--ink-2)}
.badge{display:inline-block;font-size:11px;padding:1px 7px;border-radius:99px;
  border:1px solid var(--line);color:var(--ink-3);margin-left:6px}
svg{display:block;width:100%;height:auto;overflow:visible}
/* Axis text: full-strength ink, not a grey. These are the numbers a reader
   checks a figure against, and at 11px a light grey reads as decoration. */
.ax{font-size:11.5px;fill:var(--ink)}
.absent{color:var(--ink-3);font-style:italic;white-space:nowrap}
.axl{font-size:12px;fill:var(--ink)}
.gl{stroke:var(--grid);stroke-width:1}
.zero{stroke:var(--line);stroke-width:1.5}
.hidden{display:none}
ul.caveats{margin:6px 0 0;padding-left:18px;color:var(--ink-2);font-size:13px}
ul.caveats li{margin-bottom:5px}
"""

# The page's behaviour lives in resources/dashboard.js rather than an inline
# string. It is ~5,000 lines; as a Python literal it made this module
# unreviewable and hid JS syntax errors from every editor and linter.
JS = (Path(__file__).parent / "resources" / "dashboard.js").read_text(encoding="utf-8")

HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title>
<style>{css}</style></head>
<body>
<div class="wrap">
  <h1>ComStock results dashboard</h1>
  <p class="sub">{runs} · generated {created} · {references}</p>
  <div class="controls">
    <div class="tabs" role="tablist">
      <button class="tab" role="tab" data-tab="overview">Overview</button>
      <button class="tab" role="tab" data-tab="annual">Annual vs CBECS</button>
      <button class="tab" role="tab" data-tab="dist">Distributions</button>
      <button class="tab" role="tab" data-tab="ami">Timeseries vs AMI</button>
      <button class="tab" role="tab" data-tab="params" id="paramsTab">Design parameters</button>
    </div>
    <span id="typeWrap"><label for="type" style="font-size:13px;color:var(--ink-3);margin-right:6px">Building type</label>
    <select id="type"></select></span>
    <span class="spacer"></span>
    <button id="theme" title="Toggle light/dark">◐</button>
  </div>
  <div id="view"></div>
</div>
<script>window.__DASHBOARD__ = {payload};</script>
<script>{js}</script>
</body></html>
"""


def _script_safe(text: str) -> str:
    """JSON that cannot terminate the <script> it is embedded in: a `</script>`
    in a run label or category would otherwise end the element early."""
    return (text.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
            .replace("\u2028", "\\u2028").replace("\u2029", "\\u2029"))


def build(assess: Path, out: Path) -> Path:
    payload = build_payload(assess)
    runs = " vs ".join(r["label"] for r in payload["runs"]) or "ComStock"
    html = HTML.format(
        title=f"ComStock results dashboard — {runs}",
        css=CSS, js=JS,
        payload=_script_safe(json.dumps(payload, allow_nan=False)),
        runs=runs,
        created=(payload["created"] or "")[:10],
        # region="all" used to print literally as "AMI all"; name the count of
        # regions actually compared instead of the argument.
        references=_references_label(payload),
    )
    out.write_text(html, encoding="utf-8")
    return out
