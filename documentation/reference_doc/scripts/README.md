# Reference documentation scripts

Scripts that generate the data-driven tables and figures in the reference documentation,
plus two checks to run before compiling. The generated tables and figures are committed,
so these only need to run again when the data they read changes.

All scripts locate the ComStock repository relative to this folder. The ComStock-Typical
gem is expected as a sibling checkout (`../ComStock-Typical` next to the ComStock repo);
set `COMSTOCK_TYPICAL_DIR` to point somewhere else.

## Tables

`gen_tables.py` reads `resources/create_custom/comstock_building_types.json` and the
ComStock-Typical data files and rewrites these files in `../tables/`:

| Table file | Source |
| --- | --- |
| `space_type_ratios.tex`, `space_type_ratios_all.tex` | building type space type ratios |
| `occupancy_density_all.tex` | occupancy data |
| `ventilation_rates.tex` | ventilation space type data |
| `epds.tex`, `gas_equip.tex` | electric and gas equipment data |
| `swh_flow_rates.tex` | typical water use equipment |
| `thermostat_setpoints_space_types.tex` | thermostat setpoints |
| `exhaust_rates.tex` | typical exhaust and makeup air |
| `parametric_schedule_sets.tex` | parametric schedule sets |
| `kitchen_floor_area.tex` | kitchen fractions from the space type ratios |

```bash
python documentation/reference_doc/scripts/gen_tables.py
```

## Parametric schedule figures

The occupancy profile figures (`parametric_occupancy_1.png`, `_2.png`, `_weekend.png`)
must come from the gem's own schedule expansion, not a reimplementation, so there are
two steps. First export the expanded profiles with the OpenStudio CLI and the gem on the
load path:

```bash
openstudio -I ../ComStock-Typical/lib documentation/reference_doc/scripts/export_profiles.rb documentation/reference_doc/scripts/profiles.json
```

Then plot them (matplotlib is the only non-standard dependency across these scripts):

```bash
python documentation/reference_doc/scripts/plot_profiles.py documentation/reference_doc/scripts/profiles.json
```

`profiles.json` is an intermediate file and is not committed.

## Checks

Run both before compiling the document:

```bash
python documentation/reference_doc/scripts/check_refs.py
```

Reports `\ref` targets with no `\label`, missing figure files, missing `\input` files,
and labels defined more than once.

```bash
python documentation/reference_doc/scripts/check_tables.py
```

Reports generated tables whose rows do not match the column specification, unbalanced
braces, and unescaped `%`, `#`, or `_` characters.
