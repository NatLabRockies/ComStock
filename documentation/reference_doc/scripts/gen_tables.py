"""Regenerate the data-driven reference-doc tables.

Reads resources/create_custom/comstock_building_types.json and the ComStock-Typical data
files and rewrites the generated .tex files in ../tables/. Run from anywhere:

    python documentation/reference_doc/scripts/gen_tables.py

The gem is expected as a sibling checkout of the ComStock repo (../ComStock-Typical);
set COMSTOCK_TYPICAL_DIR to use another location.
"""
import json
import os
import re
from decimal import ROUND_HALF_UP, Decimal

HERE = os.path.dirname(os.path.abspath(__file__))
DOC = os.path.abspath(os.path.join(HERE, '..'))
REPO = os.path.abspath(os.path.join(DOC, '..', '..'))
GEM = os.environ.get('COMSTOCK_TYPICAL_DIR') or os.path.abspath(os.path.join(REPO, '..', 'ComStock-Typical'))
G = os.path.join(GEM, 'lib', 'openstudio-standards')
OUT = os.path.join(DOC, 'tables')


def load(*parts):
    with open(os.path.join(*parts), encoding='utf-8') as f:
        return json.load(f)


spec = load(REPO, 'resources', 'create_custom', 'comstock_building_types.json')
all_types = load(G, 'space_type', 'data', 'all_level_space_types.json')
by_name = {r['space_type_name']: r for r in all_types}
occ = load(G, 'occupancy', 'data', 'typical_space_type_occupancy.json')
vent = load(G, 'ventilation', 'data', 'ventilation_space_type_data.json')
eq = load(G, 'equipment', 'data', 'electric_equipment_space_types.json')
gas = load(G, 'equipment', 'data', 'gas_equipment_space_types.json')
exh = load(G, 'hvac', 'exhaust', 'data', 'typical_exhaust.json')
swh = load(G, 'service_water_heating', 'data', 'typical_water_use_equipment.json')
tst = load(G, 'thermal_zone', 'data', 'thermostat_setpoints.json')['space_types']
sets = load(G, 'schedules', 'data', 'default_parametric_schedule_set.json')
occ_sch = load(G, 'schedules', 'data', 'default_occupancy_schedules.json')
ltg_sch = load(G, 'schedules', 'data', 'default_lighting_schedules.json')
eq_sch = load(G, 'schedules', 'data', 'default_electric_equipment_schedules.json')
gas_sch = load(G, 'schedules', 'data', 'default_gas_equipment_schedules.json')
hw_sch = load(G, 'schedules', 'data', 'default_hot_water_equipment_schedules.json')


def js(v):
    """Render a JSON value the way a JavaScript template literal would."""
    if v is None:
        return 'null'
    if v is True:
        return 'true'
    if v is False:
        return 'false'
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def esc(s):
    s = js(s)
    s = s.replace('\\', '\\textbackslash{}')
    s = re.sub(r'([&%$#_{}])', r'\\\1', s)
    return s.replace('~', '\\~{}')


def num(v, d=2):
    """Fixed-point number with trailing zeros stripped; '--' for missing values."""
    if v is None or v == '' or isinstance(v, bool):
        return '--'
    try:
        x = float(v)
    except (TypeError, ValueError):
        return '--'
    if x != x:
        return '--'
    q = Decimal(1).scaleb(-d) if d > 0 else Decimal(1)
    s = str(Decimal(x).quantize(q, rounding=ROUND_HALF_UP))
    if '.' in s:
        s = s.rstrip('0').rstrip('.')
    return s


pretty = {
    'FullServiceRestaurant': 'Full Service Restaurant', 'Hospital': 'Hospital', 'LargeHotel': 'Large Hotel',
    'LargeOffice': 'Large Office', 'MediumOffice': 'Medium Office', 'Outpatient': 'Outpatient',
    'PrimarySchool': 'Primary School', 'QuickServiceRestaurant': 'Quick Service Restaurant',
    'RetailStandalone': 'Retail Standalone', 'RetailStripmall': 'Retail Strip Mall',
    'SecondarySchool': 'Secondary School', 'SmallHotel': 'Small Hotel', 'SmallOffice': 'Small Office',
    'SuperMarket': 'Grocery', 'Warehouse': 'Warehouse'
}
BT = list(pretty)
BTYPES = spec['building_types']


