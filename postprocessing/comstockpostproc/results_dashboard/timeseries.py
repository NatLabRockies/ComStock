# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""How to address a ComStock timeseries table, whichever producer made it.

There are two producers, and they name the same data differently:

  published   <release>_ts_by_state   bldg_id, state, timestamp,
                                      out.<fuel>.<enduse>.energy_consumption
  crawled     <run>_timeseries        building_id, time (+timedst, timeutc),
                                      NO state, electricity_<enduse>_kwh,
                                      total_site_<fuel>_kwh

The published tables come from the SDR/OEDI publication pipeline; the crawled
ones from buildstockbatch's own postprocessing of a run. This is a difference of
PIPELINE STAGE, not of release -- release-to-release drift is a separate thing,
handled by probing types (2024 R2 stored the time as epoch nanoseconds, 2025 R3
as a real timestamp).

`ComStock.create_views` closes most of the gap for a crawled run: its
`<run>_timeseries_vu` rewrites the end-use columns into the published spelling
via create_column_alias. It does NOT rename `building_id` or `time`, and it
cannot invent `state` -- buildstockbatch only adds geography as Hive partitions
from `postprocessing.partition_columns`, which no ComStock yml sets. So even on
the view, three references still differ.

WHY THIS IS ONE MODULE RATHER THAN A FIX PER QUERY. Both the AMI leg and the
measure-timeseries leg join a timeseries table to a county metadata table on the
same three keys. Adapting one and not the other is how you get a dashboard where
the AMI tab works and the measures tab reports an error, on the same run. The
fragments below are the single definition of that adaptation.

DROPPING THE STATE TERMS CHANGES NO RESULT. They exist to prune a
state-partitioned published table. The region or state being reported is
selected by the METADATA side (its county or state filter), and the building-id
equality already pins each timeseries row to one building, so removing the
timeseries-side state predicate narrows nothing that was not already narrowed.

END USES ARE A UNION OVER THE RUN'S OWN MODELS. A run in which nothing metered
heat recovery has no such column at all -- on either schema. Asking for the full
stack unconditionally fails that run, so every query is built from the columns
the table actually has.

