# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Pure-Python checks of the results dashboard timeseries clock handling. No Athena.

Published-release tables store every building's timestamps in Eastern Standard
Time (ComStock FAQ); crawled run tables and AMI meters are in local standard
time. These pin the SQL fragments that reconcile the two.
"""

from comstockpostproc.results_dashboard import timeseries as ts
from comstockpostproc.results_dashboard.measures import MEASURE_SEASONS

CRAWLED = {**ts.PUBLISHED, "bldg": "building_id", "time": "time", "state": "",
           "kind": "crawled", "tz": "local"}


def test_published_time_is_converted_from_est_by_state():
    expr = ts.time_expr(ts.PUBLISHED)
    assert expr.startswith("date_add('hour', CASE ")
    assert "IN ('CA', 'NV', 'OR', 'WA') THEN -3" in expr
    assert "IN ('AZ', 'CO', 'ID', 'MT', 'NM', 'UT', 'WY') THEN -2" in expr
    assert "IN ('HI',) THEN -5" not in expr          # single-state groups still valid SQL
    assert "IN ('HI') THEN -5" in expr
    assert 'ELSE 0 END, t."timestamp")' in expr


def test_crawled_time_is_left_in_local_standard_time():
    assert ts.time_expr(CRAWLED) == 't."time"'
    assert "date_add('hour'" not in ts.hour_trunc(CRAWLED)


def test_hour_bucket_moves_period_ending_stamp_into_its_own_hour():
    # Same arithmetic as ComStockQueryBuilder: date_add('second', -900, time).
    assert ts.hour_trunc(CRAWLED) == '''date_trunc('hour', date_add('minute', -15, t."time"))'''


def test_published_table_without_state_cannot_be_converted():
    d = {**ts.PUBLISHED, "state": ""}
    # No state column: nothing to key the conversion on, so the stamp is left
    # alone rather than shifted by a guess.
    assert ts.time_expr(d) == 't."timestamp"'


def test_est_to_local_offsets_are_standard_time_offsets():
    assert ts.EST_TO_LOCAL_HOURS["OR"] == -3      # Pacific: the pge AMI region
    assert ts.EST_TO_LOCAL_HOURS["CO"] == -2      # Mountain: fort_collins
    assert ts.EST_TO_LOCAL_HOURS["TN"] == -1      # Central majority: epb
    assert "NY" not in ts.EST_TO_LOCAL_HOURS       # Eastern: 0 by default
    assert set(ts.EST_TO_LOCAL_HOURS.values()) == {-1, -2, -3, -4, -5}


def test_measure_seasons_match_measure_postprocessing_plots():
    # plotting_mixin.map_to_season: 3-5 and 9-11 shoulder, 6-8 summer, else winter
    def map_to_season(month):
        if 3 <= month <= 5 or 9 <= month <= 11:
            return "Shoulder"
        elif 6 <= month <= 8:
            return "Summer"
        return "Winter"
    ours = {m: s for s, months in MEASURE_SEASONS.items() for m in months}
    assert ours == {m: map_to_season(m) for m in range(1, 13)}