def fam_name(templates):
    if len(templates) == 18:
        return 'All'
    if any('90.1-2004' in t for t in templates):
        return '90.1-2004 and later; DEER 2007 and later'
    return 'DOE Ref; DEER 2003 and earlier'


used = set()
for b in BT:
    for r in BTYPES[b]['space_type_ratios']:
        used.update(r['space_types'].keys())
used_list = sorted(used)


def pick(records, tpl):
    for r in records or []:
        if r.get('templates') and tpl in r['templates']:
            return r
    return None


def short_src(s):
    if not s:
        return '--'
    first = s.split(';')[0].strip()
    m = re.match(r'^(ASHRAE 62[^|]*)\|\s*([^|]+)\|\s*(.+)$', first)
    if m:
        return f'{m.group(1).strip()}, {m.group(3).strip()}'
    return first[:57] + '...' if len(first) > 60 else first


def write(name, template, rows):
    with open(os.path.join(OUT, name), 'w', encoding='utf-8', newline='\n') as f:
        f.write(template.replace('@ROWS@', rows))


def sort_key(bt):
    # approximates String.prototype.localeCompare: case-insensitive primary order
    s = js(bt)
    return (s.lower(), s)


# ---------------------------------------------------------------- space type ratios (all)
rows = ''
for b in BT:
    for r in BTYPES[b]['space_type_ratios']:
        sub = 'default' if r['building_subtype'] == 'NA' else r['building_subtype']
        for st, v in r['space_types'].items():
            flags = [
                'default' if v.get('default') else '',
                'circulation' if v.get('circ') else '',
                'no geometry' if v.get('space_type_gen') is False else '',
                f"{js(v['story_height'])} ft story" if v.get('story_height') else '',
                f"WWR {js(v['wwr'])}" if 'wwr' in v else ''
            ]
            flags = ', '.join(x for x in flags if x)
            rows += f"{esc(pretty[b])} & {esc(sub)} & {esc(fam_name(r['applicable_templates']))} & {esc(st)} & {num(v['ratio'], 4)} & {esc(flags)} \\\\ \\hline\n"
write('space_type_ratios_all.tex', r"""\begin{center}
\scriptsize
\begin{longtable}{|p{1.0in}|p{1.05in}|p{1.1in}|p{1.9in}|p{0.55in}|p{0.95in}|}
\caption[Space Type Ratios]{Space type ratios for every ComStock building type, subtype, and template family. Space types are space type names. A building-type-qualified name (``corridor - hospital'') carries its own schedules or loads; an unqualified name shares the stock-wide record for that use. The ``default'' space type absorbs floor area released by the minimum-area constraints, and the ``circulation'' space type is placed as a double-loaded corridor.} \\ \hline
\label{tab:space_type_ratios_all}
\textbf{Building Type} & \textbf{Subtype} & \textbf{Templates} & \textbf{Space Type} & \textbf{Fraction of Floor Area} & \textbf{Flags} \\ \hline
\endfirsthead
\multicolumn{6}{c}{{\bfseries \textit{Continued from previous page}}} \\ \hline
\textbf{Building Type} & \textbf{Subtype} & \textbf{Templates} & \textbf{Space Type} & \textbf{Fraction of Floor Area} & \textbf{Flags} \\ \hline
\endhead
@ROWS@\end{longtable}
\end{center}
""", rows)

# ---------------------------------------------------------------- space type ratios (example)
rows = ''
for b, sub in [('SmallOffice', 'NA'), ('Warehouse', 'NA'), ('Warehouse', 'warehouse_bulk20')]:
    r = next(x for x in BTYPES[b]['space_type_ratios'] if x['building_subtype'] == sub)
    for st, v in r['space_types'].items():
        rows += f"{esc(pretty[b])} & {esc('default' if sub == 'NA' else sub)} & {esc(st)} & {num(100 * v['ratio'], 1)}\\% \\\\ \\hline\n"
