# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""How the assessment addresses a run: by Athena tables, and nothing else.

A "run" here is any ComStock result set reachable through Athena -- a published
SDR/OEDI release, or a private run crawled in by
`ComStock.create_sightglass_tables`. The assessment reads published aggregate
tables only. It never opens a results parquet, never needs buildstock.csv, and
never needs apportionment.

WHY A SEPARATE HANDLE RATHER THAN A ComStock SUBCLASS. `ComStock.__init__` calls
`download_data()` unconditionally and then globs local `results_up*.parquet`, so
a ComStock object cannot be constructed for a release whose simulation outputs
are not on this machine. Comparing against a published release is exactly that
case. `AthenaRunRef` is therefore a small value object: table names plus how to
label and colour the run. `from_comstock()` adapts a real ComStock object into
the same shape, so a driver passes its run under review and its comparison
releases through one uniform list.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

logger = logging.getLogger(__name__)

# Suffixes create_sightglass_tables' Glue crawlers produce for a crawled run.
# These are STARTING GUESSES only -- the assessment probes each and falls back
# to discovery, because the real name depends on the geo_top_dir of the export
# that fed the crawler and on whether the run is crawled or published.
MD_NATIONAL_SUFFIX = "_md_agg_national_parquet"
# The crawled _parquet TABLE, deliberately not the _vu VIEW. create_views
# renames `in.sqft..ft2` to `in.sqft` ("Special requirement for SightGlass",
# ComStock.create_views) and strips units from every out.* column, but
# ami_shapes.build_sqft_sql selects "in.sqft..ft2" -- so the view is the one
# table this SQL cannot run against. This pointed at _vu and would have failed
# with a column-not-found the first time the AMI leg ran on a crawled run.
MD_COUNTY_SUFFIX = "_md_agg_by_state_and_county_parquet"
# Crawled runs get <run>_timeseries; published releases use <run>_ts_by_state.
TS_SUFFIX = "_timeseries"


@dataclass(frozen=True)
class AthenaRunRef:
    """One run, addressed by its Athena tables.

    key        short identifier used in metric CSVs and dashboard state
    label      what a reader sees, e.g. "2025 R3 (OEDI release 3)"
    md_table   national metadata + annual results aggregate; the only REQUIRED
               table. Every leg except AMI and measure timeseries reads it.
    database   Athena database holding these tables. Published releases live in
               buildstock_sdr; a crawled run lives wherever
               create_sightglass_tables wrote it (its default is 'vizstock',
               while other postproc code reads 'enduse' -- so pass it
               explicitly rather than trusting a default).
    md_county_table / ts_table
               needed only for the AMI and measure-timeseries legs. Absent means
               those legs skip, which is a coverage gap and is reported as one,
               not an error.
    """

    key: str
    label: str
    md_table: str
    database: str = "buildstock_sdr"
    md_county_table: str = ""
    ts_table: str = ""
    color: str = "#0072B2"

    @property
    def has_timeseries(self) -> bool:
        return bool(self.ts_table and self.md_county_table)

    @classmethod
    def from_comstock(cls, comstock, database: str = "enduse",
                      key: str | None = None, label: str | None = None):
        """Adapt a live ComStock object to a run reference.

        Table names follow the crawler's convention, built from
        `comstock_run_name` the same way ComStockQueryBuilder derives them. This
        only makes sense after the run's tables have been crawled -- i.e. after
        create_sightglass_tables -- and the assessment checks the table is
        reachable before using it, so a run that was never crawled skips with a
        stated reason instead of failing.
        """
        run = comstock.comstock_run_name
        return cls(
            key=key or run,
            label=label or getattr(comstock, "dataset_name", None) or run,
            md_table=f"{run}{MD_NATIONAL_SUFFIX}",
            database=database,
            md_county_table=f"{run}{MD_COUNTY_SUFFIX}",
            ts_table=f"{run}{TS_SUFFIX}",
            color=getattr(comstock, "color", None) or "#0072B2",
        )
