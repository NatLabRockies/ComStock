# Running ComStock Locally

## Installation

Clone [buildstockbatch](https://github.com/NREL/buildstockbatch) onto your computer

Switch to the `ccaradonna/comstock-24-03` branch **TODO remove this step once this branch is merged into buildstockbatch**

Create a new conda environment with **python 3.11** or above (only need to do this once):
```
$ conda create -y -n buildstockbatch python=3.11 pip
$ conda activate buildstockbatch
```

Navigate to the `/buildstockbatch` directory:
```
$ cd /path/to/buildstockbatch
```

Make sure you are using the latest version of `pip`:
```
$ pip install --upgrade pip
```

Install the libraries needed for the buildstockbatch repository:
```
$ python -m pip install -e .
```

Install GHEDesigner and PySAM
```
$ pip install GHEDesigner==1.0
$ pip install NREL-PySAM==4.2.0
```

Install the correct version of [openstudio](https://github.com/NREL/OpenStudio/releases) for ComStock. You can determine the correct version by looking at the [Dockerfile](https://github.com/NREL/ComStock/blob/develop/build/Dockerfile#L5) on the `develop` branch of ComStock.

[Look up](https://github.com/NREL/OpenStudio/wiki/OpenStudio-SDK-Version-Compatibility-Matrix) the version of Ruby (X.Y.Z) compatible with the selected OpenStudio version.

Install the version of Ruby compatible with the selected OpenStudio version, down to the correct patch release (matches X.Y.Z, not just X.Y). [Windows installers](https://rubyinstaller.org/downloads/archives/), make sure to check the MSYS2 box in the installer or Mac use [rbenv](http://octopress.org/docs/setup/rbenv/).

Add an environment variable `OPENSTUDIO_EXE` pointing to the OpenStudio executable:
```
Windows -->   C:\openstudio-X.Y.Z\bin\openstudio.exe
Mac     -->   /usr/local/bin/openstudio`
```

## Running

Modify your `.yml` file to point to your local buildstock.csv, ComStock repo, and weather file zip.
Match your installed OpenStudio version and SHA.
```yml
schema_version: '0.3'
buildstock_directory: C:/GitRepos/ComStock
project_directory: national
output_directory: C:/my_effort/runs/my_run
weather_files_path: C:/my_effort/BuildStock_2018_FIPS_HI.zip

os_version: X.Y.Z
os_sha: ABCDEFG12345 # Look up SHA for os_version at https://github.com/NREL/OpenStudio/wiki/OpenStudio-SDK-Version-Compatibility-Matrix

sampler:
  type: precomputed
  args:
    sample_file: C:/my_effort/samples/buildstock.csv
```

Optional: modify `ComStock/resources/Gemfile` to customize gems. The building-generation library is `comstock-typical`, a fork of `openstudio-standards` that keeps the `lib/openstudio-standards` layout, but measures should `require 'comstock-typical'` to avoid namespace collisions with other gems that have openstudio-standards dependencies (i.e. GEB gem). You can comment out the git source and point to a local checkout to enable quick testing.
```ruby
# gem 'comstock-typical', git: 'https://github.com/NatLabRockies/ComStock-Typical.git', ref: '<sha>'
gem 'comstock-typical', path: "C:/Repos/NREL/ComStock-Typical"
```

Windows path lengths: Bundler clones git gems into `.custom_gems`, and a deep `buildstock_directory` can push those paths past the Windows limit. Runs here use a shallow checkout at `C:/csd` for that reason.

__Windows: run Anaconda Prompt as Administrator. If you don't it will fail to install custom gems!__

Activate conda environment:
```
$ conda activate buildstockbatch
```

Navigate to directory with `.yml`:
```
$ cd C:/my_effort/ymls
```

Run the simulation:
```
$ buildstock_local my_run.yml
```

__If you get a run error related to custom gem installation, try deleting  ComStock/.custom_gems/Gemfile.lock and rerunning__




Simulation results will show up in `C:/my_effort/runs/my_run`. During the run,
the simulation results will be viewable uncompressed. When the run finishes,
everything will be compressed into a `.tar.gz` just like on Eagle.
