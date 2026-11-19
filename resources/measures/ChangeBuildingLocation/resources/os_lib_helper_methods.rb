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

module OsLib_HelperMethods
  # populate choice argument from model objects
  def self.populateChoiceArgFromModelObjects(model, modelObject_args_hash, includeBuilding = nil)
    # populate choice argument for constructions that are applied to surfaces in the model
    modelObject_handles = OpenStudio::StringVector.new
    modelObject_display_names = OpenStudio::StringVector.new

    # looping through sorted hash of constructions
    modelObject_args_hash.sort.map do |key, value|
      modelObject_handles << value.handle.to_s
      modelObject_display_names << key
    end

    unless includeBuilding.nil?
      # add building to string vector with space type
      building = model.getBuilding
      modelObject_handles << building.handle.to_s
      modelObject_display_names << includeBuilding
    end

    result = { 'modelObject_handles' => modelObject_handles, 'modelObject_display_names' => modelObject_display_names }
    return result
  end

  # create variables in run from user arguments
  def self.createRunVariables(runner, model, user_arguments, arguments)
    result = {}

    error = false
    # use the built-in error checking
    unless runner.validateUserArguments(arguments, user_arguments)
      error = true
      runner.registerError('Invalid argument values.')
    end

    user_arguments.each do |argument|
      # get argument info
      arg = user_arguments[argument]
      arg_type = arg.print.lines($/)[1]

      # create argument variable
      if arg_type.include? 'Double, Required'
        eval("result[\"#{arg.name}\"] = runner.getDoubleArgumentValue(\"#{arg.name}\", user_arguments)")
      elsif arg_type.include? 'Integer, Required'
        eval("result[\"#{arg.name}\"] = runner.getIntegerArgumentValue(\"#{arg.name}\", user_arguments)")
      elsif arg_type.include? 'String, Required'
        eval("result[\"#{arg.name}\"] = runner.getStringArgumentValue(\"#{arg.name}\", user_arguments)")
      elsif arg_type.include? 'Boolean, Required'
        eval("result[\"#{arg.name}\"] = runner.getBoolArgumentValue(\"#{arg.name}\", user_arguments)")
      elsif arg_type.include? 'Choice, Required'
        eval("result[\"#{arg.name}\"] = runner.getStringArgumentValue(\"#{arg.name}\", user_arguments)")
      else
        puts 'not setup to handle all argument types yet, or any optional arguments'
      end
    end

    return false if error


    return result
  end

  # check choice argument made from model objects
  def self.checkChoiceArgFromModelObjects(object, variableName, to_ObjectType, runner, user_arguments)
    apply_to_building = false
    modelObject = nil
    if object.empty?
      handle = runner.getStringArgumentValue(variableName, user_arguments)
      if handle.empty?
        runner.registerError("No #{variableName} was chosen.") # this logic makes this not work on an optional model object argument
      else
        runner.registerError("The selected #{variableName} with handle '#{handle}' was not found in the model. It may have been removed by another measure.")
      end
      return false
    else
      if !eval("object.get.#{to_ObjectType}").empty?
        modelObject = eval("object.get.#{to_ObjectType}").get
      elsif !object.get.to_Building.empty?
        apply_to_building = true
      else
        runner.registerError("Script Error - argument not showing up as #{variableName}.")
        return false
      end
    end

    result = { 'modelObject' => modelObject, 'apply_to_building' => apply_to_building }
  end

  # check choice argument made from model objects
  def self.checkOptionalChoiceArgFromModelObjects(object, variableName, to_ObjectType, runner, user_arguments)
    apply_to_building = false
    modelObject = nil
    if object.empty?
      handle = runner.getOptionalStringArgumentValue(variableName, user_arguments)
      if handle.empty?
        # do nothing, this is a valid option
        puts 'hello'
        modelObject = nil
        apply_to_building = false
      else
        runner.registerError("The selected #{variableName} with handle '#{handle}' was not found in the model. It may have been removed by another measure.")
        return false
      end
    else
      if !eval("object.get.#{to_ObjectType}").empty?
        modelObject = eval("object.get.#{to_ObjectType}").get
      elsif !object.get.to_Building.empty?
        apply_to_building = true
      else
        runner.registerError("Script Error - argument not showing up as #{variableName}.")
        return false
      end
    end

    result = { 'modelObject' => modelObject, 'apply_to_building' => apply_to_building }
  end

  # check value of double arguments
  def self.checkDoubleAndIntegerArguments(runner, user_arguments, arg_check_hash)
    error = false

    # get hash values
    min = arg_check_hash['min']
    max = arg_check_hash['max']
    min_eq_bool = arg_check_hash['min_eq_bool']
    max_eq_bool = arg_check_hash['max_eq_bool']

    arg_check_hash['arg_array'].each do |argument|
      argument = user_arguments[argument]

      # get arg values
      arg_value = nil
      if argument.hasValue
        arg_value = argument.valueDisplayName.to_f # instead of valueAsDouble so it allows integer arguments as well
      elsif argument.hasDefaultValue
        arg_value = argument.defaultValueDisplayName.to_f
      end
      arg_display = argument.displayName

      unless min.nil?
        if min_eq_bool
          if arg_value < min
            runner.registerError("Please enter value greater than or equal to #{min} for #{arg_display}.") # add in argument display name
            error = true
          end
        else
          if arg_value <= min
            runner.registerError("Please enter value greater than #{min} for #{arg_display}.") # add in argument display name
            error = true
          end
        end
      end
      unless max.nil?
        if max_eq_bool
          if arg_value > max
            runner.registerError("Please enter value less than or equal to #{max} for #{arg_display}.") # add in argument display name
            error = true
          end
        else
          if arg_value >= max
            runner.registerError("Please enter value less than #{max} for #{arg_display}.") # add in argument display name
            error = true
          end
        end
      end
    end

    # check for any errors
    return false if error


    return true
  end

  # open channel to log info/warning/error messages
  def self.setup_log_msgs(runner, debug = false)
    # Open a channel to log info/warning/error messages
    @msg_log = OpenStudio::StringStreamLogSink.new
    if debug
      @msg_log.setLogLevel(OpenStudio::Debug)
    else
      @msg_log.setLogLevel(OpenStudio::Info)
    end
    @start_time = Time.new
    @runner = runner
  end

  # Get all the log messages and put into output
  # for users to see.
  def self.log_msgs
    @msg_log.logMessages.each do |msg|
      # DLM: you can filter on log channel here for now
      if /openstudio.*/.match(msg.logChannel) # /openstudio\.model\..*/
        # Skip certain messages that are irrelevant/misleading
        next if msg.logMessage.include?('Skipping layer') || # Annoying/bogus "Skipping layer" warnings
                msg.logChannel.include?('runmanager') || # RunManager messages
                msg.logChannel.include?('setFileExtension') || # .ddy extension unexpected
                msg.logChannel.include?('Translator') || # Forward translator and geometry translator
                msg.logMessage.include?('UseWeatherFile') # 'UseWeatherFile' is not yet a supported option for YearDescription

        # Report the message in the correct way
        if msg.logLevel == OpenStudio::Info
          @runner.registerInfo(msg.logMessage)
        elsif msg.logLevel == OpenStudio::Warn
          @runner.registerWarning("[#{msg.logChannel}] #{msg.logMessage}")
        elsif msg.logLevel == OpenStudio::Error
          @runner.registerError("[#{msg.logChannel}] #{msg.logMessage}")
        elsif msg.logLevel == OpenStudio::Debug && @debug
          @runner.registerInfo("DEBUG - #{msg.logMessage}")
        end
      end
    end
    @runner.registerInfo("Total Time = #{(Time.new - @start_time).round}sec.")
  end

  def self.check_upstream_measure_for_arg(runner, arg_name)
    # 2.x methods (currently setup for measure display name but snake_case arg names)
    arg_name_value = {}
    runner.workflow.workflowSteps.each do |step|
      if step.to_MeasureStep.is_initialized
        measure_step = step.to_MeasureStep.get

        measure_name = measure_step.measureDirName
        if measure_step.name.is_initialized
          measure_name = measure_step.name.get # this is instance name in PAT
        end
        if measure_step.result.is_initialized
          result = measure_step.result.get
          result.stepValues.each do |arg|
            name = arg.name
            value = arg.valueAsVariant.to_s
            if name == arg_name
              arg_name_value[:value] = value
              arg_name_value[:measure_name] = measure_name
              return arg_name_value # stop after find first one
            end
          end
        else
          # puts "No result for #{measure_name}"
        end
      else
        # puts "This step is not a measure"
      end
    end

    return arg_name_value
  end

  # populate choice argument from model objects. areaType should be string like "floorArea" or "exteriorArea"
  # note: it seems like spaceType.floorArea does account for multiplier, so I don't have to call this method unless I have a custom collection of spaces.
  def self.getAreaOfSpacesInArray(model, spaceArray, areaType = 'floorArea')
    # find selected floor spaces, make array and get floor area.
    totalArea = 0
    spaceAreaHash = {}
    spaceArray.each do |space|
      spaceArea = eval("space.#{areaType}*space.multiplier")
      spaceAreaHash[space] = spaceArea
      totalArea += spaceArea
    end

    result = { 'totalArea' => totalArea, 'spaceAreaHash' => spaceAreaHash }
    return result
  end

  # runs conversion and neat string, and returns value with units in string, optionally before or after the value
  def self.neatConvertWithUnitDisplay(double, fromString, toString, digits, unitBefore = false, unitAfter = true, space = true, parentheses = true)
    # convert units
    doubleConverted = OpenStudio.convert(double, fromString, toString)
    if doubleConverted.nil?
      puts "Couldn't convert values, check string choices passed in. From: #{fromString}, To: #{toString}"
    else
      doubleConverted = doubleConverted.get
    end

    # get neat version of converted
    neatConverted = OpenStudio.toNeatString(doubleConverted, digits, true)

    # add prefix
    if unitBefore
      if space == true && parentheses == true
        prefix = "(#{toString}) "
      elsif space == true && parentheses == false
        prefix = "(#{toString})"
      elsif space == false && parentheses == true
        prefix = "#{toString} "
      else
        prefix = toString.to_s
      end
    else
      prefix = ''
    end

    # add suffix
    if unitAfter
      if space == true && parentheses == true
        suffix = " (#{toString})"
      elsif space == true && parentheses == false
        suffix = "(#{toString})"
      elsif space == false && parentheses == true
        suffix = " #{toString}"
      else
        suffix = toString.to_s
      end
    else
      suffix = ''
    end

    finalString = "#{prefix}#{neatConverted}#{suffix}"

    return finalString
  end

  # helper that loops through lifecycle costs getting total costs under "Construction" and add to counter if occurs during year 0
  def self.getTotalCostForObjects(objectArray, category = 'Construction', onlyYearFromStartZero = true)
    counter = 0
    objectArray.each do |object|
      object_LCCs = object.lifeCycleCosts
      object_LCCs.each do |object_LCC|
        if object_LCC.category == category && (onlyYearFromStartZero == false || object_LCC.yearsFromStart == 0)
          counter += object_LCC.totalCost
        end
      end
    end

    return counter
  end

  # helper that loops through lifecycle costs getting total costs under "Construction" and add to counter if occurs during year 0
  def self.getSpaceTypeStandardsInformation(spaceTypeArray)
    # hash of space types
    spaceTypeStandardsInfoHash = {}

    spaceTypeArray.each do |spaceType|
      # get standards building
      if spaceType.standardsBuildingType.empty?
        standardsBuilding = nil
      else
        standardsBuilding = spaceType.standardsBuildingType.get
      end

      # get standards space type
      if spaceType.standardsSpaceType.empty?
        standardsSpaceType = nil
      else
        standardsSpaceType = spaceType.standardsSpaceType.get
      end

      # populate hash
      spaceTypeStandardsInfoHash[spaceType] = [standardsBuilding, standardsSpaceType]
    end

    return spaceTypeStandardsInfoHash
  end

  # OpenStudio has built in toNeatString method
  # OpenStudio::toNeatString(double,2,true)# double,decimals, show commas

  # OpenStudio has built in helper for unit conversion. That can be done using OpenStudio::convert() as shown below.
  # OpenStudio::convert(double,"from unit string","to unit string").get
end
