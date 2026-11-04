# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Assessment format version.

Its own module so `dashboard` and `assessment` can both read it without
importing the package __init__, which imports them -- a cycle. Recorded in the
manifest so a dashboard can be traced to the code that produced it.
"""

__version__ = "0.1.0"
