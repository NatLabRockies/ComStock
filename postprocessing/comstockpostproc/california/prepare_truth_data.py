# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""One-off preparation of the CalMAC truth data into `truth_data/v01/calmac/`.

    python -m comstockpostproc.california.prepare_truth_data <calmac data folder> [--out DIR]

The data folder is the one the utilities' files were downloaded into:

    <folder>/pg&e/PGE_Non-res_GP_Elec_2018.zip, PGE_Non-res_GP_Gas_2018.zip,
                  PGE_Non-res_GP_Elec_Gas_Characteristics.zip
    <folder>/sdg&e/SDGE_Non-res_GP_Elec_2025.zip, SDGE_Non-res_GP_Gas_2025.zip,
                   SDGE_Non-res_GP_Elec_Characteristics.zip, SDGE_Non-res_GP_Gas_Centroids.zip,
                   SDGE_Non-res_GP_Gas_Data_Dictionary.zip
    <folder>/weather/CZ2018S_127LOCS_HIST.zip  (CALMAC's 2018 historical weather, 127 stations)

What it writes, all csv with stable names (README.md in the output folder lists them):
profiles, dictionaries, centroids and segment counts per utility and fuel; the CALMAC
weather-station table with each station's CEC Title 24 zone (scraped from
calmac.org/weather.asp); and hourly dry-bulb for 2018 and 2025 at the stations nearest
the SDG&E profiles, which the 2025 -> 2018 weather normalization needs. The 2025 station
files are downloaded from calmac.org; the 2018 ones come from the supplied archive.

