# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Build elec_rate_states.csv: the state each URDB rate file in elec_rates/ applies in.

The utility_bills measure bills a building, for each state its sampling region can land in, under the
rate files of the utility serving its tract. A utility serving several states (PacifiCorp, MidAmerican,
Dominion) keeps its tariffs for every state in one EIA id folder, so without this file a Utah building
is billed under Oregon tariffs too. URDB splits such a utility into one page per state, "PacifiCorp
(Oregon)", and the rate file carries that page name; the page's state is the rate's state.

Each rate gets a state from the first source that decides it:
  1. openei_service_territory      the ServiceTerritory property of the rate's utility page on the
                                   OpenEI wiki, when it names exactly one state (needs network; skipped
                                   with --no-wiki or when the wiki is unreachable)
  2. state_in_page_name            a state in parentheses at the end of the utility page name,
                                   "Alfalfa Electric Coop, Inc (Kansas)"
  3. web_research                  a reviewer's decision for a page the records do not place, kept from
                                   the committed CSV when the file is rebuilt (a page keeps its reviewed
                                   state until a reviewer changes it or the page's rate files disappear)
  4. single_state_utility          the utility serves tracts in one state only (tract_to_elec_util_v2.csv):
                                   its rates are that state's (the filter cannot change its bills; the
                                   row documents it)
  unresolved                       a multi-state utility's page with no record of its state, or a
                                   conflict between 1 and 2: blank, the rate applies in every state the
                                   utility serves, as all rates did before this file
  not_in_tract_map                 no tract is served by the utility, so ComStock never bills it: blank
A state is never inferred by the script. Where a two-state utility has one named page and one unnamed,
the unnamed page is probably the other state's (Alfalfa Electric Coop serves Kansas and Oklahoma and
names only its Kansas page), but nothing records it, so the script leaves it unresolved and lists it;
a reviewer settles such pages in the CSV with source web_research, and those rows survive rebuilds. A state in a utility's name is not read either (Washington Electric Coop is in Vermont,
Howell-Oregon in Missouri); the report lists where such a word disagrees with the tract map.
A rate with a state applies only in that state; a rate with none applies everywhere; a state left with
no rate file keeps all of them (the measure logs a warning). Run this after refreshing the rate files
from URDB, review the report it prints (conflicts and unresolved multi-state pages), and commit the
CSV. The measure's test checks the CSV covers exactly the rate files present.

    python build_elec_rate_states.py [--no-wiki]
"""
import argparse
import csv
import glob
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'elec_rate_states.csv')
COLUMNS = ['label', 'eia_id', 'utility', 'state', 'source']
SOURCES = {'openei_service_territory', 'state_in_page_name', 'web_research', 'single_state_utility', 'unresolved',
           'not_in_tract_map'}
MANUAL_SOURCE = 'web_research'
STATES = {'Alabama': 'AL', 'Alaska': 'AK', 'Arizona': 'AZ', 'Arkansas': 'AR', 'California': 'CA', 'Colorado': 'CO',
          'Connecticut': 'CT', 'Delaware': 'DE', 'District of Columbia': 'DC', 'Florida': 'FL', 'Georgia': 'GA',
          'Hawaii': 'HI', 'Idaho': 'ID', 'Illinois': 'IL', 'Indiana': 'IN', 'Iowa': 'IA', 'Kansas': 'KS',
          'Kentucky': 'KY', 'Louisiana': 'LA', 'Maine': 'ME', 'Maryland': 'MD', 'Massachusetts': 'MA',
          'Michigan': 'MI', 'Minnesota': 'MN', 'Mississippi': 'MS', 'Missouri': 'MO', 'Montana': 'MT',
          'Nebraska': 'NE', 'Nevada': 'NV', 'New Hampshire': 'NH', 'New Jersey': 'NJ', 'New Mexico': 'NM',
          'New York': 'NY', 'North Carolina': 'NC', 'North Dakota': 'ND', 'Ohio': 'OH', 'Oklahoma': 'OK',
          'Oregon': 'OR', 'Pennsylvania': 'PA', 'Rhode Island': 'RI', 'South Carolina': 'SC', 'South Dakota': 'SD',
          'Tennessee': 'TN', 'Texas': 'TX', 'Utah': 'UT', 'Vermont': 'VT', 'Virginia': 'VA', 'Washington': 'WA',
          'West Virginia': 'WV', 'Wisconsin': 'WI', 'Wyoming': 'WY'}
WIKI_API = 'https://openei.org/w/api.php'


def rate_files():
    """(label, eia id, utility name) for every rate file."""
    out = []
    for path in sorted(glob.glob(os.path.join(HERE, 'elec_rates', '*', '*.json'))):
        with open(path, encoding='utf-8') as f:
            rate = json.load(f)
        label = os.path.basename(path)[:-5]
        eia = int(os.path.basename(os.path.dirname(path)))
        if rate.get('label') != label or int(rate.get('eiaid', eia)) != eia:
            raise ValueError(f'{path}: label {rate.get("label")!r} or eiaid {rate.get("eiaid")!r} does not match its path')
        out.append((label, eia, (rate.get('utility') or '').strip()))
    return out


def served_states():
    """The states each utility serves tracts in, from the measure's tract-to-utility map."""
    with open(os.path.join(HERE, 'state_abbrev_to_fips.json'), encoding='utf-8') as f:
        fips_to_state = {}
        for abbrev, fips in json.load(f).items():
            fips_to_state.setdefault(fips, abbrev)
    served = defaultdict(Counter)
    with open(os.path.join(HERE, 'tract_to_elec_util_v2.csv'), encoding='utf-8', newline='') as f:
        reader = csv.reader(f)
        next(reader)
        for tract, eia in reader:
            state = fips_to_state.get(tract[1:3])  # a few tracts carry a non-state code
            if eia and state:
                served[int(eia)][state] += 1
    return served


