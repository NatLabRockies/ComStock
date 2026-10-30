# Supply prices for delivery-only tariffs

**Why:** in retail choice states many URDB commercial tariffs carry delivery charges only. A
customer on them buys supply separately, from the utility's default service or a competitive
supplier. Billed under those tariffs alone, ComStock buildings in those states came out at about
0.69× the EIA-861 2022 commercial price. These files add the default service supply price to
those tariffs.

## Files

**`delivery_only_tariffs.csv`:** the URDB rate files, by state, that carry delivery charges only,
with the supply class each one takes.

| Column | Meaning |
|---|---|
| `state`, `eiaid`, `label` | State billed, utility, URDB rate file label |
| `supply_class` | `small`, `medium`, `large` or `all`: the utility's default service class for the tariff |
| `class_evidence` | How the class was chosen (see below) |
| `status_evidence` | How the tariff was found to be delivery-only (see below) |
| `name` | Tariff name, for reading |

**`supply_prices.csv`:** monthly supply prices per utility × supply class, 2018-01 on, in nominal
dollars of the month.

| Column | Meaning |
|---|---|
| `class_min_kw`, `class_max_kw` | The class's demand bounds where the utility defines it by demand (blank otherwise) |
| `supply_usd_per_kwh` | Supply price per kWh |
| `supply_usd_per_kw_month` | Supply price per kW of monthly peak demand (capacity or transmission billed per kW), usually blank |
| `method` | `default_service`: the utility's published default service price |
| | `default_service_filled`: a gap of up to 3 months, carried forward from the previous month |
| | `eia861_state`: the EIA-861 state commercial energy-only price, scaled to the class's own level where 12+ months of its published prices exist (`_scaled`) |
| | `eia861_state_pooled`: the same EIA-861 price × 1.13, the median ratio of default service to it across all small and medium classes |

## How the measure uses them

**Selecting the price.** For a tariff in `delivery_only_tariffs.csv` (state and label), the
measure takes that class's 2022 prices (`SUPPLY_YEAR` in `measure.rb`):
- Where the utility defines classes by demand, it moves the building to the class whose kW bounds
  contain the building's peak demand. Examples: PECO's hourly class from 100 kW, NJ BGS-CIEP from
  500 kW.
- An unbounded class moves to a class with a kW floor above zero that the peak reaches.

**Billing it.** `calc_elec_bill.py` bills supply as monthly kWh × $/kWh plus monthly peak kW ×
$/kW-month, on the calendar months PySAM uses. That equals adding the $/kWh to the energy tiers'
URDB `adj`, which PySAM bills as rate + adj; checked to $1 on tiered, TOU and demand tariffs.

**Escalation.** Supply is added after the tariff's own charges are escalated to 2022, so it isn't
escalated again. The energy-charge statistics include supply energy; the flat demand-charge
statistics include supply per kW.

**Not covered:** TOU-differentiated supply prices, hourly pricing for large customers (those
classes use the EIA-861 fallback), and supply that varies by load zone within a utility (NiMo,
Con Ed, MA). Zones use the mean across zones.

## How the files were built

The research, source documents and scripts live in the ComStock Filing Cabinet, under
`Efforts/Measures/HVAC - Dual Fuel RTU/rate_analysis/electric/` (`supply/README.md` there).

**Default service prices:**
- **Sources:** utilities' and PUCs' published history, collected per utility and class for
  2018-2026 from tariff filings, rate statements and auction results. Each row cites its source.
- **Fallback:** EIA-861, from the annual Sales to Ultimate Customers files and the state history
  file, 2010-2025.

**Delivery-only tariffs:** each candidate tariff of the 42 retail choice utilities whose URDB
tariffs are delivery-only was tested in four ways:
- **Price position:** its flat-load price between the utility's EIA-861 delivery-only and bundled
  commercial prices.
- **Text:** its text ("Unbundled", "Delivery Service").
- **Supply test:** whether the tariff plus the utility's supply lands nearer EIA's bundled price
  than the tariff alone.
- **Unbundled twin:** a tariff with an explicitly "(Unbundled)" twin of the same schedule is
  bundled if it costs more than half a supply price above that twin.

  Rows whose rate file `elec_rate_states.csv` assigns to another state are dropped.

**Supply class** (`class_evidence`), in order:
1. `single_class`: the utility has one class.
2. `hourly_service_in_name`: the name says hourly service (BESH, CIEP, HSS).
3. `rate_schedule`: the class's rate schedules appear in the tariff name.
4. `size_in_name`: the name says small, medium or large.
5. `kw_window`: the tariff's kW window fits inside a class.
6. `default_smallest`: the smallest class.

Regenerate both files with `scripts/export_supply_to_measure.py <supply_dir> <this measure>` in
that folder after refreshing the supply data or `elec_rate_states.csv`.
`tests/utility_bills_test.rb` checks that every listed tariff exists, is billed in its state, and
has 12 months of prices in the supply year.
