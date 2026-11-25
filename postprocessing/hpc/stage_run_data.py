#!/usr/bin/env python3
"""Copy a run's results from its buildstockbatch output folder into comstock_data/, so that postprocessing
reads them there instead of downloading them from S3.

    python3 postprocessing/hpc/stage_run_data.py /kfs2/projects/eusscom/runs/<project>/<run name>

ComStock reads a run's results_up00.parquet, results_up<nn>.parquet and buildstock.csv from
postprocessing/comstock_data/<run version>/ and downloads only the files that are missing there. This
script copies them from the run's output folder:

    results/parquet/baseline/results_up00.parquet
    results/parquet/upgrades/upgrade=<n>/results_up<nn>.parquet   (every upgrade, or those in --upgrades)
    housing_characteristics/buildstock.csv

into comstock_data/<run version>/ of this checkout, and compares each copy with its source byte for byte.
Files already there and identical are skipped. A different file with the same name stops the script
before it copies anything, unless --replace is given. The run version defaults to the run folder's
name; give --run-version when the driver's comstock_run_version differs.

The driver still lists the run's upgrades on S3 (and downloads truth data the first time), so it still
needs AWS keys. It needs only the standard library: the system python3 will do.
"""
import argparse
import filecmp
import os
import shutil
import sys

PP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def parse_ids(text):
    """'1,2,5-9' -> {1, 2, 5, 6, 7, 8, 9}"""
    ids = set()
    for part in text.split(','):
        part = part.strip()
        if not part:
            continue
        low, sep, high = part.partition('-')
        if sep:
            ids.update(range(int(low), int(high) + 1))
        else:
            ids.add(int(part))
    return ids


def run_files(run_dir, wanted):
    """(source path, file name in comstock_data) for every file to stage."""
    parquet = os.path.join(run_dir, 'results', 'parquet')
    files = [(os.path.join(parquet, 'baseline', 'results_up00.parquet'), 'results_up00.parquet')]
    upgrades = {}
    upgrades_dir = os.path.join(parquet, 'upgrades')
    for name in (os.listdir(upgrades_dir) if os.path.isdir(upgrades_dir) else []):
        key, sep, number = name.partition('=')
        if key == 'upgrade' and sep and number.isdigit():
            upgrades[int(number)] = os.path.join(upgrades_dir, name)
    if wanted:
        missing = sorted(wanted - set(upgrades))
        if missing:
            sys.exit(f'{upgrades_dir} has no upgrade={",".join(map(str, missing))} folder')
    for upgrade in sorted(upgrades):
        if wanted and upgrade not in wanted:
            continue
        name = f'results_up{upgrade:02d}.parquet'  # the name ComStock reads (str(id).zfill(2))
        files.append((os.path.join(upgrades[upgrade], name), name))
    files.append((os.path.join(run_dir, 'housing_characteristics', 'buildstock.csv'), 'buildstock.csv'))
    absent = [src for src, _ in files if not os.path.isfile(src)]
    if absent:
        sys.exit('missing in the run folder (has the run finished postprocessing?):\n  ' + '\n  '.join(absent))
    return files


def gb(n_bytes):
    return f'{n_bytes / 1e9:.2f} GB'


def n_files(n):
    return f'{n} file' if n == 1 else f'{n} files'


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0].replace('\n', ' '))
    parser.add_argument('run_dir', help="the run's buildstockbatch output folder")
    parser.add_argument('--run-version', help="folder name in comstock_data/ (default: the run folder's name)")
    parser.add_argument('--upgrades', help='upgrade ids to copy, e.g. 1,2,5-9 (default: all; the baseline is always copied)')
    parser.add_argument('--replace', action='store_true', help='replace files that differ from the run')
    parser.add_argument('--dry-run', action='store_true', help='say what would be copied, copy nothing')
    args = parser.parse_args()

    run_dir = os.path.abspath(args.run_dir)
    version = args.run_version or os.path.basename(run_dir.rstrip(os.sep))
    wanted = parse_ids(args.upgrades) if args.upgrades else set()
    dest = os.path.join(PP_DIR, 'comstock_data', version)
    sources = run_files(run_dir, wanted)
    print(f'run folder   {run_dir}')
    print(f'copying into {dest}')

    to_copy, same, differ = [], [], []
    for src, name in sources:
        dst = os.path.join(dest, name)
        if not os.path.exists(dst):
            to_copy.append((src, dst))
        elif filecmp.cmp(src, dst, shallow=False):
            same.append(name)
        else:
            differ.append((src, dst))
    if differ and not args.replace:
        sys.exit('These files are already in comstock_data and differ from the run, so nothing was copied:\n  '
                 + '\n  '.join(dst for _, dst in differ)
                 + '\nMove them away, or run again with --replace.')
    to_copy += differ
    size = sum(os.path.getsize(src) for src, _ in to_copy)
    if args.dry_run:
        for src, dst in to_copy:
            print(f'  would copy {os.path.basename(dst)} ({gb(os.path.getsize(src))})')
        print(f'{n_files(len(to_copy))} ({gb(size)}) would be copied; {n_files(len(same))} already there.')
        return 0
    if not to_copy:
        print(f'Nothing to copy: all {n_files(len(same))} are already there and identical to the run.')
        print(f"The driver's run version must be {version!r} for ComStock to read them.")
        return 0

    os.makedirs(dest, exist_ok=True)
    for src, dst in to_copy:
        partial = dst + '.partial'  # ComStock reads results_up*.parquet, so a cut-off copy is never read
        shutil.copy2(src, partial)
        if not filecmp.cmp(src, partial, shallow=False):
            os.remove(partial)
            sys.exit(f'the copy of {src} differs from the source; nothing was written for it')
        os.replace(partial, dst)
        print(f'  copied {os.path.basename(dst)} ({gb(os.path.getsize(dst))})')
    print(f'{n_files(len(to_copy))} copied ({gb(size)}) and checked byte for byte; {n_files(len(same))} already there.')
    print(f"The driver's run version must be {version!r} for ComStock to read them.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
