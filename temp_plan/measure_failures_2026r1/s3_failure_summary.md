# S3 failure summary: sdr_2026r1_all_measure_10k

## 14: ['DOAS_HP_Minisplits'] (rows=8634)
- completed_status: {'Invalid': 6736, 'Fail': 1898}
- apply_upgrade.applicable: {False: 6736, None: 1898}
- `step_failures` x6736: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': []}]
- `step_failures` x1896: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_doas_hp_minisplits/measure.rb:339:in `blo
- `step_failures` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]
- FULL `measure.rb:339` x1896: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_doas_hp_minisplits/measure.rb:339:in `block (2 levels) in run'\n/lib/resources/measures/upgrade_hvac_doas_hp_minisplits/measure.rb:282:in `each'\n/lib/resources/measures/upgrade_hvac_doas_hp_minisplits/measure.rb:282:in `block in run'\n/lib/resources/measures/upgrade_hvac_doas_hp_minisplits/measure.rb:274:in `each'\n/lib/resources/measures/upgrade_hvac_doas_hp_minisplits/measure.rb:274:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/reso
- FULL `[{'measure_dir_name': 'BuildExistingModel', 'step_errors': [` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]

## 22: ['Advanced_RTU_Controls'] (rows=8634)
- completed_status: {'Invalid': 4487, 'Fail': 4147}
- apply_upgrade.applicable: {False: 4487, None: 4147}
- `step_failures` x4487: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': []}]
- `step_failures` x4145: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_advanced_rtu_control/measure.rb:391:in `block 
- `step_failures` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]
- FULL `measure.rb:391` x4145: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_advanced_rtu_control/measure.rb:391:in `block (2 levels) in run'\n/lib/resources/measures/upgrade_advanced_rtu_control/measure.rb:333:in `each'\n/lib/resources/measures/upgrade_advanced_rtu_control/measure.rb:333:in `block in run'\n/lib/resources/measures/upgrade_advanced_rtu_control/measure.rb:331:in `each'\n/lib/resources/measures/upgrade_advanced_rtu_control/measure.rb:331:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/resources/meta_meas
- FULL `[{'measure_dir_name': 'BuildExistingModel', 'step_errors': [` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]

## 26: ['Pmp'] (rows=8634)
- completed_status: {'Invalid': 6120, 'Fail': 2514}
- apply_upgrade.applicable: {False: 6120, None: 2514}
- `step_failures` x6120: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': []}]
- `step_failures` x2512: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_pump/measure.rb:144:in `block in pump_spe
- `step_failures` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]
- FULL `measure.rb:144` x2512: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_pump/measure.rb:144:in `block in pump_specifications'\n/lib/resources/measures/upgrade_hvac_pump/measure.rb:108:in `each'\n/lib/resources/measures/upgrade_hvac_pump/measure.rb:108:in `pump_specifications'\n/lib/resources/measures/upgrade_hvac_pump/measure.rb:628:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/resources/meta_measure.rb:71:in `block in apply_measures'\n/lib/resources/meta_measure.rb:54:in `each'\n/lib/resources/meta_measur
- FULL `[{'measure_dir_name': 'BuildExistingModel', 'step_errors': [` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]

## 27: [] (rows=8634)
- completed_status: {'Fail': 8634}
- apply_upgrade.applicable: {None: 8634}
- `step_failures` x8632: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_enable_ideal_air_loads/measure.rb:86:in `
- `step_failures` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]
- FULL `measure.rb:86` x8632: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_enable_ideal_air_loads/measure.rb:86:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/resources/meta_measure.rb:71:in `block in apply_measures'\n/lib/resources/meta_measure.rb:54:in `each'\n/lib/resources/meta_measure.rb:54:in `apply_measures'\n/measures/ApplyUpgrade/measure.rb:296:in `run'"]}]
- FULL `[{'measure_dir_name': 'BuildExistingModel', 'step_errors': [` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]