write('space_type_ratios.tex', r"""\begin{table}
\small
\caption[Space Type Ratio Example]{Space Type Ratio Examples}
\label{tab:space_type_ratios}
\centering
\begin{tabular}{|l|l|l|c|}
\hline
\textbf{Building Type} & \textbf{Building Subtype} & \textbf{Space Type} & \textbf{Ratio} \\ \hline
@ROWS@\end{tabular}
\end{table}
""", rows)

# ---------------------------------------------------------------- occupancy density
rows = ''
for n in used_list:
    key = by_name[n]['ventilation_space_type_name']
    o19 = pick(occ.get(key), 'ComStock 90.1-2019')
    oref = pick(occ.get(key), 'ComStock DOE Ref Pre-1980')
    ov = []
    for b in BT:
        for o in BTYPES[b].get('occupancy_overrides') or []:
            if o['space_type'] == n:
                ov.append(f"{pretty[b]}: {js(o['occupancy']['people_per_1000_ft2'])}")
    src = esc(short_src(o19 and o19.get('source')))
    if ov:
        src += '; override ' + esc(', '.join(ov))
    rows += f"{esc(n)} & {num(o19 and o19.get('occupancy_per_area'), 2)} & {num(oref and oref.get('occupancy_per_area'), 2)} & {src} \\\\ \\hline\n"
write('occupancy_density_all.tex', r"""\begin{center}
\scriptsize
\begin{longtable}{|p{2.1in}|p{0.85in}|p{0.85in}|p{2.5in}|}
\caption[Occupant Density by Space Type]{Occupant density (people per 1,000 ft\textsuperscript{2}) by space type. The 90.1 column applies to the ASHRAE 90.1-2004 and later and DEER 2007 and later templates; the DOE Ref column applies to the DOE Ref and earlier DEER templates. Building-type overrides from the ComStock building type definitions are noted where they apply.} \\ \hline
\label{tab:occupancy_density_all}
\textbf{Space Type} & \textbf{90.1 Templates} & \textbf{DOE Ref Templates} & \textbf{Source} \\ \hline
\endfirsthead
\multicolumn{4}{c}{{\bfseries \textit{Continued from previous page}}} \\ \hline
\textbf{Space Type} & \textbf{90.1 Templates} & \textbf{DOE Ref Templates} & \textbf{Source} \\ \hline
\endhead
@ROWS@\end{longtable}
\end{center}
""", rows)

# ---------------------------------------------------------------- ventilation rates


def vent_text(v):
    if not v:
        return '--'
    s = f"{num(v.get('ventilation_per_person'), 2)} / {num(v.get('ventilation_per_area'), 3)}"
    if v.get('ventilation_air_changes'):
        s += ' / ' + num(v['ventilation_air_changes'], 2) + ' ACH'
    return s


rows = ''
for n in used_list:
    key = by_name[n]['ventilation_space_type_name']
    v19 = pick(vent.get(key), 'ComStock 90.1-2019')
    vref = pick(vent.get(key), 'ComStock DOE Ref Pre-1980')
    rows += f"{esc(n)} & {vent_text(v19)} & {vent_text(vref)} & {esc(short_src(v19 and v19.get('source')))} \\\\ \\hline\n"
