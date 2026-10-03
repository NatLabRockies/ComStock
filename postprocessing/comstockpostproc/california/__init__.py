# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""California: ComStock against the CalMAC non-residential granular profiles.

  segments            how ComStock buildings are grouped to match the profiles
  calmac.CalMAC       the truth data, one long table on Pacific standard time
  weather             clocks, station assignment, the SDG&E 2025 -> 2018 normalization
  weights             each run's LOCAL California weight table (utility x CEC zone)
  release_weights     the same table for a published release, from its tract-level Athena table
  prepare_truth_data  one-off: the utilities' files -> truth_data/v01/calmac/

The dashboard leg that uses them is results_dashboard.calmac_shapes; the driver is
compare_runs_california.py.template.
"""

from .calmac import CalMAC
from .segments import resolve_config
from .release_weights import save_release_california_weights
from .weights import california_weights_path, save_california_weights

__all__ = ["CalMAC", "resolve_config", "california_weights_path", "save_california_weights",
           "save_release_california_weights"]
