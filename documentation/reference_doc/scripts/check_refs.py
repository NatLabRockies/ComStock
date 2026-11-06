"""Check the reference doc for dangling references, missing figures and inputs, and duplicate labels.

    python documentation/reference_doc/scripts/check_refs.py
"""
import os
import re
import sys

DOC = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
os.chdir(DOC)

files = [f for f in os.listdir('.') if f.endswith('.tex')]
files += [os.path.join('tables', f) for f in os.listdir('tables')]

refs, labels, figs, inputs = set(), set(), set(), set()
label_files = {}
for f in files:
    with open(f, encoding='utf-8') as fh:
        raw = fh.read()
    text = re.sub(r'(^|[^\\])%.*$', r'\1', raw, flags=re.M)
    for m in re.finditer(r'\\(?:ref|Cref|Crefrange|autoref|cref)\{([^}]*)\}', text):
        refs.update(r.strip() for r in m.group(1).split(','))
    for m in re.finditer(r'\\label\{([^}]*)\}', text):
        labels.add(m.group(1).strip())
    for m in re.finditer(r'\\includegraphics(?:\[[^\]]*\])?\{([^}]*)\}', text):
        figs.add(m.group(1).strip())
    for m in re.finditer(r'\\input\{([^}]*)\}', text):
        inputs.add(m.group(1).strip())
    for m in re.finditer(r'\\label\{([^}]*)\}', raw):
        label_files.setdefault(m.group(1), []).append(f)


def exists(p, exts):
    return os.path.exists(p) or any(os.path.exists(p + e) for e in exts)


missing_labels = sorted(r for r in refs if r not in labels)
missing_figs = sorted(f for f in figs if not exists(f, ['.png', '.PNG', '.pdf']))
missing_inputs = sorted(i for i in inputs if not exists(i, ['.tex']))
duplicates = sorted(f'{k} in {", ".join(v)}' for k, v in label_files.items() if len(v) > 1)

print('refs', len(refs), 'labels', len(labels))
print('MISSING LABELS:', missing_labels)
print('MISSING FIGS:', missing_figs)
print('MISSING INPUTS:', missing_inputs)
print('DUPLICATE LABELS:', duplicates)
sys.exit(1 if (missing_labels or missing_figs or missing_inputs or duplicates) else 0)
