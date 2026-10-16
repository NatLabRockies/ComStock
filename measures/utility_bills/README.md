# Utility Bills

Reporting measure that calculates the model's annual utility bills for every location the stock
allocation can later put it in: each state of its sampling region, and each electric utility serving
tracts of that state. Electricity bills use URDB tariffs through PySAM (`resources/calc_elec_bill.py`),
escalated from each tariff's start year to 2022 by the state's average yearly increase in commercial
electricity prices; natural gas, propane and fuel oil use EIA state averages.

## Outputs

- `electricity_utility_bill_results`: one block per (state, utility),
  `|<EIA id>:<45 statistics>:<bill count>:<state>|`, 48 fields. The state is the last field; runs made
  before the measure recorded it end each block at the bill count, and postprocessing works their
  states out from the order the blocks are written in. A state in which none of the utility's
  tariffs applied to the building has no block, and its rows get the state-average bill.
- `state_avg_*_cost_results`: one block per state, `|<state>:<dollars>|`, for each fuel.
- `electricity_rate_files_by_state`: the version of `resources/elec_rate_states.csv` applied (see below).
  Kept in the raw results for provenance; postprocessing does not export it.

## Resources and how to maintain them

- `elec_rates/<EIA id>/<URDB label>.json`: the URDB commercial tariffs, downloaded from the OpenEI
  Utility Rate Database (initial set December 2023, non-commercial tariffs removed January 2024).
- `tract_to_elec_util_v2.csv`: the electric utility serving each census tract.
- `sampling_region_to_tracts.json`, `state_abbrev_to_fips.json`: the tracts of each sampling region
  and the state of each tract. Postprocessing's `comstockpostproc/resources/utility_bill_states_by_sampling_region.csv`
  is built from these three files (`utility_bills_join.build_bill_state_table`); rebuild it when they change.
- `elec_rate_states.csv`: the state each rate file applies in, where known. A utility serving several
  states keeps every state's tariffs in one EIA id folder; URDB names such a utility's pages by state,
  "PacifiCorp (Oregon)". The measure bills a state under the rate files assigned to it plus the files
  assigned to no state, and under all of them if none is assigned to it. Rebuild the file after
  refreshing `elec_rates/` with

      python resources/build_elec_rate_states.py

  which reads each file's utility page name, the page's service territory on the OpenEI wiki and the
  states the utility serves in `tract_to_elec_util_v2.csv`, writes the CSV with the source of each
  assignment, and prints the conflicts and the unresolved multi-state pages for review. Every row's
  `source` says how its `state` was decided:

  | source | state | meaning |
  |---|---|---|
  | `openei_service_territory` | set | The OpenEI page of the rate's utility lists this one state as its service territory. |
  | `state_in_page_name` | set | The page name ends with the state in parentheses: "Alfalfa Electric Coop, Inc (Kansas)". |
  | `web_research` | set | A reviewer's decision for a page the records do not place (52 pages, 2026-10-16). Kept when the file is rebuilt, until a record decides the page or its rate files disappear. |
  | `single_state_utility` | set | The utility serves one state only. The filter cannot change its bills; the row records why no other source was needed. |
  | `unresolved` | blank | A multi-state utility's page with no record of its state and no review. Its rates apply in every state the utility serves, as all rates did before this file. No rows at present. |
  | `not_in_tract_map` | blank | No tract is served by this utility (the map names one utility per tract), so ComStock never bills it. |

  The generator never infers a state. Where a two-state utility names one page and not the other
  (Alfalfa Electric Coop serves Kansas and Oklahoma and names only its Kansas page), the unnamed
  page is probably the other state's, but nothing records it, so the generator leaves it
  `unresolved` and lists it for review. A reviewer settles such pages in the CSV with source
  `web_research` (Alfalfa's unnamed page is now Oklahoma), and the generator carries those rows
  forward on every rebuild until a record decides the page or its rate files disappear. A state
  word inside a name is not read either (Washington Electric Coop is in Vermont); the generator
  lists the names that disagree with the tract map as a check on the map. The build is
  deterministic for a given set of rate files, tract map, wiki answers and reviewed rows: rebuilding
  today reproduces the committed file byte for byte. Runs use the committed CSV, so the wiki is
  consulted only when the file is rebuilt (`--no-wiki` skips it and keeps the committed
  service-territory rows). `tests/utility_bills_test.rb` checks the CSV covers exactly the rate
  files present.

Regenerating `measure.xml` with the OpenStudio CLI drops the JSON resource entries from its file
list; update the changed files' checksums by hand instead.
