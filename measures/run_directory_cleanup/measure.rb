# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

require 'fileutils'

# start the measure
class RunDirectoryCleanup < OpenStudio::Measure::ReportingMeasure
  # define the name that a user will see, this method may be deprecated as
  # the display name in PAT comes from the name field in measure.xml
  def name
    'Run Directory Cleanup'
  end

  # define the arguments that the user will input
  def arguments(_model = nil)
    OpenStudio::Ruleset::OSArgumentVector.new
  end

  # define what happens when the measure is run
  def run(runner, user_arguments)
    super(runner, user_arguments)

    # use the built-in error checking
    false unless runner.validateUserArguments(arguments, user_arguments)

    # Specify file patterns to delete
    del_patterns = [
      # Top-level files
      './../*.epw',
      './../*.sql',
      './../*.audit',
      './../*.bnd',
      './../*.eio',
      './../*.shd',
      './../*.mdd',
      './../*.eso',
      './../pre-preprocess.idf',
      './../*.end',
      './../*.mtd',
      './../eplusssz.csv',
      './../*.mtr',
      './../eplusout.csv',
      './../eplusmtr.csv',
      './../data_point.zip',
      # Sizing run files
      './../**/*SR*/**/*.epw',
      './../**/*SR*/**/*.sql',
      './../**/*SR*/**/*.audit',
      './../**/*SR*/**/*.bnd',
      './../**/*SR*/**/*.eio',
      './../**/*SR*/**/*.shd',
      './../**/*SR*/**/*.mdd',
      './../**/*SR*/**/*.eso',
      './../**/*SR*/**/pre-preprocess.idf',
      './../**/*SR*/**/*.end',
      './../**/*SR*/**/*.mtd',
      './../**/*SR*/**/eplusssz.csv',
      './../**/*SR*/**/*.mtr',
      './../**/*SR*/**/eplusout.csv',
      './../**/*SR*/**/eplusmtr.csv',
      './../**/*SR*/**/data_point.zip'
    ]

    # Delete files
    del_patterns.each do |del_pattern|
      Dir.glob(del_pattern).each do |f|
        File.delete(f)
        runner.registerInfo("Deleted file #{f} from the run directory.") unless File.exist?(f)
      end
    end

    true
  end
end

# this allows the measure to be use by the application
RunDirectoryCleanup.new.registerWithApplication