## 29: ['Packaged_GHP'] (rows=8634)
- completed_status: {'Fail': 5494, 'Invalid': 3140}
- apply_upgrade.applicable: {None: 5494, False: 3140}
- `step_failures` x5407: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:956:in `block in
- `step_failures` x3140: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': []}]
- `step_failures` x51: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:866:in `setAvail
- `step_failures` x32: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:874:in `setAvail
- `step_failures` x2: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:941:in `block in
- `step_failures` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]
- FULL `measure.rb:956` x5407: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:956:in `block in run'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `each'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/resources/meta_measure.rb:71:in `block in apply_measures'\n/lib/resources/meta_measure.rb:54:in `each'\n/lib/resources/meta_measure.rb:54:in `apply_measures'\n/measures/ApplyUpgrade/measure.rb:296:in `r
- FULL `measure.rb:866` x51: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:866:in `setAvailabilitySchedule'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:866:in `block in run'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `each'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/resources/meta_measure.rb:71:in `block in apply_measures'\n/lib/resources/meta_measure.rb:54:in `each'\n/l
- FULL `measure.rb:874` x32: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:874:in `setAvailabilitySchedule'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:874:in `block in run'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `each'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/resources/meta_measure.rb:71:in `block in apply_measures'\n/lib/resources/meta_measure.rb:54:in `each'\n/l
- FULL `[{'measure_dir_name': 'BuildExistingModel', 'step_errors': [` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]
- FULL `measure.rb:941` x2: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:941:in `block in run'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `each'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/resources/meta_measure.rb:71:in `block in apply_measures'\n/lib/resources/meta_measure.rb:54:in `each'\n/lib/resources/meta_measure.rb:54:in `apply_measures'\n/measures/ApplyUpgrade/measure.rb:296:in `r

## 31: ['Chiller_Replacement'] (rows=8634)
- completed_status: {'Invalid': 7471, 'Fail': 1163}
- apply_upgrade.applicable: {False: 7471, None: 1163}
- `step_failures` x7471: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': []}]
- `step_failures` x1161: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_chiller/measure.rb:159:in `block in pump_
- `step_failures` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]
- FULL `measure.rb:159` x1161: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_chiller/measure.rb:159:in `block in pump_specifications'\n/lib/resources/measures/upgrade_hvac_chiller/measure.rb:133:in `each'\n/lib/resources/measures/upgrade_hvac_chiller/measure.rb:133:in `pump_specifications'\n/lib/resources/measures/upgrade_hvac_chiller/measure.rb:734:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/resources/meta_measure.rb:71:in `block in apply_measures'\n/lib/resources/meta_measure.rb:54:in `each'\n/lib/resources
- FULL `[{'measure_dir_name': 'BuildExistingModel', 'step_errors': [` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]

## 43: [] (rows=8634)
- completed_status: {'Fail': 8634}
- apply_upgrade.applicable: {None: 8634}
- `step_failures` x1641: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'office' does not have a prototype_lighting_space_type property assigned.  Cannot assign light
- `step_failures` x1211: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'retail' does not have a prototype_lighting_space_type property assigned.  Cannot assign light
- `step_failures` x897: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'corridor' does not have a prototype_lighting_space_type property assigned.  Cannot assign lig
- `step_failures` x775: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'classroom/lecture/training' does not have a prototype_lighting_space_type property assigned. 
- `step_failures` x740: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'storage - warehouse - medium to bulky palletized items' does not have a prototype_lighting_sp
- `step_failures` x602: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'dining' does not have a prototype_lighting_space_type property assigned.  Cannot assign light
- `step_failures` x555: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'guest room' does not have a prototype_lighting_space_type property assigned.  Cannot assign l
- `step_failures` x479: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'storage' does not have a prototype_lighting_space_type property assigned.  Cannot assign ligh
- FULL `[{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space` x8632: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'retail' does not have a prototype_lighting_space_type property assigned.  Cannot assign lighting."]}]
- FULL `[{'measure_dir_name': 'BuildExistingModel', 'step_errors': [` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]

