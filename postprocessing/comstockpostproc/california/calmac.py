# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""CalMAC granular profiles as truth data: one long table on Pacific standard time.

    calmac = CalMAC()            # builds output/CalMAC v01/ from truth_data/v01/calmac/
    calmac = CalMAC(reload_from_csv=True)   # reuses what an earlier build wrote

Reads the csv files `prepare_truth_data` writes (fetching any that are missing from
s3://eulp/truth_data/<version>/calmac/), and writes to output/CalMAC <version>/:

  CalMAC long.parquet      utility_id, fuel, gp, industry, size, cz_group, basis, year,
                           timestamp (PST, hour-beginning; the date for daily gas),
                           value (kWh or therms PER PREMISE), premise_count, merged_hour
  CalMAC segments.csv      one row per profile: segment keys, sample size, whether an
                           identical S/M pair was collapsed into it, normalization
  CalMAC centroids.csv     each profile's centroid, its nearest CALMAC station and that
                           station's CEC Title 24 zone (the plan's §4.4 check)
  CalMAC normalization.csv fit statistics of the SDG&E 2025 -> 2018 normalization
  CalMAC weather stations.csv  the normalization's candidate stations and the
                           year-consistency check that can exclude one

Parquet rather than csv for the long table: with SDG&E's raw and normalized series it
is ~2.5 million rows, ~300 MB as text.

Polars throughout, with every per-row rule an expression or a join. The only loops are
over the four utility-fuel input files and, in the normalization, over profiles --
one regression each.

Loader rules (CALMAC_DASHBOARD_PLAN.md §2.3, §6.1):
  * PG&E `hour` 0..23 is hour-beginning clock time; SDG&E `hour` 1..24 is hour-ending
    clock time and becomes hour-beginning by subtracting one.
  * The spring-forward hour that does not exist is dropped (SDG&E zero-fills it; PG&E
    omits it). The fall-back hour recorded once for two clock hours is flagged
    `merged_hour`. Then clock time -> PST (weather.clock_to_pst_expr).
  * PG&E publishes identical `_S_` and `_M_` series where it combined sizes; such a pair
    becomes one `_A_` series. A pair that is close but not identical is an error.
  * SDG&E series are also weather-normalized to 2018 (basis 'normalized_2018'),
    unless the fit is too poor (weather.MAX_CVRMSE_PCT); every series keeps basis 'raw'.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

import polars as pl

from ..naming_mixin import NamingMixin
from ..s3_utilities_mixin import S3UtilitiesMixin
from . import weather
from .segments import PGE, SDGE, SEASONS

logger = logging.getLogger(__name__)

LONG_FILE = "CalMAC long.parquet"
SEGMENTS_FILE = "CalMAC segments.csv"
STATIONS_FILE = "CalMAC weather stations.csv"
CENTROIDS_FILE = "CalMAC centroids.csv"
NORMALIZATION_FILE = "CalMAC normalization.csv"

# (utility, fuel) -> (profile file, the year it covers, hourly?)
PROFILE_FILES = {
    (PGE, "electricity"): ("pge_elec_2018.csv", 2018, True),
    (PGE, "natural_gas"): ("pge_gas_2018.csv", 2018, False),
    (SDGE, "electricity"): ("sdge_elec_2025.csv", 2025, True),
    (SDGE, "natural_gas"): ("sdge_gas_2025.csv", 2025, False),
}
FUEL_FILE_TAG = {"electricity": "elec", "natural_gas": "gas"}
UTIL_FILE_TAG = {PGE: "pge", SDGE: "sdge"}
# PG&E hours are hour-beginning (0..23), SDG&E hour-ending (1..24).
HOUR_ENDING = {PGE: False, SDGE: True}
TARGET_YEAR = 2018
NEAREST_STATIONS = 3          # weather fetched for this many stations per SDG&E profile
GP_PATTERN = r"^[^_]{6}_[^_]+_[^_]+$"
CATEGORICAL = ("fuel", "gp", "industry", "size", "cz_group", "basis")
TU = weather.TIME_UNIT


def _base_files() -> list[str]:
    files = [f for f, _, _ in PROFILE_FILES.values()]
    for u in (PGE, SDGE):
        for fuel in ("elec", "gas"):
            files += [f"{UTIL_FILE_TAG[u]}_{fuel}_dictionary.csv",
                      f"{UTIL_FILE_TAG[u]}_{fuel}_centroids.csv"]
    return files + ["weather/stations.csv"]


