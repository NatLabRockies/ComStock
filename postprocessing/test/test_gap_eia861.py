import os
import pytest
import logging

import comstockpostproc.gap.eia861

def test_eia_861():
    # annual, all data
    # reload_from_csv=False: download and process the truth file, which the checks below
    # expect, even when an earlier run left the processed csv behind
    annual_all = comstockpostproc.gap.eia861.EIA861(type='Annual', reload_from_csv=False)

    print(annual_all.data.columns)
    checks = ['COMMERCIAL', 'RESIDENTIAL', 'INDUSTRIAL', 'TOTAL', 'Sales', 'Customers', 'Revenues']
    assert(all(any(item in col for col in annual_all.data.columns) for item in checks))

    assert(os.path.exists(os.path.join(annual_all.truth_data_dir, 'Sales_Ult_Cust_2018.xlsx')))
    assert(os.path.exists(os.path.join(annual_all.processed_dir, 'eia861_Annual_2018_All_All.csv')))

    # annual, commercial-only
    annual_com = comstockpostproc.gap.eia861.EIA861(type='Annual', segment='Commercial')
    missing = ['RESIDENTIAL', 'INDUSTRIAL', 'TOTAL', 'Sales', 'Customers', 'Revenues']
    assert(all(any(item not in col for col in annual_com.data.columns) for item in missing))
    present = ['COMMERCIAL', 'Sales', 'Customers', 'Revenues']
    assert(all(any(item in col for col in annual_com.data.columns) for item in present))
    assert(os.path.exists(os.path.join(annual_com.processed_dir, 'eia861_Annual_2018_Commercial_All.csv')))

    # annual, commercial sales
    annual_com_sales = comstockpostproc.gap.eia861.EIA861(type='Annual', segment='Commercial', measure='Sales')
    missing = ['RESIDENTIAL', 'INDUSTRIAL', 'TOTAL', 'Customers', 'Revenues']
    assert(all(any(segment not in col for col in annual_com_sales.data.columns) for segment in missing))
    present = ['COMMERCIAL', 'Sales']
    assert(all(any(item in col for col in annual_com_sales.data.columns) for item in present))
    assert(os.path.exists(os.path.join(annual_com_sales.processed_dir, 'eia861_Annual_2018_Commercial_Sales.csv')))

    # annual, commercial and residential sales and customers
    annual = comstockpostproc.gap.eia861.EIA861(type='Annual', segment=['Commercial', 'Residential'], measure=['Sales', 'Customers'])
    missing = ['INDUSTRIAL', 'TOTAL', 'Revenues']
    assert(all(any(item not in col for col in annual.data.columns) for item in missing))
    present = ['COMMERCIAL', 'RESIDENTIAL', 'Sales', 'Customers']
    assert(all(any(item in col for col in annual.data.columns) for item in present))
    assert(os.path.exists(os.path.join(annual.processed_dir, 'eia861_Annual_2018_Commercial_Residential_Sales_Customers.csv')))

    customers = comstockpostproc.gap.eia861.EIA861(type='Annual', segment=['Commercial', 'Residential', 'Industrial'], measure='Customers')
    assert(os.path.exists(os.path.join(customers.processed_dir, 'eia861_Annual_2018_Commercial_Residential_Industrial_Customers.csv')))

def test_monthly():
    # monthly, all data
    monthly_all = comstockpostproc.gap.eia861.EIA861(type='Monthly', year='All')
    assert(os.path.exists(os.path.join(monthly_all.processed_dir, 'eia861_Monthly_All_All_All.csv')))

def test_short():
    short = comstockpostproc.gap.eia861.EIA861(type='Short')
    print(short.data)