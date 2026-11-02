# Expand occupancy schedules with the gem's own expansion (as the schedule editor does) and
# write them to JSON for plotting. Run: openstudio -I <ComStock-Typical>/lib export_profiles.rb out.json
require 'json'
require 'openstudio-standards'

gem_dir = ENV['COMSTOCK_TYPICAL_DIR'] || File.expand_path('../../../../ComStock-Typical', __dir__)
G = File.join(gem_dir, 'lib', 'openstudio-standards') + '/'
all_types = JSON.parse(File.read("#{G}space_type/data/all_level_space_types.json"), symbolize_names: true)
sets = JSON.parse(File.read("#{G}schedules/data/default_parametric_schedule_set.json"), symbolize_names: true)
occ = JSON.parse(File.read("#{G}schedules/data/default_occupancy_schedules.json"), symbolize_names: true)

types = %w[office conference/meeting/multipurpose lobby retail] + ['retail - supermarket', 'classroom/lecture/training - primary school',
          'classroom/lecture/training - secondary school', 'library - primary school', 'dining', 'dining - cafeteria/fast food',
          'food preparation', 'food preparation - primary school', 'guest room', 'laundry/washing', 'exam/treatment', 'nurses station',
          'patient room', 'operating room', 'emergency room', 'imaging', 'physical therapy', 'lounge/breakroom', 'storage', 'exercise area']

out = {}
types.each do |st_name|
  a = all_types.find { |r| r[:space_type_name] == st_name }
  set = sets.find { |s| s[:schedule_set_name] == a[:schedule_set_name] }
  sch_name = set[:occupancy_schedule]
  out[st_name] = { 'schedule' => sch_name, 'days' => {} }
  next if sch_name.nil?

  occ.select { |r| r[:name] == sch_name }.each do |rec|
    day = rec[:day_types] || 'Default'
    next if %w[SmrDsn WntrDsn].include?(day)

    pairs = OpenstudioStandards::Schedules.expand_schedule_control_points(rec, rec[:base_std], rec[:peak_std], rec[:st_std], rec[:et_std], 4)
    out[st_name]['days'][day] = { 'st' => rec[:st_std], 'et' => rec[:et_std], 'pairs' => pairs }
  end
end
File.write(ARGV[0], JSON.pretty_generate(out))
puts "wrote #{ARGV[0]}: #{out.size} space types"