PUBLISHED TIMESTAMPS ARE IN EASTERN STANDARD TIME, FOR EVERY BUILDING. The
publication pipeline converts each building's local standard time to EST "to
prevent issues when aggregating across time zones" (ComStock FAQ,
https://nrel.github.io/ComStock.github.io/docs/faq.html), wrapping the last
hours of the year to the front for western zones. A crawled table's `time` is
the building's LOCAL standard time (the weather file's clock), and so is every
AMI meter. Left as published, a Pacific building's profile sits 3 hours late
against its AMI truth while an Eastern one looks fine -- which is how it was
noticed: the 2025 R3 overlay against baseline_10k was +3 h in pge (Portland)
and +2 h in fort_collins, with exterior lighting switching on at 22:00.
time_expr() therefore converts a published table back to local standard time,
by state. State-level is an approximation for the split-zone states (TN, KY,
FL, TX, ID, ND, SD, NE, KS, MI, IN, OR): the majority zone is used, and a
crawled table, where there is one, is the exact reference.
"""

from __future__ import annotations

import logging

from . import athena
from .metrics_def import ENDUSE_STACK_ORDER, TS_ENDUSE_COL

logger = logging.getLogger(__name__)

# Hours to ADD to a published (EST) timestamp to get the building's local
# standard time, by state. Standard offsets only: EST is a fixed zone and so is
# the EnergyPlus clock, so DST never enters. Split-zone states take their
# majority zone (module docstring). Anything not listed is Eastern: 0.
EST_TO_LOCAL_HOURS = {
    **{s: -3 for s in ("WA", "OR", "CA", "NV")},
    **{s: -2 for s in ("MT", "ID", "WY", "UT", "CO", "AZ", "NM")},
    **{s: -1 for s in ("ND", "SD", "NE", "KS", "OK", "TX", "MN", "IA", "MO", "AR",
                       "LA", "WI", "IL", "MS", "AL", "TN")},
    "AK": -4, "HI": -5,
}

# Fuel totals, published spelling -> crawled spelling.
TOTAL_CANDIDATES = {
    "electricity": ("out.electricity.total.energy_consumption",
                    "total_site_electricity_kwh"),
    "natural_gas": ("out.natural_gas.total.energy_consumption",
                    "total_site_natural_gas_kwh"),
}


def ts_dialect(ts_table: str, no_cache: bool = False) -> dict:
    """How to address `ts_table`: real column names, and what is absent.

    Returns the mapping rather than a schema LABEL, because callers need the
    column names, and because a table can be of a known shape yet still be
    missing something a query needs.

    Keys:
      bldg, time   identifier and time columns, by their real names
      state        the state column, or "" when the table has none
      epoch_ns     the time column is epoch nanoseconds (bigint)
      enduses      {stack end use -> real column name}, present ones only
      totals       {fuel -> real column name}, present ones only
      kind         'published' | 'crawled' | 'mixed' | 'unknown' (reporting only)
      tz           'est' when the stamps are Eastern Standard Time for every
                   building (published tables), 'local' otherwise
      missing      what a timeseries query needs and cannot find
    """
    d = {"bldg": "", "time": "", "state": "", "epoch_ns": False, "up_type": "",
         "enduses": {}, "totals": {}, "kind": "unknown", "tz": "local", "missing": []}
    try:
        types = athena.table_column_types(ts_table, no_cache=no_cache)
    except Exception as exc:                                      # noqa: BLE001
        logger.warning("cannot read columns of %s: %s", ts_table, exc)
        d["missing"].append(f"could not read the columns of {ts_table}")
        return d
    cols = set(types)
    if not cols:
        d["missing"].append(f"{ts_table} has no columns (absent or unreadable)")
        return d

    d["bldg"] = next((c for c in ("bldg_id", "building_id") if c in cols), "")
    d["time"] = next((c for c in ("timestamp", "time") if c in cols), "")
    d["state"] = "state" if "state" in cols else ""
    if d["time"]:
        d["epoch_ns"] = str(types.get(d["time"], "")).startswith("bigint")
    # So every literal against `upgrade` can be typed to the column.
    d["up_type"] = str(types.get("upgrade", ""))

    for e in ENDUSE_STACK_ORDER:
        d["enduses"][e] = next(
            (c for c in (TS_ENDUSE_COL.format(e), f"electricity_{e}_kwh") if c in cols),
            None)
    d["enduses"] = {e: c for e, c in d["enduses"].items() if c}

    for fuel, cands in TOTAL_CANDIDATES.items():
        col = next((c for c in cands if c in cols), "")
        if col:
            d["totals"][fuel] = col

    if not d["bldg"]:
        d["missing"].append("a building identifier column (bldg_id or building_id)")
    if not d["time"]:
        d["missing"].append("a time column (timestamp or time)")
    if "electricity" not in d["totals"]:
        d["missing"].append("a total electricity column "
                            "(out.electricity.total.energy_consumption or "
                            "total_site_electricity_kwh)")
    if not d["enduses"]:
        d["missing"].append("any of the stacked end-use electricity columns")

    published_ids = d["bldg"] == "bldg_id" and d["time"] == "timestamp"
    dotted = d["totals"].get("electricity", "").startswith("out.")
    d["kind"] = ("published" if published_ids and dotted
                 else "crawled" if not published_ids and not dotted
                 else "mixed")
    # Only the publication pipeline re-clocks to EST. A crawled table, even one
    # viewed through create_views, keeps the building's local standard time.
    d["tz"] = "est" if d["kind"] == "published" else "local"
    if d["tz"] == "est" and not d["state"]:
        d["missing"].append("a state column, needed to convert published EST "
                            "timestamps back to local standard time")
    if d["tz"] == "est":
        logger.info("%s: published table, timestamps are EST for every building; "
                    "converting to local standard time by state", ts_table)
    return d


PUBLISHED = {
    "bldg": "bldg_id", "time": "timestamp", "state": "state", "epoch_ns": False,
    "up_type": "bigint",
    "enduses": {e: TS_ENDUSE_COL.format(e) for e in ENDUSE_STACK_ORDER},
    "totals": {f: c[0] for f, c in TOTAL_CANDIDATES.items()},
    "kind": "published", "tz": "est", "missing": [],
}


def _d(dialect: dict | None) -> dict:
    """Default to the published schema so SQL can be dumped without Athena."""
    return dialect or PUBLISHED


def est_to_local_case(dialect: dict | None, alias: str = "t") -> str:
    """CASE over the state column: hours to add to an EST stamp for local time."""
    d = _d(dialect)
    state_col = f'{alias}."{d["state"]}"'
    by_shift: dict[int, list[str]] = {}
    for st, h in EST_TO_LOCAL_HOURS.items():
        by_shift.setdefault(h, []).append(st)
    whens = " ".join(
        f"WHEN {state_col} IN ({', '.join(repr(s) for s in sorted(sts))}) THEN {h}"
        for h, sts in sorted(by_shift.items()))
    return f"CASE {whens} ELSE 0 END"


def time_expr(dialect: dict | None, alias: str = "t") -> str:
    """The time column as a LOCAL-standard-time timestamp expression.

    A published table is stored in EST for every building (module docstring);
    it is shifted back to the building's local standard time by state here, so
    every consumer -- hour buckets, day types, seasons -- sees the same clock
    the AMI meters and the crawled tables use.
    """
    d = _d(dialect)
    col = f'{alias}."{d["time"]}"'
    expr = f"from_unixtime({col} / 1000000000)" if d["epoch_ns"] else col
    if d.get("tz") == "est" and d["state"]:
        expr = f"date_add('hour', {est_to_local_case(d, alias)}, {expr})"
    return expr


def hour_trunc(dialect: dict | None, alias: str = "t") -> str:
    """Hour bucket. The -15 minutes puts a period-ENDING timestep in its own hour."""
    return f"date_trunc('hour', date_add('minute', -15, {time_expr(dialect, alias)}))"


def check_no_duplicate_hours(ts_table: str, dialect: dict | None = None,
                             no_cache: bool = False) -> str:
    """Return "" if each (building, hour) appears once, else a description of the problem.

    WHY THIS IS CHECKED RATHER THAN ASSUMED. ComStock timeseries output is
    written per state, and a building apportioned into several states can have
    its profile duplicated across those files. Every query here multiplies a
    timeseries value by a metadata weight and sums, so a duplicated
    (building, hour) row is counted once per copy -- silently, and by a factor
    nothing else in the assessment would reveal.

    A state-partitioned PUBLISHED table is safe because the queries join
    `t.state = m.state`, which selects one copy. A crawled table has no state
    column, so there is nothing to disambiguate on: if it carries duplicates,
    the only honest options are to say so or to stop. This reports; the caller
    decides.

    Checks one day rather than the year -- duplication is structural, so a day
    is enough to detect it, and scanning 8,760 hours to prove a data-shape
    property is not worth the money.
    """
    d = _d(dialect)
    if not d["bldg"] or not d["time"]:
        return ""
    day = ("from_unixtime(t.\"%s\" / 1000000000)" % d["time"] if d["epoch_ns"]
           else 't."%s"' % d["time"])
    sql = (
        f'SELECT COUNT(*) AS rows_all,\n'
        f'    COUNT(DISTINCT (t."{d["bldg"]}", {day})) AS distinct_bldg_hour\n'
        f"FROM {ts_table} t\n"
        f"WHERE {day} < from_iso8601_timestamp('2018-01-02T00:00:00')"
    )
    try:
        df = athena.query(sql, no_cache=no_cache,
                          label=f"duplicate-hour check on {ts_table}")
    except Exception as exc:                                      # noqa: BLE001
        logger.info("could not check %s for duplicate hours: %s", ts_table, exc)
        return ""
    if df.empty:
        return ""
    rows = float(df.iloc[0]["rows_all"])
    uniq = float(df.iloc[0]["distinct_bldg_hour"])
    if not uniq or rows <= uniq * 1.0001:
        return ""
    return (f"{ts_table} carries {rows / uniq:.2f} rows per (building, hour) — the "
            "profile is duplicated, most likely once per state the building is "
            "apportioned into. Every weighted timeseries sum would count it once "
            "per copy. A published state-partitioned table is disambiguated by "
            f"the state join, but {ts_table} has "
            f"{'a state column that is not being used' if d['state'] else 'no state column'}"
            ", so the copies cannot be told apart.")


def bldg_col(dialect: dict | None, alias: str = "t") -> str:
    """The timeseries building-id column, qualified. For joins to CTEs that key
    on the metadata side's `bldg_id` and need no state term."""
    return f'{alias}."{_d(dialect)["bldg"]}"'


