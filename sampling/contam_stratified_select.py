# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Choose buildings for the CONTAM infiltration campaign (osm2contam PLAN.md §8.4).

Two steps, run either side of a survey:

    pool      Draw a candidate pool from a full ComStock sample, spread evenly over
              proxy cells (building type x storey band x climate group). Proxies are all
              that is known before the survey; the survey measures the real axes.

        python sampling/contam_stratified_select.py pool <buildstock.csv> \\
            --size 1000 --out samples/contam_pool.csv

    campaign  From the survey's buildings.csv (osm2contam scripts/comstock_collect.py
              --survey), bin every building on the measured §8.4.2 axes, fully cross
              imbalance x height x climate (§8.4.5), fill each cell, keep the §8.4.6
              hold-out types as their own arm, pin airtightness to one stock value
              (§8.4.3), and write the campaign sample in batches with a YAML each.

        python sampling/contam_stratified_select.py campaign <buildings.csv> \\
            <buildstock.csv> --out samples/contam_campaign --template ymls/contam_dev.yml

Building type is used only to spread the pool and to name the hold-out arm. It is never
a selection axis for the main arm: the fit must not be keyed on it (§8.6).

Standard library only, so it runs under any Python.
"""

import argparse
import collections
import csv
import json
import random
import re
import statistics
import sys
from pathlib import Path

#: §8.4.6: types held out of the fit *before* it is run — one exhaust-dominated, one
#: tall, one large-volume single-zone — then predicted and compared.
DEFAULT_HOLDOUT = ("full_service_restaurant", "large_hotel", "warehouse")

#: §8.4.2 bins. Each is (label, upper bound exclusive); the last bound is infinity.
IMBALANCE_BINS = (("balanced", 0.05), ("moderate", 0.20), ("exhaust", float("inf")))
OA_BINS = (("low", 0.15), ("mid", 0.30), ("high", float("inf")))
HEIGHT_BINS = (("1", 2), ("2-3", 4), ("4-8", 9), ("9+", float("inf")))
HDD_BINS = (("hot", 1500.0), ("mild", 3000.0), ("cold", float("inf")))

#: California CEC zones onto the IECC thermal digit, for the pool's proxy only. The
#: campaign's climate axis is measured from each building's weather file instead.
CEC_TO_IECC = {
    "CEC1": 4, "CEC2": 3, "CEC3": 3, "CEC4": 3, "CEC5": 3, "CEC6": 3, "CEC7": 3,
    "CEC8": 3, "CEC9": 3, "CEC10": 3, "CEC11": 3, "CEC12": 3, "CEC13": 3, "CEC14": 3,
    "CEC15": 2, "CEC16": 5,
}


def bin_of(value, bins):
    for label, upper in bins:
        if value < upper:
            return label
    return bins[-1][0]


def read_csv(path):
    with open(path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        return reader.fieldnames, list(reader)


def write_csv(path, fieldnames, rows):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


# -- pool ---------------------------------------------------------------------------


def storey_band(number_stories):
    match = re.match(r"\d+", number_stories or "")
    return bin_of(int(match.group()) if match else 1, HEIGHT_BINS)


def climate_group(zone):
    digit = CEC_TO_IECC.get(zone)
    if digit is None:
        match = re.match(r"\d", zone or "")
        digit = int(match.group()) if match else 4
    return "hot" if digit <= 2 else "warm" if digit == 3 else "mixed" if digit == 4 else "cold"


def pool(args):
    fields, rows = read_csv(args.sample)
    cells = collections.defaultdict(list)
    for row in rows:
        key = (row["building_type"], storey_band(row["number_stories"]),
               climate_group(row["climate_zone"]))
        cells[key].append(row)
    rng = random.Random(args.seed)
    for members in cells.values():
        rng.shuffle(members)

    # Round-robin over the occupied cells: one from each per pass, so a rare cell (a
    # nine-storey hot-climate hotel) is drawn as surely as a common one, and the pool
    # spans the space rather than reproducing the stock's proportions.
    order = sorted(cells)
    rng.shuffle(order)
    chosen, taken = [], collections.Counter()
    while len(chosen) < args.size and any(taken[c] < len(cells[c]) for c in order):
        for cell in order:
            if len(chosen) >= args.size:
                break
            if taken[cell] < len(cells[cell]):
                chosen.append((cell, cells[cell][taken[cell]]))
                taken[cell] += 1

    write_csv(args.out, fields, [row for _, row in chosen])
    manifest = Path(args.out).with_name(Path(args.out).stem + "_cells.csv")
    write_csv(manifest, ["Building", "building_type", "storey_band", "climate_group"], [
        {"Building": row["Building"], "building_type": c[0], "storey_band": c[1],
         "climate_group": c[2]} for c, row in chosen
    ])
    print(f"pool: {len(chosen)} of {len(rows)} rows over {len(cells)} occupied proxy cells "
          f"-> {args.out}")
    print(f"  per cell: min {min(taken.values())}, max {max(taken.values())}")
    return 0


# -- campaign ---------------------------------------------------------------------------


def _float(row, key):
    try:
        return float(row[key])
    except (KeyError, TypeError, ValueError):
        return None


def campaign(args):
    _, surveyed = read_csv(args.buildings)
    fields, sample = read_csv(args.sample)
    by_id = {row["Building"]: row for row in sample}

    ok = [b for b in surveyed if b.get("status") == "ok"]
    if not ok:
        print("no successfully surveyed buildings", file=sys.stderr)
        return 2
    winds = [w for b in ok if (w := _float(b, "rms_wind_m_s")) is not None]
    wind_split = statistics.median(winds)
    exposures = sorted(e for b in ok if (e := _float(b, "exterior_area_per_volume_1_m")) is not None)
    tertiles = (exposures[len(exposures) // 3], exposures[2 * len(exposures) // 3])

    for b in ok:
        b["imbalance_bin"] = bin_of(_float(b, "imbalance_ratio") or 0.0, IMBALANCE_BINS)
        b["oa_bin"] = bin_of(_float(b, "oa_fraction") or 0.0, OA_BINS)
        b["height_bin"] = bin_of(int(_float(b, "building_storeys") or 1), HEIGHT_BINS)
        b["climate_bin"] = (bin_of(_float(b, "hdd18_c_day") or 0.0, HDD_BINS) + "/"
                            + ("windy" if (_float(b, "rms_wind_m_s") or 0) >= wind_split
                               else "calm"))
        exposure = _float(b, "exterior_area_per_volume_1_m") or 0.0
        b["exposure_bin"] = ("compact" if exposure < tertiles[0]
                             else "medium" if exposure < tertiles[1] else "exposed")
        b["cell"] = f"{b['imbalance_bin']}|{b['height_bin']}|{b['climate_bin']}"

    holdout_types = set(args.holdout)
    main = [b for b in ok if b["building_type"] not in holdout_types]
    held = [b for b in ok if b["building_type"] in holdout_types]
    rng = random.Random(args.seed)

    # -- main arm: every cell of the primary crossing, filled up to --per-cell ----------
    by_cell = collections.defaultdict(list)
    for b in main:
        by_cell[b["cell"]].append(b)
    climate_bins = [f"{h}/{w}" for h, _ in HDD_BINS for w in ("calm", "windy")]
    all_cells = [f"{i}|{h}|{c}" for i, _ in IMBALANCE_BINS for h, _ in HEIGHT_BINS
                 for c in climate_bins]

    def pick(candidates, count):
        """Greedy: each pick adds the most secondary-axis values not yet represented
        (OA band, exposure, fan mode, and — for spread only — building type)."""
        candidates = list(candidates)
        rng.shuffle(candidates)
        chosen, seen = [], collections.defaultdict(set)
        axes = ("oa_bin", "exposure_bin", "fan_mode", "building_type")
        while candidates and len(chosen) < count:
            best = max(candidates, key=lambda b: sum(b.get(a) not in seen[a] for a in axes))
            candidates.remove(best)
            chosen.append(best)
            for a in axes:
                seen[a].add(best.get(a))
        return chosen

    selected = []
    for cell in all_cells:
        for b in pick(by_cell.get(cell, []), args.per_cell):
            selected.append({**b, "arm": "main"})
    # Top up to the target from the cells with spare candidates, widest cells last.
    if args.target and len(selected) < args.target:
        spare = [b for b in main if not any(s["Building"] == b["Building"] for s in selected)]
        extra = pick(spare, args.target - len(selected))
        selected += [{**b, "arm": "main"} for b in extra]

    # -- hold-out arm: per type, spread over height and climate -------------------------
    for building_type in sorted(holdout_types):
        candidates = [b for b in held if b["building_type"] == building_type]
        groups = collections.defaultdict(list)
        for b in candidates:
            groups[(b["height_bin"], b["climate_bin"])].append(b)
        ordered = []
        for members in groups.values():
            rng.shuffle(members)
        while len(ordered) < min(args.holdout_per_type, len(candidates)):
            for members in groups.values():
                if members and len(ordered) < args.holdout_per_type:
                    ordered.append(members.pop())
        selected += [{**b, "arm": "holdout"} for b in ordered]

    # -- airtightness pinned to one stock value (§8.4.3) --------------------------------
    pin = args.airtightness or _stock_median(sample, "airtightness")
    out = Path(args.out)
    rows = []
    for s in selected:
        row = dict(by_id[s["Building"]])
        s["airtightness_sampled"] = row["airtightness"]
        row["airtightness"] = pin
        rows.append(row)

    # -- batches: each one a mix of cells, so a batch that dies costs breadth, not a cell
    selected.sort(key=lambda s: (s["arm"], s["cell"]))
    n_batches = max(1, -(-len(selected) // args.batch_size))
    for index, s in enumerate(selected):
        s["batch"] = index % n_batches + 1
    row_of = {r["Building"]: r for r in rows}
    write_csv(out / "campaign_buildstock.csv", fields, [row_of[s["Building"]] for s in selected])
    for batch in range(1, n_batches + 1):
        members = [row_of[s["Building"]] for s in selected if s["batch"] == batch]
        sample_path = out / f"contam_campaign_{batch:02d}.csv"
        write_csv(sample_path, fields, members)
        if args.template:
            _write_yaml(Path(args.template), out / f"contam_campaign_{batch:02d}.yml",
                        sample_path, batch, len(members))

    manifest_fields = ["Building", "arm", "batch", "cell", "imbalance_bin", "height_bin",
                       "climate_bin", "oa_bin", "exposure_bin", "fan_mode", "building_type",
                       "climate_zone", "airtightness_sampled"]
    write_csv(out / "selection.csv", manifest_fields, selected)

    counts = collections.Counter(s["cell"] for s in selected if s["arm"] == "main")
    write_csv(out / "cells.csv", ["cell", "candidates", "selected"], [
        {"cell": c, "candidates": len(by_cell.get(c, [])), "selected": counts.get(c, 0)}
        for c in all_cells
    ])
    occupied = sum(1 for c in all_cells if by_cell.get(c))
    summary = {
        "surveyed": len(surveyed), "ok": len(ok), "main": sum(s["arm"] == "main" for s in selected),
        "holdout": sum(s["arm"] == "holdout" for s in selected), "batches": n_batches,
        "cells": len(all_cells), "cells_with_candidates": occupied,
        "airtightness_pinned": pin, "wind_split_rms_m_s": wind_split,
        "exposure_tertiles_1_m": tertiles, "holdout_types": sorted(holdout_types),
    }
    (out / "selection.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


def _stock_median(sample, column):
    values = sorted(float(r[column]) for r in sample if r.get(column))
    median = values[len(values) // 2]
    # Keep the option's own spelling (e.g. "20.0"), or options_lookup will not match it.
    spelling = {float(r[column]): r[column] for r in sample if r.get(column)}
    return spelling[median]


def _write_yaml(template, target, sample_path, batch, count):
    text = template.read_text(encoding="utf-8")
    replacements = {
        r"^output_directory:.*$": f"output_directory: ../contam_campaign_output/batch_{batch:02d}",
        r"^(\s*)sample_file:.*$": lambda m: f"{m.group(1)}sample_file: {sample_path.resolve().as_posix()}",
        r"^(\s*)n_buildings_represented:.*$": lambda m: f"{m.group(1)}n_buildings_represented: {count}",
    }
    for pattern, replacement in replacements.items():
        text, n = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
        if n != 1:
            raise SystemExit(f"{template}: no line matching {pattern!r}")
    target.write_text(text, encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("pool", help="draw a candidate pool spread over proxy cells")
    p.add_argument("sample", help="a full ComStock buildstock.csv")
    p.add_argument("--size", type=int, default=1000)
    p.add_argument("--seed", type=int, default=2026)
    p.add_argument("--out", required=True, help="pool buildstock.csv to write")
    p.set_defaults(func=pool)

    p = sub.add_parser("campaign", help="select the campaign from the survey")
    p.add_argument("buildings", help="the survey's buildings.csv (comstock_collect --survey)")
    p.add_argument("sample", help="the buildstock.csv the survey's rows came from")
    p.add_argument("--out", required=True, help="directory for the campaign files")
    p.add_argument("--per-cell", type=int, default=3)
    p.add_argument("--target", type=int, default=0,
                   help="top the main arm up to this many from spare candidates")
    p.add_argument("--holdout", nargs="*", default=list(DEFAULT_HOLDOUT))
    p.add_argument("--holdout-per-type", type=int, default=5)
    p.add_argument("--airtightness",
                   help="pinned airtightness option (default: the sample's median)")
    p.add_argument("--batch-size", type=int, default=40)
    p.add_argument("--template", help="a coupled-run YAML to write one per batch from")
    p.add_argument("--seed", type=int, default=2026)
    p.set_defaults(func=campaign)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