write('ventilation_rates.tex', r"""\begin{center}
\scriptsize
\begin{longtable}{|p{2.1in}|p{1.05in}|p{1.05in}|p{2.1in}|}
\caption[Design Outdoor Air Rates by Space Type]{Design outdoor air rates by space type, as cfm per person / cfm per ft\textsuperscript{2}. The 90.1 column applies to the ASHRAE 90.1-2004 and later and DEER 2007 and later templates; the DOE Ref column applies to the DOE Ref and earlier DEER templates, which carry the ventilation rates of the reference building models of their era. A space type with zero in both columns receives no outdoor air through its ventilation requirement.} \\ \hline
\label{tab:ventilation_rates}
\textbf{Space Type} & \textbf{90.1 Templates (cfm/person / cfm/ft\textsuperscript{2})} & \textbf{DOE Ref Templates (cfm/person / cfm/ft\textsuperscript{2})} & \textbf{Source} \\ \hline
\endfirsthead
\multicolumn{4}{c}{{\bfseries \textit{Continued from previous page}}} \\ \hline
\textbf{Space Type} & \textbf{90.1 Templates} & \textbf{DOE Ref Templates} & \textbf{Source} \\ \hline
\endhead
@ROWS@\end{longtable}
\end{center}
""", rows)

# ---------------------------------------------------------------- electric equipment power density


def is_comstock(bt):
    return bt is None or bt == '*' or bt in BT or bt in ('Office', 'Retail', 'StripMall')


rows = ''
for n in used_list:
    name = by_name[n].get('electric_equipment_space_type_name')
    matches = [r for r in eq if r.get('electric_equipment_space_type_name') == name
               and r.get('electric_equipment_per_area') is not None and is_comstock(r.get('standards_building_type'))]
    if not matches:
        rows += f"{esc(n)} & -- & -- & -- & -- & -- \\\\ \\hline\n"
        continue
    matches.sort(key=lambda r: sort_key(r.get('standards_building_type')))
    for i, r in enumerate(matches):
        bt = r.get('standards_building_type')
        bt = 'any' if bt is None or bt == '*' else bt
        rows += f"{esc(n) if i == 0 else ''} & {esc(bt)} & {num(r['electric_equipment_per_area'], 2)} & {num(r.get('electric_equipment_fraction_radiant'), 2)} & {num(r.get('electric_equipment_fraction_latent'), 2)} & {num(r.get('electric_equipment_fraction_lost'), 2)} \\\\ \\hline\n"
write('epds.tex', r"""\begin{center}
\scriptsize
\begin{longtable}{|p{2.2in}|p{1.3in}|p{0.7in}|p{0.6in}|p{0.6in}|p{0.6in}|}
\caption[Electric Equipment Power Density]{Electric equipment power density by space type. Where the source data distinguishes a building type, the row matching the model's primary building type is used; ``any'' rows apply to every building type; a space type with no row for the building type uses the median across the building types that have one. Densities do not vary by template.} \\ \hline
\label{tab:epds}
\textbf{Space Type} & \textbf{Building Type} & \textbf{EPD (W/ft\textsuperscript{2})} & \textbf{Fraction Radiant} & \textbf{Fraction Latent} & \textbf{Fraction Lost} \\ \hline
\endfirsthead
\multicolumn{6}{c}{{\bfseries \textit{Continued from previous page}}} \\ \hline
\textbf{Space Type} & \textbf{Building Type} & \textbf{EPD (W/ft\textsuperscript{2})} & \textbf{Fraction Radiant} & \textbf{Fraction Latent} & \textbf{Fraction Lost} \\ \hline
\endhead
@ROWS@\end{longtable}
\end{center}
""", rows)

# ---------------------------------------------------------------- gas equipment
rows = ''
for n in used_list:
    name = by_name[n].get('natural_gas_equipment_space_type_name')
    if not name:
        continue
    matches = [r for r in gas if r.get('natural_gas_equipment_space_type_name') == name
               and r.get('gas_equipment_per_area') is not None
               and (r.get('standards_building_type') in BT or r.get('standards_building_type') in (None, '*'))]
    matches.sort(key=lambda r: sort_key(r.get('standards_building_type')))
    for i, r in enumerate(matches):
        rows += f"{esc(n) if i == 0 else ''} & {esc(r.get('standards_building_type') or 'any')} & {num(r['gas_equipment_per_area'], 1)} & {num(r.get('gas_equipment_fraction_radiant'), 2)} & {num(r.get('gas_equipment_fraction_latent'), 2)} & {num(r.get('gas_equipment_fraction_lost'), 2)} \\\\ \\hline\n"
