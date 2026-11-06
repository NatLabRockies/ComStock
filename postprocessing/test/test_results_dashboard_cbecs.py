# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""CBECS-side aggregation of the results dashboard. No Athena, no files."""

import numpy as np
import pandas as pd

from comstockpostproc.results_dashboard import annual, heating_fuel as hf
from comstockpostproc.results_dashboard.jackknife import grouped_totals_with_ci

REP = "Unknown Eligibility and Nonresponse Adjusted Replicate Weight {}"


def _cbecs(**cols):
    n = len(next(iter(cols.values())))
    df = pd.DataFrame(cols)
    df["weight"] = 1.0
    # distinct replicate weights, so a nonzero group has a nonzero variance
    for r, w in ((1, 0.5), (2, 1.5)):
        df[REP.format(r)] = w
    return df


def test_blank_is_non_use_and_an_unpublished_column_stays_missing():
    df = _cbecs(grp=["a", "a", "b", "b"], gas=[10.0, np.nan, np.nan, np.nan],
                propane=[np.nan] * 4)
    r = grouped_totals_with_ci(df, ["gas", "propane"], by="grp").set_index(["grp", "metric_col"])
    assert r.loc[("a", "gas"), "estimate"] == 10.0          # the blank adds nothing
    assert r.loc[("a", "gas"), "se"] > 0                     # the variance is really computed
    assert r.loc[("b", "gas"), "estimate"] == 0.0           # no users in b: zero, not missing
    for col in ("se", "ci95_low", "ci95_high", "rse_pct"):  # ...and no interval to test against
        assert np.isnan(r.loc[("b", "gas"), col])
    assert np.isnan(r.loc[("a", "propane"), "estimate"])    # never published: missing everywhere
    assert np.isnan(r.loc[("b", "propane"), "estimate"])


def test_percent_of_a_zero_cbecs_value_is_missing_not_infinite():
    pct = annual._pct_of(pd.Series([5.0, 0.0, 3.0]), pd.Series([0.0, 0.0, 2.0]))
    assert np.isnan(pct[0]) and np.isnan(pct[1]) and pct[2] == 50.0


def test_multi_fuel_record_splits_its_area_and_counts_district_once():
    yes = {c: ["No"] * 3 for c in hf.CBECS_FUEL_COLS}
    yes["Natural gas used for main heating"] = ["Yes", "Yes", "No"]
    yes["Electricity used for main heating"] = ["No", "Yes", "No"]
    yes["District steam used for main heating"] = ["No", "No", "Yes"]
    yes["District hot water used for main heating"] = ["No", "No", "Yes"]
    df = pd.DataFrame(yes)
    df[hf.CBECS_HEATED_COL] = "Yes"
    df["weight"] = 1.0
    df[hf.SQFT_COL] = [100.0, 100.0, 100.0]
    df[hf.BLDG_TYPE_COL] = "Office"
    df[hf.DIV_COL] = "Pacific"
    long, prov = hf.cbecs_heating_fuel(df)
    assert prov["multiple_fuels"] == 1                       # record 2 only: steam + hot water is one fuel
    nat = long[(long.btype == "All") & (long.dimension == "none")].set_index("fuel")
    # every canonical fuel is present in every cell, at zero where none was used,
    # so the page can show a numeric difference instead of a "cannot represent" tag
    assert nat["area"].to_dict() == {"Natural gas": 150.0, "Electricity": 50.0, "District heating": 100.0,
                                     "Fuel oil": 0.0, "Propane": 0.0, "Wood": 0.0}
    assert abs(nat["area_share_pct"].sum() - 100.0) < 1e-9    # still a partition
    assert nat["n"].to_dict() == {"Natural gas": 2.0, "Electricity": 1.0, "District heating": 1.0,
                                  "Fuel oil": 0.0, "Propane": 0.0, "Wood": 0.0}
    assert (nat["cell_n"] == 3.0).all()                        # three buildings, each counted once
