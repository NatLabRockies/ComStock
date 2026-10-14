# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2018, Alliance for Sustainable Energy, LLC.
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

require 'openstudio-standards'

# start the measure
class UpgradeRefrigeration < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    return 'upgrade_refrigeration'
  end

  # human readable description
  def description
    return 'This measure upgrades the refrigeration template in the model to a user selected template.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'This measure upgrades the refrigeration template in the model to a user selected template. The original refrigeration system will be removed and a new system with the user-defined template will be installed.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    refrigeration_template_choices = OpenStudio::StringVector.new
    refrigeration_template_choices << 'new'
    refrigeration_template_choices << 'advanced'

    refrigeration_template = OpenStudio::Measure::OSArgument.makeChoiceArgument('refrigeration_template', refrigeration_template_choices, true)
    refrigeration_template.setDisplayName('Refrigeration Technology Level')
    refrigeration_template.setDescription('Technology level for refrigerated cases, walkins, compressors, and systems.')
    refrigeration_template.setDefaultValue('new')
    args << refrigeration_template

    return args
  end

  # count all refrigeration objects currently in the model
  def refrigeration_object_count(model)
    count = model.getRefrigerationCases.size + model.getRefrigerationWalkIns.size
    count += model.getRefrigerationSystems.size if model.respond_to?(:getRefrigerationSystems)
    count += model.getRefrigerationCompressorRacks.size if model.respond_to?(:getRefrigerationCompressorRacks)
    return count
  end

  # remove existing refrigeration objects
  def remove_existing_refrigeration(model)
    removed_count = 0

    # Remove parent objects first to avoid dangling references.
    if model.respond_to?(:getRefrigerationSystems)
      model.getRefrigerationSystems.each do |ref_system|
        ref_system.remove
        removed_count += 1
      end
    end

    if model.respond_to?(:getRefrigerationCompressorRacks)
      model.getRefrigerationCompressorRacks.each do |compressor_rack|
        compressor_rack.remove
        removed_count += 1
      end
    end

    model.getRefrigerationCases.each do |ref_case|
      ref_case.remove
      removed_count += 1
    end

    model.getRefrigerationWalkIns.each do |walk_in|
      walk_in.remove
      removed_count += 1
    end

    return removed_count
  end

  # run create_typical_refrigeration in os-standards with user-specified template
  def create_refrigeration_system(model, runner, refrigeration_template)
    runner.registerInfo("Creating replacement refrigeration using template '#{refrigeration_template}'.")
    result = OpenstudioStandards::Refrigeration.create_typical_refrigeration(
      model,
      template: refrigeration_template
    )
    runner.registerInfo('Refrigeration creation call finished.')
    return result != false
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    runner.registerInfo('Starting refrigeration upgrade measure.')

    # validate arguments
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    refrigeration_template = runner.getStringArgumentValue('refrigeration_template', user_arguments)
    runner.registerInfo("Selected refrigeration template: #{refrigeration_template}")

    # report baseline refrigeration object count
    initial_count = refrigeration_object_count(model)
    runner.registerInitialCondition("Model starts with #{initial_count} refrigeration objects.")

    # register measure not applicable if no refrigeration objects are present
    if initial_count == 0
      runner.registerAsNotApplicable('Model does not have refrigeration system. Measure not applicable.')
      return true
    end

    # check existing refrigeration template and skip when it already meets the requested level
    existing_refrigeration_template = model.getBuilding.additionalProperties.getFeatureAsString('refrigeration_technology_level').get

    if existing_refrigeration_template == 'advanced'
      runner.registerAsNotApplicable("Model already has 'advanced' refrigeration system, which is equal to or more efficient than the user-requested refrigeration template '#{refrigeration_template}'. Measure not applicable.")
      return true
    end

    if existing_refrigeration_template == 'new' && refrigeration_template == 'new'
      runner.registerAsNotApplicable("Model already has 'new' refrigeration system, which is equal to or more efficient than the user-requested refrigeration template '#{refrigeration_template}'. Measure not applicable.")
      return true
    end

    if existing_refrigeration_template == 'advanced' && refrigeration_template == 'new'
      runner.registerAsNotApplicable("Model already has 'advanced' refrigeration system, which is equal to or more efficient than the user-requested refrigeration template '#{refrigeration_template}'. Measure not applicable.")
      return true
    end

    # remove existing refrigeration loads and systems
    runner.registerInfo('Removing existing refrigeration objects before applying replacement template.')
    remove_call_count = remove_existing_refrigeration(model)
    post_removal_count = refrigeration_object_count(model)
    removed_count = initial_count - post_removal_count
    runner.registerInfo("Removal step issued #{remove_call_count} remove calls; refrigeration object count changed from #{initial_count} to #{post_removal_count} (#{removed_count} removed).")

    # build replacement refrigeration system from selected template
    runner.registerInfo('Adding replacement refrigeration objects.')
    if !create_refrigeration_system(model, runner, refrigeration_template)
      runner.registerError("Failed to create replacement refrigeration system using template '#{refrigeration_template}'.")
      return false
    end

    # confirm refrigeration object count after replacement
    final_count = refrigeration_object_count(model)
    created_count = final_count - post_removal_count
    runner.registerInfo("Post-upgrade refrigeration object count: #{final_count}")
    if final_count <= 0
      runner.registerError("No refrigeration objects were found after attempting to apply template '#{refrigeration_template}'.")
      return false
    end

    runner.registerFinalCondition("Refrigeration replacement complete: removed #{removed_count} refrigeration objects and created #{created_count} refrigeration objects using '#{refrigeration_template}' template. Initial: #{initial_count}, final: #{final_count}.")
    return true
  end
end

# register the measure to be used by the application
UpgradeRefrigeration.new.registerWithApplication
