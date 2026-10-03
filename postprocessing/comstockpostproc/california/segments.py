# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""How ComStock buildings are grouped to match the CalMAC granular-profile segments.

Plain dicts, so a driver can override any of them (`resolve_config`). The resolved
mapping is written into the dashboard manifest, so the page states exactly what
was compared with what.

A granular profile (GP) is named `<Industry6>_<Size>_<CZ group>`, e.g.
`Office_M_C`. Its value is the AVERAGE PER-PREMISE consumption of ~200 sampled
non-participant premises -- not a total, and not per square foot.

Where each choice comes from (CALMAC_DASHBOARD_PLAN.md):
  INDUSTRY_MAP        agreed with the owner (plan §4.1). Every ComStock type maps to
                      exactly one GP industry; eleven GP industries have no ComStock
                      counterpart and are reported, not compared.
  SIZE_RULE           plan §4.2. The truth's size is a RATE CLASS; ComStock has none,
                      so annual peak demand stands in for it. PG&E A-1/A-6 are below
                      75 kW, SDG&E Schedule A is up to about 20 kW.
  SIZE_NOT_COMPARABLE plan §4.2. The truth's size is a property of the metered
                      premise, and for these industries a ComStock building is many
                      premises, so their size split is shown only as indicative.
  CZ_GROUPS           PG&E from its methodology document; SDG&E from the centroid
                      check (plan §4.4) -- the SDG&E document repeats PG&E's zone
                      numbers, which cannot apply to San Diego.
  SEASONS             the CalTRACK seasons the SDG&E document uses (plan §4.5).
