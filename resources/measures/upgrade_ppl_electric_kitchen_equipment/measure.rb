# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.


# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

# start the measure
class ElectrifyKitchenEquipment < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'electrify_kitchen_equipment'
  end

  # human readable description
  def description
    return 'Measure replaces primary gas kitchen equipment with the electric equivalent. Primary kitchen equipment includes griddles, ovens, fryers, steamers, ranges, and stoves. The new equipment will follow the same schedule as the equipment originally in the model.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'Measure replaces primary gas kitchen equipment with the electric equivalent. Primary kitchen equipment includes griddles, ovens, fryers, steamers, ranges, and stoves. The new equipment will follow the same schedule as the equipment originally in the model.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    return args
  end

  # The gas appliances set_primary_kitchen_equipment writes are named
  # 'gas_<type>_equipment_bldg_quantity=<count>', possibly with the ' N' suffix OpenStudio adds to
  # keep names unique. Only those are replaced.
  APPLIANCE_NAME = /\Agas_(?<type>[a-z]+)_equipment_bldg_quantity=(?<quantity>[0-9.]+)( \d+)?\z/.freeze

  # Helper method to extract quantity from the object name
  #
  # @param string [String] a gas equipment name
  # @return [Float, nil] the appliance count, or nil if the name is not a sampled appliance
  def get_quantity_from_name(string)
    match = APPLIANCE_NAME.match(string.to_s)
    return nil if match.nil?

    match[:quantity].to_f
  end

  # Helper method to extract the appliance type from the object name
  #
  # @param string [String] a gas equipment name
  # @return [String, nil] the appliance type, or nil if the name is not a sampled appliance
  def get_equip_type_from_name(string)
    match = APPLIANCE_NAME.match(string.to_s)
    return nil if match.nil?

    match[:type]
  end

  # Is this name a commercial kitchen?
  #
  # Matches the prototype 'Kitchen' spelling and the all-level 'food preparation' spelling,
  # including building-type-qualified variants ('food preparation - primary school').
  # The grocery service areas 'food preparation - deli', '- bakery' and '- deli/bakery' are
  # sub-types of food preparation that hold no primary cooking appliances, so they are excluded.
  # Kept in step with set_primary_kitchen_equipment, which installs the appliances this replaces.
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

    # search for kitchen spaces and space types in the model
    # this will provide list of kitchen spaces, space types, and number of kitchen spaces
    li_spaces_with_kitchens = []
    li_space_types_with_kitchens = []
    num_kitchens = 0
    model.getSpaces.sort.each do |space|
      next unless kitchen_space?(space)
      next if space.spaceType.empty?

      # append kitchen to list
      li_spaces_with_kitchens << space
      num_kitchens += 1
      # get space type of kitchen and add to list if not already
      kitchen_space_type = space.spaceType.get
      next if li_space_types_with_kitchens.include? kitchen_space_type

      li_space_types_with_kitchens << kitchen_space_type
    end

    electric_equipment_hash = [
      { equip_type: 'broiler', elec_design_level_w: 10815.0, frac_latent: 0.1, frac_radiant: 0.35, frac_lost: 0.45 },
      { equip_type: 'fryer', elec_design_level_w: 14009.0, frac_latent: 0.1, frac_radiant: 0.36, frac_lost: 0.44, frac_convected: 0.1 },
      { equip_type: 'griddle', elec_design_level_w: 17116.0, frac_latent: 0.1, frac_radiant: 0.39, frac_lost: 0.41 },
      { equip_type: 'oven', elec_design_level_w: 12104.0, frac_latent: 0.1, frac_radiant: 0.22, frac_lost: 0.58 },
      { equip_type: 'range', elec_design_level_w: 21014.0, frac_latent: 0.1, frac_radiant: 0.1, frac_lost: 0.8 },
      { equip_type: 'steamer', elec_design_level_w: 26964.0, frac_latent: 0.1, frac_radiant: 0.1, frac_lost: 0.79 }
    ]

    # measure not applicable if building does not have a kitchen
    if num_kitchens == 0
      runner.registerAsNotApplicable('Building does not have a kitchen; measure is not applicable.')
      return true
    end

    replaced_equip_list = []

    # Iterate through each kitchen space type and replace its gas appliances
    li_space_types_with_kitchens.each do |space_type|
      # loop through each gas equipment
      space_type.gasEquipment.sort.each do |gas_equip|
        # Get the appliance type and quantity from the gas equipment object name
        quantity = get_quantity_from_name(gas_equip.name.to_s)
        equip_type = get_equip_type_from_name(gas_equip.name.to_s)
        electric_properties = electric_equipment_hash.find { |equip| equip[:equip_type] == equip_type }
        if quantity.nil? || electric_properties.nil?
          runner.registerWarning("Gas equipment '#{gas_equip.name}' in #{space_type.name} is not a primary cooking appliance set by set_primary_kitchen_equipment and is left as gas.")
          next
        end
        if gas_equip.schedule.empty? || gas_equip.schedule.get.to_ScheduleRuleset.empty?
          runner.registerWarning("Gas equipment '#{gas_equip.name}' in #{space_type.name} has no ruleset schedule to carry over and is left as gas.")
          next
        end

        multiplier = gas_equip.multiplier
        modified_name = gas_equip.name.to_s.sub(/^gas_/, '')
        # get existing gas equipment definition schedule
        gas_equip_sched_orig = gas_equip.schedule.get.to_ScheduleRuleset.get

        # Remove the gas equipment object and its definition
        gas_equip_def = gas_equip.gasEquipmentDefinition
        gas_equip.remove
        gas_equip_def.remove if gas_equip_def.instances.empty?

        # Create a new electric equipment object
        electric_equip_definition = OpenStudio::Model::ElectricEquipmentDefinition.new(model)
        electric_equip_definition.setName("electric_#{modified_name}")
        electric_equip_definition.setDesignLevel(electric_properties[:elec_design_level_w] * quantity)
        electric_equip_definition.setFractionLatent(electric_properties[:frac_latent])
        electric_equip_definition.setFractionRadiant(electric_properties[:frac_radiant])
        electric_equip_definition.setFractionLost(electric_properties[:frac_lost])

        electric_equip = OpenStudio::Model::ElectricEquipment.new(electric_equip_definition)
        electric_equip.setName("electric_#{equip_type}_equipment_bldg_quantity=#{quantity}")
        electric_equip.setMultiplier(multiplier)
        electric_equip.setSpaceType(space_type)
        # set new equipment schedule to the old gas equip schedule
        electric_equip.setSchedule(gas_equip_sched_orig)

        replaced_equip_list << "#{quantity} #{equip_type}s"
      end
    end

    if replaced_equip_list.empty?
      runner.registerAsNotApplicable("The #{num_kitchens} kitchen space(s) have no gas cooking appliances to replace; measure is not applicable.")
      return true
    end

    runner.registerFinalCondition("Replaced #{replaced_equip_list.join(', ')} with electric appliances.")
    return true
  end
end

# register the measure to be used by the application
ElectrifyKitchenEquipment.new.registerWithApplication
