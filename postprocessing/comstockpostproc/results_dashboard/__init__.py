# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Results dashboard.

Compares ComStock runs against CBECS, AMI, and each other from published Athena
aggregate tables, writing metric CSVs plus one self-contained dashboard.html.
Deterministic throughout: SQL, pandas, and a hand-written JS bundle.
"""

from .assessment import ResultsDashboard
from .exports import load_ami, load_cbecs
from .run_ref import AthenaRunRef

__all__ = ["ResultsDashboard", "AthenaRunRef", "load_ami", "load_cbecs"]
