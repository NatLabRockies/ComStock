# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The CalMAC truth loader: profile names, clock rules, size collapse. No S3.

The published profiles are in local CLOCK time with daylight saving: PG&E's `hour`
is 0..23 hour-beginning and omits the spring-forward hour; SDG&E's is 1..24
hour-ending and zero-fills it. Converted to Pacific standard time, the
spring-forward DATE comes out complete and the fall-back date loses PST 01:00, with
the clock hour that was recorded twice flagged at PST 00:00.
"""

import datetime as dt

import polars as pl
import pytest

from comstockpostproc.california import segments as SEG
from comstockpostproc.california.calmac import collapse_identical_sizes, load_profiles
from comstockpostproc.california.prepare_truth_data import parse_station_table, read_xlsx


def _year(gps, year, hour_ending, fill_spring=False, value=None):
    """A year of hourly clock-time rows in a utility's published layout. `value` is
    an expression over `gp` and the clock time `ts`; the spring-forward hour is
    omitted, or zero-filled when `fill_spring`."""
    spring = dt.datetime(year, 3, 11 if year == 2018 else 9, 2)
    ts = pl.datetime_range(dt.datetime(year, 1, 1), dt.datetime(year, 12, 31, 23), "1h",
                           time_unit="us", eager=True).alias("ts")
    df = pl.DataFrame({"gp": gps}).join(ts.to_frame(), how="cross")
    if not fill_spring:
        df = df.filter(pl.col("ts") != spring)
    v = value if value is not None else pl.lit(1.0)
    return df.select(
        "gp",
        pl.col("ts").dt.strftime("%Y-%m-%d").alias("date"),
        (pl.col("ts").dt.hour() + (1 if hour_ending else 0)).alias("hour"),
        pl.when(pl.col("ts") == spring).then(0.0).otherwise(v).alias("kwh"))


def _on(df, day):
    return df.filter(pl.col("timestamp").dt.strftime("%Y-%m-%d") == day)


def test_parse_gp():
    assert SEG.parse_gp("Office_M_C") == ("Office", "M", "C")
    with pytest.raises(ValueError):
        SEG.parse_gp("Office-M-C")
    with pytest.raises(ValueError):
        SEG.parse_gp("Off_M_C")


def test_pge_clock_to_pst_dst_dates():
    df, collapsed = load_profiles(_year(["Office_M_C"], 2018, hour_ending=False), SEG.PGE, hourly=True)
    assert collapsed.is_empty()
    assert df.height == 8759                                  # 8760 clock hours less the one that does not exist
    spring = _on(df, "2018-03-11")
    assert sorted(spring["timestamp"].dt.hour().to_list()) == list(range(24))   # complete in PST
    fall = _on(df, "2018-11-04")
    assert 1 not in fall["timestamp"].dt.hour().to_list()                       # PST 01:00 missing
    assert fall.filter(pl.col("merged_hour"))["timestamp"].dt.hour().to_list() == [0]
    # a summer clock 13:00 is PST 12:00
    july = df.filter(pl.col("clock") == dt.datetime(2018, 7, 2, 13))
    assert july["timestamp"][0] == dt.datetime(2018, 7, 2, 12)


def test_sdge_hour_ending_and_zero_filled_spring_hour():
    raw = _year(["Office_L_C"], 2025, hour_ending=True, fill_spring=True)
    assert raw["hour"].min() == 1 and raw["hour"].max() == 24
    df, _ = load_profiles(raw, SEG.SDGE, hourly=True)
    assert df.height == 8759                                  # the zero-filled hour is dropped
    assert df["timestamp"].min() == dt.datetime(2025, 1, 1)  # HE1 -> 00:00
    nov = _on(df, "2025-11-02")
    assert 1 not in nov["timestamp"].dt.hour().to_list()
    assert nov["merged_hour"].sum() == 1


def test_identical_size_pair_collapses_to_A():
    value = (pl.when(pl.col("gp").str.starts_with("Religi"))
             .then(pl.col("ts").dt.hour().cast(pl.Float64))            # S and M identical
             .when(pl.col("gp").str.ends_with("S_C")).then(1.0).otherwise(2.0))
    raw = _year(["Religi_S_C", "Religi_M_C", "Office_S_C", "Office_M_C"], 2018, False, value=value)
    df, collapsed = load_profiles(raw, SEG.PGE, hourly=True)
    assert collapsed.to_dicts() == [{"a_gp": "Religi_A_C", "s_gp": "Religi_S_C", "m_gp": "Religi_M_C"}]
    assert set(df["gp"].unique().to_list()) == {"Religi_A_C", "Office_S_C", "Office_M_C"}
    assert (df.filter(pl.col("gp") == "Religi_A_C")["size"] == "A").all()


def test_nearly_identical_pair_is_an_error():
    ts = pl.datetime_range(dt.datetime(2018, 1, 1), dt.datetime(2018, 1, 1, 2), "1h",
                           time_unit="us", eager=True)
    df = pl.DataFrame({"gp": ["Religi_S_C"] * 3 + ["Religi_M_C"] * 3,
                       "timestamp": pl.concat([ts, ts]),
                       "value": [1.0, 2.0, 3.0, 1.0, 2.0, 3.0 * (1 + 1e-9)]})
    with pytest.raises(ValueError, match="neither identical"):
        collapse_identical_sizes(df)


def test_bad_profile_name_is_an_error():
    raw = pl.DataFrame({"gp": ["Office-A-C"], "date": ["2018-01-01"], "therms": [1.0]})
    with pytest.raises(ValueError, match="granular-profile"):
        load_profiles(raw, SEG.PGE, hourly=False)


def test_daily_gas_keeps_dates():
    raw = pl.DataFrame({"gp": ["Office_A_C"] * 3, "date": ["2018-01-01", "2018-01-02", "2018-01-03"],
                        "therms": [1.0, 2.0, 3.0]})
    df, _ = load_profiles(raw, SEG.PGE, hourly=False)
    assert df["fuel"].unique().to_list() == ["natural_gas"]
    assert (df["timestamp"].dt.hour() == 0).all() and not df["merged_hour"].any()


def test_xlsx_reader_reads_shared_strings_numbers_and_dates(tmp_path):
    import io
    import zipfile
    sheet = ('<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/'
             'spreadsheetml/2006/main"><sheetData>'
             '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c></row>'
             '<row r="2"><c r="A2" t="s"><v>3</v></c><c r="B2"><v>45658</v></c><c r="C2"><v>2.5</v></c></row>'
             '</sheetData></worksheet>')
    shared = ('<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
              '<si><t>gp</t></si><si><t>date</t></si><si><t>consm_therm</t></si><si><t>Office_A_C</t></si></sst>')
    wb = ('<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
          '<sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>')
    rels = ('<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Target="worksheets/sheet1.xml" Type="x"/></Relationships>')
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("xl/worksheets/sheet1.xml", sheet)
        z.writestr("xl/sharedStrings.xml", shared)
        z.writestr("xl/workbook.xml", wb)
        z.writestr("xl/_rels/workbook.xml.rels", rels)
    df = read_xlsx(buf.getvalue())
    assert df.to_dict("records") == [{"gp": "Office_A_C", "date": "2025-01-01", "consm_therm": 2.5}]


def test_station_table_parsing():
    html = """<table><tr><td>City</td><td>CTZ</td><td>WMO</td><td>Lat</td><td>Lon</td><td>2018</td><td>2025</td></tr>
      <tr><td>San-Diego-IAP<a href='weather_map.asp?wmo=722900'>view on map</a></td><td>7</td><td>722900</td>
      <td>32.734</td><td>-117.183</td><td><a href='weather/2018/CA_SAN-DIEGO_722900S_18.zip'>2018</a></td>
      <td><a href='weather/2025/CA_SAN-DIEGO-IAP_722900_25.zip'>2025</a></td></tr></table>"""
    st = parse_station_table(html)
    r = st.iloc[0].to_dict()
    assert (r["wmo"], r["ctz"], r["name"]) == ("722900", 7, "San-Diego-IAP")
    assert r["href_2025"] == "weather/2025/CA_SAN-DIEGO-IAP_722900_25.zip"


def test_resolve_config_validates_and_normalizes_keys():
    cfg = SEG.resolve_config({"size_rule": "none", "utilities": {"14328": "PG&E"}})
    assert cfg["size_rule"]["kind"] == "none" and cfg["utilities"] == {14328: "PG&E"}
    with pytest.raises(KeyError):
        SEG.resolve_config({"nope": 1})
    with pytest.raises(ValueError):
        SEG.resolve_config({"industry_map": {"Office": ["SmallOffice"], "Retail": ["SmallOffice"]}})