"""

from __future__ import annotations

import copy

PGE, SDGE = 14328, 16609

UTILITIES = {PGE: "PG&E", SDGE: "SDG&E"}
# File-name and payload-key form of each utility.
UTILITY_SLUG = {PGE: "pge", SDGE: "sdge"}

# The six-letter industry codes of the GP names, with the long names the data
# dictionaries use.
INDUSTRY_NAMES = {
    "Agricu": "Agriculture and Pumping",
    "Automo": "Automotive and Repair",
    "Constr": "Construction",
    "Educat": "Education",
    "FullSe": "Full-Service Restaurants and Bars",
    "GasSta": "Gas Stations and Convenience Stores",
    "Govern": "Government-Institutional",
    "Grocer": "Grocery",
    "Health": "Health",
    "Limite": "Limited-Service Restaurants",
    "Lodgin": "Lodging and Entertainment",
    "Manufa": "Manufacturing",
    "Missin": "Miscellaneous / Unknown",
    "Office": "Office",
    "Person": "Personal Care Services",
    "Proper": "Property Management",
    "Religi": "Religious",
    "Retail": "Retail",
    "Transp": "Transportation, Communications and Utilities",
    "Wareho": "Warehouse and Wholesale",
}

# GP industry -> the ComStock building types that stand for it (plan §4.1).
INDUSTRY_MAP = {
    "Office": ["SmallOffice", "MediumOffice", "LargeOffice"],
    "Retail": ["RetailStandalone", "RetailStripmall"],
    "Grocer": ["Grocery"],
    "FullSe": ["FullServiceRestaurant"],
    "Limite": ["QuickServiceRestaurant"],
    "Lodgin": ["SmallHotel", "LargeHotel"],
    "Educat": ["PrimarySchool", "SecondarySchool"],
    "Health": ["Hospital", "Outpatient"],
    "Wareho": ["Warehouse"],
}

# The aggregate segment: every mapped industry together. The most robust shape
# comparison, because it dilutes any one mapping error.
ALL_MAPPED = "All mapped"

# Size proxy (plan §4.2). `labels` are the truth's own size letters for each
# utility, (small, medium/large); 'A' in the truth means sizes were combined.
SIZE_RULE = {
    "kind": "peak_kw",                       # 'peak_kw' | 'none' (fully pooled)
    "thresholds_kw": {PGE: 75.0, SDGE: 20.0},  # annual peak below this -> small
    "labels": {PGE: ["S", "M"], SDGE: ["S", "L"]},
}
SIZE_NOT_COMPARABLE = {
    "Retail": "RetailStripmall is one building of many small premises, so the truth's "
              "small/large split (a property of the metered premise) has no ComStock "
              "counterpart",
    "Office": "medium and large offices are mostly multi-tenant, so the truth's "
              "small/large split (a property of the metered premise) has no ComStock "
              "counterpart",
}
POOLED = "pooled"

# How the truth's size series (and, for All mapped, its industries) are combined
# into one pooled series. The CalMAC files carry no premise POPULATION: the PG&E
# "segments and counts" file and the SDG&E "count" column are the ~200-premise
# SAMPLE behind each profile (PG&E's sums to exactly 140 x 200 = 28,000). So the
# default weights each truth series by the ComStock run's own weighted building
# count in the matching cell (composition-matched): the pooled truth is then the
# profile the meters would show with ComStock's mix, and the pooled comparison
# tests the shapes rather than a difference in mix. 'equal' is the alternative.
POOL_WEIGHTS = "comstock"                    # 'comstock' | 'equal'

# CEC Title 24 building climate zones in each GP climate-zone group (plan §4.3).
CZ_GROUPS = {
    PGE: {"C": ["CEC1", "CEC3", "CEC5"], "I": ["CEC2", "CEC4"],
          "N": ["CEC11", "CEC12"], "S": ["CEC13"]},
    SDGE: {"C": ["CEC7"], "I": ["CEC10"]},
}
CZ_GROUP_LABELS = {
    PGE: {"C": "Coastal", "I": "Inland", "N": "North Central Valley",
          "S": "South Central Valley"},
    SDGE: {"C": "Coastal", "I": "Inland"},
}
OTHER_ZONE = "other"

# CalTRACK seasons (plan §4.5); day types are weekday / weekend, no holidays.
SEASONS = {"Summer": [6, 7, 8, 9], "Winter": [11, 12, 1, 2], "Shoulder": [3, 4, 5, 10]}
SEASON_ORDER = ["Summer", "Winter", "Shoulder"]

# 1 therm = 100,000 Btu = 29.3071 kWh.
KWH_PER_THERM = 29.307107


def parse_gp(gp: str) -> tuple[str, str, str]:
    """`Office_M_C` -> ('Office', 'M', 'C'). Raises on anything else, so a renamed
    profile fails loudly instead of landing in the wrong segment."""
    parts = str(gp).split("_")
    if len(parts) != 3 or len(parts[0]) != 6 or not parts[1] or not parts[2]:
        raise ValueError(f"not a granular-profile name: {gp!r} (expected <Industry6>_<Size>_<CZ>)")
    return parts[0], parts[1], parts[2]


def industry_of_type(industry_map: dict) -> dict:
    """ComStock building type -> GP industry, checking no type maps twice."""
    out = {}
    for ind, types in industry_map.items():
        for t in types:
            if t in out:
                raise ValueError(f"building type {t} is mapped to both {out[t]} and {ind}")
            out[t] = ind
    return out


def zone_to_group(cz_groups_for_utility: dict) -> dict:
    """'CEC7' -> 'C' for one utility, checking no zone sits in two groups."""
    out = {}
    for grp, zones in cz_groups_for_utility.items():
        for z in zones:
            if z in out:
                raise ValueError(f"climate zone {z} is in both group {out[z]} and {grp}")
            out[z] = grp
    return out


def resolve_config(overrides: dict | None = None) -> dict:
    """The defaults above with a driver's overrides applied.

    Keys: utilities, industry_map, size_rule, size_not_comparable, cz_groups,
    cz_group_labels, seasons, pool_weights, truth_basis. Utility ids may arrive as
    strings (a JSON round trip); they are normalized to int.
    """
    cfg = {
        "utilities": dict(UTILITIES),
        "industry_map": copy.deepcopy(INDUSTRY_MAP),
        "size_rule": copy.deepcopy(SIZE_RULE),
        "size_not_comparable": dict(SIZE_NOT_COMPARABLE),
        "cz_groups": copy.deepcopy(CZ_GROUPS),
        "cz_group_labels": copy.deepcopy(CZ_GROUP_LABELS),
        "seasons": copy.deepcopy(SEASONS),
        "pool_weights": POOL_WEIGHTS,
        # SDG&E profiles: 'normalized_2018' (weather-normalized to ComStock's year)
        # or 'raw' (the published 2025 series)
        "truth_basis": "normalized_2018",
    }
    for k, v in (overrides or {}).items():
        if k not in cfg:
            raise KeyError(f"unknown CalMAC setting {k!r}; expected one of {sorted(cfg)}")
        cfg[k] = copy.deepcopy(v)
    if isinstance(cfg["size_rule"], str):           # 'none' or 'peak_kw' shorthand
        cfg["size_rule"] = {**copy.deepcopy(SIZE_RULE), "kind": cfg["size_rule"]}
    cfg["utilities"] = {int(k): v for k, v in cfg["utilities"].items()}
    cfg["cz_groups"] = {int(k): v for k, v in cfg["cz_groups"].items()}
    cfg["cz_group_labels"] = {int(k): v for k, v in cfg["cz_group_labels"].items()}
    sr = cfg["size_rule"]
    sr["thresholds_kw"] = {int(k): float(v) for k, v in sr.get("thresholds_kw", {}).items()}
    sr["labels"] = {int(k): list(v) for k, v in sr.get("labels", {}).items()}
    if sr["kind"] not in ("peak_kw", "none"):
        raise ValueError(f"size_rule kind must be 'peak_kw' or 'none', not {sr['kind']!r}")
    if cfg["pool_weights"] not in ("comstock", "equal"):
        raise ValueError(f"pool_weights must be 'comstock' or 'equal', not {cfg['pool_weights']!r}")
    if cfg["truth_basis"] not in ("normalized_2018", "raw"):
        raise ValueError("truth_basis must be 'normalized_2018' or 'raw'")
    industry_of_type(cfg["industry_map"])           # validates
    for u, groups in cfg["cz_groups"].items():
        zone_to_group(groups)                       # validates
    return cfg


def config_for_json(cfg: dict) -> dict:
    """The resolved config with string keys, for the manifest and the page."""
    def keys_to_str(d):
        return {str(k): v for k, v in d.items()}
    out = copy.deepcopy(cfg)
    for k in ("utilities", "cz_groups", "cz_group_labels"):
        out[k] = keys_to_str(out[k])
    out["size_rule"]["thresholds_kw"] = keys_to_str(out["size_rule"]["thresholds_kw"])
    out["size_rule"]["labels"] = keys_to_str(out["size_rule"]["labels"])
    out["utility_slugs"] = {str(k): UTILITY_SLUG.get(k, str(k)) for k in cfg["utilities"]}
    out["industry_names"] = dict(INDUSTRY_NAMES)
    out["all_mapped"] = ALL_MAPPED
    return out
