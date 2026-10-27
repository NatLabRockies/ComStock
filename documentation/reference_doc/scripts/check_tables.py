"""Check the generated tables for rows that do not match their column specification.

    python documentation/reference_doc/scripts/check_tables.py
"""
import os
import re
import sys

TABLES = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tables'))
GENERATED = [
    'space_type_ratios_all.tex', 'space_type_ratios.tex', 'occupancy_density_all.tex', 'ventilation_rates.tex',
    'epds.tex', 'gas_equip.tex', 'swh_flow_rates.tex', 'thermostat_setpoints_space_types.tex',
    'exhaust_rates.tex', 'parametric_schedule_sets.tex', 'kitchen_floor_area.tex'
]

problems = 0
for name in GENERATED:
    with open(os.path.join(TABLES, name), encoding='utf-8') as fh:
        t = fh.read()
    spec = re.search(r'\\begin\{(?:longtable|tabular)\}(?:\[[^\]]*\])?\s*\{([^\n]*)\}', t)
    cols = len(re.findall(r'p\{|[lcr](?![a-z])', spec.group(1))) if spec else 0
    rows = [l for l in t.split('\n')
            if re.search(r'\\\\\s*\\hline\s*$', l) and not re.search(r'caption|endhead|endfirsthead|multicolumn', l)]
    bad = [l for l in rows if len(re.findall(r'(?<!\\)&', l)) != cols - 1]
    braces = t.count('{') - t.count('}')
    unescaped = [l for l in t.split('\n')
                 if re.search(r'(?<!\\)[%#]|(?<!\\)_(?![^{]*\})', l) and not re.match(r'^\s*%', l)][:2]
    note = 'CHECK: ' + unescaped[0][:80] if unescaped else ''
    print(f'{name:<40} cols {cols} rows {len(rows)} bad rows {len(bad)} brace balance {braces} {note}')
    if bad:
        print('   e.g.', bad[0][:120])
    problems += len(bad) + (1 if braces else 0)
sys.exit(1 if problems else 0)
