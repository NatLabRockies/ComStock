# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""S3 exports and Athena tables for a run, built only when they are missing.

Every driver used to carry the same block: export the metadata aggregates to
S3, run the Glue crawler, fix the timeseries partition dtype, create the `_vu`
views -- unconditionally. Re-running a driver on a run whose tables already
existed meant either paying for the export again (the county resolution alone
is ~3,100 files PER UPGRADE) or commenting the block out and remembering to put
it back. `prepare_athena_tables` replaces that block with one call that looks
first, and a driver switch (`REBUILD_ATHENA_TABLES`) that says "no, what is up
there is stale -- do it again".

WHO READS THESE TABLES
  * the measure timeseries plots (`ComStockMeasureComparison` with
    `make_timeseries_plots=True`)
  * the AMI comparison (`ComStock.download_timeseries_data_for_ami_comparison`,
    which reads the county `_vu` view)
  * the results dashboard (`ResultsDashboard`)

WHAT A RUN NEEDS
  national    <run>_md_agg_national_by_state_parquet   everything reads it
  county      <run>_md_agg_by_state_and_county_parquet the AMI comparison and
              AMI tab, and timeseries plots for a COUNTY location. It carries
              county-split weights; the national table's state x climate-zone
              weights cannot be restricted to a county subset correctly, and
              `in.as_simulated_nhgis_county_gisjoin` is not a shortcut past
              that (it is where a model was SIMULATED, not where it counts).
  views       <table>_vu for each metadata table, plus <run>_timeseries_vu --
              the timeseries plots and the AMI paths read the views; the
              timeseries one also renames a crawled run's
              `electricity_<enduse>_kwh` columns to the published spelling
  timeseries  <run>_timeseries -- comes from buildstockbatch's own crawl of the
              run, NOT from here. Its absence is reported, not repaired.

Both exports land under the run's `metadata_and_annual_results_aggregates`
prefix, so ONE crawl covers both.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

from .athena_config import ATHENA_WORKGROUP

logger = logging.getLogger(__name__)

NATIONAL_EXPORT = "national_by_state"
COUNTY_EXPORT = "by_state_and_county"
DEFAULT_GLUE_ROLE = "service-role/AWSGlueServiceRole-default"


# ---------------------------------------------------------------------------
# geo exports
# ---------------------------------------------------------------------------

def required_geo_exports(comstock, county: bool = False) -> list[dict]:
    """The `geo_exports` entries the Athena consumers need.

    Args:
        comstock: only its column-name constants are read (STATE_ABBRV,
            CZ_ASHRAE, COUNTY_ID).
        county: include the county resolution. It is the expensive one -- one
            file per state-county pair rather than one national file -- so it
            is only asked for when something reads it.

    Returns:
        A list of geo_export dicts, most-aggregated first.
    """
    national = {
        'geo_top_dir': NATIONAL_EXPORT,
        'partition_cols': {},
        'aggregation_levels': [[comstock.STATE_ABBRV, comstock.CZ_ASHRAE]],
        'data_types': ['full'],
        'file_types': ['parquet'],
    }
    if not county:
        return [national]
    county_res = {
        'geo_top_dir': COUNTY_EXPORT,
        'partition_cols': {
            comstock.STATE_ABBRV: 'state',
            comstock.COUNTY_ID: 'county',
        },
        'aggregation_levels': [comstock.COUNTY_ID],
        'data_types': ['full'],
        'file_types': ['parquet'],
    }
    return [national, county_res]


# ---------------------------------------------------------------------------
# what exists, and what to do about it
# ---------------------------------------------------------------------------

