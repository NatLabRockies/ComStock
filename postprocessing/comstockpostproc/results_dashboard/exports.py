# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""What the assessment needs on disk and in Athena, so a driver does not guess.

The Athena side -- which aggregates to export, which tables and views must
exist, and building only what is missing -- is shared with the timeseries plots
and the AMI comparison, so it lives in `comstockpostproc.athena_tables`. Drivers
call `cspp.prepare_athena_tables(...)` once per run, and the assessment reads
what that produced. Constructing `ResultsDashboard` creates NO tables: it
probes and skips what it cannot find, reporting the cause.

What is left here is the one input the assessment needs that nothing else
does: the AMI truth data.
"""

from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


def load_ami(truth_data_version: str = "v01", **kwargs):
    """A `cspp.AMI` that reads its exported CSV if present, and builds it if not.

    `reload_from_csv` is a footgun as a driver setting: True raises
    FileNotFoundError when 'AMI long.csv' is absent, False spends several minutes
    recomputing an 82 MB file that is probably already there -- and the setting
    sits far from the top of the file, so whoever hits it has no reason to know
    where to look. The answer is on disk, so read it from disk.
    """
    import os

    from ..ami import AMI

    # Mirrors how AMI.__init__ derives output_dir, rather than constructing one
    # just to ask it -- construction is what does the expensive work.
    here = os.path.dirname(os.path.abspath(__file__))
    csv = os.path.join(here, "..", "..", "output",
                       f"AMI {truth_data_version}", "AMI long.csv")
    have = os.path.exists(csv)
    logger.info("AMI: %s 'AMI long.csv'", "reloading" if have else "building")
    return AMI(truth_data_version=truth_data_version, reload_from_csv=have,
               **kwargs)


def load_cbecs(cbecs_year: int = 2018, truth_data_version: str = "v01",
               color_hex: str = "#009E73", **kwargs):
    """A `cspp.CBECS` whose 'CBECS wide.csv' exists afterwards, whichever way.

    Same footgun as AMI, one step worse: `reload_from_csv=True` raises when the
    file is absent, and `reload_from_csv=False` neither reads nor WRITES it --
    only `export_to_csv_wide()` does -- so a first run that forgets the export
    gets no CBECS legs in the dashboard. Reads the file if present; otherwise
    builds the object and exports it.
    """
    import os

    from ..cbecs import CBECS

    here = os.path.dirname(os.path.abspath(__file__))
    csv = os.path.join(here, "..", "..", "output",
                       f"CBECS {cbecs_year}", "CBECS wide.csv")
    have = os.path.exists(csv)
    logger.info("CBECS: %s 'CBECS wide.csv'", "reloading" if have else "building")
    cbecs = CBECS(cbecs_year=cbecs_year, truth_data_version=truth_data_version,
                  color_hex=color_hex, reload_from_csv=have, **kwargs)
    if not have:
        cbecs.export_to_csv_wide()
    return cbecs
