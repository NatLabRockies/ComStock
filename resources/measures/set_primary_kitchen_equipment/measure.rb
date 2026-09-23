# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.


# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

# start the measure
class SetPrimaryKitchenEquipment < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'set_primary_kitchen_equipment'
  end

  # human readable description
  def description
    return 'Measure adds specific primary kitchen equipment to kitchen space type based on user inputs. Primary kitchen equipment includes griddles, ovens, fryers, steamers, ranges, and stoves. Equipment can be either gas or electric based on user-specified inputs. Exisiting kitchen equipment will be removed, but new equipment will follow the same schedule as the equipment originally in the model.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'Measure adds specific primary kitchen equipment to kitchen space type based on user inputs. Primary kitchen equipment includes griddles, ovens, fryers, steamers, ranges, and stoves. Equipment can be either gas or electric based on user-specified inputs. Exisiting kitchen equipment will be removed, but new equipment will follow the same schedule as the equipment originally in the model.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # argument for food service type of building
    cook_dining_type = OpenStudio::Measure::OSArgument.makeStringArgument('cook_dining_type', true)
    cook_dining_type.setDisplayName('cook_dining_type')
    cook_dining_type.setDescription('Food service type in building; this will determine major cooking equipment distribution.')
    cook_dining_type.setDefaultValue('None')
    args << cook_dining_type

    # Arguments for appliance fuel type and quantity

    # Broilers
    # argument for broiler fuel type
    cook_fuel_broiler = OpenStudio::Measure::OSArgument.makeStringArgument('cook_fuel_broiler', true)
    cook_fuel_broiler.setDisplayName('cook_fuel_broiler')
    cook_fuel_broiler.setDescription('Fuel type of broilers in building. All broilers will be the same fuel type.')
    cook_fuel_broiler.setDefaultValue('Gas')
    args << cook_fuel_broiler
    # argument for broiler fuel type
    cook_broilers_counts = OpenStudio::Measure::OSArgument.makeDoubleArgument('cook_broilers_counts', true)
    cook_broilers_counts.setDisplayName('cook_broilers_counts')
    cook_broilers_counts.setDescription('Quantity of broilers in building.')
    cook_broilers_counts.setDefaultValue(0)
    args << cook_broilers_counts

    # Griddles
    # argument for griddle fuel type
    cook_fuel_griddle = OpenStudio::Measure::OSArgument.makeStringArgument('cook_fuel_griddle', true)
    cook_fuel_griddle.setDisplayName('cook_fuel_griddle')
    cook_fuel_griddle.setDescription('Fuel type of griddles in building. All griddles will be the same fuel type.')
    cook_fuel_griddle.setDefaultValue('Gas')
    args << cook_fuel_griddle
    # argument for broiler counts
    cook_griddles_counts = OpenStudio::Measure::OSArgument.makeDoubleArgument('cook_griddles_counts', true)
    cook_griddles_counts.setDisplayName('cook_griddles_counts')
    cook_griddles_counts.setDescription('Quantity of griddles in building.')
    cook_griddles_counts.setDefaultValue(0)
    args << cook_griddles_counts

    # Fryers
    # argument for fryer fuel type
    cook_fuel_fryer = OpenStudio::Measure::OSArgument.makeStringArgument('cook_fuel_fryer', true)
    cook_fuel_fryer.setDisplayName('cook_fuel_fryer')
    cook_fuel_fryer.setDescription('Fuel type of fryers in building. All fryer will be the same fuel type.')
    cook_fuel_fryer.setDefaultValue('Gas')
    args << cook_fuel_fryer
    # argument for fryer counts
    cook_fryers_counts = OpenStudio::Measure::OSArgument.makeDoubleArgument('cook_fryers_counts', true)
    cook_fryers_counts.setDisplayName('cook_fryers_counts')
    cook_fryers_counts.setDescription('Quantity of fryer in building.')
    cook_fryers_counts.setDefaultValue(0)
    args << cook_fryers_counts

    # Ovens
    # argument for oven fuel type
    cook_fuel_oven = OpenStudio::Measure::OSArgument.makeStringArgument('cook_fuel_oven', true)
    cook_fuel_oven.setDisplayName('cook_fuel_oven')
    cook_fuel_oven.setDescription('Fuel type of oven in building. All oven will be the same fuel type.')
    cook_fuel_oven.setDefaultValue('Gas')
    args << cook_fuel_oven
    # argument for oven counts
    cook_ovens_counts = OpenStudio::Measure::OSArgument.makeDoubleArgument('cook_ovens_counts', true)
    cook_ovens_counts.setDisplayName('cook_ovens_counts')
    cook_ovens_counts.setDescription('Quantity of oven in building.')
    cook_ovens_counts.setDefaultValue(0)
    args << cook_ovens_counts

    # Ranges
    # argument for range fuel type
    cook_fuel_range = OpenStudio::Measure::OSArgument.makeStringArgument('cook_fuel_range', true)
    cook_fuel_range.setDisplayName('cook_fuel_range')
    cook_fuel_range.setDescription('Fuel type of range in building. All range will be the same fuel type.')
    cook_fuel_range.setDefaultValue('Gas')
    args << cook_fuel_range
    # argument for range counts
    cook_ranges_counts = OpenStudio::Measure::OSArgument.makeDoubleArgument('cook_ranges_counts', true)
    cook_ranges_counts.setDisplayName('cook_ranges_counts')
    cook_ranges_counts.setDescription('Quantity of range in building.')
    cook_ranges_counts.setDefaultValue(0)
    args << cook_ranges_counts

    # Steamers
    # argument for steamer fuel type
    cook_fuel_steamer = OpenStudio::Measure::OSArgument.makeStringArgument('cook_fuel_steamer', true)
    cook_fuel_steamer.setDisplayName('cook_fuel_steamer')
    cook_fuel_steamer.setDescription('Fuel type of steamer in building. All steamer will be the same fuel type.')
    cook_fuel_steamer.setDefaultValue('Gas')
    args << cook_fuel_steamer
    # argument for steamer counts
    cook_steamers_counts = OpenStudio::Measure::OSArgument.makeDoubleArgument('cook_steamers_counts', true)
    cook_steamers_counts.setDisplayName('cook_steamers_counts')
    cook_steamers_counts.setDescription('Quantity of steamer in building.')
    cook_steamers_counts.setDefaultValue(0)
    args << cook_steamers_counts

    return args
  end

  # Is this name a commercial kitchen?
  #
  # Matches the prototype 'Kitchen' spelling and the all-level 'food preparation' spelling,
  # including building-type-qualified variants ('food preparation - primary school').
  # The grocery service areas 'food preparation - deli', '- bakery' and '- deli/bakery' are
  # sub-types of food preparation that hold no primary cooking appliances, so they are excluded.
  #
  # @param name [String] a space, space type, or standards space type name
  # @return [Boolean] true if the name identifies a commercial kitchen
  def kitchen_name?(name)
    name = name.to_s
    return true if name =~ /kitchen/i
    return false unless name =~ /food preparation/i

    name !~ /deli|bakery/i
  end

  # Is this space a commercial kitchen?
  #
  # Checks the space name, its space type name, and its standards space type.
  #
  # @param space [OpenStudio::Model::Space] the space
  # @return [Boolean] true if the space is a commercial kitchen
  def kitchen_space?(space)
    names = [space.name.to_s]
    if space.spaceType.is_initialized
      space_type = space.spaceType.get
      names << space_type.name.to_s
      names << space_type.standardsSpaceType.get if space_type.standardsSpaceType.is_initialized
    end
    names.any? { |n| kitchen_name?(n) }
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # assign the user inputs to variables
    cook_dining_type = runner.getStringArgumentValue('cook_dining_type', user_arguments)
    cook_fuel_broiler = runner.getStringArgumentValue('cook_fuel_broiler', user_arguments)
    cook_broilers_counts = runner.getDoubleArgumentValue('cook_broilers_counts', user_arguments)
    cook_fuel_griddle = runner.getStringArgumentValue('cook_fuel_griddle', user_arguments)
    cook_griddles_counts = runner.getDoubleArgumentValue('cook_griddles_counts', user_arguments)
    cook_fuel_fryer = runner.getStringArgumentValue('cook_fuel_fryer', user_arguments)
    cook_fryers_counts = runner.getDoubleArgumentValue('cook_fryers_counts', user_arguments)
    cook_fuel_oven = runner.getStringArgumentValue('cook_fuel_oven', user_arguments)
    cook_ovens_counts = runner.getDoubleArgumentValue('cook_ovens_counts', user_arguments)
    cook_fuel_range = runner.getStringArgumentValue('cook_fuel_range', user_arguments)
    cook_ranges_counts = runner.getDoubleArgumentValue('cook_ranges_counts', user_arguments)
    cook_fuel_steamer = runner.getStringArgumentValue('cook_fuel_steamer', user_arguments)
    cook_steamers_counts = runner.getDoubleArgumentValue('cook_steamers_counts', user_arguments)

    # search for kitchen spaces and space types in the model
    # this will provide list of kitchen spaces, space types, and number of kitchen spaces.
    # Prototype-derived models name the kitchen space type and its spaces 'Kitchen'. Models built
    # from a ComStock building spec use the all-level space type 'food preparation', or a
    # building-type-qualified variant such as 'food preparation - primary school', and the spaces
    # inherit that name ('food preparation A - Story 1'). Both spellings are commercial kitchens.
    li_spaces_with_kitchens = []
    li_space_types_with_kitchens = []
    num_kitchens = 0
    # sum of the thermal zone multipliers of the kitchen spaces. A kitchen in a zone with a
    # multiplier of 5 stands for five kitchens, so the per-building appliance counts are spread
    # over this total rather than over the number of space objects.
    total_kitchen_multiplier = 0
    model.getSpaces.sort.each do |space|
      next unless kitchen_space?(space)

      if space.spaceType.empty?
        runner.registerWarning("Kitchen space #{space.name} has no space type and will be ignored.")
        next
      end

      # append kitchen to list
      li_spaces_with_kitchens << space
      num_kitchens += 1
      total_kitchen_multiplier += space.multiplier
      # get space type of kitchen and add to list if not already
      kitchen_space_type = space.spaceType.get
      next if li_space_types_with_kitchens.include? kitchen_space_type

      li_space_types_with_kitchens << kitchen_space_type
    end

    # skip if there are no kitchen spaces in model, or if there is more than 1 kitchen space type.
    if li_spaces_with_kitchens.empty?
      runner.registerAsNotApplicable('Model does not contain a kitchen spaces and will not be affected by this measure.')
      return false
    elsif li_space_types_with_kitchens.length > 1
      runner.registerAsNotApplicable("Model contains #{li_space_types_with_kitchens.length} kitchen space types (#{li_space_types_with_kitchens.map { |st| st.name.to_s }.join(', ')}). This measure only supports 1 kitchen space type, and therefore is not applicable.")
      return false
    end

    # define kitchen space type
    kitchen_stype = li_space_types_with_kitchens[0]

    # define equipment fuels and quantities which will be used to add loads to model
    # make list of equipment
    li_appliance_types = ['broiler', 'griddle', 'fryer', 'oven', 'range', 'steamer']
    # make list of equipment fuels
    li_appliance_fuel = [cook_fuel_broiler, cook_fuel_griddle, cook_fuel_fryer, cook_fuel_oven, cook_fuel_range, cook_fuel_steamer]
    # make hash of equipment type and fuels
    appliance_fuel_hash = li_appliance_types.zip(li_appliance_fuel).to_h
    # make list of equipment quantities
    li_appliance_quantities = [cook_broilers_counts, cook_griddles_counts, cook_fryers_counts, cook_ovens_counts, cook_ranges_counts, cook_steamers_counts]
    # make hash of equipment quantities
    appliance_quantity_hash = li_appliance_types.zip(li_appliance_quantities).to_h
    # make list of electric equipment power (in kW)
    li_appliance_electric_power_kw = [10.815, 17.116, 14.009, 12.104, 21.014, 26.964]
    # make hash of electric equipment
    appliance_electric_power_hash = li_appliance_types.zip(li_appliance_electric_power_kw).to_h
    # make list of gas equipment power (in kW)
    li_appliance_gas_power_kw = [28.136, 26.377, 23.447, 12.896, 42.497, 58.617]
    # make hash of gas equipment
    appliance_gas_power_hash = li_appliance_types.zip(li_appliance_gas_power_kw).to_h

    # fraction latent always set to 0.1
    frac_latent = 0.1
    # make list of gas radiant fraction values
    li_gas_frac_radiant = [0.12, 0.18, 0.23, 0.08, 0.11, 0.1]
    gas_fraction_radiant_hash = li_appliance_types.zip(li_gas_frac_radiant).to_h
    # make list of electric radiant fraction values
    li_elec_frac_radiant = [0.35, 0.39, 0.36, 0.22, 0.1, 0.1]
    elec_fraction_radiant_hash = li_appliance_types.zip(li_elec_frac_radiant).to_h
    # make list of gas lost fraction values
    li_gas_frac_lost = [0.68, 0.62, 0.57, 0.72, 0.69, 0.7]
    gas_fraction_lost_hash = li_appliance_types.zip(li_gas_frac_lost).to_h
    # make list of electric lost fraction values
    li_elec_frac_lost = [0.45, 0.41, 0.44, 0.58, 0.7, 0.7]
    elec_fraction_lost_hash = li_appliance_types.zip(li_elec_frac_lost).to_h

    # make list of equipment to delete
    # A space type may carry several gas or electric equipment objects (a building spec can name
    # more than one pre-defined load object for a space type), so every original instance is
    # handled: all gas equipment is removed and replaced by the sampled appliances, and all
    # electric equipment is reduced to a miscellaneous load. The first instance by name lends its
    # schedule and definition to the new appliances.
    li_euip_to_remove = []
    orig_gas_equip = kitchen_stype.gasEquipment.sort_by { |g| g.name.to_s }
    orig_gas_equip_count = orig_gas_equip.size
    # get base gas equipment, if any
    if orig_gas_equip_count > 0
      # get existing kitchen gas equipment in model
      gas_equip_orig = orig_gas_equip[0]
      # get existing gas equipment definition schedule
      gas_equip_sched_orig = gas_equip_orig.schedule.get.to_ScheduleRuleset.get
      # get existing gas equipment definition
      gas_equip_def_orig = gas_equip_orig.gasEquipmentDefinition
      # add equipment to list
      orig_gas_equip.each do |g|
        li_euip_to_remove << g
        li_euip_to_remove << g.gasEquipmentDefinition
      end
    end

    orig_electric_equip = kitchen_stype.electricEquipment.sort_by { |e| e.name.to_s }
    orig_electric_equip_count = orig_electric_equip.size
    # get base electric equipment, if any
    if orig_electric_equip_count > 0
      # get existing kitchen electric equipment in model
      electric_equip_orig = orig_electric_equip[0]
      # get existing electric equipment definition
      electric_equip_def_orig = electric_equip_orig.electricEquipmentDefinition
      # we will not remove electric equipment, but will reduce it
    end

    # register initial model conditions
    runner.registerInitialCondition("The building contains #{num_kitchens} applicable kitchen space(s) with a total zone multiplier of #{total_kitchen_multiplier}. The original kitchen space type, #{kitchen_stype.name}, uses #{kitchen_stype.gasEquipmentPowerPerFloorArea} W/m^2 of gas equipment and #{kitchen_stype.electricEquipmentPowerPerFloorArea} W/m^2 of electric equipment. 10% of electric equipment, if any, will remain in model to account for misc. loads.")

    # loop through equipment types and add to model
    li_appliance_types.each do |app|
      # skip equipment type if 0 quantity
      next unless appliance_quantity_hash[app] > 0

      # check fuel type for gas
      if appliance_fuel_hash[app] == 'Gas'
        # skip if no gas equipment existed in model
        next unless orig_gas_equip_count > 0

        # create new gas equipment definition
        equip_def_new = gas_equip_def_orig.clone.to_GasEquipmentDefinition.get
        equip_def_new.setName("gas_#{app}_equipment_definition_bldg_quantity=#{appliance_quantity_hash[app]}")
        # set aggregate equipment power; multiply quantity by power per unit; multiply by 1000 for kW to W
        agg_power = appliance_quantity_hash[app] * appliance_gas_power_hash[app]
        equip_def_new.setDesignLevel(agg_power * 1000)
        equip_def_new.setFractionLatent(frac_latent)
        frac_radiant = gas_fraction_radiant_hash[app]
        equip_def_new.setFractionRadiant(frac_radiant)
        frac_lost = gas_fraction_lost_hash[app]
        equip_def_new.setFractionLost(frac_lost)
        # create new gas equipment and link to new definition
        equip_new = gas_equip_orig.clone.to_GasEquipment.get
        equip_new.setName("gas_#{app}_equipment_bldg_quantity=#{appliance_quantity_hash[app]}")
        equip_new.setGasEquipmentDefinition(equip_def_new)
        # use original gas equipment schedule
        equip_new.setSchedule(gas_equip_sched_orig)
        # use multiplier to spread equipment across multiple kitchens, counting zone multipliers
        equip_new.setMultiplier(1.0 / total_kitchen_multiplier)
        # register message for adding gas equipment to model
        runner.registerInfo("(#{appliance_quantity_hash[app]}) #{appliance_gas_power_hash[app]}kW gas #{app}(s) were added to model kitchen space(s).")
      elsif appliance_fuel_hash[app] == 'Electric'
        # skip if no electric equipment existed in model
        next unless orig_electric_equip_count > 0

        # create new electric equipment definition
        equip_def_new = electric_equip_def_orig.clone.to_ElectricEquipmentDefinition.get
        equip_def_new.setName("electric_#{app}_equipment_definition_bldg_quantity=#{appliance_quantity_hash[app]}")
        # set aggregate equipment power; multiply quantity by power per unit; multiply by 1000 for kW to W
        agg_power = appliance_quantity_hash[app] * appliance_electric_power_hash[app]
        equip_def_new.setDesignLevel(agg_power * 1000)
        equip_def_new.setFractionLatent(frac_latent)
        frac_radiant = elec_fraction_radiant_hash[app]
        equip_def_new.setFractionRadiant(frac_radiant)
        frac_lost = elec_fraction_lost_hash[app]
        equip_def_new.setFractionLost(frac_lost)
        # create new gas equipment and link to new definition
        equip_new = electric_equip_orig.clone.to_ElectricEquipment.get
        equip_new.setName("electric_#{app}_equipment_bldg_quantity=#{appliance_quantity_hash[app]}")
        equip_new.setElectricEquipmentDefinition(equip_def_new)
        # use original gas equipment schedule; consider using gas schedules for schools
        equip_new.setSchedule(gas_equip_sched_orig)
        # equip_new.setSchedule(gas_equip_sched_orig)
        # use multiplier to spread equipment across multiple kitchens, counting zone multipliers
        equip_new.setMultiplier(1.0 / total_kitchen_multiplier)
        # register message for adding gas equipment to model
        runner.registerInfo("(#{appliance_quantity_hash[app]}) #{appliance_electric_power_hash[app]}kW electric #{app}(s) were added to model kitchen space(s).")
      else
        runner.registerWarning("Fuel type '#{appliance_fuel_hash[app]}' for #{app} appliance is not applicable. String must match either 'Gas' or 'Electric'. This equipment will be ignored.")
      end
    end

    # remove original gas equipment (definitions after the instances that use them)
    li_euip_to_remove.uniq.each(&:remove)

    # set original electric equipment to 10% of original value to account for misc.
    orig_electric_equip.each_with_index do |electric_equip, i|
      suffix = i.zero? ? '' : " #{i + 1}"
      # change name to misc. equipment
      electric_equip.setName("misc_electric_kitchen_equipment#{suffix}")
      electric_equip_def = electric_equip.electricEquipmentDefinition
      electric_equip_def.setName("misc_electric_kitchen_equipment_definition#{suffix}")
      # get original power
      original_power_per_area = electric_equip.powerPerFloorArea.to_f
      # change power per sf to 10% of original
      new_power = original_power_per_area * 0.1
      electric_equip_def.setWattsperSpaceFloorArea(new_power)
      runner.registerInfo("The original kitchen electric load #{electric_equip.name} has been reduced to 10% of the original value from #{original_power_per_area.round}W/m^2 to #{new_power.round}W/m^2 to remove energy associated with major cooking appliances while retaining miscellaneous electric loads.")
    end

    return true
  end
end

# register the measure to be used by the application
SetPrimaryKitchenEquipment.new.registerWithApplication
