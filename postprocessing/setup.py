# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
#!/usr/bin/env python3

import os
from setuptools import find_packages, setup

# get key package details from py_pkg/__version__.py
about = {}  # type: ignore
here = os.path.abspath(os.path.dirname(__file__))
with open(os.path.join(here, 'comstockpostproc', '__version__.py')) as f:
    exec(f.read(), about)

# load the README file and use it as the long_description for PyPI
with open('README.md', 'r') as f:
    readme = f.read()

# package configuration - for reference see:
# https://setuptools.readthedocs.io/en/latest/setuptools.html#id9
setup(
    name=about['__title__'],
    description=about['__description__'],
    long_description=readme,
    long_description_content_type='text/markdown',
    version=about['__version__'],
    author=about['__author__'],
    author_email=about['__author_email__'],
    url=about['__url__'],
    packages=find_packages(),
    include_package_data=True,
    package_data={
        'comstockpostproc': ['resources/*.csv'],
        'comstockpostproc.results_dashboard': ['resources/*.js'],
    },
    license=about['__license__'],
    zip_safe=False,
    entry_points={
        'console_scripts': ['comstockpostproc=comstockpostproc.entry_points:main'],
    },
    classifiers=[
        'Development Status :: 4 - Beta',
        'Intended Audience :: Developers',
        'Programming Language :: Python :: 3.10',
    ],
    keywords='comstock postprocessing',
    python_requires="==3.12.12",
    install_requires=[
        'boto3',
        'botocore',
        'fsspec',
        'joblib',
        'natsort',
        'nbformat',
        'pandas',
        'plotly',
        'polars==1.32.2',
        'pyarrow',
        'pyyaml',
        's3fs',
        'scipy',
        'seaborn>=0.12.0',
        'SQLAlchemy==1.4.46',
        'sqlalchemy-views==0.3.2',
        'xlrd',
        'buildstock_query @ git+https://github.com/NREL/buildstock-query@0479759'
    ],
    extras_require={
        'dev': [
            'autopep8',
            'ipykernel',
            'pytest',
            # 'awscli',
            # 'codecov',
            # 'colorama==0.4.3'
            # 'coverage',
            # 'flake8==3.8.2',
            # 'pdoc3',
        ],
        'gap': [
            'shapely',
            'geopandas',
            'folium',
            'matplotlib',
            'mapclassify',
            'scikit-learn',
            'openpyxl',
            'better @ git+https://github.com/LBNL-JCI-ICF/better@packageready'
        ],
        ':sys_platform == "win32"': [
            'kaleido==0.1.0post1',  # kaleido version for Windows
        ],
        ':sys_platform == "linux"': [
            'kaleido==0.1.0',  # kaleido version for Linux
        ],
        ':sys_platform == "darwin"': [
            'kaleido==0.2.0',  # kaleido version for MacOS
        ],

    }
)