Needs nothing beyond the standard library and pandas: the few SDG&E spreadsheets are
read as the zipped XML an .xlsx is, because openpyxl is not in the postprocessing
environments. After it runs, upload the output folder to
s3://eulp/truth_data/v01/calmac/ so other machines can fetch it.
"""

from __future__ import annotations

import argparse
import datetime as dt
import io
import logging
import math
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from html.parser import HTMLParser
from pathlib import Path

import pandas as pd

logger = logging.getLogger(__name__)

CALMAC_WEATHER_PAGE = "https://www.calmac.org/weather.asp"
CALMAC_WEATHER_BASE = "https://www.calmac.org/"
DEFAULT_OUT = Path(__file__).resolve().parents[2] / "truth_data" / "v01" / "calmac"
# Weather is fetched for this many stations nearest each SDG&E profile.
NEAREST_STATIONS = 3


# ---------------------------------------------------------------------------
# xlsx without openpyxl
# ---------------------------------------------------------------------------

_NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
       "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
       "rel": "http://schemas.openxmlformats.org/package/2006/relationships"}
_EXCEL_EPOCH = dt.datetime(1899, 12, 30)


def _col_index(ref: str) -> int:
    letters = re.match(r"[A-Z]+", ref).group(0)
    n = 0
    for ch in letters:
        n = n * 26 + (ord(ch) - 64)
    return n - 1


def read_xlsx(data: bytes, sheet: str | None = None, date_columns=("date",)) -> pd.DataFrame:
    """The first (or the named) worksheet of an .xlsx as a DataFrame.

    Handles shared strings, inline strings, booleans and numbers. Excel stores dates
    as day serials; columns named in `date_columns` are converted from serial to an
    ISO date string. Header = first row.
    """
    z = zipfile.ZipFile(io.BytesIO(data))
    shared = []
    if "xl/sharedStrings.xml" in z.namelist():
        root = ET.fromstring(z.read("xl/sharedStrings.xml"))
        for si in root.findall("m:si", _NS):
            shared.append("".join(t.text or "" for t in si.iter(f"{{{_NS['m']}}}t")))
    wb = ET.fromstring(z.read("xl/workbook.xml"))
    sheets = [(s.get("name"), s.get(f"{{{_NS['r']}}}id"))
              for s in wb.find("m:sheets", _NS).findall("m:sheet", _NS)]
    rels = ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))
    target = {r.get("Id"): r.get("Target") for r in rels.findall("rel:Relationship", _NS)}
    name, rid = next(((n, i) for n, i in sheets if sheet is None or n == sheet), (None, None))
    if rid is None:
        raise KeyError(f"no sheet {sheet!r}; have {[n for n, _ in sheets]}")
    path = target[rid].lstrip("/")
    path = path if path.startswith("xl/") else f"xl/{path}"
    root = ET.fromstring(z.read(path))
    rows = []
    for row in root.find("m:sheetData", _NS).findall("m:row", _NS):
        vals = {}
        for c in row.findall("m:c", _NS):
            t, ref = c.get("t"), c.get("r")
            v = c.find("m:v", _NS)
            if t == "s":
                val = shared[int(v.text)] if v is not None else None
            elif t == "inlineStr":
                val = "".join(x.text or "" for x in c.iter(f"{{{_NS['m']}}}t"))
            elif t in ("str", "e"):
                val = v.text if v is not None else None
            elif t == "b":
                val = bool(int(v.text)) if v is not None else None
            else:
                val = float(v.text) if v is not None and v.text not in (None, "") else None
            vals[_col_index(ref)] = val
        if vals:
            width = max(vals) + 1
            rows.append([vals.get(i) for i in range(width)])
    header = [str(h) for h in rows[0]]
    body = [r + [None] * (len(header) - len(r)) for r in rows[1:]]
    df = pd.DataFrame([r[:len(header)] for r in body], columns=header)
    for col in df.columns:
        if col in date_columns:
            df[col] = df[col].map(
                lambda x: (_EXCEL_EPOCH + dt.timedelta(days=float(x))).date().isoformat()
                if isinstance(x, (int, float)) and not (isinstance(x, float) and math.isnan(x))
                else x)
    # whole-number floats back to int where every value is integral (counts, ids)
    for col in df.columns:
        s = df[col]
        if s.dtype == float and s.notna().all() and (s % 1 == 0).all():
            df[col] = s.astype("int64")
    return df


# ---------------------------------------------------------------------------
# archive access
# ---------------------------------------------------------------------------

def _member(zpath: Path, pattern: str) -> bytes:
    """The one member of `zpath` whose name matches `pattern` (a regex)."""
    with zipfile.ZipFile(zpath) as z:
        hits = [n for n in z.namelist() if re.search(pattern, n) and not n.endswith("/")]
        if len(hits) != 1:
            raise FileNotFoundError(f"{zpath.name}: expected one member matching {pattern!r}, "
                                    f"found {hits}")
        return z.read(hits[0])


def _csv(data: bytes, **kw) -> pd.DataFrame:
    return pd.read_csv(io.BytesIO(data), **kw)


# ---------------------------------------------------------------------------
# profiles, dictionaries, centroids
# ---------------------------------------------------------------------------

def _gp_parts(df: pd.DataFrame) -> pd.DataFrame:
    parts = df["gp"].str.split("_", expand=True)
    return df.assign(industry=parts[0], size=parts[1], cz_group=parts[2])


def prepare_pge(folder: Path, out: Path) -> None:
    pge = folder / "pg&e"
    elec = _csv(_member(pge / "PGE_Non-res_GP_Elec_2018.zip", r"\.csv$"))
    elec = elec[["gp", "date", "hour", "kwh"]]
    elec.to_csv(out / "pge_elec_2018.csv", index=False)
    gas = _csv(_member(pge / "PGE_Non-res_GP_Gas_2018.zip", r"\.csv$"))
    gas[["gp", "date", "therms"]].to_csv(out / "pge_gas_2018.csv", index=False)
    logger.info("PG&E: %d electric rows over %d profiles, %d gas rows over %d profiles",
                len(elec), elec["gp"].nunique(), len(gas), gas["gp"].nunique())

    chars = pge / "PGE_Non-res_GP_Elec_Gas_Characteristics.zip"
    for fuel, tag in (("elec", "Elec"), ("gas", "Gas")):
        d = _csv(_member(chars, rf"Non-res_{tag}_Data_Dictionary\.csv$"))
        d = _gp_parts(d.rename(columns={"prem": "premises"}))
        d["industry_name"] = d["seg_industry"]
        d[["gp", "industry", "size", "cz_group", "premises", "industry_name"]].to_csv(
            out / f"pge_{fuel}_dictionary.csv", index=False)
        c = _csv(_member(chars, rf"Non-res_{tag}(tric)?_GP_Centroids\.csv$"))
        c[["gp", "latitude", "longitude"]].to_csv(out / f"pge_{fuel}_centroids.csv", index=False)
        s = _csv(_member(chars, rf"Nonres_{tag}_GP_Segments_and_Counts\.csv$"))
        s.to_csv(out / f"pge_{fuel}_segment_counts.csv", index=False)


def prepare_sdge(folder: Path, out: Path) -> None:
    sd = folder / "sdg&e"
    elec = _csv(_member(sd / "SDGE_Non-res_GP_Elec_2025.zip", r"\.csv$"))
    elec["date"] = pd.to_datetime(elec["date"], format="%m/%d/%Y").dt.date.astype(str)
    elec[["gp", "date", "hour", "kwh"]].to_csv(out / "sdge_elec_2025.csv", index=False)
    gas = read_xlsx(_member(sd / "SDGE_Non-res_GP_Gas_2025.zip", r"\.xlsx$"))
    gas = gas.rename(columns={"consm_therm": "therms"})[["gp", "date", "therms"]]
    gas.to_csv(out / "sdge_gas_2025.csv", index=False)
    logger.info("SDG&E: %d electric rows over %d profiles, %d gas rows over %d profiles",
                len(elec), elec["gp"].nunique(), len(gas), gas["gp"].nunique())

    sources = {
        "elec": (sd / "SDGE_Non-res_GP_Elec_Characteristics.zip",
                 r"Electric_Data_Dictionary\.xlsx$", r"Electric_Centroids\.xlsx$"),
        "gas": (sd / "SDGE_Non-res_GP_Gas_Data_Dictionary.zip", r"\.xlsx$", None),
    }
    for fuel, (zpath, dict_pat, cent_pat) in sources.items():
        d = read_xlsx(_member(zpath, dict_pat))
        d = _gp_parts(d.rename(columns={"count": "premises"}))
        d["industry_name"] = d["seg_industry"]
        d[["gp", "industry", "size", "cz_group", "premises", "industry_name"]].to_csv(
            out / f"sdge_{fuel}_dictionary.csv", index=False)
        cz = (read_xlsx(_member(zpath, cent_pat)) if cent_pat
              else read_xlsx(_member(sd / "SDGE_Non-res_GP_Gas_Centroids.zip", r"\.xlsx$")))
        cz[["gp", "latitude", "longitude"]].to_csv(out / f"sdge_{fuel}_centroids.csv", index=False)


# ---------------------------------------------------------------------------
# weather stations and dry-bulb
# ---------------------------------------------------------------------------

class _StationTable(HTMLParser):
    """Rows of the station table on calmac.org/weather.asp: cell text and the hrefs
    inside each cell. The header row names the columns (City, CTZ, WMO, Lat, Lon,
    ..., one column per historical year)."""

    def __init__(self):
        super().__init__()
        self.rows, self._row, self._cell, self._links = [], None, None, None

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._cell, self._links = [], []
        elif tag == "a" and self._cell is not None:
            href = dict(attrs).get("href")
            if href:
                self._links.append(href)

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self._cell is not None and self._row is not None:
            self._row.append((" ".join("".join(self._cell).split()), self._links))
            self._cell = None
        elif tag == "tr" and self._row is not None:
            self.rows.append(self._row)
            self._row = None

    def handle_data(self, data):
        if self._cell is not None:
            self._cell.append(data)


def parse_station_table(html: str) -> pd.DataFrame:
    """wmo, name, lat, lon, ctz, plus `href_<year>` for every historical year column."""
    p = _StationTable()
    p.feed(html)
    header = next((r for r in p.rows if [c[0] for c in r[:3]] == ["City", "CTZ", "WMO"]), None)
    if header is None:
        raise ValueError("the CALMAC weather page no longer has a City/CTZ/WMO table")
    names = [c[0] for c in header]
    recs = []
    for row in p.rows:
        if len(row) != len(names) or not re.fullmatch(r"\d{6}", row[2][0]):
            continue
        rec = {"name": row[0][0].replace("view on map", "").strip(),
               "ctz": int(row[1][0]) if row[1][0].isdigit() else None,
               "wmo": row[2][0], "lat": float(row[3][0]), "lon": float(row[4][0])}
        for (text, links), col in zip(row, names):
            if re.fullmatch(r"20\d\d", col):
                zips = [h for h in links if h.lower().endswith(".zip")]
                rec[f"href_{col}"] = zips[0] if zips else None
        recs.append(rec)
    df = pd.DataFrame(recs).drop_duplicates("wmo").reset_index(drop=True)
    if df.empty:
        raise ValueError("no stations parsed from the CALMAC weather page")
    return df


def fetch(url: str) -> bytes:
    # urllib, not requests: on the NREL machines urllib uses the Windows certificate
    # store and reaches calmac.org, while requests' bundled certificates do not.
    logger.info("downloading %s", url)
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def epw_drybulb(epw: bytes) -> pd.DataFrame:
    """Hourly dry-bulb from an EPW: `timestamp_pst` (hour-BEGINNING, local standard
    time -- EPW hours 1..24 are hour-ending standard time) and `drybulb_c`."""
    text = epw.decode("latin-1").splitlines()[8:]
    rows = [ln.split(",") for ln in text if ln.strip()]
    df = pd.DataFrame({"year": [int(r[0]) for r in rows], "month": [int(r[1]) for r in rows],
                       "day": [int(r[2]) for r in rows], "hour": [int(r[3]) for r in rows],
                       "drybulb_c": [float(r[6]) for r in rows]})
    df["timestamp_pst"] = (pd.to_datetime(df[["year", "month", "day"]])
                           + pd.to_timedelta(df["hour"] - 1, unit="h"))
    return df[["timestamp_pst", "drybulb_c"]]


def _haversine_km(lat1, lon1, lat2, lon2):
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi, dlmb = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def prepare_weather(folder: Path, out: Path, stations_html: str | None = None) -> None:
    wx = out / "weather"
    wx.mkdir(parents=True, exist_ok=True)
    html = stations_html or fetch(CALMAC_WEATHER_PAGE).decode("utf-8", errors="ignore")
    st = parse_station_table(html)

    # Which stations the supplied 2018 archive actually holds, by WMO id.
    arch = folder / "weather" / "CZ2018S_127LOCS_HIST.zip"
    with zipfile.ZipFile(arch) as z:
        inner = {m.group(1): n for n in z.namelist()
                 for m in [re.search(r"_(\d{6})S?_18\.zip$", n)] if m}
    st["in_2018_archive"] = st["wmo"].isin(inner)
    st[["wmo", "name", "lat", "lon", "ctz", "in_2018_archive", "href_2018", "href_2025"]].to_csv(
        wx / "stations.csv", index=False)
    logger.info("stations: %d on the CALMAC page, %d in the 2018 archive",
                len(st), int(st["in_2018_archive"].sum()))

    # The NEAREST_STATIONS stations nearest each SDG&E profile centroid, among those
    # with both a 2018 file (supplied) and a 2025 file (on calmac.org): the
    # normalization needs both years at one station. More than one per profile so the
    # station consistency check in CalMAC (weather.station_year_consistency) has an
    # alternative when it rejects the nearest -- it rejected Miramar, whose 2018 and
    # 2025 records disagree with their neighbours by ~1.8 C.
    usable = st[st["in_2018_archive"] & st["href_2025"].notna()].reset_index(drop=True)
    need = set()
    for fuel in ("elec", "gas"):
        cents = pd.read_csv(out / f"sdge_{fuel}_centroids.csv")
        for _, c in cents.iterrows():
            d = usable.apply(lambda s: _haversine_km(c.latitude, c.longitude, s.lat, s.lon), axis=1)
            need.update(usable.loc[d.nsmallest(NEAREST_STATIONS).index, "wmo"])
    logger.info("SDG&E normalization candidate stations: %s", sorted(need))

    with zipfile.ZipFile(arch) as z:
        for wmo in sorted(need):
            epw = _member_bytes_from_nested(z.read(inner[wmo]), r"\.epw$")
            epw_drybulb(epw).to_csv(wx / f"{wmo}_2018.csv", index=False)
            href = st.loc[st["wmo"] == wmo, "href_2025"].iloc[0]
            data = fetch(CALMAC_WEATHER_BASE + href.lstrip("/"))
            d25 = epw_drybulb(_member_bytes_from_nested(data, r"\.epw$"))
            if len(d25) < 8760 or d25["timestamp_pst"].dt.year.min() != 2025:
                raise ValueError(f"{wmo}: 2025 file from {href} is not a full 2025 year "
                                 f"({len(d25)} rows)")
            d25.to_csv(wx / f"{wmo}_2025.csv", index=False)


def _member_bytes_from_nested(zip_bytes: bytes, pattern: str) -> bytes:
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as z:
        hits = [n for n in z.namelist() if re.search(pattern, n, re.I)]
        if len(hits) != 1:
            raise FileNotFoundError(f"expected one member matching {pattern!r}, found {hits}")
        return z.read(hits[0])


README = """# CalMAC non-residential granular profiles (truth data for the California dashboard)

