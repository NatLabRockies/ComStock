# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
from .athena_config import ATHENA_WORKGROUP
from .comstock import ComStock
from .cbecs import CBECS
from .eia import EIA
from .ami import AMI
from .comstock_apportionment import Apportion
from .comstock_to_cbecs_comparison import ComStockToCBECSComparison
from .comstock_measure_comparison import ComStockMeasureComparison
from .comstock_to_eia_comparison import ComStockToEIAComparison
from .comstock_to_ami_comparison import ComStockToAMIComparison
from .comstock_to_eia_comparison import ComStockToEIAComparison
from .resstock import ResStock
from .results_dashboard import AthenaRunRef, ResultsDashboard, load_ami, load_cbecs, report_caches
# S3 exports + Athena tables, built only when missing. One call per run in a
# driver; the timeseries plots, the AMI comparison and the dashboard read them.
from .athena_tables import prepare_athena_tables, required_geo_exports
from . import athena_tables  # athena_tables.export_levels checks a driver's export settings
# The stock allocation (apportionment draw) as a portable file: fingerprint,
# provenance, the sharing plan a driver follows.
from . import allocation
from .utils.hpc import *
# Drivers end with run_or_submit(main, KESTREL_JOB): main() runs where it is started, except on a Kestrel
# login node, where the driver is queued as a Slurm job instead (README, "Running on Kestrel").
from . import kestrel
from .kestrel import run_or_submit

from .__version__ import (
    __author__,
    __author_email__,
    __copyright__,
    __description__,
    __title__,
    __license__,
    __title__,
    __url__,
    __version__,
    __name__
)
