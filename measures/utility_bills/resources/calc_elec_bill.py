#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

"""
This script reads a CSV of hourly kWh and a JSON utility rate in URDB format
and calculates the annual electricity bill.
"""

import argparse
import json

import PySAM.Utilityrate5 as utility_rate
import PySAM.UtilityRateTools
import PySAM.LoadTools


# Command line arguments for the path to the electricity consumption and utility rate
parser = argparse.ArgumentParser(description="Calculates the annual utility bill given hourly kWh and a rate",
                                 formatter_class=argparse.ArgumentDefaultsHelpFormatter)
parser.add_argument("kwhpath", help="Full path to kwh CSV file")
parser.add_argument("ratepath", help="Full path to URDB rate JSON file")
args = parser.parse_args()

# Load the hourly kWh consumption from disk
hourly_kwh = []
with open(args.kwhpath) as f:
  for val in f:
    hourly_kwh.append(float(val))
assert len(hourly_kwh) == 8760, f"Got {len(hourly_kwh)} instead of expected 8760 hourly kWh values"

# Load the rate data from disk
with open(args.ratepath, 'r') as f:
    rate_data = json.load(f)

# Do the bill calculation using PySAM
try:
    rates = PySAM.UtilityRateTools.URDBv8_to_ElectricityRates(rate_data)

    ur = utility_rate.new()
    for k, v in rates.items():
        ur.value(k, v)

    # Set up other defaults
    analysis_period = 1 # Number of years to run the simulation
    ur.value("analysis_period", analysis_period)
    ur.value("system_use_lifetime_output", 0) # Set to 1 if load and gen have length 8760 * analysis_period
    ur.value("inflation_rate", 2.5) # Units of %
    ur.value("degradation", [0] * analysis_period) # AC energy loss per year due to degradation during analysis period (%)

    gen = [0] * 8760 # No renewable generation

    ur.value("gen", gen) # Hourly kW
    ur.value("load", hourly_kwh) # Hourly kW (aka kWh because 1kW * 1hr = 1kWh)

    monthly_peaks = PySAM.LoadTools.get_monthly_peaks(hourly_kwh, 1) # Used by rates with billing demand
    ur.value("ur_yearzero_usage_peaks", monthly_peaks)

    ur.execute() # Run the utility rate module

    out = {
       'total_utility_bill_dollars': int(round(ur.Outputs.elec_cost_without_system_year1, 0)),
       'average_rate_dollars_per_kwh': round(ur.Outputs.elec_cost_without_system_year1 / sum(hourly_kwh), 2),
       'charge_wo_sys_dc_fixed': int(round(ur.Outputs.charge_wo_sys_dc_fixed[1],0)),
       'charge_wo_sys_dc_tou': int(round(ur.Outputs.charge_wo_sys_dc_tou[1],0)),
       'charge_wo_sys_ec': int(round(ur.Outputs.charge_wo_sys_ec[1],0)),
       'charge_wo_sys_fixed_ym': int(round(sum(ur.Outputs.charge_wo_sys_fixed_ym[1]),0))
       }    

    print(json.dumps(out))
except:
    msg = f'PySAM error calculating bills with rate {args.kwhpath}'
    print(msg)
    exit(code=1)