def gp_parts_exprs(gp: pl.Expr = pl.col("gp")) -> list[pl.Expr]:
    """industry, size, cz_group from `<Industry6>_<Size>_<CZ>`."""
    parts = gp.str.split_exact("_", 2)
    return [parts.struct.field("field_0").alias("industry"),
            parts.struct.field("field_1").alias("size"),
            parts.struct.field("field_2").alias("cz_group")]


def _check_gp_names(df: pl.DataFrame) -> None:
    bad = df.filter(~pl.col("gp").str.contains(GP_PATTERN))["gp"].unique()
    if len(bad):
        raise ValueError(f"not granular-profile names (expected <Industry6>_<Size>_<CZ>): "
                         f"{bad.to_list()[:5]}")


class CalMAC(NamingMixin, S3UtilitiesMixin):
    """The CalMAC truth data, built (or reloaded) on construction."""

    def __init__(self, truth_data_version: str = "v01", reload_from_csv: bool = False,
                 download_truth_data: bool = True, color_hex: str = "#1a1d1f"):
        self.truth_data_version = truth_data_version
        self.dataset_name = f"CalMAC {truth_data_version}"
        here = Path(__file__).resolve().parent
        self.truth_data_dir = here.parents[1] / "truth_data" / truth_data_version / "calmac"
        self.output_dir = here.parents[1] / "output" / self.dataset_name
        self.color = color_hex
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.long_path = self.output_dir / LONG_FILE
        self._station_check = None
        if reload_from_csv:
            missing = [p for p in (LONG_FILE, SEGMENTS_FILE, CENTROIDS_FILE)
                       if not (self.output_dir / p).exists()]
            if missing:
                raise FileNotFoundError(
                    f"cannot reload CalMAC: {missing} not in {self.output_dir}; "
                    "set reload_from_csv=False to build them")
            logger.info("CalMAC: reloading %s", self.long_path)
            return
        if download_truth_data:
            self.download_truth_data()
        self.build()

    # ---- inputs ------------------------------------------------------------
    def _fetch(self, rel: str) -> Path:
        """truth_data/<v>/calmac/<rel>, downloaded from s3://eulp/truth_data/<v>/calmac/
        when absent. The shared download_truth_data_file flattens paths into
        truth_data/<v>/, which would lose the calmac/ and weather/ folders."""
        local = self.truth_data_dir / rel
        if local.exists():
            return local
        import boto3
        key = f"truth_data/{self.truth_data_version}/calmac/{rel}"
        local.parent.mkdir(parents=True, exist_ok=True)
        logger.info("downloading s3://eulp/%s", key)
        try:
            boto3.client("s3").download_file("eulp", key, str(local))
        except Exception as exc:                                  # noqa: BLE001
            raise FileNotFoundError(
                f"{rel} is neither in {self.truth_data_dir} nor at s3://eulp/{key} ({exc}). "
                "Build it with `python -m comstockpostproc.california.prepare_truth_data "
                "<CalMAC data folder>` and upload truth_data/<v>/calmac/ to that prefix.") from exc
        return local

    def download_truth_data(self) -> None:
        for rel in _base_files():
            self._fetch(rel)
        # the weather files the SDG&E normalization needs, named by station
        for wmo in sorted(self._normalization_stations()):
            for year in (2018, 2025):
                try:
                    self._fetch(f"weather/{wmo}_{year}.csv")
                except FileNotFoundError as exc:
                    logger.warning("CalMAC: %s; SDG&E profiles nearest %s will stay raw", exc, wmo)

    def stations(self) -> pl.DataFrame:
        """CALMAC weather stations with a CEC zone (ctz > 0)."""
        st = pl.read_csv(self.truth_data_dir / "weather" / "stations.csv",
                         schema_overrides={"wmo": pl.String, "href_2018": pl.String,
                                           "href_2025": pl.String})
        return st.with_columns(
            in_2018_archive=pl.col("in_2018_archive").cast(pl.String).str.to_lowercase() == "true"
        ).filter(pl.col("ctz").fill_null(0) > 0)

    def _candidate_stations(self) -> pl.DataFrame:
        """Stations that could serve the normalization: a 2018 file in the supplied
        archive and a 2025 file on calmac.org -- the rule prepare_truth_data used."""
        return self.stations().filter(pl.col("in_2018_archive") & pl.col("href_2025").is_not_null())

    def station_check(self) -> pl.DataFrame:
        """Every candidate station with BOTH years of weather on disk, with the
        year-consistency verdict (weather.station_year_consistency). Computed once
        per object: it reads every candidate's two weather files."""
        if self._station_check is None:
            self._station_check = self._compute_station_check()
        return self._station_check

    def _compute_station_check(self) -> pl.DataFrame:
        files = sorted(str(p) for p in (self.truth_data_dir / "weather").glob("*_20[0-9][0-9].csv"))
        empty = pl.DataFrame(schema={"wmo": pl.String, "name": pl.String, "ctz": pl.Int64,
                                     "lat": pl.Float64, "lon": pl.Float64, "excluded": pl.Boolean})
        if not files:
            return empty
        # every station-year file in one scan; the file name says which station and year
        means = (pl.scan_csv(files, include_file_paths="path")
                 .with_columns(wmo=pl.col("path").str.extract(r"(\d{6})_(\d{4})\.csv$", 1),
                               year=pl.col("path").str.extract(r"(\d{6})_(\d{4})\.csv$", 2))
                 .group_by("wmo")
                 .agg(mean_2018_c=pl.col("drybulb_c").filter(pl.col("year") == "2018").mean(),
                      mean_2025_c=pl.col("drybulb_c").filter(pl.col("year") == "2025").mean())
                 .collect())
        cand = (self._candidate_stations().select("wmo", "name", "ctz", "lat", "lon")
                .join(means, on="wmo", how="inner")
                .drop_nulls(["mean_2018_c", "mean_2025_c"]))
        return weather.station_year_consistency(cand) if not cand.is_empty() else empty

    def _weather_stations(self) -> pl.DataFrame:
        """Stations the normalization assigns profiles to: both years on disk and not
        excluded by the year-consistency check."""
        chk = self.station_check()
        if chk.is_empty():
            return chk
        bad = chk.filter(pl.col("excluded"))
        if not bad.is_empty() and not getattr(self, "_station_warned", False):
            msg = bad.select(pl.format("{} ({}): {}", "name", "wmo", "reason")).to_series()
            logger.warning("CalMAC: weather stations excluded from the normalization: %s",
                           "; ".join(msg.to_list()))
        self._station_warned = True
        return chk.filter(~pl.col("excluded"))

    def _centroids(self, utility: int, fuel: str) -> pl.DataFrame:
        return pl.read_csv(self.truth_data_dir /
                           f"{UTIL_FILE_TAG[utility]}_{FUEL_FILE_TAG[fuel]}_centroids.csv")

    def _normalization_stations(self) -> set[str]:
        """The stations whose weather files download_truth_data fetches: the three
        nearest each SDG&E profile, as prepare_truth_data chose them."""
        cents = pl.concat([self._centroids(SDGE, f).select("gp", "latitude", "longitude")
                           for f in ("electricity", "natural_gas")])
        near = weather.nearest_stations(cents, self._candidate_stations(), k=NEAREST_STATIONS)
        return set(near["wmo"].unique().to_list())

    def _dictionary(self, utility: int, fuel: str) -> pl.DataFrame:
        return pl.read_csv(self.truth_data_dir /
                           f"{UTIL_FILE_TAG[utility]}_{FUEL_FILE_TAG[fuel]}_dictionary.csv")

    def _weather(self, wmo: str, year: int) -> pl.DataFrame | None:
        p = self.truth_data_dir / "weather" / f"{wmo}_{year}.csv"
        if not p.exists():
            return None
        return pl.read_csv(p).with_columns(
            pl.col("timestamp_pst").str.to_datetime(time_unit=TU),
            pl.col("drybulb_c").cast(pl.Float64))

    # ---- build ---------------------------------------------------------------
    def build(self) -> None:
        parts, seg_frames, norm_frames = [], [], []
        for (utility, fuel), (fname, year, hourly) in PROFILE_FILES.items():   # four files
            raw = pl.read_csv(self.truth_data_dir / fname)
            series, collapsed = load_profiles(raw, utility, hourly)
            dic = self._dictionary(utility, fuel).select("gp", "premises", "industry_name")
            # A collapsed 'A' profile keeps its S profile's sample size and name; both
            # were sampled from the same combined segment.
            dic = pl.concat([dic, collapsed.join(dic, left_on="s_gp", right_on="gp")
                             .select(pl.col("a_gp").alias("gp"), "premises", "industry_name")])
            undocumented = series.select("gp").unique().join(dic, on="gp", how="anti")["gp"]
            if len(undocumented):
                logger.warning("CalMAC %s %s: profiles absent from the dictionary: %s",
                               utility, fuel, sorted(undocumented.to_list()))
            prem = dic.select("gp", pl.col("premises").alias("premise_count"))
            series = series.join(prem, on="gp", how="left").with_columns(basis=pl.lit("raw"))
            parts.append(series)
            norm_status = pl.DataFrame(schema={"gp": pl.String, "normalized_2018": pl.Boolean})
            if utility == SDGE:
                normed, stats = self._normalize(series, fuel, hourly)
                if not normed.is_empty():
                    parts.append(normed.join(prem, on="gp", how="left"))
                if not stats.is_empty():
                    norm_frames.append(stats)
                    norm_status = stats.filter(pl.col("season") == "All").select(
                        "gp", pl.col("normalized").alias("normalized_2018"))
            segs = (series.select("gp", "industry", "size", "cz_group").unique().sort("gp")
                    .join(dic, on="gp", how="left")
                    .join(collapsed.select(pl.col("a_gp").alias("gp"),
                                           pl.concat_str(["s_gp", "m_gp"], separator="+")
                                           .alias("collapsed_from")), on="gp", how="left")
                    .join(norm_status, on="gp", how="left")
                    .with_columns(utility_id=pl.lit(utility), fuel=pl.lit(fuel),
                                  year=pl.lit(year),
                                  collapsed_from=pl.col("collapsed_from").fill_null(""),
                                  normalized_2018=(pl.col("normalized_2018").fill_null(False)
                                                   if utility == SDGE
                                                   else pl.lit(None, dtype=pl.Boolean)))
                    .select("utility_id", "fuel", "gp", "industry", "size", "cz_group",
                            "premises", "industry_name", "year", "collapsed_from",
                            "normalized_2018"))
            seg_frames.append(segs)
        long = (pl.concat(parts, how="diagonal_relaxed")
                .with_columns([pl.col(c).cast(pl.Categorical) for c in CATEGORICAL]
                              + [pl.col("utility_id").cast(pl.Int32),
                                 pl.col("year").cast(pl.Int16)]))
        long.write_parquet(self.long_path)
        pl.concat(seg_frames, how="diagonal_relaxed").write_csv(self.output_dir / SEGMENTS_FILE)
        self.centroid_check().write_csv(self.output_dir / CENTROIDS_FILE)
        if norm_frames:
            pl.concat(norm_frames, how="diagonal_relaxed").write_csv(
                self.output_dir / NORMALIZATION_FILE)
        self.station_check().write_csv(self.output_dir / STATIONS_FILE)
        n_profiles = long.select("utility_id", "fuel", "gp").unique().height
        logger.info("CalMAC: %s rows over %d profiles -> %s", f"{long.height:,}", n_profiles,
                    self.long_path)

    def _normalize(self, series: pl.DataFrame, fuel: str, hourly: bool):
        """SDG&E 2025 -> 2018, per profile, at the station nearest its centroid."""
        assign = weather.assign_stations(self._centroids(SDGE, fuel), self._weather_stations())
        no_centroid = series.select("gp").unique().join(assign, on="gp", how="anti")["gp"]
        if len(no_centroid):
            logger.warning("CalMAC SDG&E %s: no centroid, so no station; stays raw: %s",
                           fuel, sorted(no_centroid.to_list()))
        # each needed station's two years, read once
        wx = {w: (self._weather(w, 2025), self._weather(w, 2018))
              for w in assign["wmo"].unique().to_list()}
        target = series.join(assign.select("gp", "wmo", "nearest_station", "distance_km"),
                             on="gp", how="inner")
        out, stats = [], []
        for (gp,), g in target.group_by("gp", maintain_order=True):   # one regression each
            wmo, station, dist = g["wmo"][0], g["nearest_station"][0], g["distance_km"][0]
            w25, w18 = wx[wmo]
            if w25 is None or w18 is None:
                logger.warning("CalMAC SDG&E %s: no weather for station %s; stays raw", gp, wmo)
                continue
            if hourly:
                obs = g.filter(~pl.col("merged_hour")).select("clock", "value")
                pred, s = weather.normalize_hourly(obs, w25, w18, TARGET_YEAR, SEASONS)
                pred = pred.rename({"timestamp_pst": "timestamp"})
            else:
                obs = g.select(pl.col("timestamp").alias("date"), "value")
                pred, s = weather.normalize_daily_gas(obs, w25, w18, TARGET_YEAR, SEASONS)
                pred = pred.rename({"date": "timestamp"})
            ok, cv = weather.annual_fit_ok(s)
            s = s.with_columns(utility_id=pl.lit(SDGE), fuel=pl.lit(fuel), gp=pl.lit(gp),
                               wmo=pl.lit(wmo), station=pl.lit(station),
                               distance_km=pl.lit(dist), normalized=pl.lit(ok),
                               raw_2025_total=pl.lit(g["value"].sum()),
                               normalized_2018_total=pl.lit(pred["value"].sum() if ok else None,
                                                            dtype=pl.Float64))
            stats.append(s)
            if not ok:
                logger.warning("CalMAC SDG&E %s %s: CV(RMSE) %.1f%% > %.0f%%; not normalized, "
                               "the raw 2025 series is used", fuel, gp, cv, weather.MAX_CVRMSE_PCT)
                continue
            out.append(pred.select("timestamp", "value").with_columns(
                utility_id=pl.lit(SDGE), fuel=pl.lit(fuel), gp=pl.lit(gp),
                basis=pl.lit("normalized_2018"), year=pl.lit(TARGET_YEAR),
                merged_hour=pl.lit(False)))
        normed = (pl.concat(out).with_columns(gp_parts_exprs()) if out else pl.DataFrame())
        return normed, (pl.concat(stats, how="diagonal_relaxed") if stats else pl.DataFrame())

    def centroid_check(self) -> pl.DataFrame:
        """Every profile's centroid against the nearest CALMAC station's CEC zone
        (plan §4.4). A diagnostic: it confirms compact climate-zone groups and says
        nothing about groups spanning several zones."""
        st = self.stations()
        frames = [weather.assign_stations(self._centroids(u, f), st)
                  .with_columns(utility_id=pl.lit(u), fuel=pl.lit(f),
                                cz_group=pl.col("gp").str.split("_").list.get(2))
                  for (u, f) in PROFILE_FILES]
        return pl.concat(frames).select(
            "utility_id", "fuel", "gp", "cz_group", "latitude", "longitude",
            "nearest_station", "wmo", "distance_km", "station_ctz")

    # ---- access --------------------------------------------------------------
    def load(self, utility: int | None = None, fuel: str | None = None,
             basis: str | None = None) -> pl.DataFrame:
        lf = pl.scan_parquet(self.long_path)
        if utility is not None:
            lf = lf.filter(pl.col("utility_id") == int(utility))
        if fuel is not None:
            lf = lf.filter(pl.col("fuel").cast(pl.String) == fuel)
        if basis is not None:
            lf = lf.filter(pl.col("basis").cast(pl.String) == basis)
        return lf.collect()


