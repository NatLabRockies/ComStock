#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

"""
This script reads a CSV of hourly kWh and a JSON utility rate in URDB format
and calculates the annual electricity bill.

For a tariff that carries delivery charges only, the supply (default service) charges can be
passed as 12 monthly prices. They're billed on the same calendar months PySAM uses (hour 0 is
January 1, 365 days): monthly kWh x $/kWh, plus monthly peak kW x $/kW-month. This equals adding
the $/kWh to the energy tiers' `adj` (PySAM bills rate + adj), and keeps supply out of the
tariff so the measure can escalate the delivery bill without escalating supply.
"""

import argparse
import json

import PySAM.Utilityrate5 as utility_rate
import PySAM.UtilityRateTools
import PySAM.LoadTools

HOURS_PER_MONTH = [24 * d for d in (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)]


def twelve_floats(text):
    vals = [float(v) for v in text.split(",")]
    if len(vals) != 12:
        raise argparse.ArgumentTypeError(f"expected 12 comma-separated monthly values, got {len(vals)}")
    return vals


def supply_charges(hourly_kwh, usd_per_kwh, usd_per_kw_month):
    """Supply energy and demand charges, in dollars, for 12 monthly prices."""
    energy, demand, i = 0.0, 0.0, 0
    for m, hours in enumerate(HOURS_PER_MONTH):
        month = hourly_kwh[i:i + hours]
        energy += sum(month) * usd_per_kwh[m]
        demand += max(month) * usd_per_kw_month[m]
        i += hours
    return energy, demand


# Command line arguments for the path to the electricity consumption and utility rate
parser = argparse.ArgumentParser(description="Calculates the annual utility bill given hourly kWh and a rate",
                                 formatter_class=argparse.ArgumentDefaultsHelpFormatter)
parser.add_argument("kwhpath", help="Full path to kwh CSV file")
parser.add_argument("ratepath", help="Full path to URDB rate JSON file")
parser.add_argument("--supply-usd-per-kwh", type=twelve_floats, default=None,
                    help="12 comma-separated monthly supply prices ($/kWh) for a delivery-only tariff")
parser.add_argument("--supply-usd-per-kw-month", type=twelve_floats, default=None,
                    help="12 comma-separated monthly supply demand prices ($/kW-month) on monthly peak demand")
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

    if args.supply_usd_per_kwh is not None or args.supply_usd_per_kw_month is not None:
        supply_energy, supply_demand = supply_charges(
            hourly_kwh, args.supply_usd_per_kwh or [0.0] * 12, args.supply_usd_per_kw_month or [0.0] * 12)
        out['supply_energy_charge_dollars'] = round(supply_energy, 2)
        out['supply_demand_charge_dollars'] = round(supply_demand, 2)

    print(json.dumps(out))
except:
    msg = f'PySAM error calculating bills with rate {args.kwhpath}'
    print(msg)
    exit(code=1)