def state_in_name(utility):
    m = re.search(r'\(([^()]+)\)\s*$', utility)
    return STATES.get(m.group(1).strip()) if m else None


def wiki_territories(eia_ids):
    """utility page name -> states in its ServiceTerritory property, for the given EIA ids."""
    territories = {}
    for i, eia in enumerate(sorted(eia_ids)):
        query = urllib.parse.quote(f'[[EiaUtilityId::{eia}]]|?ServiceTerritory|limit=100', safe='')
        req = urllib.request.Request(f'{WIKI_API}?action=ask&query={query}&format=json',
                                     headers={'User-Agent': 'ComStock utility_bills build_elec_rate_states'})
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
        for page, result in data.get('query', {}).get('results', {}).items():
            values = result.get('printouts', {}).get('ServiceTerritory', [])
            names = {(v.get('fulltext') if isinstance(v, dict) else str(v)).split('#')[0] for v in values}
            territories[page] = sorted(STATES[n] for n in names if n in STATES)
        time.sleep(0.2)
    return territories


def committed_decisions(source):
    """Pages the committed CSV places with the given source: (eia id, utility page) -> state."""
    if not os.path.exists(OUT):
        return {}
    decided = {}
    with open(OUT, encoding='utf-8', newline='') as f:
        for row in csv.DictReader(f):
            if row.get('source') == source and row.get('state'):
                decided[(int(row['eia_id']), row['utility'])] = row['state']
    return decided


def committed_newline():
    """The committed CSV's line ending, so a rebuild changes only the rows that change."""
    if os.path.exists(OUT):
        with open(OUT, 'rb') as f:
            return '\r\n' if b'\r\n' in f.read(4096) else '\n'
    return '\n'