def existing_tables(run: str, database: str) -> set[str] | None:
    """Names of this run's tables and views in `database`, or None if Glue
    could not be listed (no credentials, no such database).

    Glue rather than the Athena adapter: the adapter needs an existing table to
    reflect on construction, which is exactly what is being asked.
    """
    import boto3
    try:
        glue = boto3.client("glue", region_name="us-west-2")
        names, kw = set(), {"DatabaseName": database, "Expression": f"{run}_*"}
        resp = glue.get_tables(**kw)
        names.update(t["Name"] for t in resp["TableList"])
        while "NextToken" in resp:
            resp = glue.get_tables(NextToken=resp["NextToken"], **kw)
            names.update(t["Name"] for t in resp["TableList"])
        return names
    except Exception as exc:                                      # noqa: BLE001
        logger.info("athena tables: cannot list %s (%s)", database, exc)
        return None


@dataclass
class Plan:
    """What `prepare_athena_tables` has decided to do, and why.

    Kept separate from doing it so the decision can be tested without AWS and
    read in the log before anything expensive starts.
    """
    run: str
    database: str
    export: list[str] = field(default_factory=list)   # geo_top_dirs to export
    crawl: bool = False
    views: bool = False
    timeseries_missing: bool = False                   # cannot be fixed here
    unknown: bool = False                              # could not list Glue
    wants_timeseries: bool = False                     # views/timeseries were asked for
    county_skipped: bool = False                       # county wanted, but no timeseries table

    @property
    def nothing_to_do(self) -> bool:
        return not (self.export or self.crawl or self.views)

    def describe(self) -> str:
        if self.unknown:
            return (f"could not list {self.database}; assuming {self.run} needs "
                    "everything")
        if self.nothing_to_do:
            s = f"{self.run} already has every table it needs in {self.database}"
        else:
            steps = []
            if self.export:
                steps.append("export " + " + ".join(self.export))
            if self.crawl:
                steps.append("crawl")
            if self.views:
                steps.append("create views")
            s = f"{self.run} in {self.database}: " + ", ".join(steps)
        if self.timeseries_missing and (self.wants_timeseries or self.county_skipped):
            s += (f". Note: {self.run}_timeseries is absent -- that table comes "
                  "from buildstockbatch's crawl, not from here, so timeseries "
                  "plots and the AMI legs will skip"
                  + ("; the county export is skipped for the same reason"
                     if self.county_skipped else ""))
        return s


def plan(names: set[str] | None, run: str, database: str, county: bool = False,
         views: bool = False) -> Plan:
    """Decide what a run is missing. Pure: `names` is what Glue listed.

    Args:
        names: table and view names present for the run, or None if unknown.
        county: the county aggregate is wanted.
        views: the `_vu` views are wanted (timeseries plots, AMI).
    """
    p = Plan(run=run, database=database, wants_timeseries=views)
    if names is None:
        p.unknown = True
        p.export = [NATIONAL_EXPORT] + ([COUNTY_EXPORT] if county else [])
        p.crawl, p.views = True, views
        return p

    # Exact names. The crawler produces <run>_md_agg_<geo_top_dir>_parquet and
    # the consumers read exactly these two, so neither a run NAME containing
    # "county" nor a PUMA aggregate crawled alongside may change the answer.
    nat = f"{run}_md_agg_{NATIONAL_EXPORT}_parquet"
    cty = f"{run}_md_agg_{COUNTY_EXPORT}_parquet"
    if nat not in names:
        p.export.append(NATIONAL_EXPORT)
    ts_table = f"{run}_timeseries"
    p.timeseries_missing = ts_table not in names
    if county and cty not in names:
        if p.timeseries_missing:
            # Everything that reads the county aggregate -- the AMI comparison,
            # the AMI tab, county timeseries profiles -- also needs the
            # timeseries table, which only buildstockbatch's crawl creates.
            # Hours of ~3,100 files per upgrade for legs that will skip anyway
            # is the one expensive mistake this probe exists to prevent.
            p.county_skipped = True
        else:
            p.export.append(COUNTY_EXPORT)
    p.crawl = bool(p.export)
    if views:
        # Only the views something reads: national always, county only when
        # county is wanted. create_views names PUMA views differently, and
        # nothing here reads them.
        wanted = {t.replace("_parquet", "_vu")
                  for t in ([nat] + ([cty] if county else [])) if t in names}
        if ts_table in names:
            wanted.add(f"{ts_table}_vu")
        # New tables from the export above will need views too.
        p.views = bool(p.export) or not wanted.issubset(names)
    return p


