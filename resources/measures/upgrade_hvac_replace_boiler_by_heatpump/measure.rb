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

# Author: Korbaga Woldekidan
# Date: Nov 2022 - Dec 2022

# References:
# EnergyPlus InputOutput Reference, Sections:
# https://www.nrcan.gc.ca/sites/nrcan/files/canmetenergy/pdf/ASHP%20Sizing%20and%20Selection%20Guide%20(EN).pdf

# start the measure
class ReplaceBoilerWithHeatPump < OpenStudio::Measure::ModelMeasure
  require 'comstock-typical'

  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'replace_boiler_by_heatpump'
  end

  # human readable description
  def description
    'This measure replaces an exising natural gas boiler by an air source heat pump. An electric resister element or the existing boiler could be used as a back up heater. The heat pump could be sized to handle the entire heating load or a percentage of the heating load with a back up system handling the rest. '
  end

  # human readable description of modeling approach
  def modeler_description
    return 'This measure replaces an exising natural gas boiler by an air source heat pump. An electric resister element or the existing boiler could be used as a back up heater. The heat pump could be sized to handle the entire heating load or a percentage of the heating load with a back up system handling the rest.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # create argument for keeping the hot water loop temperature setpoint
    keep_setpoint = OpenStudio::Measure::OSArgument.makeBoolArgument('keep_setpoint', true)
    keep_setpoint.setDisplayName('Keep existing hot water loop setpoint?')
    keep_setpoint.setDescription('')
    keep_setpoint.setDefaultValue(false)
    args << keep_setpoint

    hw_setpoint_f = OpenStudio::Measure::OSArgument.makeDoubleArgument('hw_setpoint_F', true)
    hw_setpoint_f.setDisplayName('Set hot water setpoint [F]')
    hw_setpoint_f.setDescription('Applicable only if user chooses to change the existing hot water setpoint')
    hw_setpoint_f.setDefaultValue(140)
    args << hw_setpoint_f

    # create argument for removal of existing water heater tanks on selected loop
    autosize_hc = OpenStudio::Measure::OSArgument.makeBoolArgument('autosize_hc', true)
    autosize_hc.setDisplayName('Autosize heating coils?')
    autosize_hc.setDescription('Applicable only if user chooses to change the hot water setpoint')
    autosize_hc.setDefaultValue(true)
    args << autosize_hc

    # Checkig for ng bilers and their capacity in the Hot Water loop
    wh_cap = []
    loops = model.getPlantLoops
    loops.each do |l|
      if l.name.get.to_s == 'Hot Water Loop'
        l.supplyComponents.each do |supply_comp|
          if supply_comp.to_BoilerHotWater.is_initialized
            wheater = supply_comp.to_BoilerHotWater.get
            if wheater.nominalCapacity.is_initialized
              wh_cap << wheater.nominalCapacity.get.to_f
            elsif wheater.isNominalCapacityAutosized
              wh_cap << wheater.autosizedNominalCapacity.to_f
            else
              wh_cap << 0.0
            end
          end
        end
      else
        wh_cap << 0.0
      end
    end

    # winter design day temperature for heat pump sizinig
    hd_temps = []
    dds = model.getDesignDays
    dds.each do |dd|
      dt = dd.dayType
      dt_name = dd.name.get
      if dt.include?('WinterDesignDay') && dt_name.include?('99.6% Condns DB')
        hd_temps << dd.maximumDryBulbTemperature.to_f # heating design day temperature
      end
    end
    if hd_temps.empty?
      hd_temp = 0 # assign a design day temperature of 0oC if heating design day temperature is not found in the model
    else
      hd_temp = hd_temps[0]
    end
    hd_temp_f = OpenStudio.convert(hd_temp, 'C', 'F').get

    # create argument for sizing method
    sizing_method = OpenStudio::Measure::OSArgument.makeChoiceArgument('sizing_method', ['Percentage of Peak Load', 'Outdoor Air Temperature'], true)
    sizing_method.setDisplayName('Select heat pump water heater sizing method')
    sizing_method.setDescription('')
    sizing_method.setDefaultValue('Outdoor Air Temperature')
    args << sizing_method

    # estimate default sizing percentage at 17oF(-8.6oC), recommended oat for heat pump sizing in colder climates
    if wh_cap[0].nil? || wh_cap[0] == 0
      def_percentage = 70.0
    else
      tar_cap = [(15.56 - -8.6) * wh_cap[0] / (15.56 - hd_temp), wh_cap[0]].min
      def_percentage = ((tar_cap / wh_cap[0]) * 100).round(1)
    end

    hp_sizing_temp = OpenStudio::Measure::OSArgument.makeDoubleArgument('hp_sizing_temp', true)
    hp_sizing_temp.setDisplayName('HP Sizing Temperature[F]')
    hp_sizing_temp.setDescription('Applicable only if "Based on Outdoor Temperature" is selected for the sizing method')
    # sizing will be done by the max of either the winter design temp or 17oF, recommended oat for heat pump sizing in colder climates
    hp_sizing_temp.setDefaultValue([17, hd_temp_f.round(1)].max)
    args << hp_sizing_temp

    hp_sizing_per = OpenStudio::Measure::OSArgument.makeDoubleArgument('hp_sizing_per', true)
    hp_sizing_per.setDisplayName('HP Sizing Percentage[%]')
    hp_sizing_per.setDescription('Applicable only if "Percentage of Peak Load" is selected for the sizing method')
    hp_sizing_per.setDefaultValue(def_percentage)
    args << hp_sizing_per

    # max design heat pump capacity at the design condistion. Default is 1500MBH (439kW) based on Trane Ascend air-to-water heat pump series
    hp_des_cap = OpenStudio::Measure::OSArgument.makeDoubleArgument('hp_des_cap', true)
    hp_des_cap.setDisplayName('Rated ASHP heating capacity per unit [kW]')
    hp_des_cap.setDescription('')
    hp_des_cap.setDefaultValue(40.0)
    args << hp_des_cap

    # create argument for backup heater
    bu_type = OpenStudio::Measure::OSArgument.makeChoiceArgument('bu_type', ['Existing Boiler', 'New Electric Resistance Heater'], true)
    bu_type.setDisplayName('Select backup heater')
    bu_type.setDescription('')
    bu_type.setDefaultValue('Existing Boiler')
    args << bu_type

    # set a heat pump cut-off tempeerature
    hpwh_cutoff_t = OpenStudio::Measure::OSArgument.makeDoubleArgument('hpwh_cutoff_T', true)
    hpwh_cutoff_t.setDisplayName('Set the heat pump cutoff temperature [F]')
    hpwh_cutoff_t.setDescription('')
    hpwh_cutoff_t.setDefaultValue(-5.0)
    args << hpwh_cutoff_t

    # reset outdoor air condition for the heat pump
    hpwh_design_oat = OpenStudio::Measure::OSArgument.makeDoubleArgument('hpwh_Design_OAT', true)
    hpwh_design_oat.setDisplayName('Set the heat pump design outdoor air temperature to base the performance data [F]')
    hpwh_design_oat.setDescription('')
    hpwh_design_oat.setDefaultValue(47.0)
    args << hpwh_design_oat

    # create argument for heat pump rated cop
    cop = OpenStudio::Measure::OSArgument.makeDoubleArgument('cop', true)
    cop.setDisplayName('Set heat pump rated COP (heating)')
    cop.setDescription('Applicaeble if Custom Performance Data is selected')
    cop.setDefaultValue(2.85)
    args << cop

    args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    unless runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # report initial condition of model
    hpwh_ic = model.getBoilerHotWaters.size
    runner.registerInitialCondition("The building started with #{hpwh_ic} hot water boilers.")

    # assign the user inputs to variables
    keep_setpoint = runner.getBoolArgumentValue('keep_setpoint', user_arguments)
    hw_setpoint_f = runner.getDoubleArgumentValue('hw_setpoint_F', user_arguments)
    autosize_hc = runner.getBoolArgumentValue('autosize_hc', user_arguments)

    sizing_method = runner.getStringArgumentValue('sizing_method', user_arguments)
    hp_sizing_temp_f = runner.getDoubleArgumentValue('hp_sizing_temp', user_arguments)
    hp_sizing_per_100 = runner.getDoubleArgumentValue('hp_sizing_per', user_arguments)

    hp_sizing_temp = OpenStudio.convert(hp_sizing_temp_f, 'F', 'C').get

    hp_des_cap = runner.getDoubleArgumentValue('hp_des_cap', user_arguments)
    cop = runner.getDoubleArgumentValue('cop', user_arguments)
    hpwh_cutoff_t_f = runner.getDoubleArgumentValue('hpwh_cutoff_T', user_arguments)
    hpwh_design_oat_f = runner.getDoubleArgumentValue('hpwh_Design_OAT', user_arguments)

    # Unit conversion
    hpwh_cutoff_t = OpenStudio.convert(hpwh_cutoff_t_f, 'F', 'C').get
    hpwh_design_oat = OpenStudio.convert(hpwh_design_oat_f, 'F', 'C').get

    bu_type = runner.getStringArgumentValue('bu_type', user_arguments)

    # check for existence of water heater boiler (if "all" is selected)
    if model.getBoilerHotWaters.empty?
      runner.registerAsNotApplicable('No hot water boiler found in the model. Measure not applicable.')
      return true
    end

    if hw_setpoint_f > 160
      runner.registerWarning("#{hw_setpoint_f}F is above or near the limit of the HP performance curves. If the simulation fails with cooling capacity less than 0, you have exceeded performance limits. Consider setting max temp to less than 160F.")
    end

    # use OS standards build
    std = Standard.build('NREL ZNE Ready 2017')

    # heat pump performance curve coefficients
    # performace curve data for the heat pump
    hpwh_cap_coefficient1constant = 0.883027485
    hpwh_cap_coefficient2x = -0.001651307
    hpwh_cap_coefficient3xpow2 = 1.44E-05
    hpwh_cap_coefficient4y = 0.018333846
    hpwh_cap_coefficient5ypow2 = 3.63958E-05
    hpwh_cap_coefficient6xtimesy = -2.0405E-05

    hpwh_eir_coefficient1constant = 0.841776467
    hpwh_eir_coefficient2x = 0.006485039
    hpwh_eir_coefficient3xpow2 = -8.68E-06
    hpwh_eir_coefficient4y = -0.027367731
    hpwh_eir_coefficient5ypow2 = 0.000187536
    hpwh_eir_coefficient6xtimesy = 0.000108196

    hpwh_eir_plr_coefficient1constant = 1.25
    hpwh_eir_plr_coefficient2x = -0.25
    hpwh_eir_plr_coefficient3xpow2 = 0

    if keep_setpoint == true # keep the origional hot water setpoint
      # get boiler hot water schedule that will be used as a default
      scheds = []
      loops = model.getPlantLoops
      loops.each do |l|
        if l.name.get.to_s == 'Hot Water Loop'
          l.supplyComponents.each do |supply_comp|
            if supply_comp.to_BoilerHotWater.is_initialized
              l.supplyOutletNode.setpointManagers.each do |spm|
                sched = spm.to_SetpointManagerScheduled.get.schedule
                scheds << sched
              end
            end
          end
        end
      end

      # extracting hot water setpoint temperature value to apply for the heat pump setpoint
      sched = scheds[0]
      day_value = sched.to_ScheduleRuleset.get.defaultDaySchedule
      hw_setpoint_c = day_value.values[0].to_f
    else # assign a new hot water setpoint based on user input
      hw_setpoint_c = OpenStudio.convert(hw_setpoint_f, 'F', 'C').get
    end

    # new schedule object for hot water setpoint
    sched = OpenStudio::Model::ScheduleRuleset.new(model, hw_setpoint_c)
    sched.setName('Heat Pump Heating Temperature Setpoint')
    sched.defaultDaySchedule.setName('Heat Pump Heating Temperature Setpoint Default')

    # Find all ng boilers in the hot water loop
    whtrs = []
    loops = model.getPlantLoops
    loops.each do |l|
      if l.name.get.to_s == 'Hot Water Loop'
        l.supplyComponents.each do |supply_comp|
          if supply_comp.to_BoilerHotWater.is_initialized
            wheater = supply_comp.to_BoilerHotWater.get
            if wheater.fuelType.to_s == 'NaturalGas'
              whtrs << wheater
            end
          end
        end
      end
    end

    # don't apply this measure if no ng boiler exist in the hot water loop
    if whtrs.empty?
      runner.registerAsNotApplicable('No natural gas hot water boiler found in the Hot Water Loop. Measure not applicable.')
      return true
    end

    # get boilers capacity
    tot_blr_cap = 0
    cap_blr = []
    whtrs.each do |whtr|
      if whtr.nominalCapacity.is_initialized
        cap_blr << whtr.nominalCapacity.get.to_f
      elsif whtr.autosizedNominalCapacity.is_initialized
        cap_blr << whtr.autosizedNominalCapacity.get.to_f
      else
        cap_blr << 0
      end
    end

    # estimating total ng boilers heating capacity in the hot water loop
    cap_blr.each { |val| tot_blr_cap += val }

    #### unitary systems consideration #####
    # if the model has unitary systems that are autosized without specifying the flow rate method during heating operation, running the 'autosizing' measure will crush with
    # the following error "Blank field not allowed for this coil type when cooling coil air flow rate is not AutoSized". To avoid this, if the flow rate method is blank, a default method
    # called "SupplyAirFlowRate" is assigned

    unitarys = model.getAirLoopHVACUnitarySystems
    unitarys.each do |unit|
      flowmethod = unit.supplyAirFlowRateMethodDuringHeatingOperation
      runner.registerInfo("flow method is #{flowmethod} ")
      if model.version < OpenStudio::VersionString.new('3.7.0')
        if flowmethod == ''
          unit.setSupplyAirFlowRateMethodDuringHeatingOperation('SupplyAirFlowRate')
          runner.registerInfo("SupplyAirFlowRateMethodDuringHeatingOperation is reset to use 'SupplyAirFlowRate' method")
        end
      else
        if flowmethod == ''
          unit.autosizeSupplyAirFlowRateDuringHeatingOperation
          runner.registerInfo("SupplyAirFlowRateMethodDuringHeatingOperation is reset to use 'SupplyAirFlowRate' method")
        end
      end
    end

    # perform autosizing to find boiler capacity if hard coded values don't exist in the model
    if tot_blr_cap.nil? || tot_blr_cap == 0
      # Make the standard applier
      standard = Standard.build('ComStock DOE Ref Pre-1980')

      # Run a sizing run to determine equipment capacities and flow rates
      if standard.model_run_sizing_run(model, "#{Dir.pwd}/hardsize_model_SR") == false
        runner.registerError('Sizing run for Hardsize model failed, cannot hard-size model.')
        puts('Sizing run for Hardsize model failed, cannot hard-size model.')
        return false
      end

      # Hard sizing every object in the model.
      model.applySizingValues
    end

    ##### main loop for adding of heat pump #########
    whtrs.each do |whtr|
      # updating hot water loop setpoint manager value
      loops = model.getPlantLoops
      loops.each do |l|
        l.supplyComponents.each do |c|
          if c.name.to_s == whtr.name.to_s
            l.supplyOutletNode.setpointManagers.each do |spm|
              sch = spm.to_SetpointManagerScheduled.get
              sch.setSchedule(sched) # updating the setpoint manager to match the heatpump setpoint schedule
            end
          end
        end
      end

      # getting winter design day temperature for heat pump sizing application
      hd_temps = []
      dds = model.getDesignDays
      dds.each do |dd|
        dt = dd.dayType
        dt_name = dd.name.get
        if dt.include?('WinterDesignDay') && dt_name.include?('99.6% Condns DB')
          hd_temps << dd.maximumDryBulbTemperature.to_f # heating design temperature
          runner.registerInfo("Winter design day temperature is  #{dd.maximumDryBulbTemperature.to_f} oC")
        end
      end

      if hd_temps.empty?
        hd_temp = 0
        runner.registerInfo('Winter design day temperature not found in the model. A default value of 32oF(0oC) is used')
      else
        hd_temp = hd_temps[0]
      end

      if whtr.nominalCapacity.is_initialized
        cap_blr = whtr.nominalCapacity.get.to_f
      else
        runner.registerError("For #{whtr.name} capacity is not available, cannot apply this measure.")
        return true
      end

      # estimation of target heat pump capacity
      if sizing_method.include? 'Percentage of Peak Load'
        target_capacity = (hp_sizing_per_100 / 100) * cap_blr
        # outdoor temperaute corresponding to the target capacity. 15.56oc(60oF) is assumed outdoor air temperature for enabling heating
        target_capacity_oat = 15.56 - (target_capacity * (15.56 - hd_temp) / cap_blr)
      else
        target_capacity = (15.56 - hp_sizing_temp) * cap_blr / (15.56 - hd_temp)
        target_capacity_oat = hp_sizing_temp # outdoor temperaute corresponding to the target capacity
      end

      # update the target capacity oat if it is below the heat pump cut off temperature
      if target_capacity_oat < hpwh_cutoff_t
        runner.registerInfo("The target outdoor temperature for sizing #{target_capacity_oat.round(2)} oC is lower than the cutoff point #{hpwh_cutoff_t.round(2)}oC. Sizing will be done based on the cut-off temperature. Only the backup heater will be used below the cut-off temperature.")
        target_capacity_oat = hpwh_cutoff_t # the target capacity oat will be updated by the cutoff temp and the sing will be done at the cut off temp in this case
        target_capacity = (15.56 - hpwh_cutoff_t) * cap_blr / (15.56 - hd_temp)
      end

      # update the target capacity oat if it is below the heating design temperature
      if target_capacity_oat < hd_temp
        runner.registerInfo("The target outdoor temperature for sizing #{target_capacity_oat.round(2)} oC is lower than heating design temperatuure #{hd_temp.round(2)}oC. Sizing will be done based on the heating design temperature")
        target_capacity_oat = hd_temp # the target capacity oat will be updated by the cutoff temp and the sing will be done at the cut off temp in this case
        target_capacity = (15.56 - hd_temp) * cap_blr / (15.56 - hd_temp)
      end

      # performance cuve output at the target oat and hot water setpoint
      capft_target_oat = hpwh_cap_coefficient1constant +
                         (hpwh_cap_coefficient2x * hw_setpoint_c) +
                         (hpwh_cap_coefficient3xpow2 * (hw_setpoint_c**2)) +
                         (hpwh_cap_coefficient4y * target_capacity_oat) +
                         (hpwh_cap_coefficient5ypow2 * (target_capacity_oat**2)) +
                         (hpwh_cap_coefficient6xtimesy * target_capacity_oat * hw_setpoint_c)

      # heat pump design capacity at the rated OAT
      tar_cap_at_des_oat = target_capacity / capft_target_oat # target capacity of the heat pump at the hp design operating (rated) conditions based on which the performance curve values are computed

      # defrost consideration
      # ref https://www.trane.com/content/dam/Trane/Commercial/global/products-systems/equipment/chillers/air-cooled/ascend/SYS-APG003A-EN_04252022.pdf
      if hpwh_design_oat_f > 47
        derate_factor = 1
      elsif hpwh_design_oat_f > 35
        derate_factor = ((0.03 / 12) * (hpwh_design_oat_f - 35)) + 0.95
      elsif hpwh_design_oat_f > 20
        derate_factor = ((0.05 / 14) * (hpwh_design_oat_f - 20)) + 0.90
      elsif hpwh_design_oat_f > 5
        derate_factor = ((0.05 / 15) * (hpwh_design_oat_f - 5)) + 0.85
      else
        derate_factor = max(((0.05 / 5) * (hpwh_design_oat_f - 0)) + 0.8, 0.8)
      end
      tar_cap_at_des_oat /= derate_factor # updated target capacity after application of derate factor due to defrosting

      # Register info
      runner.registerInfo("Boiler capacity is equal to #{cap_blr} W.")
      runner.registerInfo("outdoor temperature corresponding to the target capacity is #{target_capacity_oat} ")
      runner.registerInfo("The rated heat pump capacity at the design condition is #{tar_cap_at_des_oat} W.")
      runner.registerInfo("Target heat pump capacity at the sizing OAT is #{target_capacity} W.")
      runner.registerInfo("cutoff outdoor air temp is #{hpwh_cutoff_t} ")

      # back up heater consideration
      # replace the ng boiler by electric resistance boiler is user wants to remove the existing ng boiler
      if bu_type.include? 'New Electric Resistance Heater'
        runner.registerInfo("#{whtr.name} ng boiler was replaced by electric resisance water heater")
        whtr.setFuelType('Electricity')
        whtr.setNominalThermalEfficiency(1.0)
      else
        runner.registerInfo("#{whtr.name} ng boiler is used as backup water heater")
      end

      inlet = whtr.inletModelObject.get.to_Node.get
      outlet = whtr.outletModelObject.get.to_Node.get

      ### Creating Heat Pump Loop #######
      # Add HX to connect secondary and primary loop
      heat_exchanger = OpenStudio::Model::HeatExchangerFluidToFluid.new(model)
      heat_exchanger.setName('HX for heat pump')
      heat_exchanger.setHeatExchangeModelType('Ideal')
      heat_exchanger.setControlType('UncontrolledOn')
      heat_exchanger.setHeatTransferMeteringEndUseType('LoopToLoop')
      heat_exchanger.addToNode(inlet)

      # create new hot water loop
      hp_loop = OpenStudio::Model::PlantLoop.new(model)
      runner.registerInfo('Heat Pump Loop added.')
      hp_loop.setName('Heat Pump Loop')
      hp_loop.setMaximumLoopTemperature(100.0)
      hp_loop.setMinimumLoopTemperature(10.0)
      hp_loop.setLoadDistributionScheme('SequentialLoad')
      hp_loop_sizing = hp_loop.sizingPlant
      hp_loop_sizing.setLoopType('Heating')
      hp_loop_sizing.setDesignLoopExitTemperature(hw_setpoint_c)

      # create and add a pump to the loop
      pump = OpenStudio::Model::PumpConstantSpeed.new(model)
      pump.setName('Heat pump circulation Pump')
      pump.setRatedPumpHead(44834.7) # 15 ft for primary pump for a priamry-secondary system based on Appendix G
      pump.addToNode(hp_loop.supplyInletNode)

      # create a scheduled setpoint manager
      hp_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
      hp_temp_sch.setName('HP Loop Supply Temp Schedule')
      hp_temp_sch.setValue(hw_setpoint_c)
      hp_setpoint_manager = OpenStudio::Model::SetpointManagerScheduled.new(model, hp_temp_sch)
      hp_setpoint_manager.setName('HP Loop Supply Temp Setpoint Manager')
      hp_setpoint_manager.addToNode(hp_loop.supplyOutletNode)

      air_temp_surrounding_piping = 21.1111
      # Service water heating piping heat loss scheduled air temperature
      wh_piping_air_temp_c = air_temp_surrounding_piping
      wh_piping_air_temp_f = OpenStudio.convert(wh_piping_air_temp_c, 'C', 'F').get
      wh_piping_air_temp_sch = OpenStudio::Model::ScheduleRuleset.new(model)
      wh_piping_air_temp_sch.setName('HP Pipe Ambient Schedule')
      wh_piping_air_temp_sch.defaultDaySchedule.setName('HP Pipe Ambient Schedule Default')
      wh_piping_air_temp_sch.defaultDaySchedule.addValue(OpenStudio::Time.new(0, 24, 0, 0), wh_piping_air_temp_c)

      # Service water heating piping heat loss scheduled air velocity
      wh_piping_air_velocity_m_per_s = 0.3
      wh_piping_air_velocity_mph = OpenStudio.convert(wh_piping_air_velocity_m_per_s, 'm/s', 'mile/hr').get
      wh_piping_air_velocity_sch = OpenStudio::Model::ScheduleRuleset.new(model)
      wh_piping_air_velocity_sch.setName('HP Piping Air Velocity Schedule')
      wh_piping_air_velocity_sch.defaultDaySchedule.setName("HP Piping Air Velocity Default - #{wh_piping_air_velocity_mph.round(2)}mph")
      wh_piping_air_velocity_sch.defaultDaySchedule.addValue(OpenStudio::Time.new(0, 24, 0, 0), wh_piping_air_velocity_m_per_s)

      # Construction for pipe
      pipe_construction = OpenStudio::Model::Construction.new(model)
      # Material for 3/4in type L (heavy duty) copper pipe
      copper_pipe = OpenStudio::Model::StandardOpaqueMaterial.new(model)
      copper_pipe.setName('Copper pipe 0.75in type L')
      copper_pipe.setRoughness('Smooth')
      copper_pipe.setThickness(OpenStudio.convert(0.045, 'in', 'm').get)
      copper_pipe.setThermalConductivity(386.0)
      copper_pipe.setDensity(OpenStudio.convert(556, 'lb/ft^3', 'kg/m^3').get)
      copper_pipe.setSpecificHeat(OpenStudio.convert(0.092, 'Btu/lb*R', 'J/kg*K').get)
      copper_pipe.setThermalAbsorptance(0.9) # @todo find reference for property
      copper_pipe.setSolarAbsorptance(0.7) # @todo find reference for property
      copper_pipe.setVisibleAbsorptance(0.7) # @todo find reference for property

      # pipe_insulation_thickness = 0.0127, # 1/2in
      pipe_insulation_thickness_in = OpenStudio.convert(0.0127, 'm', 'in').get
      insulation = OpenStudio::Model::StandardOpaqueMaterial.new(model)
      insulation.setName("Fiberglass batt #{pipe_insulation_thickness_in.round(2)}in")
      insulation.setRoughness('Smooth')
      insulation.setThickness(OpenStudio.convert(pipe_insulation_thickness_in, 'in', 'm').get)
      insulation.setThermalConductivity(OpenStudio.convert(0.46, 'Btu*in/hr*ft^2*R', 'W/m*K').get)
      insulation.setDensity(OpenStudio.convert(0.7, 'lb/ft^3', 'kg/m^3').get)
      insulation.setSpecificHeat(OpenStudio.convert(0.2, 'Btu/lb*R', 'J/kg*K').get)
      pipe_construction.setName("Copper pipe 0.75in type L with #{pipe_insulation_thickness_in.round(2)}in fiberglass batt")
      pipe_construction.setLayers([insulation, copper_pipe])

      # add pipes
      hp_demand_outlet_pipe = OpenStudio::Model::PipeAdiabatic.new(model)
      hp_supply_bypass_pipe = OpenStudio::Model::PipeAdiabatic.new(model)
      hp_demand_bypass_pipe = OpenStudio::Model::PipeAdiabatic.new(model)

      # heat loss pipe to avoid heat build up from pump operation due to adiabatic piping assumptions
      hp_demand_inlet_pipe = OpenStudio::Model::PipeIndoor.new(model)
      hp_demand_inlet_pipe.setConstruction(pipe_construction)
      hp_demand_inlet_pipe.setEnvironmentType('Schedule')
      hp_demand_inlet_pipe.setPointer(7, wh_piping_air_temp_sch.handle)
      hp_demand_inlet_pipe.setPointer(8, wh_piping_air_velocity_sch.handle)

      hp_loop.addSupplyBranchForComponent(hp_supply_bypass_pipe)
      hp_loop.addDemandBranchForComponent(hp_demand_bypass_pipe)
      hp_demand_inlet_pipe.addToNode(hp_loop.demandInletNode)
      hp_demand_outlet_pipe.addToNode(hp_loop.demandOutletNode)

      # add water connections to the loop
      hp_loop.addDemandBranchForComponent(heat_exchanger)

      # total number of heat pumps  needed based on a heat pump capacity of "hp_des_cap" per unit provided by users
      no_hps = (tar_cap_at_des_oat / (hp_des_cap * 1000)).ceil

      # if the tar_cap_at_des_oat is less than the hp_des_cap, the tar_cap_at_des_oat will be used for sizing.
      if no_hps == 1
        hp_des_cap = tar_cap_at_des_oat / 1000
      end

      # adding heat pumps to the loop
      (1..no_hps).each do |hp|
        # create air source heat pump object
        heatpump = OpenStudio::Model::HeatPumpPlantLoopEIRHeating.new(model)
        heatpump.setName("HeatPump #{hp}")
        heatpump.autosizedLoadSideReferenceFlowRate
        heatpump.autosizedSourceSideReferenceFlowRate
        heatpump.setReferenceCapacity(hp_des_cap * 1000)
        heatpump.setCondenserType('AirSource')
        heatpump.setReferenceCoefficientofPerformance(cop)

        # Updating heat pump performance curve coefficients
        hpwh_cap = OpenStudio::Model::CurveBiquadratic.new(model)
        hpwh_cap.setName('HPWH-Cap-fT')
        hpwh_cap.setCoefficient1Constant(hpwh_cap_coefficient1constant)
        hpwh_cap.setCoefficient2x(hpwh_cap_coefficient2x)
        hpwh_cap.setCoefficient3xPOW2(hpwh_cap_coefficient3xpow2)
        hpwh_cap.setCoefficient4y(hpwh_cap_coefficient4y)
        hpwh_cap.setCoefficient5yPOW2(hpwh_cap_coefficient5ypow2)
        hpwh_cap.setCoefficient6xTIMESY(hpwh_cap_coefficient6xtimesy)
        hpwh_cap.setMinimumValueofx(-40.0)
        hpwh_cap.setMaximumValueofx(100.0)
        hpwh_cap.setMinimumValueofy(-40.0)
        hpwh_cap.setMaximumValueofy(100.0)
        hpwh_cap.setMaximumCurveOutput(10)
        hpwh_cap.setMinimumCurveOutput(0.05)
        hpwh_cap.setInputUnitTypeforX('Temperature')
        hpwh_cap.setInputUnitTypeforY('Temperature')

        hpwh_eir = OpenStudio::Model::CurveBiquadratic.new(model)
        hpwh_eir.setName('HPWH-EIR-fT')
        hpwh_eir.setCoefficient1Constant(hpwh_eir_coefficient1constant)
        hpwh_eir.setCoefficient2x(hpwh_eir_coefficient2x)
        hpwh_eir.setCoefficient3xPOW2(hpwh_eir_coefficient3xpow2)
        hpwh_eir.setCoefficient4y(hpwh_eir_coefficient4y)
        hpwh_eir.setCoefficient5yPOW2(hpwh_eir_coefficient5ypow2)
        hpwh_eir.setCoefficient6xTIMESY(hpwh_eir_coefficient6xtimesy)
        hpwh_eir.setMinimumValueofx(-40.0)
        hpwh_eir.setMaximumValueofx(100.0)
        hpwh_eir.setMinimumValueofy(-40.0)
        hpwh_eir.setMaximumValueofy(100.0)
        hpwh_eir.setMaximumCurveOutput(10)
        hpwh_eir.setMinimumCurveOutput(0.05)
        hpwh_eir.setInputUnitTypeforX('Temperature')
        hpwh_eir.setInputUnitTypeforY('Temperature')

        hpwh_eir_plr = OpenStudio::Model::CurveQuadratic.new(model)
        hpwh_eir_plr.setName('HPWH-EIR-PLR')
        hpwh_eir_plr.setCoefficient1Constant(hpwh_eir_plr_coefficient1constant)
        hpwh_eir_plr.setCoefficient2x(hpwh_eir_plr_coefficient2x)
        hpwh_eir_plr.setCoefficient3xPOW2(hpwh_eir_plr_coefficient3xpow2)

        # assinging performance curves to the heat pump
        heatpump.setCapacityModifierFunctionofTemperatureCurve(hpwh_cap)
        heatpump.setElectricInputtoOutputRatioModifierFunctionofTemperatureCurve(hpwh_eir)
        heatpump.setElectricInputtoOutputRatioModifierFunctionofPartLoadRatioCurve(hpwh_eir_plr)

        # adding  the heat pump to the supply side of the heat pump loop
        hp_loop.addSupplyBranchForComponent(heatpump)
      end

      # adding availability manager to heat pump loop. This is based on users cut-off temperature input
      heat_pump_avail_sch = OpenStudio::Model::ScheduleConstant.new(model)
      heat_pump_avail_sch.setValue(1.0)
      low_temp_off = OpenStudio::Model::AvailabilityManagerScheduled.new(model)
      low_temp_off.setSchedule(heat_pump_avail_sch)
      heat_pump_avail_sch_var = OpenStudio::Model::OutputVariable.new('Schedule Value', model)
      heat_pump_avail_sch_var.setKeyValue(heat_pump_avail_sch.name.to_s)
      hp_loop.addAvailabilityManager(low_temp_off)

      oat_db_c_sen = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Site Outdoor Air Drybulb Temperature')
      oat_db_c_sen.setName('OATVestibule')
      oat_db_c_sen.setKeyName('Environment')

      heat_pump_avail_sch_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(heat_pump_avail_sch, 'Schedule:Constant', 'Schedule Value')
      heat_pump_avail_sch_prog = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
      heat_pump_avail_sch_prog.setName('Availability Schedule Program by Line')
      # EMS code to turn of the heat pump if outdoor air temp is lower than the cut off temperature
      heat_pump_avail_sch_prog_body = <<-EMS
          IF #{oat_db_c_sen.handle} > #{hpwh_cutoff_t}
            SET #{heat_pump_avail_sch_actuator.handle} = 1
          ELSE
            SET #{heat_pump_avail_sch_actuator.handle} = 0
          ENDIF
      EMS
      heat_pump_avail_sch_prog.setBody(heat_pump_avail_sch_prog_body)
      # List of EMS program manager objects
      programs_at_beginning_of_timestep = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
      programs_at_beginning_of_timestep.setName('Programs_At_Beginning_Of_Timestep')
      programs_at_beginning_of_timestep.setCallingPoint('BeginZoneTimestepAfterInitHeatBalance')
      programs_at_beginning_of_timestep.addProgram(heat_pump_avail_sch_prog)
      ### End of creating Heat Pump Loop #######

      # changing hardsized heating coil values by autosizing
      # only change coil to autosize if user choose to autosize it
      if (keep_setpoint != true) && (autosize_hc == true)
        cls = []
        loops = model.getPlantLoops

        loops.each do |l|
          loop_name = l.name.get
          if loop_name.include?('Hot Water Loop')
            # matching the hot water loop design exit temperature with the HP boiler setpoint
            pl = l.sizingPlant
            if pl.loopType.include?('Heating')
              pl.setDesignLoopExitTemperature(hw_setpoint_c)
              tempd = pl.loopDesignTemperatureDifference.to_f
            end
          end

          # autosizing pump properties
          l.supplyComponents.each do |supply_comp|
            if supply_comp.to_PumpVariableSpeed.is_initialized
              v_pump = supply_comp.to_PumpVariableSpeed.get
              v_pump.autosizeRatedFlowRate
              v_pump.autosizeRatedPowerConsumption
            elsif supply_comp.to_PumpConstantSpeed.is_initialized
              c_pump = supply_comp.to_PumpConstantSpeed.get
              c_pump.autosizeRatedFlowRate
              c_pump.autosizeRatedPowerConsumption
            end
          end

          # autosizing coil properties and adjusting rated inlete water temperature to match the HP boiler setpoint
          l.demandComponents.each do |dem_comp|
            if dem_comp.to_CoilHeatingWater.is_initialized
              h_coil = dem_comp.to_CoilHeatingWater.get
              h_coil.autosizeUFactorTimesAreaValue
              h_coil.autosizeMaximumWaterFlowRate
              h_coil.autosizeRatedCapacity
              h_coil.setRatedInletWaterTemperature(hw_setpoint_c)
              h_coil.setRatedOutletWaterTemperature(hw_setpoint_c - tempd)
            elsif dem_comp.to_CoilHeatingWaterBaseboard.is_initialized
              h_coil = dem_comp.to_CoilHeatingWaterBaseboard.get
              h_coil.autosizeUFactorTimesAreaValue
              h_coil.autosizeMaximumWaterFlowRate
              h_coil.autosizeHeatingDesignCapacity
            end
          end
        end

        sizings = model.getSizingSystems
        sizings.each(&:autosizeHeatingDesignCapacity)

        # autosizing the Maximum Hot Water/steam Flow Rate.
        model.getAirTerminalSingleDuctVAVReheats.each(&:autosizeMaximumHotWaterOrSteamFlowRate)
      end
    end

    # Register final condition
    whs_ic = model.getBoilerHotWaters.size
    hp_ic =  model.getHeatPumpPlantLoopEIRHeatings.size

    runner.registerFinalCondition("The building finished with #{whs_ic} hot water boilers and #{hp_ic} heat pump water heater(s).")
    true
  end
end

# register the measure to be used by the application
ReplaceBoilerWithHeatPump.new.registerWithApplication