def build(use_wiki=True):
    files = rate_files()
    served = served_states()
    manual = committed_decisions(MANUAL_SOURCE)
    multi_state = {eia for eia, states in served.items() if len(states) >= 2}
    pages = sorted({(eia, utility) for _, eia, utility in files})
    territories = {}
    if use_wiki:
        try:
            territories = wiki_territories({eia for eia, _ in pages if eia in multi_state})
            print(f'OpenEI wiki: ServiceTerritory read for {sum(1 for v in territories.values() if v)} utility pages '
                  f'of {len(multi_state)} multi-state utilities', file=sys.stderr)
        except Exception as e:  # the wiki is a refinement; the file can be built without it
            print(f'WARNING: OpenEI wiki not consulted ({type(e).__name__}: {e}); using the utility names and the '
                  f'tract map only', file=sys.stderr)
            territories = {}
    if not territories:
        # Without the wiki, keep the territories the committed file already recorded
        kept_wiki = committed_decisions('openei_service_territory')
        for (eia, utility), state in kept_wiki.items():
            territories[utility] = [state]
        if kept_wiki:
            print(f'OpenEI wiki not consulted; kept {len(kept_wiki)} service-territory states from the committed file',
                  file=sys.stderr)

    # Rules 1 and 2 decide pages; rule 3 decides the pages they left, per utility
    page_state, page_source, conflicts = {}, {}, []
    for eia, utility in pages:
        wiki = territories.get(utility)
        wiki_state = wiki[0] if wiki and len(wiki) == 1 else None
        named = state_in_name(utility)
        if wiki_state and named and wiki_state != named:
            conflicts.append((eia, utility, wiki_state, named))
            continue
        if wiki_state:
            page_state[(eia, utility)], page_source[(eia, utility)] = wiki_state, 'openei_service_territory'
        elif named:
            page_state[(eia, utility)], page_source[(eia, utility)] = named, 'state_in_page_name'
    # Reviewed pages keep their state unless a record (1 or 2) now decides them
    for page, state in manual.items():
        if page not in page_state and page in {(e, u) for e, u in pages}:
            page_state[page], page_source[page] = state, MANUAL_SOURCE

    # Pages an elimination rule would place (one unnamed page, one state left): reported, not applied
    by_elimination = []
    for eia in sorted(multi_state):
        eia_pages = [(e, u) for e, u in pages if e == eia]
        unassigned_pages = [p for p in eia_pages if p not in page_state]
        unassigned_states = set(served[eia]) - {page_state[p] for p in eia_pages if p in page_state}
        if len(unassigned_pages) == 1 and len(unassigned_states) == 1:
            by_elimination.append((eia, unassigned_pages[0][1], next(iter(unassigned_states))))

    for eia, utility in pages:
        page = (eia, utility)
        if page in page_state:
            continue
        if eia not in served:
            page_source[page] = 'not_in_tract_map'
        elif len(served[eia]) == 1:
            page_state[page], page_source[page] = next(iter(served[eia])), 'single_state_utility'
        else:
            page_source[page] = 'unresolved'
    rows = [{'label': label, 'eia_id': eia, 'utility': utility,
             'state': page_state.get((eia, utility), ''), 'source': page_source[(eia, utility)]}
            for label, eia, utility in files]
    rows.sort(key=lambda r: (r['eia_id'], r['label']))
    newline = committed_newline()
    with open(OUT, 'w', encoding='utf-8', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS, lineterminator=newline)
        writer.writeheader()
        writer.writerows(rows)

    # Report, for the reviewer
    by_source = Counter(r['source'] or '(none)' for r in rows)
    kept = sum(1 for p, src in page_source.items() if src == MANUAL_SOURCE)
    dropped = [p for p in manual if p not in {(e, u) for e, u in pages}]
    print(f'\nWrote {OUT}: {len(rows):,} rate files, {len(pages):,} utility pages, {len(served):,} utilities in the tract map')
    print(f'reviewed pages carried forward: {kept}' + (f'; reviewed pages whose rate files are gone: {len(dropped)}' if dropped else ''))
    print('rate files by source: ' + ', '.join(f'{k} {v:,}' for k, v in by_source.most_common()))
    multi_rows = [r for r in rows if r['eia_id'] in multi_state]
    print(f'\nMulti-state utilities (the only ones the filter changes): {len(multi_state)}, {len(multi_rows):,} rate files')
    print('  by source: ' + ', '.join(f'{k} {v:,}' for k, v in Counter(r['source'] or '(none)' for r in multi_rows).most_common()))
    if conflicts:
        print('\nCONFLICTS (left blank; decide and set the state in the CSV):')
        for eia, utility, w, n in conflicts:
            print(f'  {eia} {utility!r}: wiki {w}, name {n}')
    if by_elimination:
        print('\nUnnamed pages an elimination rule would place (not applied; they apply in every state the utility serves):')
        for eia, utility, state in by_elimination:
            print(f'  {eia} {utility!r}: would be {state}; tracts ' + ' '.join(f'{st}:{n}' for st, n in served[eia].most_common()))
    # A state word inside a name against the tract map: not used for assignment, listed for the map's reviewers
    word = re.compile(r'\b(' + '|'.join(re.escape(n) for n in STATES) + r')\b')
    disagreeing = sorted({(eia, utility, STATES[m.group(1)], ' '.join(sorted(served[eia])))
                          for eia, utility in pages if eia in served and state_in_name(utility) is None
                          for m in [word.search(utility)] if m and STATES[m.group(1)] not in set(served[eia])})
    if disagreeing:
        print('\nState words in utility names that disagree with the tract map (not used; check the map):')
        for eia, utility, named, srv in disagreeing:
            print(f'  {eia} {utility!r}: name says {named}, serves {srv}')
    unresolved = Counter((r['eia_id'], r['utility']) for r in multi_rows if not r['state'])
    if unresolved:
        print(f'\nUnresolved pages of multi-state utilities (rates apply in every state the utility serves):')
        for (eia, utility), n in sorted(unresolved.items(), key=lambda x: -x[1]):
            print(f'  {eia} {utility!r}: {n} rate files; serves {" ".join(sorted(set(served[eia])))}')
    return rows


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--no-wiki', action='store_true', help='do not consult the OpenEI wiki')
    args = parser.parse_args()
    build(use_wiki=not args.no_wiki)