# ---------------------------------------------------------------------------
# doing it
# ---------------------------------------------------------------------------

def _plots_county_location(comstock) -> bool:
    """Does the driver ask for a county timeseries location? Uses ComStock's
    own state-or-county rule so the plots and this check agree."""
    locs = getattr(comstock, "timeseries_locations_to_plot", None) or {}
    for loc in locs:
        ids = loc if isinstance(loc, (tuple, list)) else (loc,)
        if any(comstock.determine_state_or_county_timeseries_table(i) == "county"
               for i in ids):
            return True
    return False


def _run_upgrade_ids(comstock) -> list:
    """The upgrades a run exports: its own list, or the baseline alone when
    the driver said include_upgrades=False. ComStock.__init__ fills
    upgrade_ids_to_process from every results_up*.parquet on disk regardless
    of that flag, and a baseline-only driver has no weights for the others."""
    if not getattr(comstock, "include_upgrades", True):
        return [0]
    return list(getattr(comstock, "upgrade_ids_to_process", None) or [0])


def prepare_athena_tables(comstock, database: str = "enduse",
                          timeseries: bool = False, ami: bool = False,
                          rebuild: bool = False, upgrade_ids=None,
                          glue_service_role: str = DEFAULT_GLUE_ROLE) -> bool:
    """Make sure this run's S3 exports and Athena tables exist. One call per run.

    Checks Glue first and does only what is missing: export the aggregates to
    the run's S3 prefix, crawl them, and (when wanted) fix the timeseries
    partition dtype and create the `_vu` views. `rebuild=True` skips the check
    and does all of it again -- for when what is up there is known to be stale.
    It re-exports the run's current upgrades (same-named files are
    overwritten); files for upgrades no longer in the run stay on S3 and in
    the table.

    Args:
        comstock: the run. What goes to S3 is fixed -- the parquet national
            aggregate, plus county when needed (see required_geo_exports) --
            and is independent of whatever the driver exports locally.
        database: where the run's tables live. Note `create_sightglass_tables`
            defaults to 'vizstock' while the rest of postprocessing reads
            'enduse', so drivers pass this explicitly.
        timeseries: the timeseries plots are wanted -> views, and the county
            aggregate if any plotted location is a county.
        ami: the AMI comparison or AMI dashboard tab is wanted -> county
            aggregate and views.
        rebuild: export, crawl and create views regardless of what exists.
        upgrade_ids: which upgrades the COUNTY export covers; default is the
            run's own list. The national export always covers the run's list,
            because every annual and measure leg reads it. Presence is checked
            per table, not per upgrade, so a county table exported for [0]
            counts as present afterwards -- use rebuild=True to extend it.

    Returns True when the tables are in place, False otherwise -- including
    when timeseries or AMI was asked for and the run has no `<run>_timeseries`
    table, which only buildstockbatch's crawl creates. It LOGS rather
    than raising: this runs inside someone's postprocessing job, and a Glue or
    S3 problem must not destroy the results it already produced. On False the
    results dashboard skips the affected legs and says why; the timeseries plots
    and the AMI comparison cannot run without their tables, so a driver that
    needs those should stop. If Glue cannot be listed at all (expired
    credentials, missing permission) nothing is exported: exporting blind can
    mean hours of county files for tables that are already there.
    """
    run = getattr(comstock, "comstock_run_name", "?")
    step = "listing tables"
    try:
        county = ami or (timeseries and _plots_county_location(comstock))
        views = timeseries or ami
        ts_needed = timeseries or ami
        if rebuild:
            p = plan(None, run, database, county=county, views=views)
            p.unknown = False
            logger.info("athena tables: REBUILD requested; %s", p.describe())
        else:
            p = plan(existing_tables(run, database), run, database,
                     county=county, views=views)
            logger.info("athena tables: %s", p.describe())
            if p.unknown:
                logger.warning(
                    "athena tables: not exporting %s without being able to check "
                    "%s first -- fix the credentials, or set rebuild=True "
                    "(REBUILD_ATHENA_TABLES) to export regardless.", run, database)
                return False
        ts_absent = p.timeseries_missing
        if not p.nothing_to_do:
            s3_dir = f"s3://{comstock.s3_base_dir}/{run}/{run}"
            if p.export:
                step = "exporting to S3"
                # Only the resolutions that are missing, always as parquet -- the
                # crawler builds tables from parquet, whatever a driver writes locally.
                by_dir = {g["geo_top_dir"]: g
                          for g in required_geo_exports(comstock, county=county)}
                s3_out = comstock.setup_fsspec_filesystem(s3_dir, aws_profile_name=None)
                all_ids = _run_upgrade_ids(comstock)
                county_ids = all_ids if upgrade_ids is None else list(upgrade_ids)
                if COUNTY_EXPORT in p.export and len(county_ids) > 1:
                    logger.warning("athena tables: the county export runs for %d "
                                   "upgrades, ~3,100 files each", len(county_ids))
                for upgrade_id in sorted(set(all_ids) | set(county_ids)):
                    geo = [by_dir[g] for g in p.export
                           if upgrade_id in (all_ids if g == NATIONAL_EXPORT else county_ids)]
                    if not geo:
                        continue
                    logger.info("athena tables: exporting upgrade %s of %s (%s) to S3",
                                upgrade_id, run, ", ".join(g["geo_top_dir"] for g in geo))
                    comstock.export_metadata_and_annual_results_for_upgrade(
                        upgrade_id=upgrade_id, geo_exports=geo, output_dir=s3_out)
            if p.crawl:
                step = "crawling"
                logger.info("athena tables: crawling %s into %s", run, database)
                comstock.create_sightglass_tables(
                    s3_location=f"{s3_dir}/metadata_and_annual_results_aggregates",
                    dataset_name=run, database_name=database,
                    glue_service_role=glue_service_role)
                # The crawler reports READY whether or not it built anything: look.
                after = plan(existing_tables(run, database), run, database,
                             county=county, views=False)
                if after.unknown or after.export:
                    logger.warning(
                        "athena tables: after crawling, %s still lacks %s in %s; check "
                        "the crawler's last run in the Glue console", run,
                        " + ".join(after.export) or "(could not list)", database)
                    _forget_cached_queries(run)
                    return False
                ts_absent = after.timeseries_missing
            if p.views:
                step = "creating views"
                # fix_timeseries_tables aligns the `upgrade` partition dtype with the
                # metadata tables so joins work; create_views builds every _vu.
                comstock.fix_timeseries_tables(run, database)
                comstock.create_views(run, database, ATHENA_WORKGROUP)
            # The tables changed under every cached query that read them.
            _forget_cached_queries(run)
        if ts_needed and ts_absent:
            logger.warning(
                "athena tables: %s has no %s_timeseries table in %s. That table comes "
                "from buildstockbatch's own postprocessing crawl of the run, not from "
                "here, so the timeseries plots and the AMI comparison cannot run and "
                "the dashboard's timeseries legs will skip.", run, run, database)
            return False
        return True
    except Exception as exc:                                      # noqa: BLE001
        logger.warning(
            "athena tables: could not prepare %s -- failed while %s (%s). The rest "
            "of this postprocessing run is unaffected. The results dashboard skips the "
            "legs whose tables are missing and says so; the timeseries plots and "
            "the AMI comparison need them.", run, step, exc)
        return False


def _forget_cached_queries(run: str) -> None:
    """Drop the dashboard's cached query results that read this run's tables.

    The query cache is keyed on SQL text, so after an export or crawl the same
    SQL would keep answering from the previous tables.
    """
    try:
        from .results_dashboard import athena
        athena.invalidate_cache(run)
    except Exception as exc:                                      # noqa: BLE001
        logger.info("athena tables: could not clear cached queries for %s (%s)", run, exc)
