# ComStock
ComStock is an NREL model of the U.S. commercial building stock. The model takes some building characteristics from the
U.S. Department of Energy's (DOE's) Commercial Prototype Building Models and Commercial Reference Building. However,
unlike many other building stock models, ComStock also combines these with a variety of additional public- and
private-sector data sets. Collectively, this information provides high-fidelity building stock representation with a
realistic diversity of building characteristics.

This repository contains the source code used to build and execute ComStock models, including upgrade scenarios. In
addition, the sampling of buildings characteristics used for the initial ComStock (V1.0) release is provided.  The ComStock model is under active calibration and development, which is publicly visible on this repository.

Execution of the ComStock workflow is managed through the [buildstockbatch repository](https://github.com/NREL/buildstockbatch), a shared asset of ResStock and ComStock,
specifically developed to scale to execution of tens of millions of simulations through multiple infrastructure
providers.

The dataset output from the initial ComStock (V1.0) release can be found at the accompanying
[ComStock data viewer website](https://comstock.nrel.gov) and additional information about ComStock found on the
[NREL Buildings Website](https://www.nrel.gov/buildings/comstock.html). For more details about ongoing model development
please consult the [End Use Load Profiles](https://www.nrel.gov/buildings/end-use-load-profiles.html) website.

ComStock is a direct result of the NREL residential stock modeling tool
[ResStock](https://www.nrel.gov/buildings/resstock.html) (recipient of a
[R&D100 award](https://www.rdworldonline.com/rd100/resstock-a-21st-century-tool-for-energy-efficiency-modeling-with-unparalleled-granularity/))
and was inspired by the high-fidelity solar & storage adoption model [dGen](https://www.nrel.gov/analysis/dgen/).
Additionally, this tool would not be possible without the decades of work undertaken by the
[OpenStudio](https://www.openstudio.net/) and [EnergyPlus](https://energyplus.net/) visionaries and contributors,
significant funding, feedback and support from the [Los Angeles Department of Water and Power](https://www.ladwp.com/),
and the [Department of Energy's Building Technology Office](https://www.energy.gov/eere/buildings/building-technologies-office)
ongoing support of and investment in building energy modeling software.

## Directories
- [**`/build`**](https://github.com/NREL/ComStock/tree/main/build) contains instructions for building Apptainer images for running ComStock on HPC systems.
- [**`/documentation`**](https://github.com/NREL/ComStock/tree/main/documentation) contains LaTeX documentation and instructions for building the documentation.
- [**`/measures`**](https://github.com/NREL/ComStock/tree/main/measures) contains the high-level "meta" measures used to call other measures, and the reporting measures used to summarize outputs.
- [**`/national`**](https://github.com/NREL/ComStock/tree/main/national) contains seed directories necessary for a ComStock run using buildstockbatch.
- [**`/postprocessing`**](https://github.com/NREL/ComStock/tree/main/postprocessing) contains postprocessing scripts to create graphics for viewing results and comparing to other data sources.
- [**`/resources`**](https://github.com/NREL/ComStock/tree/main/resources) contains workflow and upgrade measures
- [**`/samples`**](https://github.com/NREL/ComStock/tree/main/samples) contains sample buildstock.csv files, which describe the set of models included in a run.
- [**`/sampling`**](https://github.com/NREL/ComStock/tree/main/sampling) contains instructions and code to generate buildstock.csv files.
- [**`/ymls`**](https://github.com/NREL/ComStock/tree/main/ymls) contains sample .yml files, which are the configuration files used to execture a ComStock run with buildstockbatch.

## Usage
ComStock is under an open source license. See [LICENSE.txt](https://github.com/NREL/ComStock/blob/develop/LICENSE.txt) in this directory.
You are welcome to use this repository for your own use. However, we do not provide technical support. Please refer to our [technical assistance documentation](https://nrel.github.io/ComStock.github.io/docs/resources/resources.html) instead. We strongly suggest and support using the public datasets instead of attempting to run millions of building energy models yourself.

## Developer Installation
This is needed if you are a developer making changes to the `comstock-typical` gem (the fork of `openstudio-standards` that builds ComStock's models; see `resources/Gemfile`) or are running simulations locally using [BuildStock Batch](https://buildstockbatch.readthedocs.io/en/stable/).

1. Install the [latest version of OpenStudio](https://github.com/NREL/OpenStudio/releases). ComStock requires **OpenStudio 3.8.0** or newer.
2. Install the Ruby version that corresponds to your OpenStudio install. See the [OpenStudio SDK Version Compatibility Matrix](https://github.com/NREL/OpenStudio/wiki/OpenStudio-SDK-Version-Compatibility-Matrix).
      1. **On Mac**:
      2. Install Ruby 3.2.2 using [rbenv](http://octopress.org/docs/setup/rbenv/) (`ruby -v` from command prompt to check installed version).
      3. **On Windows**:
      4. Install [Ruby+Devkit 3.2.2](https://rubyinstaller.org/downloads/archives) (`ruby -v` from command prompt to check installed version).

3. Connect Ruby to OpenStudio:
	1. **On Mac**:
	2. Create a file called `openstudio.rb`
	3. Contents: `require "/Applications/openstudio-3.8.0/Ruby/openstudio.rb"` Modify `3.8.0` to the version you installed.
	4. Save it here: `/usr/lib/ruby/site_ruby/openstudio.rb`
	5. **On Windows**:
	6. Create a file called `openstudio.rb`
	7. Contents: `require "C:/openstudio-3.8.0/Ruby/openstudio.rb"`  Modify `3.8.0` to the version you installed.
	8. Save it here: `C:/Ruby32-x64/lib/ruby/site_ruby/openstudio.rb`

4. `gem install bundler` This installs the `bundler` ruby gem.
5. Install [Git](https://git-scm.com/).
6. Install [GitHub desktop](https://desktop.github.com/) or another GUI that makes Git easier to use.
7. Clone the [ComStock source code](https://github.com/NREL/ComStock.git) using GitHub desktop (easier) or Git (harder).
8. Run all commands below from the top level `/ComStock` directory
13. `mkdir .custom_gems` This makes a temp directory to install required gems inside.
13. `copy /Y .\resources\Gemfile .\.custom_gems\Gemfile` This copies the Gemfile to the temp directory.
13. `gem install bundler:2.4.10` This installs the version of bundler needed by OpenStudio.
13. `bundle _2.4.10_ install --path "C:/GitRepos/ComStock/.custom_gems" --gemfile "C:/GitRepos/ComStock/.custom_gems/Gemfile" --without test` This will install all ruby gems necessary to develop this code.
14. If running simulations locally, install [BuildStock Batch](https://buildstockbatch.readthedocs.io/en/stable/installation.html#local)
15. Add the following additional Python packages into your `buildstockbatch` environment:
```bash
conda activate buildstockbatch
pip install GHEDesigner==1.0
pip install NREL-PySAM==4.2.0
```

## Measure Tests
1. Follow the developer installation instructions above. In particular, `GHEDesigner==1.0` must be installed with `pip install GHEDesigner==1.0`.
2. Run the measure tests with the rake command:
  - `bundle exec rake unit_tests:all_tests` to run all measure tests.
  - `bundle exec rake unit_tests:reporting_measure_tests` to run all reporting measure tests.
  - `bundle exec rake unit_tests:workflow_measure_tests` to run all workflow measure tests.
	- `bundle exec rake unit_tests:upgrade_measure_tests` to run all `upgrade_` measure tests.

## Running Rubocop
1. Follow the developer installation instructions above
2. navigate to the `.custom_gems` directory
3. run `bundle exec rake rubocop:show` in terminal
4. review results by opening the `rubocop-results.html` in the `.rubocop/` directory
5. rubcop can automatically fix errors by running `rubocop --autocorrect`. This will fix some, but not all errors, so you still need to check and make manual fixes.
