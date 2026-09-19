# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2021, Alliance for Sustainable Energy, LLC.
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# (1) Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# (2) Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# (3) Neither the name of the copyright holder nor the names of any contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission from the respective party.
#
# (4) Other than as required in clauses (1) and (2), distributions in any form
# of modifications or other derivative works may not use the "OpenStudio"
# trademark, "OS", "os", or any other confusingly similar designation without
# specific prior written permission from Alliance for Sustainable Energy, LLC.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER(S) AND ANY CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
# THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER(S), ANY CONTRIBUTORS, THE
# UNITED STATES GOVERNMENT, OR THE UNITED STATES DEPARTMENT OF ENERGY, NOR ANY OF
# THEIR EMPLOYEES, BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
# OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# *******************************************************************************

# Measure distributed under NREL Copyright terms, see LICENSE.md file.

# start the measure
class ElectricResistanceBoilers < OpenStudio::Measure::ModelMeasure
  require 'comstock-typical'

  # human readable name
  def name
    # Measure name should be the title case of the class name.
    'electric_resistance_boilers'
  end

  # human readable description
  def description
    'This measure replaces an exising natural gas boiler with an electric resistance boiler.'
  end

  # human readable description of modeling approach
  def modeler_description
    'This measure replaces an exising natural gas boiler with an electric resistance boiler. The measure loops through existing boiler objects and switches the fuel to "electricity". It also increases the nominal efficiency to 100% and replaces the efficiency curve to one representing electric boilers.'
  end

  ## USER ARGS ---------------------------------------------------------------------------------------------------------
  # define the arguments that the user will input
  def arguments(_model)
    OpenStudio::Measure::OSArgumentVector.new
  end
  ## END USER ARGS -----------------------------------------------------------------------------------------------------

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # report initial condition of model
    num_boilers = model.getBoilerHotWaters.size
    runner.registerInitialCondition("The building started with #{num_boilers} hot water boilers.")

    # check for existence of water heater boiler
    if model.getBoilerHotWaters.empty?
      runner.registerAsNotApplicable('No hot water boilers found in the model. Measure not applicable ')
      return true
    end

    # create new linear performance curve EIR = 0.02*PLR + 0.98 (from MASControl3 database)
    elec_boiler_curve = OpenStudio::Model::CurveLinear.new(model)
    elec_boiler_curve.setName('Electric Boiler Efficiency Curve')
    elec_boiler_curve.setCoefficient1Constant(0.98)
    elec_boiler_curve.setCoefficient2x(0.02)

    boilers = model.getBoilerHotWaters
    boilers.each do |boiler|
      # get existing fuel type and efficiency
      existing_boiler_fuel_type = boiler.fuelType
      existing_boiler_efficiency = boiler.nominalThermalEfficiency
      existing_boiler_capacity = boiler.nominalCapacity

      runner.registerInfo("Existing boiler #{boiler.name} has nominal efficiency #{existing_boiler_efficiency}, fuel type #{existing_boiler_fuel_type}, and nominal capacity #{existing_boiler_capacity} W.")

      # set fuel to electricity and efficiency to 1.0 to reflect electric boiler
      boiler.setFuelType('Electricity')
      boiler.setNominalThermalEfficiency(1.0)

      # set new performance curve
      boiler.setNormalizedBoilerEfficiencyCurve(elec_boiler_curve)

      # autosize the boiler capacity. should not make a difference if running standalone measure, but could downsize if run with other upgrades.
      boiler.autosizeNominalCapacity
      boiler.autosizeDesignWaterFlowRate

      # rename boiler
      boiler.setName('Electric Boiler Thermal Eff 1.0')
    end

    # Register final condition
    runner.registerFinalCondition("The building finished with #{num_boilers} electric boilers.")
    true
  end
end

# register the measure to be used by the application
ElectricResistanceBoilers.new.registerWithApplication
