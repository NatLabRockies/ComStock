# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'fileutils'
require 'minitest/autorun'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'comstock-typical'
require_relative '../measure'

class AddHVACSystemTest < Minitest::Test
  def test_add_hvac_systems
    # Make the output directory if it doesn't exist
    output_dir = "#{__dir__}/output/"
    FileUtils.mkdir_p(output_dir)

    # List all the HVAC system types to test
    # [system_type, allowable_htg_unmet_hrs, allowable_clg_unmet_hrs]
    hvac_systems = [
      ['Baseboard district hot water', 600, 8760],
      ['Baseboard electric heat', 600, 8760],
      ['Baseboard gas boiler', 600, 8760],
      ['Direct evap coolers with baseboard district hot water', 600, 600],
      ['Direct evap coolers with baseboard electric', 600, 600],
      ['Direct evap coolers with baseboard gas boiler', 600, 600],
      ['Direct evap coolers with no heat', 8760, 600],
      ['Direct evap coolers with gas unit heaters', 600, 600],
      ['Fan coil chiller with boiler', 600, 600],
      ['Fan coil chiller with central air source heat pump', 600, 600],
      ['Fan coil chiller with district hot water', 600, 600],
      ['Fan coil chiller with baseboard electric', 600, 600],
      ['Fan coil chiller with gas unit heaters', 600, 600],
      ['Fan coil chiller with no heat', 8760, 600],
      ['Fan coil district chilled water with district hot water', 600, 600],
      ['Fan coil district chilled water with baseboard electric', 600, 600],
      ['Fan coil district chilled water with gas unit heaters', 600, 600],
      ['Fan coil district chilled water with no heat', 8760, 600],
      ['Forced air furnace', 600, 8760],
      ['Gas unit heaters', 600, 8760],
      ['PTAC with gas boiler', 600, 600],
      ['PTAC with gas coil', 600, 600],
      ['PTAC with baseboard electric', 600, 600],
      ['PTAC with no heat', 8760, 600],
      ['PTAC with district hot water', 600, 600],
      ['PTHP', 600, 600],
      ['PSZ-AC with baseboard electric', 600, 600],
      ['PSZ-AC with gas coil', 600, 600],
      ['PSZ-AC with district hot water', 600, 600],
      ['PSZ-AC with no heat', 8760, 600],
      ['PSZ-HP', 600, 600],
      ['PVAV with gas boiler reheat', 600, 600],
      ['PVAV with PFP boxes', 600, 600],
      ['Residential AC with baseboard electric', 600, 600],
      ['Residential AC with baseboard gas boiler', 600, 600],
      ['Residential AC with no heat', 8760, 600],
      ['Residential heat pump', 600, 600],
      ['Residential heat pump with no cooling', 600, 8760],
      ['Residential forced air furnace', 600, 600],
      ['VAV chiller with gas boiler reheat', 600, 600],
      ['VAV chiller with central air source heat pump reheat', 600, 600],
      ['VAV chiller with district hot water reheat', 600, 600],
      ['VAV chiller with PFP boxes', 600, 600],
      ['VAV chiller with gas coil reheat', 600, 600],
      ['Window AC with baseboard electric', 600, 600],
      ['Window AC with baseboard gas boiler', 600, 600],
      ['Window AC with baseboard central air source heat pump', 600, 600],
      ['Window AC with baseboard district hot water', 600, 600],
      ['Window AC with forced air furnace', 600, 600],
      ['Window AC with unit heaters', 600, 600],
      ['Window AC with no heat', 8760, 600]
    ]
    template = '90.1-2013'
    building_type = 'SmallOffice'
    climate_zone = 'ASHRAE 169-2013-2A'

    # Get the original working directory
    start_dir = Dir.pwd

    # Add each HVAC system to the test model
    # and run a sizing run to ensure it simulates.
    errs = []
    hvac_systems.each do |system_type, allowable_htg_unmet_hrs, allowable_clg_unmet_hrs|
      reset_log

      model_dir = "#{output_dir}/#{system_type.delete('/')}"
      FileUtils.mkdir_p model_dir

      begin
        Dir.chdir(model_dir)

        # Load the model if already created
        if File.exist?("#{model_dir}/AR/run/eplusout.sql")
          puts "Already ran #{system_type}"
          model = OpenStudio::Model::Model.new
          sql = OpenStudio::SqlFile.new("#{model_dir}/AR/run/eplusout.sql")
          model.setSqlFile(sql)
        else # make and run annual simulation
          puts "Running #{system_type}"

          # Load the test model
          translator = OpenStudio::OSVersion::VersionTranslator.new
          model = translator.loadModel(OpenStudio::Path.new("#{__dir__}/SmallOffice.osm"))
          assert(!model.empty?)
          model = model.get

          # set the weather file for the test model
          epw_file_path = "#{__dir__}/USA_TX_Houston-Bush.Intercontinental.AP.722430_TMY3.epw"
          OpenstudioStandards::Weather.model_set_building_location(model,
                                                                   weather_file_path: epw_file_path)

          # Modify the unmet hours tolerance to a reasonable value of 1F
          unmet_hrs_tol_r = 1
          unmet_hrs_tol_k = OpenStudio.convert(unmet_hrs_tol_r, 'R', 'K').get
          tol = model.getOutputControlReportingTolerances
          tol.setToleranceforTimeHeatingSetpointNotMet(unmet_hrs_tol_k)
          tol.setToleranceforTimeCoolingSetpointNotMet(unmet_hrs_tol_k)

          # create an instance of the measure
          measure = CreateTypicalBuildingFromModel.new

          # create an instance of a runner
          runner = OpenStudio::Ruleset::OSRunner.new

          # get arguments
          arguments = measure.arguments(model)
          argument_map = OpenStudio::Ruleset.convertOSArgumentVectorToMap(arguments)

          # create hash of argument values.
          args_hash = {}
          args_hash['system_type'] = system_type
          args_hash['building_type'] = building_type
          args_hash['template'] = template
          args_hash['climate_zone'] = climate_zone
          args_hash['add_elevators'] = false
          args_hash['add_internal_mass'] = false
          args_hash['add_exhaust'] = false
          args_hash['add_exterior_lights'] = false
          args_hash['add_swh'] = false

          # populate argument with specified hash value if specified
          arguments.each do |arg|
            temp_arg_var = arg.clone
            if args_hash[arg.name]
              assert(temp_arg_var.setValue(args_hash[arg.name]), "Could not set #{arg.name} to #{args_hash[arg.name]}")
            end
            argument_map[arg.name] = temp_arg_var
          end

          # run the measure
          measure.run(model, runner, argument_map)
          result = runner.result

          # show the output
          show_output(result)

          # assert that it ran correctly
          # errs << "Failed on #{system_type}" unless result.value.valueName == "Success"

          # Save the model
          model.save("#{model_dir}/final.osm", true)

          # Run the annual simulation
          std = Standard.build(template)
          annual_run_success = std.model_run_simulation_and_log_errors(model, "#{model_dir}/AR")

          # Log the errors
          log_messages_to_file("#{model_dir}/openstudio-standards.log", debug = false)

          # Check that the annual simulation succeeded
          errs << "For #{system_type} annual run failed" unless annual_run_success
        end

        # Check the conditioned floor area
        errs << "For #{system_type} there was no conditioned area." if model.getBuilding.conditionedFloorArea.get.zero?

        # Check the unmet heating hours
        unmet_htg_hrs = OpenstudioStandards::SqlFile.model_get_annual_occupied_unmet_heating_hours(model)
        if unmet_htg_hrs
          errs << "For #{system_type} there were #{unmet_htg_hrs} unmet occupied heating hours, more than the limit of #{allowable_htg_unmet_hrs}." if unmet_htg_hrs > allowable_htg_unmet_hrs
        else
          errs << "For #{system_type} could not determine unmet heating hours; simulation may have failed."
        end

        # Check the unmet cooling hours
        unmet_clg_hrs = OpenstudioStandards::SqlFile.model_get_annual_occupied_unmet_cooling_hours(model)
        if unmet_clg_hrs
          errs << "For #{system_type} there were #{unmet_clg_hrs} unmet occupied cooling hours, more than the limit of #{allowable_clg_unmet_hrs}." if unmet_clg_hrs > allowable_clg_unmet_hrs
        else
          errs << "For #{system_type} could not determine unmet cooling hours; simulation may have failed."
        end
      ensure
        Dir.chdir(start_dir)
      end
    end

    # Expected error "Cannot find current Workflow Step"
    assert(errs.size < 2, errs.join("\n"))

    return true
  end
end
