# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2023, Alliance for Sustainable Energy, LLC.
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

require 'csv'
require 'comstock-typical'

# start the measure
class SetNISTInfiltrationCorrelations < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'Set NIST Infiltration Correlations'
  end

  # human readable description
  def description
    return "This measure incorporates infiltration that varies with weather and HVAC operation, and takes into account building geometry (height, above-ground exterior surface area, and volume). It is based on work published by Ng et al. (2018) <a href='https://doi.org/10.1016/j.buildenv.2017.10.029'>'Weather correlations to calculate infiltration rates for U.S. commercial building energy models'</a> and Ng et al. (2021) <a href='https://doi.org/10.1016/j.buildenv.2021.107783'>'Evaluating potential benefits of air barriers in commercial buildings using NIST infiltration correlations in EnergyPlus'</a>. This method of calculating infiltration was developed using eleven of the DOE commercial prototype building models (<a href='https://www.energycodes.gov/development/commercial/prototype_models'>Goel et al. 2014</a>) and TMY3 weather files for eight climate zones (CZ). Guidance on implementing the infiltration correlations are explained in the NIST technical report <a href='https://doi.org/10.6028/NIST.TN.2221'>'Implementing NIST Infiltration Correlations'</a>. Ng et al. (2018) shows that when analyzing the benefits of building envelope airtightening, greater HVAC energy savings were predicted using the infiltration inputs included in this Measure compared with using the default inputs that are included in the prototype building models. Brian Polidoro (NIST) first developed this Measure in 2015 and updated it in 2018 and 2019. Matthew Dahlhausen (NREL) updated the 2019 Measure and published this current version in 2023. To provide feedback on the NIST infiltration correlations, please email infiltration@list.nist.gov or lisa.ng@nist.gov. For measure implementation questions or issues, contact matthew.dahlhausen@nrel.gov."
  end

  # human readable description of modeling approach
  def modeler_description
    return "This measure will remove any existing infiltration objects (OS:SpaceInfiltration:DesignFlowRate and OS:SpaceInfiltration:EffectiveLeakageArea). Every zone will then get two OS:SpaceInfiltration:DesignFlowRate objects that add infiltration using the 'Flow per Exterior Surface Area' input option, one infiltration object when the HVAC system is on and one object when the HVAC system is off. The method assumes that HVAC operation is set by a schedule, though it may not reflect actual simulation/operation when fan operation may depend on internal loads and temperature setpoints. By default, interior zones will receive no infiltration. The user may enter a design building envelope airtightness at a specific design pressure, and whether the design value represents a 4-sided, 5-sided, or 6-sided normalization.  By default, the measure assumes an airtightness design value of 13.8 (m^3/h-m^2) at 75 Pa. The measure assumes that infiltration is evenly distributed across the entire building envelope, including the roof. The user may select the HVAC system operating schedule in the model, or infer it based on the availability schedule of the air loop that serves the largest amount of floor area. The measure will make a copy of the HVAC operating schedule, 'Infiltration HVAC On Schedule', which is used with the HVAC on infiltration correlations.  The measure will also make an 'Infiltration HVAC Off Schedule' with inverse operation, used with the HVAC off infiltration correlations. OS:SpaceInfiltration:DesignFlowRate object coefficients (A, B, C, and D) come from Ng et al. (2018). The user may select the Building Type and Climate Zone, or the measure will infer them from the model."
  end

  # DOE prototype buildings for which there are NIST infiltration coefficients
  def nist_building_types
    building_types = OpenStudio::StringVector.new
    building_types << 'SecondarySchool'
    building_types << 'PrimarySchool'
    building_types << 'SmallOffice'
    building_types << 'MediumOffice'
    building_types << 'SmallHotel'
    building_types << 'LargeHotel'
    building_types << 'RetailStandalone'
    building_types << 'RetailStripmall'
    building_types << 'Hospital'
    building_types << 'MidriseApartment'
    building_types << 'HighriseApartment'

    return building_types
  end

  def infer_nist_building_type(model)
    if model.getBuilding.standardsBuildingType.is_initialized
      model_building_type = model.getBuilding.standardsBuildingType.get
    else
      model_building_type = ''
    end

    case model_building_type
    when 'Office', 'SmallOffice', 'SmallOfficeDetailed', 'MediumOffice', 'MediumOfficeDetailed', 'LargeOffice', 'LargeOfficeDetailed', 'Outpatient', 'OfS', 'OfL', 'SmallDataCenterLowITE', 'SmallDataCenterHighITE', 'LargeDataCenterLowITE', 'LargeDataCenterHighITE'
      # map office or data center building type to small, medium or large
      floor_area = model.getBuilding.floorArea
      if floor_area < 2750.0
        nist_building_type = 'SmallOffice'
      else
        nist_building_type = 'MediumOffice'
      end
    when 'Retail'
      # map retal building type to RetailStripmall or RetailStandalone based on building name
      building_name = model.getBuilding.name.get
      if building_name.include? 'RetailStandalone'
        nist_building_type = 'RetailStandalone'
      else
        nist_building_type = 'RetailStripmall'
      end
    when 'RetailStripmall', 'StripMall', 'Warehouse', 'QuickServiceRestaurant', 'FullServiceRestaurant', 'RtS', 'RSD', 'RFF', 'SCn', 'SUn', 'WRf'
      nist_building_type = 'RetailStripmall'
    when 'RetailStandalone', 'SuperMarket', 'RtL', 'Rt3', 'Gro'
      nist_building_type = 'RetailStandalone'
    when 'PrimarySchool', 'EPr'
      nist_building_type = 'PrimarySchool'
    when 'SecondarySchool', 'ESe', 'College', 'Laboratory'
      nist_building_type = 'SecondarySchool'
    when 'SmallHotel', 'Mtl'
      nist_building_type = 'SmallHotel'
    when 'LargeHotel', 'Htl', 'TallBuilding', 'SuperTallBuilding'
      nist_building_type = 'LargeHotel'
    when 'Hospital', 'Hsp'
      nist_building_type = 'Hospital'
    when 'MidriseApartment'
      nist_building_type = 'MidriseApartment'
    when 'HighriseApartment'
      nist_building_type = 'HighriseApartment'
    when 'Courthouse'
      nist_building_type = 'MediumOffice'
    else
      nist_building_type = model_building_type
    end

    results = {}
    results['model_building_type'] = model_building_type
    results['nist_building_type'] = nist_building_type

    return results
  end

  # method to invert a schedule day
  def invert_schedule_day(old_schedule_day, new_schedule_day, new_schedule_name)
    new_schedule_day.setName(new_schedule_name)
    for index in 0..(old_schedule_day.times.size - 1)
      old_value = old_schedule_day.values[index]
      if old_value == 0
        new_value = 1
      else
        new_value = 0
      end
      new_schedule_day.addValue(old_schedule_day.times[index], new_value)
    end

    return new_schedule_day
  end

  # method to invert a schedule ruleset
  def invert_schedule_ruleset(schedule_ruleset, new_schedule_name)
    model = schedule_ruleset.model
    new_schedule = OpenStudio::Model::ScheduleRuleset.new(model, 0.0)
    new_schedule.setName(new_schedule_name)

    # The design day setters CLONE the day schedule they are handed, so a day schedule built
    # first and handed over is left in the model with no parent once the clone becomes the
    # real child - and orphaned day schedules reach the IDF with no schedule type limits,
    # 214 "Schedule Type Limits Name is empty" lines across a 50-building validation run.
    # As openstudio-standards' create_simple_schedule does: set the design day from the
    # ruleset's own getter, take the clone back, clear it, and fill that.
    # change summer design day
    new_schedule.setSummerDesignDaySchedule(new_schedule.summerDesignDaySchedule)
    new_summer_design_day_schedule = new_schedule.summerDesignDaySchedule
    new_summer_design_day_schedule.clearValues
    invert_schedule_day(schedule_ruleset.summerDesignDaySchedule, new_summer_design_day_schedule, "#{new_schedule_name} Summer Design Day Schedule")

    # change winter design day
    new_schedule.setWinterDesignDaySchedule(new_schedule.winterDesignDaySchedule)
    new_winter_design_day_schedule = new_schedule.winterDesignDaySchedule
    new_winter_design_day_schedule.clearValues
    invert_schedule_day(schedule_ruleset.winterDesignDaySchedule, new_winter_design_day_schedule, "#{new_schedule_name} Winter Design Day Schedule")

    # change the default day values
    default_day_schedule = schedule_ruleset.defaultDaySchedule
    new_default_day_schedule = new_schedule.defaultDaySchedule
    invert_schedule_day(default_day_schedule, new_default_day_schedule, "#{new_schedule_name} Default Day Schedule")

    # change for schedule rules: a rule made on the ruleset owns its day schedule from the
    # start, so fill that rather than handing the constructor one to clone
    schedule_ruleset.scheduleRules.each_with_index do |rule, i|
      old_schedule_day = rule.daySchedule
      new_rule = OpenStudio::Model::ScheduleRule.new(new_schedule)
      new_schedule_day = invert_schedule_day(old_schedule_day, new_rule.daySchedule, "#{new_schedule_name} Schedule Day #{i}")
      new_rule.setName("#{new_schedule_day.name} Rule")
      new_rule.setApplySunday(rule.applySunday)
      new_rule.setApplyMonday(rule.applyMonday)
      new_rule.setApplyTuesday(rule.applyTuesday)
      new_rule.setApplyWednesday(rule.applyWednesday)
      new_rule.setApplyThursday(rule.applyThursday)
      new_rule.setApplyFriday(rule.applyFriday)
      new_rule.setApplySaturday(rule.applySaturday)
    end
    return new_schedule
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # airtightness value
    airtightness_value = OpenStudio::Measure::OSArgument.makeDoubleArgument('airtightness_value', false)
    airtightness_value.setDefaultValue(13.8)
    airtightness_value.setDisplayName('Airtightness design value (m^3/h-m^2)')
    airtightness_value.setDescription('The airtightness design value from a building pressurization test. Use 5.0 (m^3/h-m^2) as a default for buildings with air barriers. Convert (cfm/ft^2) to (m^3/h-m^2) by multiplying by 18.288 (m-min/ft-hr). (0.3048 m/ft)*(60 min/hr) = 18.288 (m-min/ft-hr).')
    args << airtightness_value

    # airtightness pressure
    airtightness_pressure = OpenStudio::Measure::OSArgument.makeDoubleArgument('airtightness_pressure', false)
    airtightness_pressure.setDefaultValue(75.0)
    airtightness_pressure.setDisplayName('Airtightness design pressure (Pa)')
    airtightness_pressure.setDescription('The corresponding pressure for the airtightness design value, typically 75 Pa for commercial buildings and 50 Pa for residential buildings.')
    args << airtightness_pressure

    # choices for air-tightness scope
    airtightness_choices = OpenStudio::StringVector.new
    airtightness_choices << '4-sided'
    airtightness_choices << '5-sided'
    airtightness_choices << '6-sided'

    # airtightness area
    airtightness_area = OpenStudio::Measure::OSArgument.makeChoiceArgument('airtightness_area', airtightness_choices, false)
    airtightness_area.setDefaultValue('5-sided')
    airtightness_area.setDisplayName('Airtightness exterior surface area scope')
    airtightness_area.setDescription('Airtightness measurements are weighted by exterior surface area. 4-sided values divide infiltration by exterior wall area.  5-sided values additionally include roof area. 6-sided values additionally include floor and ground area.')
    args << airtightness_area

    # air barrier
    air_barrier = OpenStudio::Measure::OSArgument.makeBoolArgument('air_barrier', false)
    air_barrier.setDefaultValue(false)
    air_barrier.setDisplayName('Does the building have an air barrier?')
    air_barrier.setDescription('Buildings with air barriers use a different set of coefficients.')
    args << air_barrier

    # populate choice argument for schedules in the model
    sch_handles = OpenStudio::StringVector.new
    sch_display_names = OpenStudio::StringVector.new

    # populate choice argument for schedules that are applied to surfaces in the model
    schedule_handles = OpenStudio::StringVector.new
    schedule_display_names = OpenStudio::StringVector.new

    # putting space types and names into hash
    schedule_names = []
    schedule_names << 'Lookup From Model'
    model.getScheduleRulesets.each { |sch| schedule_names << sch.name.to_s }
    model.getScheduleConstants.each { |sch| schedule_names << sch.name.to_s }

    # hvac operation schedule
    hvac_schedule = OpenStudio::Measure::OSArgument.makeChoiceArgument('hvac_schedule', schedule_names, false, true)
    hvac_schedule.setDefaultValue('Lookup From Model')
    hvac_schedule.setDisplayName('HVAC Operating Schedule')
    hvac_schedule.setDescription('Choose the HVAC Operating Schedule for the building. The schedule must be a Schedule Constant or Schedule Ruleset object. Lookup From Model will use the operating schedule from the largest airloop by floor area served. If the largest airloop serves less than 5% of the building, the measure will attempt to use the Building Hours of Operation schedule instead.')
    args << hvac_schedule

    # climate zone options
    cz_choices = OpenStudio::StringVector.new
    cz_choices << '1A'
    cz_choices << '1B'
    cz_choices << '2A'
    cz_choices << '2B'
    cz_choices << '3A'
    cz_choices << '3B'
    cz_choices << '3C'
    cz_choices << '4A'
    cz_choices << '4B'
    cz_choices << '4C'
    cz_choices << '5A'
    cz_choices << '5B'
    cz_choices << '5C'
    cz_choices << '6A'
    cz_choices << '6B'
    cz_choices << '7A'
    cz_choices << '8A'
    cz_choices << 'Lookup From Model'

    # climate zone
    climate_zone = OpenStudio::Measure::OSArgument.makeChoiceArgument('climate_zone', cz_choices, false)
    climate_zone.setDefaultValue('Lookup From Model')
    climate_zone.setDisplayName('Climate Zone')
    climate_zone.setDescription('Specify the ASHRAE climate zone. CEC climate zones are not supported.')
    args << climate_zone

    # building type options
    building_types = nist_building_types
    building_types << 'Lookup From Model'

    # building type
    building_type = OpenStudio::Measure::OSArgument.makeChoiceArgument('building_type', building_types, false)
    building_type.setDefaultValue('Lookup From Model')
    building_type.setDisplayName('Building Type')
    building_type.setDescription('If the building type is not available, pick the one with the most similar geometry and exhaust fan flow rates.')
    args << building_type

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # assign the user inputs to variables
    airtightness_value = runner.getDoubleArgumentValue('airtightness_value', user_arguments)
    airtightness_pressure = runner.getDoubleArgumentValue('airtightness_pressure', user_arguments)
    airtightness_area = runner.getStringArgumentValue('airtightness_area', user_arguments)
    air_barrier = runner.getBoolArgumentValue('air_barrier', user_arguments)
    hvac_schedule = runner.getStringArgumentValue('hvac_schedule', user_arguments)
    climate_zone = runner.getStringArgumentValue('climate_zone', user_arguments)
    building_type = runner.getStringArgumentValue('building_type', user_arguments)

    # validate airtightness value and pressure
    if airtightness_value < 0.0
      runner.registerError('Airtightness value must be postive.')
      return false
    end

    if airtightness_pressure < 0.0
      runner.registerError('Airtightness pressure must be postive.')
      return false
    end

    # calculate infiltration design value at 4 Pa
    airtightness_value_4pa_per_hr = airtightness_value * ((4.0 / airtightness_pressure)**0.65)
    runner.registerInfo("User-inputed airtightness design value #{airtightness_value} (m^3/h-m^2) at #{airtightness_pressure} Pa converts to #{airtightness_value_4pa_per_hr.round(7)} (m^3/h-m^2) at 4 Pa")

    # convert to m^3/s-m^2
    airtightness_value_4pa_per_s = airtightness_value_4pa_per_hr / 3600.0

    # get 4-sided, 5-sided, and 6-sided areas
    exterior_wall_area = 0.0
    exterior_roof_area = 0.0
    exterior_floor_area = 0.0
    ground_wall_area = 0.0
    ground_roof_area = 0.0
    ground_floor_area = 0.0
    model.getSurfaces.each do |surface|
      bc = surface.outsideBoundaryCondition
      type = surface.surfaceType
      area = surface.grossArea
      exterior_wall_area += area if bc == 'Outdoors' && type == 'Wall'
      exterior_roof_area += area if bc == 'Outdoors' && type == 'RoofCeiling'
      exterior_floor_area += area if bc == 'Outdoors' && type == 'Floor'
      ground_wall_area += area if bc == 'Ground' && type == 'Wall'
      ground_roof_area += area if bc == 'Ground' && type == 'RoofCeiling'
      ground_floor_area += area if bc == 'Ground' && type == 'Floor'
    end
    four_sided_area = exterior_wall_area + ground_wall_area
    five_sided_area = exterior_wall_area + ground_wall_area + exterior_roof_area + ground_roof_area
    six_sided_area = exterior_wall_area + ground_wall_area + exterior_roof_area + ground_roof_area + exterior_floor_area + ground_floor_area
    energy_plus_area = exterior_wall_area + exterior_roof_area
    runner.registerInfo("4-sided area = #{four_sided_area.round(2)} m^2, 5-sided area = #{five_sided_area.round(2)} m^2, 6-sided area = #{six_sided_area.round(2)} m^2.")

    # The SpaceInfiltrationDesignFlowRate object FlowperExteriorSurfaceArea method only counts surfaces with the 'Outdoors' boundary conditions towards exterior surface area, not surfaces with the 'Ground' boundary conditions.  That means all values need to be normalized to exterior wall and roof area.
    case airtightness_area
    when '4-sided'
      design_infiltration_4pa = airtightness_value_4pa_per_s * (four_sided_area / energy_plus_area)
      runner.registerInfo("#{airtightness_area} infiltration design value #{airtightness_value_4pa_per_s.round(7)} (m^3/s-m^2) converted to #{design_infiltration_4pa.round(7)} (m^3/s-m^2) based on 4-sided area #{four_sided_area.round(2)} m^2 and 5-sided area #{energy_plus_area.round(2)} m^2 excluding ground boundary surfaces for energyplus.")
    when '5-sided'
      design_infiltration_4pa = airtightness_value_4pa_per_s * (five_sided_area / energy_plus_area)
      runner.registerInfo("#{airtightness_area} infiltration design value #{airtightness_value_4pa_per_s.round(7)} (m^3/s-m^2) converted to #{design_infiltration_4pa.round(7)} (m^3/s-m^2) based on 5-sided area #{five_sided_area.round(2)} m^2 and 5-sided area #{energy_plus_area.round(2)} m^2 excluding ground boundary surfaces for energyplus.")
    when '6-sided'
      design_infiltration_4pa = airtightness_value_4pa_per_s * (six_sided_area / energy_plus_area)
      runner.registerInfo("#{airtightness_area} infiltration design value #{airtightness_value_4pa_per_s.round(7)} (m^3/s-m^2) converted to #{design_infiltration_4pa.round(7)} (m^3/s-m^2) based on 6-sided area #{six_sided_area.round(2)} m^2 and 5-sided area #{energy_plus_area.round(2)} m^2 excluding ground boundary surfaces for energyplus.")
    end
    runner.registerValue('design_infiltration_4pa', design_infiltration_4pa, 'm/s')

    # validate hvac schedule
    if hvac_schedule == 'Lookup From Model'
      # lookup from model, using largest air loop
      # check multiple kinds of systems, including unitary systems
      hvac_schedule = nil
      largest_area = 0.0

      model.getAirLoopHVACs.each do |air_loop|
        air_loop_area = 0.0
        air_loop.thermalZones.each { |tz| air_loop_area += tz.floorArea * tz.multiplier }
        if air_loop_area > largest_area
          hvac_schedule = air_loop.availabilitySchedule
          largest_area = air_loop_area
        end
      end

      model.getAirLoopHVACUnitarySystems.each do |unitary|
        next unless unitary.thermalZone.is_initialized

        tz = unitary.thermalZone.get
        air_loop_area = tz.floorArea * tz.multiplier
        if air_loop_area > largest_area
          if unitary.availabilitySchedule.is_initialized
            hvac_schedule = unitary.availabilitySchedule.get
          else
            hvac_schedule = model.alwaysOnDiscreteSchedule
          end
          largest_area = air_loop_area
        end
      end

      model.getAirLoopHVACUnitaryHeatPumpAirToAirs.each do |unitary|
        next unless unitary.controllingZone.is_initialized

        tz = unitary.controllingZone.get
        air_loop_area = tz.floorArea * tz.multiplier
        if air_loop_area > largest_area
          hvac_schedule = unitary.availabilitySchedule.get
          largest_area = air_loop_area
        end
      end

      model.getAirLoopHVACUnitaryHeatPumpAirToAirMultiSpeeds.each do |unitary|
        next unless unitary.controllingZoneorThermostatLocation.is_initialized

        tz = unitary.controllingZoneorThermostatLocation.get
        air_loop_area = tz.floorArea * tz.multiplier
        if air_loop_area > largest_area
          if unitary.availabilitySchedule.is_initialized
            hvac_schedule = unitary.availabilitySchedule.get
          else
            hvac_schedule = model.alwaysOnDiscreteSchedule
          end
          largest_area = air_loop_area
        end
      end

      model.getFanZoneExhausts.each do |fan|
        next unless fan.thermalZone.is_initialized

        tz = fan.thermalZone.get
        air_loop_area = tz.floorArea * tz.multiplier
        if air_loop_area > largest_area
          if fan.availabilitySchedule.is_initialized
            hvac_schedule = fan.availabilitySchedule.get
          else
            hvac_schedule = model.alwaysOnDiscreteSchedule
          end
          largest_area = air_loop_area
        end
      end

      building_area = model.getBuilding.floorArea
      if largest_area < (0.05 * building_area)
        runner.registerWarning("The largest airloop or HVAC system serves #{largest_area.round(1)} m^2, which is less than 5% of the building area #{building_area.round(1)} m^2. Attempting to use building hours of operation schedule instead.")
        default_schedule_set = model.getBuilding.defaultScheduleSet
        if default_schedule_set.is_initialized
          default_schedule_set = default_schedule_set.get
          hoo = default_schedule_set.hoursofOperationSchedule
          if hoo.is_initialized
            hvac_schedule = hoo.get
            largest_area = building_area
          else
            runner.registerWarning('Unable to determine building hours of operation schedule. Treating the building as if there is no HVAC system schedule.')
            hvac_schedule = nil
          end
        else
          runner.registerWarning('Unable to determine building hours of operation schedule. Treating the building as if there is no HVAC system schedule.')
          hvac_schedule = nil
        end
      end

      unless hvac_schedule.nil?
        area_fraction = 100.0 * largest_area / building_area
        runner.registerInfo("Using schedule #{hvac_schedule.name} serving area #{largest_area.round(1)} m^2, #{area_fraction.round(0)}% of building area #{building_area.round(1)} m^2 to determine infiltration on/off schedule.")
      end
    else
      hvac_schedule = model.getScheduleByName(hvac_schedule)
      unless schedule_object.is_initialized
        runner.registerError("HVAC schedule argument #{hvac_schedule} not found in the model. IT may have been removed by another measure.")
        return false
      end
      hvac_schedule = hvac_schedule.get
      if hvac_schedule.get.to_ScheduleRuleset.is_initialized
        hvac_schedule = hvac_schedule.get.to_ScheduleRuleset.get
      elsif hvac_schedule.get.to_ScheduleConstant.is_initialized
        hvac_schedule = hvac_schedule.get.to_ScheduleConstant.get
      else
        runner.registerError("HVAC schedule argument #{hvac_schedule} is not a Schedule Constant or Schedule Ruleset object.")
        return false
      end

      runner.registerInfo("Using HVAC schedule #{hvac_schedule.name} from user arguments to determine infiltration on/off schedule.")
    end

    # creating infiltration schedules based on hvac schedule
    if hvac_schedule.nil?
      runner.registerWarning('Unable to determine the HVAC schedule. Treating the building as if there is no HVAC system with outdoor air.  If this is not the case, input a schedule argument, or assign one to an air loop in the model.')
      on_schedule = OpenStudio::Model::ScheduleConstant.new(model)
      on_schedule.setName('Infiltration HVAC On Schedule')
      on_schedule.setValue(0.0)
      off_schedule = OpenStudio::Model::ScheduleConstant.new(model)
      off_schedule.setName('Infiltration HVAC Off Schedule')
      off_schedule.setValue(1.0)
    elsif hvac_schedule.to_ScheduleConstant.is_initialized
      hvac_schedule = hvac_schedule.to_ScheduleConstant.get
      on_schedule = OpenStudio::Model::ScheduleConstant.new(model)
      on_schedule.setName('Infiltration HVAC On Schedule')
      on_schedule.setValue(hvac_schedule.value)
      off_schedule = OpenStudio::Model::ScheduleConstant.new(model)
      off_schedule.setName('Infiltration HVAC Off Schedule')
      if hvac_schedule.value > 0
        off_schedule.setValue(0.0)
      else
        off_schedule.setValue(1.0)
      end
    elsif hvac_schedule.to_ScheduleRuleset.is_initialized
      hvac_schedule = hvac_schedule.to_ScheduleRuleset.get
      on_schedule = hvac_schedule.clone.to_ScheduleRuleset.get
      on_schedule.setName('Infiltration HVAC On Schedule')
      off_schedule = invert_schedule_ruleset(hvac_schedule, 'Infiltration HVAC Off Schedule')
    end

    # State the type limits. The infiltration schedule slot does not stamp them, so without
    # this EnergyPlus reports "Schedule Type Limits Name is empty ... Schedule will not be
    # validated" for these schedules and every day profile inside them. This mirrors what
    # OpenstudioStandards::Infiltration.model_set_nist_infiltration_schedules does; this
    # measure carries its own copy of that logic.
    infiltration_schedule_type_limits = OpenstudioStandards::Schedules.create_schedule_type_limits(model, standard_schedule_type_limit: 'Fractional')
    [on_schedule, off_schedule].each { |schedule| schedule.setScheduleTypeLimits(infiltration_schedule_type_limits) }

    # validate climate zone
    if climate_zone == 'Lookup From Model'
      climate_zone = ''
      model.getClimateZones.climateZones.each do |cz|
        next if cz.value == ''

        cz_institution = cz.institution
        if cz_institution == 'ASHRAE'
          climate_zone = cz.value
          climate_zone = climate_zone.gsub('ASHRAE 169-2006-', '')
          climate_zone = climate_zone.gsub('ASHRAE 169-2013-', '')
          climate_zone = climate_zone.gsub('ASHRAE 169-2020-', '')
          climate_zone = climate_zone.gsub('ASHRAE 169-2021-', '')
        elsif cz_institution == 'CEC'
          california_cz = cz.value.gsub('CEC', '')
          case california_cz
          when '1'
            climate_zone = '4B'
          when '2', '3', '4', '5', '6'
            climate_zone = '3C'
          when '7', '8', '9', '10', '11', '12', '13', '14'
            climate_zone = '3B'
          when '15'
            climate_zone = '2B'
          when '16'
            climate_zone = '5B'
          end
          runner.registerWarning("Using ASHRAE climate zone #{climate_zone} for California climate zone #{california_cz}.")
        end
      end

      if climate_zone == ''
        runner.registerError('Unable to determine an ASHRAE climate zone for the model.  An ASHRAE climate zone value is necessary to lookup the coefficients.')
        return false
      end

      runner.registerInfo("Using climate zone #{climate_zone} from model.")
    else
      runner.registerInfo("Using climate zone #{climate_zone} from user arguments.")
    end

    # get climate zone number
    climate_zone_number = climate_zone.delete('^0-9').to_i

    # validate building type
    if building_type == 'Lookup From Model'

      # get building type from the model
      building_type_data = infer_nist_building_type(model)
      model_building_type = building_type_data['model_building_type']
      nist_building_type = building_type_data['nist_building_type']
      building_type = nist_building_type

      # check that model building type is supported
      unless nist_building_types.include? nist_building_type
        runner.registerError("NIST coefficients are not available for model building type #{nist_building_type}.")
        return false
      end

      # warn the user if the model building type is different from support nist building types
      if model_building_type == nist_building_type
        runner.registerInfo("Using building type #{building_type} from model.")
      else
        runner.registerWarning("Using building type #{building_type} for model building type #{model_building_type}.")
      end
    else
      runner.registerInfo("Using building type #{building_type} from user arguments.")
    end

    # remove existing infiltration objects
    runner.registerInitialCondition("The modeled started with #{model.getSpaceInfiltrationDesignFlowRates.size} infiltration objects and #{model.getSpaceInfiltrationEffectiveLeakageAreas.size} effective leakage area objects.")
    model.getSpaceInfiltrationDesignFlowRates.each(&:remove)
    model.getSpaceInfiltrationEffectiveLeakageAreas.each(&:remove)

    # load NIST infiltration correlations file and convert to hash table
    nist_infiltration_correlations_csv = "#{File.dirname(__FILE__)}/resources/Data-NISTInfiltrationCorrelations.csv"
    if !File.file?(nist_infiltration_correlations_csv)
      runner.registerError("Unable to find file: #{nist_infiltration_correlations_csv}")
      return nil
    end
    coefficients_tbl = CSV.table(nist_infiltration_correlations_csv)
    coefficients_hsh = coefficients_tbl.map(&:to_hash)

    # select down to building type and climate zone
    coefficients = coefficients_hsh.select { |r| (r[:building_type] == building_type) && (r[:climate_zone] == climate_zone_number) }

    # filter by air barrier
    if air_barrier
      coefficients = coefficients.select { |r| r[:air_barrier] == 'yes' }
    else
      coefficients = coefficients.select { |r| r[:air_barrier] == 'no' }
    end

    # determine coefficients
    # if no off coefficients are defined, use 0 for a and the on coefficients for b and d
    on_coefficients = coefficients.select { |r| r[:hvac_status] == 'on' }
    off_coefficients = coefficients.select { |r| r[:hvac_status] == 'off' }
    a_on = on_coefficients[0][:a]
    b_on = on_coefficients[0][:b]
    d_on = on_coefficients[0][:d]
    a_off = off_coefficients[0][:a].nil? ? on_coefficients[0][:a] : off_coefficients[0][:a]
    b_off = off_coefficients[0][:b].nil? ? on_coefficients[0][:b] : off_coefficients[0][:b]
    d_off = off_coefficients[0][:d].nil? ? on_coefficients[0][:d] : off_coefficients[0][:d]

    # add new infiltration objects
    # define infiltration as flow per exterior area
    model.getSpaces.each do |space|
      next unless space.exteriorArea > 0.0

      hvac_on_infiltration = OpenStudio::Model::SpaceInfiltrationDesignFlowRate.new(model)
      hvac_on_infiltration.setName("#{space.name.get} HVAC On Infiltration")
      hvac_on_infiltration.setFlowperExteriorSurfaceArea(design_infiltration_4pa)
      hvac_on_infiltration.setConstantTermCoefficient(a_on)
      hvac_on_infiltration.setTemperatureTermCoefficient(b_on)
      hvac_on_infiltration.setVelocityTermCoefficient(0.0)
      hvac_on_infiltration.setVelocitySquaredTermCoefficient(d_on)
      hvac_on_infiltration.setSpace(space)
      hvac_on_infiltration.setSchedule(on_schedule)

      hvac_off_infiltration = OpenStudio::Model::SpaceInfiltrationDesignFlowRate.new(model)
      hvac_off_infiltration.setName("#{space.name.get} HVAC Off Infiltration")
      hvac_off_infiltration.setFlowperExteriorSurfaceArea(design_infiltration_4pa)
      hvac_off_infiltration.setConstantTermCoefficient(a_off)
      hvac_off_infiltration.setTemperatureTermCoefficient(b_off)
      hvac_off_infiltration.setVelocityTermCoefficient(0.0)
      hvac_off_infiltration.setVelocitySquaredTermCoefficient(d_off)
      hvac_off_infiltration.setSpace(space)
      hvac_off_infiltration.setSchedule(off_schedule)
    end

    runner.registerFinalCondition("The modeled finished with #{model.getSpaceInfiltrationDesignFlowRates.size} infiltration objects.")

    return true
  end
end

# register the measure to be used by the application
SetNISTInfiltrationCorrelations.new.registerWithApplication
