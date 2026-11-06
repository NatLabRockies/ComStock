# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Athena connection settings shared by every query site in the package.

One constant instead of eight literals. The workgroup used to be hardcoded as
'comcore' at every BuildStockQuery() call, and that workgroup does not exist on
the NLR account -- every query failed with "WorkGroup is not found". Because
the results dashboard cached query results by SQL text, the failure stayed
hidden for months behind cache hits. Keeping the name in exactly one place means
the next account move is a one-line change that cannot be half-applied.
"""

# Athena workgroup on the NLR account. 'comcore' was the pre-rename value and
# is gone; the SDR/OEDI tables and the run tables are both reachable from here.
ATHENA_WORKGROUP = "buildstock"