write('gas_equip.tex', r"""\begin{table}[h!]
\scriptsize
\centering
\caption[Gas Equipment Power Density]{Gas equipment power density (Btu/hr-ft\textsuperscript{2}) by space type. Kitchen (food preparation) values are the placeholder loads that the kitchen equipment measure replaces with counted appliances, as described in Section~\ref{sec:kitchen_equipment}.}
\label{tab:gas_equip}
\begin{tabular}{|p{2.2in}|p{1.3in}|r|r|r|r|}
\hline
\textbf{Space Type} & \textbf{Building Type} & \textbf{Btu/hr-ft\textsuperscript{2}} & \textbf{Radiant} & \textbf{Latent} & \textbf{Lost} \\ \hline
@ROWS@\end{tabular}
\end{table}
""", rows)

# ---------------------------------------------------------------- service water heating draws
rows = ''
for n in used_list:
    recs = [r for r in swh['space_types'] if n in (r.get('all_level_space_types') or [])]
    overrides = []
    for b in BT:
        for o in BTYPES[b].get('service_water_heating_overrides') or []:
            if o['space_type'] == n:
                overrides.append((b, o['equipment']))
    if not recs and not overrides:
        continue
    first = True
    for r in recs:
        for w in r['water_use_equipment']:
            rows += f"{esc(n) if first else ''} & stock ({esc(js(r.get('building_type')) + ' ' + js(r.get('space_type')))}) & {esc(w.get('equipment_name') or 'general')} & {num(w.get('peak_flow_rate_gph_per_floor_area_ft2'), 5)} & {esc(w.get('loop_type') or '--')} & {num(w.get('mixed_water_temperature_f'), 0)} \\\\ \\hline\n"
            first = False
    for b, e in overrides:
        for k, v in e.items():
            temp = num(v['mixed_water_temperature_f'], 0) if v.get('mixed_water_temperature_f') else 'as stock'
            rows += f"{esc(n) if first else ''} & {esc(pretty[b])} override & {esc('general' if k == '*' else k)} & {num(v.get('peak_flow_rate_gph_per_floor_area_ft2'), 5)} & {esc(v.get('loop_type') or 'as stock')} & {temp} \\\\ \\hline\n"
            first = False
write('swh_flow_rates.tex', r"""\begin{center}
\scriptsize
\begin{longtable}{|p{1.7in}|p{1.6in}|p{0.9in}|p{0.7in}|p{0.75in}|p{0.55in}|}
\caption[Service Water Heating Draws by Space Type]{Service water heating draws by space type: the stock record each space type resolves to, and the building-type overrides the ComStock building type definitions apply on top of it. Peak flow is gal/h per ft\textsuperscript{2} of the space's floor area. ``Shared'' draws are served by the building water heater, ``One Per Space'' draws by a point-of-use heater in the space, and ``Dishwasher Booster'' draws by the 180\textdegree F booster loop.} \\ \hline
\label{tab:swh_flow_rates}
\textbf{Space Type} & \textbf{Record} & \textbf{Equipment} & \textbf{Peak Flow (gal/h-ft\textsuperscript{2})} & \textbf{Loop} & \textbf{Mixed Temp. (\textdegree F)} \\ \hline
\endfirsthead
\multicolumn{6}{c}{{\bfseries \textit{Continued from previous page}}} \\ \hline
\textbf{Space Type} & \textbf{Record} & \textbf{Equipment} & \textbf{Peak Flow} & \textbf{Loop} & \textbf{Mixed Temp.} \\ \hline
\endhead
@ROWS@\end{longtable}
\end{center}
""", rows)

# ---------------------------------------------------------------- thermostat setpoints by space type


def f2(c):
    return num(c * 9 / 5 + 32, 1)


def d2(k):
    return num(k * 9 / 5, 1)