def join_on(dialect: dict | None, alias: str = "t", md: str = "m",
            md_state: str = "state") -> str:
    """The building (and, where it exists, state) join between ts and metadata."""
    d = _d(dialect)
    on = f'{alias}."{d["bldg"]}" = {md}.bldg_id'
    if d["state"]:
        # The metadata side's state column is `state` on a county aggregate (a
        # partition column) but `in.state` on a national one, so it is passed
        # in rather than assumed.
        on += f' AND {alias}."{d["state"]}" = {md}."{md_state}"'
    return on


def state_filter(dialect: dict | None, states, alias: str = "t") -> str:
    """Timeseries-side state predicate, or "" when the table has no state column.

    Returns a bare predicate with no leading AND, or "" -- callers decide the
    conjunction so an empty result cannot leave a dangling operator.
    """
    d = _d(dialect)
    if not d["state"]:
        return ""
    vals = ", ".join(f"'{s}'" for s in ([states] if isinstance(states, str) else states))
    return f'{alias}."{d["state"]}" IN ({vals})'


def enduse_sums(dialect: dict | None, alias: str = "t", weight: str = "m.weight",
                indent: str = "    ") -> str:
    """One weighted SUM per end use the table actually has."""
    d = _d(dialect)
    return ",\n".join(f'{indent}SUM({alias}."{col}" * {weight}) AS {e}'
                      for e, col in d["enduses"].items())


def total_sum(dialect: dict | None, fuel: str, as_name: str, alias: str = "t",
              weight: str = "m.weight") -> str:
    """Weighted SUM of a fuel total, or a typed NULL when the table lacks it.

    A NULL keeps the result shape stable so a caller's downstream code does not
    have to branch on which fuels a run happened to meter.
    """
    d = _d(dialect)
    col = d["totals"].get(fuel)
    if not col:
        return f"CAST(NULL AS double) AS {as_name}"
    return f'SUM({alias}."{col}" * {weight}) AS {as_name}'
