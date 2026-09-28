"""Stamp a constant parameter onto a precomputed buildstock sample, one copy per value.

Run-level sensitivity inputs are not sampled characteristics, so they have no column in the
buildstock.csv. BuildExistingModel applies a parameter only when its column is present, and it
resolves the column's value through options_lookup.tsv like any other parameter. So a sensitivity
run needs nothing more than a copy of the sample with one extra constant column per value, and a
yml whose sample_file points at that copy. The baseline sample is untouched.

The parameter must exist in options_lookup.tsv with a row for every value stamped here; the
value is written exactly as given, so match the option spelling ('0.5', not '0.50').

Example, for the food preparation gas equipment schedule peak sensitivity:

    python samples/stamp_parameter.py buildstock.csv food_preparation_gas_equipment_peak 0.4 0.6 0.8

writes buildstock_food_preparation_gas_equipment_peak_0.4.csv and so on next to the input.
"""
import argparse
import csv
import os
import sys


def stamp(sample_path, parameter, value, out_path):
    with open(sample_path, newline='', encoding='utf-8') as src, open(out_path, 'w', newline='', encoding='utf-8') as dst:
        reader = csv.reader(src)
        writer = csv.writer(dst)
        header = next(reader)
        if parameter in header:
            index = header.index(parameter)
            writer.writerow(header)
            for row in reader:
                row[index] = value
                writer.writerow(row)
        else:
            writer.writerow(header + [parameter])
            for row in reader:
                writer.writerow(row + [value])


def lookup_has_option(lookup_path, parameter, value):
    with open(lookup_path, newline='', encoding='utf-8') as f:
        for row in csv.reader(f, delimiter='\t'):
            if len(row) >= 2 and row[0] == parameter and row[1] == value:
                return True
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('sample', help='precomputed buildstock.csv to copy')
    parser.add_argument('parameter', help='parameter name, as it appears in options_lookup.tsv')
    parser.add_argument('values', nargs='+', help='one option value per output file')
    parser.add_argument('--out-dir', help='where to write the copies (default: next to the sample)')
    parser.add_argument('--options-lookup', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'resources', 'options_lookup.tsv'),
                        help='options_lookup.tsv to check the values against')
    args = parser.parse_args()

    out_dir = args.out_dir or os.path.dirname(os.path.abspath(args.sample))
    os.makedirs(out_dir, exist_ok=True)
    stem = os.path.splitext(os.path.basename(args.sample))[0]

    missing = [v for v in args.values if not lookup_has_option(args.options_lookup, args.parameter, v)]
    if missing:
        sys.exit(f"options_lookup.tsv has no '{args.parameter}' option for: {', '.join(missing)}")

    for value in args.values:
        out_path = os.path.join(out_dir, f'{stem}_{args.parameter}_{value}.csv')
        stamp(args.sample, args.parameter, value, out_path)
        print(out_path)


if __name__ == '__main__':
    main()