rows = ''
for n in used_list:
    t = next((r for r in tst if r['space_type_name'] == n), None)
    inherited = False
    if t is None and ' - ' in n:
        base = n.split(' - ')[0]
        t = next((r for r in tst if r['space_type_name'] == base), None)
        inherited = True
    if t is None:
        rows += f"{esc(n)} & -- & -- & -- & -- & no record \\\\ \\hline\n"
        continue
    src = (t.get('source_building_type') or 'curated') + (' (via base type)' if inherited else '')
    rows += f"{esc(n)} & {f2(t['heating_setpoint_c'])} & {d2(t['heating_setback_delta_c'])} & {f2(t['cooling_setpoint_c'])} & {d2(t['cooling_setback_delta_c'])} & {esc(src)} \\\\ \\hline\n"
write('thermostat_setpoints_space_types.tex', r"""\begin{center}
\scriptsize
\begin{longtable}{|p{2.2in}|p{0.7in}|p{0.7in}|p{0.7in}|p{0.7in}|p{1.2in}|}
\caption[Stock Thermostat Setpoints by Space Type]{Stock thermostat setpoints and unoccupied setback deltas by space type (\textdegree F). These are the values a space type carries before any sampled setpoint or setback is applied; a setback delta of zero means the space type holds its setpoint around the clock and never receives a sampled setback. The source column names the building type whose prototype thermostat schedules the record was derived from.} \\ \hline
\label{tab:thermostat_setpoints_space_types}
\textbf{Space Type} & \textbf{Heating Setpoint} & \textbf{Heating Setback Delta} & \textbf{Cooling Setpoint} & \textbf{Cooling Setback Delta} & \textbf{Source} \\ \hline
\endfirsthead
\multicolumn{6}{c}{{\bfseries \textit{Continued from previous page}}} \\ \hline
\textbf{Space Type} & \textbf{Heating Setpoint} & \textbf{Heating Setback Delta} & \textbf{Cooling Setpoint} & \textbf{Cooling Setback Delta} & \textbf{Source} \\ \hline
\endhead
@ROWS@\end{longtable}
\end{center}
""", rows)

# ---------------------------------------------------------------- exhaust
rows = ''
for n in used_list:
    ex = next((r for r in exh['space_types'] if n in (r.get('all_level_space_types') or [])), None)
    ov = []
    for b in BT:
        for o in BTYPES[b].get('exhaust_overrides') or []:
            if o['space_type'] == n:
                ov.append(f"{pretty[b]}: {js(o['exhaust']['exhaust_per_area'])}")
    if ex is None and not ov:
        continue
    rate = num(ex['exhaust_per_area'], 2) if ex else '--'
    src = esc(js(ex.get('building_type')) + ' ' + js(ex.get('space_type'))) if ex else '--'
    rows += f"{esc(n)} & {rate} & {src} & {esc(', '.join(ov) or '--')} \\\\ \\hline\n"
write('exhaust_rates.tex', r"""\begin{table}[h!]
\scriptsize
\centering
\caption[Zone Exhaust Rates by Space Type]{Zone exhaust rates (cfm per ft\textsuperscript{2} of space floor area) by space type, the prototype record each rate was carried over from, and the building-type overrides applied by the ComStock building type definitions. Kitchen exhaust draws half of its makeup air from the adjacent dining space.}
\label{tab:exhaust_rates}
\begin{tabular}{|p{2.2in}|p{0.8in}|p{1.6in}|p{1.4in}|}
\hline
\textbf{Space Type} & \textbf{Exhaust (cfm/ft\textsuperscript{2})} & \textbf{Carried Over From} & \textbf{Override} \\ \hline
@ROWS@\end{tabular}
\end{table}
""", rows)

# ---------------------------------------------------------------- parametric schedule sets
occ_by_name = {r['name']: r for r in occ_sch if r.get('day_types') == 'Default'}


def rec_by_name(records):
    return {r['name']: r for r in records if not r.get('day_types') or r['day_types'] == 'Default'}


L, E, Gs, H = rec_by_name(ltg_sch), rec_by_name(eq_sch), rec_by_name(gas_sch), rec_by_name(hw_sch)
PROV = {'pnnl_support': 'PNNL support data', 'comstock_2019': 'ComStock prototype schedule', 'legacy': 'legacy prototype', 'authored': 'authored'}