## 64: ['Package_11'] (rows=8634)
- completed_status: {'Fail': 8040, 'Invalid': 594}
- apply_upgrade.applicable: {None: 8040, False: 594}
- `step_failures` x5405: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:956:in `block in
- `step_failures` x594: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': []}]
- `step_failures` x430: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'guest room' does not have a prototype_lighting_space_type property assigned.  Cannot assign l
- `step_failures` x388: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'office' does not have a prototype_lighting_space_type property assigned.  Cannot assign light
- `step_failures` x299: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'retail' does not have a prototype_lighting_space_type property assigned.  Cannot assign light
- `step_failures` x285: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'corridor' does not have a prototype_lighting_space_type property assigned.  Cannot assign lig
- `step_failures` x223: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'classroom/lecture/training' does not have a prototype_lighting_space_type property assigned. 
- `step_failures` x190: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'storage - warehouse - medium to bulky palletized items' does not have a prototype_lighting_sp
- FULL `measure.rb:956` x5405: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:956:in `block in run'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `each'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/resources/meta_measure.rb:71:in `block in apply_measures'\n/lib/resources/meta_measure.rb:54:in `each'\n/lib/resources/meta_measure.rb:54:in `apply_measures'\n/measures/ApplyUpgrade/measure.rb:296:in `r
- FULL `[{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space` x2499: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Space type 'storage' does not have a prototype_lighting_space_type property assigned.  Cannot assign lighting.", 'Child measure (light_led) failed.']}]
- FULL `measure.rb:866` x35: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:866:in `setAvailabilitySchedule'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:866:in `block in run'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `each'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/resources/meta_measure.rb:71:in `block in apply_measures'\n/lib/resources/meta_measure.rb:54:in `each'\n/l
- FULL `measure.rb:215` x3: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /usr/lib/resources/measures/upgrade_env_exterior_wall_insulation/measure.rb:215:in `setConstruction'\n/usr/lib/resources/measures/upgrade_env_exterior_wall_insulation/measure.rb:215:in `block in run'\n/usr/lib/resources/measures/upgrade_env_exterior_wall_insulation/measure.rb:209:in `each'\n/usr/lib/resources/measures/upgrade_env_exterior_wall_insulation/measure.rb:209:in `run'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/resources/call_other_measures.rb:124:in `call_walls'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:388:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/l
- FULL `measure.rb:874` x25: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:874:in `setAvailabilitySchedule'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:874:in `block in run'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `each'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/resources/meta_measure.rb:71:in `block in apply_measures'\n/lib/resources/meta_measure.rb:54:in `each'\n/l
- FULL `measure.rb:443` x69: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_hydronic_gshp/measure.rb:443:in `block in run'\n/lib/resources/measures/upgrade_hvac_hydronic_gshp/measure.rb:442:in `each'\n/lib/resources/measures/upgrade_hvac_hydronic_gshp/measure.rb:442:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/resources/meta_measure.rb:71:in `block in apply_measures'\n/lib/resources/meta_measure.rb:54:in `each'\n/lib/resources/meta_measure.rb:54:in `apply_measures'\n/measures/ApplyUpgrade/measure.rb:296:in `r
- FULL `[{'measure_dir_name': 'BuildExistingModel', 'step_errors': [` x2: [{'measure_dir_name': 'BuildExistingModel', 'step_errors': ['create_custom_building_from_spec failed, see previous errors.']}]
- FULL `measure.rb:941` x2: [{'measure_dir_name': 'ApplyUpgrade', 'step_errors': ["Measure Failed with Error: /lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:941:in `block in run'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `each'\n/lib/resources/measures/upgrade_hvac_packaged_gshp/measure.rb:854:in `run'\n/lib/resources/meta_measure.rb:201:in `run_measure'\n/lib/resources/meta_measure.rb:77:in `block (2 levels) in apply_measures'\n/lib/resources/meta_measure.rb:71:in `each'\n/lib/resources/meta_measure.rb:71:in `block in apply_measures'\n/lib/resources/meta_measure.rb:54:in `each'\n/lib/resources/meta_measure.rb:54:in `apply_measures'\n/measures/ApplyUpgrade/measure.rb:296:in `r

- hvac_system_type `PSZ-AC with gas coil`: 2077
- hvac_system_type `PSZ-AC with electric coil`: 1104
- hvac_system_type `Residential AC with residential forced air furnace`: 659
- hvac_system_type `PVAV with gas boiler reheat`: 633
- hvac_system_type `PSZ-HP`: 562
- hvac_system_type `PVAV with PFP boxes`: 525
- hvac_system_type `PTAC with electric coil`: 374
- hvac_system_type `PTHP`: 367
- hvac_system_type `PVAV with gas heat with electric reheat`: 360
- hvac_system_type `VAV chiller with gas boiler reheat`: 355
- hvac_system_type `VAV air-cooled chiller with gas boiler reheat`: 243
- hvac_system_type `VAV district chilled water with district hot water reheat`: 235
- hvac_system_type `PTAC with gas boiler`: 183
- hvac_system_type `PSZ-AC with gas boiler`: 151
- hvac_system_type `VAV chiller with PFP boxes`: 120
- hvac_system_type `DOAS with water source heat pumps cooling tower with boiler`: 115
- hvac_system_type `DOAS with fan coil air-cooled chiller with boiler`: 107
- hvac_system_type `DOAS with water source heat pumps with ground source heat pump`: 101
- hvac_system_type `DOAS with fan coil chiller with boiler`: 94
- hvac_system_type `PTAC with gas coil`: 93
- hvac_system_type `VAV chiller with district hot water reheat`: 70
- hvac_system_type `DOAS with fan coil chiller with district hot water`: 31
- hvac_system_type `DOAS with fan coil district chilled water with district hot water`: 25
- hvac_system_type `DOAS with fan coil chiller with baseboard electric`: 16
- hvac_system_type `PSZ-AC with district hot water`: 11
- hvac_system_type `VAV air-cooled chiller with PFP boxes`: 8
- hvac_system_type `PVAV with district hot water reheat`: 8
- hvac_system_type `DOAS with fan coil district chilled water with baseboard electric`: 5
- hvac_system_type `VAV air-cooled chiller with district hot water reheat`: 2