Prepared by `python -m comstockpostproc.california.prepare_truth_data <folder>` from the
files PG&E and SDG&E publish through CalMAC. Every profile value is the AVERAGE PER-PREMISE
consumption of the ~200 sampled premises behind it -- not a total and not per square foot.
Times are as published: local clock time with daylight saving. PG&E `hour` is 0..23
(hour-beginning); SDG&E `hour` is 1..24 (hour-ending). `comstockpostproc.california.CalMAC`
converts both to Pacific standard time.

| file | content |
|---|---|
| pge_elec_2018.csv | gp, date, hour, kwh -- hourly, 2018 |
| pge_gas_2018.csv | gp, date, therms -- daily, 2018 |
| sdge_elec_2025.csv | gp, date, hour, kwh -- hourly, 2025 |
| sdge_gas_2025.csv | gp, date, therms -- daily, 2025 |
| <utility>_<fuel>_dictionary.csv | gp, industry, size, cz_group, premises (sample size), industry_name |
| <utility>_<fuel>_centroids.csv | gp, latitude, longitude (premise-weighted) |
| pge_<fuel>_segment_counts.csv | the 200-premise PRIMARY SAMPLE per profile cross-tabulated by segment -- not the premise population |
| weather/stations.csv | CALMAC weather stations: wmo, name, lat, lon, ctz (CEC Title 24 zone), whether the 2018 archive has it, and the calmac.org paths of its 2018 and 2025 files |
| weather/<wmo>_2018.csv, weather/<wmo>_2025.csv | hourly dry-bulb (timestamp_pst hour-beginning, drybulb_c) at the three stations nearest each SDG&E profile |

Sources: PG&E and SDG&E non-residential granular profiles and characteristics (CalMAC);
weather: CALMAC historical weather files, https://www.calmac.org/weather.asp.
"""


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("folder", type=Path, help="the CalMAC data folder (pg&e/, sdg&e/, weather/)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"default {DEFAULT_OUT}")
    ap.add_argument("--stations-html", type=Path, default=None,
                    help="a saved copy of calmac.org/weather.asp, if this machine cannot reach it")
    args = ap.parse_args(argv)
    logging.basicConfig(level="INFO", format="%(asctime)s %(levelname)s:%(name)s:%(message)s")
    args.out.mkdir(parents=True, exist_ok=True)
    prepare_pge(args.folder, args.out)
    prepare_sdge(args.folder, args.out)
    html = args.stations_html.read_text(encoding="utf-8", errors="ignore") if args.stations_html else None
    prepare_weather(args.folder, args.out, html)
    (args.out / "README.md").write_text(README, encoding="utf-8")
    logger.info("CalMAC truth data written to %s; upload it to s3://eulp/truth_data/v01/calmac/",
                args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
