#!/usr/bin/env python3
"""Check that a Python environment matches this checkout's postprocessing requirements.

Run it with the environment's python; it works the same locally and on Kestrel:

    python postprocessing/hpc/check_env.py              # full check, including a test figure export
    python postprocessing/hpc/check_env.py --no-export  # without the figure export
    python postprocessing/hpc/check_env.py --quiet      # print only problems and the result

It checks:
  - the Python version against python_requires in setup.py;
  - that every package setup.py requires (with the dev extra) is installed and satisfies it;
  - that every installed package pinned in constraints.txt has the pinned version;
  - that comstockpostproc imports from this checkout;
  - that plotly exports a figure through Kaleido and Chrome.
It exits 0 when all of these pass and 1 otherwise. Installed packages that constraints.txt does not
pin are listed as notes.

    python3 postprocessing/hpc/check_env.py --print-requirements

prints the requirements from setup.py, one per line, for pip install -r; setup_kestrel_env.sh uses
it. That mode needs only the standard library.
"""
import argparse
import ast
import json
import os
import re
import sys
import tempfile
import threading
import time
import warnings

HPC_DIR = os.path.dirname(os.path.abspath(__file__))
PP_DIR = os.path.dirname(HPC_DIR)
SETUP_PY = os.path.join(PP_DIR, 'setup.py')
CONSTRAINTS = os.path.join(PP_DIR, 'constraints.txt')
ENV_RECORD = 'comstockpostproc_env.txt'  # written by setup_kestrel_env.sh when a build finishes
TOOLING = {'pip', 'setuptools', 'wheel'}  # installed by venv itself, not by setup.py
EXPORT_TIMEOUT_S = 180


def canonical(name):
    return re.sub(r'[-_.]+', '-', name).lower()


def setup_keywords():
    """The literal keyword arguments of the setup() call in setup.py, read without running it."""
    with open(SETUP_PY) as f:
        tree = ast.parse(f.read(), SETUP_PY)
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and getattr(node.func, 'id', None) == 'setup':
            return {kw.arg: ast.literal_eval(kw.value) for kw in node.keywords
                    if kw.arg in ('python_requires', 'install_requires', 'extras_require')}
    sys.exit(f'no setup() call found in {SETUP_PY}')


def setup_requirements(extras):
    kw = setup_keywords()
    reqs = list(kw.get('install_requires', []))
    for extra in extras:
        if extra not in kw.get('extras_require', {}):
            sys.exit(f'setup.py has no extra named {extra!r}')
        reqs += kw['extras_require'][extra]
    return kw.get('python_requires', ''), reqs


def read_constraints():
    """{canonical name: (name, version)} for every name==version line of constraints.txt."""
    pins = {}
    with open(CONSTRAINTS) as f:
        for line in f:
            text = line.split('#', 1)[0].strip()
            if not text:
                continue
            name, sep, version = text.partition('==')
            if not sep:
                sys.exit(f'{CONSTRAINTS}: expected name==version, found {text!r}')
            pins[canonical(name)] = (name.strip(), version.strip())
    return pins


def import_packaging():
    try:
        from packaging.requirements import Requirement
        from packaging.specifiers import SpecifierSet
        from packaging.version import Version
    except ImportError:  # pip vendors a copy
        from pip._vendor.packaging.requirements import Requirement
        from pip._vendor.packaging.specifiers import SpecifierSet
        from pip._vendor.packaging.version import Version
    return Requirement, SpecifierSet, Version


class Report:
    def __init__(self, quiet):
        self.quiet = quiet
        self.problems = 0

    def ok(self, text):
        if not self.quiet:
            print(f'ok        {text}')

    def note(self, text):
        if not self.quiet:
            print(f'note      {text}')

    def problem(self, text):
        self.problems += 1
        print(f'PROBLEM   {text}')


def check_python(rep, python_requires, SpecifierSet):
    import platform
    version = platform.python_version()
    if not python_requires or SpecifierSet(python_requires).contains(version, prereleases=True):
        rep.ok(f'python {version} (setup.py: {python_requires or "no python_requires"})')
    else:
        rep.problem(f'python {version}, but setup.py requires {python_requires}')


def installed_distributions(rep):
    from importlib import metadata
    found = {}
    for dist in metadata.distributions():
        name = dist.metadata['Name']
        if not name:
            continue
        key = canonical(name)
        if key in found:
            rep.note(f'{name} is installed twice ({found[key].version} and {dist.version})')
            continue
        found[key] = dist
    return found


def check_requirements(rep, reqs, installed, Requirement):
    """Every setup.py requirement is installed and satisfies its specifier (or its pinned commit)."""
    url_names = set()
    good = 0
    for text in reqs:
        req = Requirement(text)
        if req.marker is not None and not req.marker.evaluate():
            continue
        dist = installed.get(canonical(req.name))
        if dist is None:
            rep.problem(f'{req.name} is required by setup.py ({text}) but not installed')
            continue
        if req.url:
            url_names.add(canonical(req.name))
            want = req.url.rsplit('@', 1)[-1]
            info = json.loads(dist.read_text('direct_url.json') or '{}')
            got = info.get('vcs_info', {}).get('commit_id', '')
            if re.fullmatch(r'[0-9a-f]{7,40}', want) and not got.startswith(want):
                rep.problem(f'{req.name} is installed from commit {got[:10] or "unknown"}; setup.py pins {want}')
                continue
        elif not req.specifier.contains(dist.version, prereleases=True):
            rep.problem(f'{req.name} {dist.version} is installed; setup.py requires {text}')
            continue
        good += 1
    rep.ok(f'{good} packages that setup.py requires are installed and satisfy it')
    return url_names