def prov(p):
    if not p:
        return '--'
    k = p.split(':')[0].strip()
    return PROV.get(k, k)


def der(r):
    if not r:
        return '--'
    if r.get('type') == 'parametric' or not r.get('derivation_type'):
        return f"control points, {js(r.get('st_std'))}--{js(r.get('et_std'))} h, {num(r.get('base_std'), 2)}--{num(r.get('peak_std'), 2)}"
    s = f"{r['derivation_type']}, {num(r.get('base'), 2)}--{num(r.get('peak'), 2)}"
    if r.get('response') is not None:
        s += ', r ' + num(r['response'], 2)
    return s


rows = ''
for n in used_list:
    a = by_name[n]
    s = next((x for x in sets if x['schedule_set_name'] == a.get('schedule_set_name')), None)
    if s is None:
        rows += f"{esc(n)} & -- & -- & -- & -- & -- \\\\ \\hline\n"
        continue
    o = occ_by_name.get(s.get('occupancy_schedule'))
    if o:
        occ_txt = f"{js(o['st_std'])}--{js(o['et_std'])} h, {num(o['base_std'], 2)}--{num(o['peak_std'], 2)}, {len(o['control_points'])} points ({prov(s.get('occupancy_provenance'))})"
    else:
        occ_txt = 'none (unoccupied)'
    rows += f"{esc(n)} & {esc(occ_txt)} & {esc(der(L.get(s.get('interior_lighting_schedule'))))} & {esc(der(E.get(s.get('electric_equipment_schedule'))))} & {esc(der(Gs.get(s.get('gas_equipment_schedule'))))} & {esc(der(H.get(s.get('hot_water_equipment_schedule'))))} \\\\ \\hline\n"
write('parametric_schedule_sets.tex', r"""\begin{center}
\scriptsize
\begin{longtable}{|p{1.5in}|p{1.6in}|p{0.95in}|p{0.95in}|p{0.8in}|p{0.8in}|}
\caption[Parametric Schedule Sets by Space Type]{Parametric schedule sets by space type. Occupancy lists the standalone start and end hour, the base and peak fractions, the number of control points, and the provenance of the fitted profile. Each load column lists the derivation type, the base and peak fractions, and the response parameter (r) where the derivation uses one.} \\ \hline
\label{tab:parametric_schedule_sets}
\textbf{Space Type} & \textbf{Occupancy} & \textbf{Lighting} & \textbf{Electric Equipment} & \textbf{Gas Equipment} & \textbf{Hot Water} \\ \hline
\endfirsthead
\multicolumn{6}{c}{{\bfseries \textit{Continued from previous page}}} \\ \hline
\textbf{Space Type} & \textbf{Occupancy} & \textbf{Lighting} & \textbf{Electric Equipment} & \textbf{Gas Equipment} & \textbf{Hot Water} \\ \hline
\endhead
@ROWS@\end{longtable}
\end{center}
""", rows)

# ---------------------------------------------------------------- kitchen floor area
rows = ''
for b in BT:
    r = next(x for x in BTYPES[b]['space_type_ratios'] if x['building_subtype'] == 'NA')
    for st, v in r['space_types'].items():
        if st.startswith('food preparation'):
            rows += f"{esc(pretty[b])} & {esc(st)} & {num(100 * v['ratio'], 1)}\\% \\\\ \\hline\n"
write('kitchen_floor_area.tex', r"""\begin{table}[h!]
\small
\centering
\caption[Kitchen Space Type Percentage of Total Floor Area]{Kitchen (food preparation) space type percentage of total floor area}
\label{tab:kitchen_floor_area}
\begin{tabular}{|l|l|l|}
\hline
\textbf{Building Type} & \textbf{Space Type} & \textbf{Percentage of Total Floor Area} \\ \hline
@ROWS@\end{tabular}
\end{table}
""", rows)

print('tables written; used space types:', len(used_list))
