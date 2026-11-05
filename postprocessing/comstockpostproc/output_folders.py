# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Where postprocessing writes.

Everything about one run is in that run's folder, output/ComStock <run version>/: its caches, stock allocation, bills
and exports, the figures of every comparison of that run alone (measure_runs/, cbecs_comparison/, ami_comparison/,
eia_comparison/) and its results_dashboard/. A comparison of several runs goes in output/<name>/, with the name its
driver sets (COMPARISON_NAME). No folder name is made up from the dataset names.

Shared by every run that uses them, and so in no run's folder: output/Stock Estimation <version>/ (the estimate's
apportionment), output/CBECS <year>/ and the AMI data. The downloaded results are in comstock_data/<run version>/.
"""
import os

OUTPUT_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'output'))


def run_folder(comstock):
    """The run's local folder: its output_dir, or output/ComStock <run version> when that output_dir is on S3."""
    out = getattr(comstock, 'output_dir', None)
    if isinstance(out, dict) and out.get('fs_path') and type(out.get('fs')).__name__ != 'S3FileSystem':
        return os.path.abspath(out['fs_path'])
    return os.path.join(OUTPUT_ROOT, f'ComStock {comstock.comstock_run_version}')


def comparison_folder(comstock_runs, name, subfolder):
    """output/<name> for a named comparison; <run folder>/<subfolder> for an unnamed comparison of one run."""
    if name:
        return os.path.join(OUTPUT_ROOT, name)
    if len(comstock_runs) == 1:
        return os.path.join(run_folder(comstock_runs[0]), subfolder)
    raise ValueError(f'A comparison of {len(comstock_runs)} ComStock runs needs name=..., its folder under output/ '
                     "(the multi-run drivers pass COMPARISON_NAME). Only a comparison of one run goes in that run's "
                     'folder.')