def check_constraints(rep, pins, installed, url_names, Version):
    """Every installed package that constraints.txt pins has the pinned version."""
    matched, absent = 0, 0
    for key, (name, pinned) in sorted(pins.items()):
        dist = installed.get(key)
        if dist is None:
            absent += 1  # another platform's package, or one nothing here requires
        elif Version(dist.version) != Version(pinned):
            rep.problem(f'{name} {dist.version} is installed; constraints.txt pins {pinned}')
        else:
            matched += 1
    rep.ok(f'{matched} installed packages have the versions in constraints.txt '
           f'({absent} {"pin is" if absent == 1 else "pins are"} for packages not installed here)')
    skip = TOOLING | url_names | {'comstock-postprocessing'}
    unpinned = sorted(f'{installed[k].metadata["Name"]} {installed[k].version}'
                      for k in installed if k not in pins and k not in skip)
    if unpinned:
        rep.note('not pinned in constraints.txt: ' + ', '.join(unpinned))
    if 'comstock-postprocessing' in installed:
        rep.note('this env also has comstockpostproc installed (pip install -e); a driver run from a '
                 "checkout's postprocessing/ folder imports that checkout's code all the same")


def check_import(rep):
    sys.path.insert(0, PP_DIR)
    warnings.filterwarnings('ignore', category=SyntaxWarning)  # old escape sequences in some modules
    start = time.time()
    try:
        import comstockpostproc
    except Exception as e:
        rep.problem(f'import comstockpostproc failed: {type(e).__name__}: {e}')
        return
    where = os.path.dirname(os.path.abspath(comstockpostproc.__file__))
    expected = os.path.join(PP_DIR, 'comstockpostproc')
    if os.path.normcase(os.path.realpath(where)) == os.path.normcase(os.path.realpath(expected)):
        rep.ok(f'comstockpostproc imports from this checkout ({time.time() - start:.1f} s)')
    else:
        rep.problem(f'comstockpostproc imports from {where}, not from this checkout ({expected})')


def check_export(rep):
    """Export a small figure the way the plotting code does (plotly.io.write_images, Kaleido v1)."""
    import logging
    for name in ('choreographer', 'kaleido'):  # comstockpostproc's import turns on INFO logging
        logging.getLogger(name).setLevel(logging.WARNING)
    try:
        from choreographer.browsers.chromium import Chromium
        chrome = Chromium.find_browser(skip_local=False)
    except Exception:
        chrome = None
    source = ' (from BROWSER_PATH)' if chrome and chrome == os.environ.get('BROWSER_PATH') else ''
    result = {}

    def export():
        try:
            import plotly.graph_objects as go
            import plotly.io as pio
            fig = go.Figure(go.Bar(y=[1, 2, 3]))
            with tempfile.TemporaryDirectory() as tmp:
                out = os.path.join(tmp, 'check_env.png')
                if hasattr(pio, 'write_images'):
                    pio.write_images([fig], [out])
                else:
                    fig.write_image(out)
                result['bytes'] = os.path.getsize(out)
        except Exception as e:
            result['error'] = f'{type(e).__name__}: {e}'

    start = time.time()
    worker = threading.Thread(target=export, daemon=True)
    worker.start()
    worker.join(EXPORT_TIMEOUT_S)
    if worker.is_alive():
        rep.problem(f'figure export did not finish in {EXPORT_TIMEOUT_S} s (Chrome: {chrome or "not found"})')
        return False
    if 'error' in result:
        rep.problem(f'figure export failed: {result["error"]} (Chrome: {chrome or "not found"}). '
                    'Kaleido needs Chrome: run plotly_get_chrome -y')
    else:
        rep.ok(f'figure export: {result["bytes"]:,}-byte PNG in {time.time() - start:.1f} s; '
               f'Chrome {chrome or "found by Kaleido"}{source}')
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--print-requirements', action='store_true',
                        help="print setup.py's requirements, one per line, and exit")
    parser.add_argument('--extras', default='dev',
                        help='comma-separated setup.py extras to include (default: dev; "" for none)')
    parser.add_argument('--no-export', action='store_true', help='skip the test figure export')
    parser.add_argument('--quiet', action='store_true', help='print only problems and the result')
    args = parser.parse_args()
    extras = [e for e in args.extras.split(',') if e]
    python_requires, reqs = setup_requirements(extras)

    if args.print_requirements:
        print('\n'.join(reqs))
        return 0

    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(line_buffering=True)  # keep these lines in order with library warnings
    rep = Report(args.quiet)
    if not args.quiet:
        print(f'Checking the environment {sys.prefix}')
        print(f'against the checkout     {PP_DIR}')
        record = os.path.join(sys.prefix, ENV_RECORD)
        if os.path.isfile(record):
            with open(record) as f:
                print('env record               ' + f.readline().strip())
    Requirement, SpecifierSet, Version = import_packaging()
    installed = installed_distributions(rep)
    check_python(rep, python_requires, SpecifierSet)
    url_names = check_requirements(rep, reqs, installed, Requirement)
    check_constraints(rep, read_constraints(), installed, url_names, Version)
    check_import(rep)
    finished = True
    if not args.no_export:
        finished = check_export(rep)

    if rep.problems:
        print(f'NOT OK: {rep.problems} problem(s) above. On Kestrel, bash postprocessing/hpc/setup_kestrel_env.sh '
              'builds the env this checkout needs; locally, run pip install -c constraints.txt -e .[dev] '
              'in postprocessing/.')
    else:
        print(f'OK: {sys.prefix} matches the checkout {PP_DIR}')
    code = 1 if rep.problems else 0
    if not finished:  # a stuck Chrome would keep the interpreter from exiting
        sys.stdout.flush()
        os._exit(code)
    return code


if __name__ == '__main__':
    sys.exit(main())