def load_profiles(raw: pl.DataFrame, utility: int, hourly: bool) -> tuple[pl.DataFrame, pl.DataFrame]:
    """One utility-fuel file -> long rows on PST, plus the collapsed size pairs.

    raw: gp, date, hour, kwh (hourly) or gp, date, therms (daily).
    Returns (utility_id, fuel, gp, industry, size, cz_group, year, timestamp, value,
    merged_hour, and `clock` -- the original clock time -- for hourly series;
    collapsed: a_gp, s_gp, m_gp).
    """
    fuel = "electricity" if hourly else "natural_gas"
    _check_gp_names(raw)
    df = raw.with_columns(pl.col("date").cast(pl.String).str.to_date("%Y-%m-%d"))
    if hourly:
        hour = pl.col("hour").cast(pl.Int64) - (1 if HOUR_ENDING[utility] else 0)
        lo, hi = df.select(hour.min().alias("lo"), hour.max().alias("hi")).row(0)
        if lo < 0 or hi > 23:
            raise ValueError(f"utility {utility}: hours outside 0..23 after the "
                             f"{'hour-ending' if HOUR_ENDING[utility] else 'hour-beginning'} rule")
        df = df.with_columns(clock=pl.col("date").cast(pl.Datetime(TU)) + pl.duration(hours=hour),
                             value=pl.col("kwh").cast(pl.Float64))
        df = df.with_columns(nonexistent=weather.nonexistent_hour_expr(pl.col("clock")),
                             merged_hour=weather.merged_hour_expr(pl.col("clock")))
        dropped = df.filter(pl.col("nonexistent"))
        if not dropped.is_empty():
            logger.info("utility %s: dropping %d readings at the spring-forward hour that does "
                        "not exist (largest |value| %.4g)", utility, dropped.height,
                        dropped["value"].abs().max())
        df = (df.filter(~pl.col("nonexistent"))
              .with_columns(timestamp=weather.clock_to_pst_expr(pl.col("clock"))))
    else:
        df = df.with_columns(value=pl.col("therms").cast(pl.Float64),
                             timestamp=pl.col("date").cast(pl.Datetime(TU)),
                             merged_hour=pl.lit(False))
    df = df.sort(["gp", "timestamp"])
    dup = df.select(pl.struct("gp", "timestamp").is_duplicated().sum()).item()
    if dup:
        raise ValueError(f"utility {utility} {fuel}: {dup} duplicate (profile, timestamp) rows "
                         "after the clock conversion")
    df, collapsed = collapse_identical_sizes(df)
    df = df.with_columns(gp_parts_exprs() + [pl.lit(utility).alias("utility_id"),
                                             pl.lit(fuel).alias("fuel"),
                                             pl.col("timestamp").dt.year().alias("year")])
    cols = ["utility_id", "fuel", "gp", "industry", "size", "cz_group", "year", "timestamp",
            "value", "merged_hour"] + (["clock"] if hourly else [])
    return df.select(cols), collapsed


def collapse_identical_sizes(df: pl.DataFrame) -> tuple[pl.DataFrame, pl.DataFrame]:
    """Where an industry x CZ group has an S and an M (or L) series that are exactly
    equal, PG&E combined the sizes and published the same series twice: keep one,
    relabelled `<ind>_A_<cz>`. Nearly-equal series are an error, not a duplicate.

    df: gp, timestamp, value. Returns (df, collapsed: a_gp, s_gp, m_gp).
    """
    k = df.select("gp", "timestamp", "value").with_columns(gp_parts_exprs())
    keys = ["industry", "cz_group"]
    small = k.filter(pl.col("size") == "S").select(*keys, "timestamp", pl.col("gp").alias("s_gp"),
                                                    pl.col("value").alias("s"))
    big = k.filter(pl.col("size").is_in(["M", "L"])).select(*keys, "timestamp",
                                                            pl.col("gp").alias("m_gp"),
                                                            pl.col("value").alias("m"))
    n_s = small.group_by(keys).agg(n_s=pl.len())
    n_m = big.group_by(keys).agg(n_m=pl.len())
    cmp = (small.join(big, on=keys + ["timestamp"], how="inner")
           .group_by(keys + ["s_gp", "m_gp"])
           .agg(n_j=pl.len(), equal=(pl.col("s") == pl.col("m")).all(),
                rel=((pl.col("s") - pl.col("m")).abs()
                     / pl.col("m").abs().clip(lower_bound=1e-12)).max())
           .join(n_s, on=keys).join(n_m, on=keys)
           .with_columns(same_index=(pl.col("n_j") == pl.col("n_s")) & (pl.col("n_j") == pl.col("n_m"))))
    near = cmp.filter(pl.col("same_index") & ~pl.col("equal") & (pl.col("rel") < 1e-6))
    if not near.is_empty():
        r = near.row(0, named=True)
        raise ValueError(f"{r['s_gp']} and {r['m_gp']} differ by at most {r['rel']:.2e} relative: "
                         "neither identical (a combined-size duplicate) nor distinct")
    collapsed = (cmp.filter(pl.col("same_index") & pl.col("equal"))
                 .select(pl.concat_str([pl.col("industry"), pl.lit("_A_"), pl.col("cz_group")])
                         .alias("a_gp"), "s_gp", "m_gp")
                 .sort("a_gp"))
    if not collapsed.is_empty():
        logger.info("collapsed identical size pairs into one 'A' series: %s", "; ".join(
            collapsed.select(pl.format("{}={}+{}", "a_gp", "s_gp", "m_gp")).to_series().to_list()))
    out = (df.filter(~pl.col("gp").is_in(collapsed["m_gp"].implode()))
           .with_columns(pl.col("gp").replace(collapsed["s_gp"], collapsed["a_gp"])))
    return out, collapsed


def calmac_long_path(truth_data_version: str = "v01") -> Path:
    here = Path(os.path.dirname(os.path.abspath(__file__)))
    return here.parents[1] / "output" / f"CalMAC {truth_data_version}" / LONG_FILE
