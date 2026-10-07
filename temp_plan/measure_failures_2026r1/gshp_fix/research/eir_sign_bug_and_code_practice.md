# Research: EIR heating sign bug, and code/practice for GSHP plant pumping (2026-10-06)

Two research agents; raw structured results. The first block verifies the EnergyPlus 25.1 heating source-side sign bug and its upstream fix; the second covers ASHRAE 90.1, manufacturer minimum flows and pumping practice, with sources.

====================================================================================================
## claim_verdict
confirmed

## code_analysis
The code claim is correct. All line numbers are from C:/tmp/eplus_src/PlantLoopHeatPumpEIR.cc, which I checked is byte-identical to the NREL v25.1.0 tag. The installed exe reports 'EnergyPlus, Version 25.1.0-1c11a3d85f'.

- simulate L86-159. L93 refreshes this->sourceSideInletTemp from Node(source inlet) on every call, including source-side calls. L99 calls setOperatingFlowRatesWSHP. On the source-loop branch, L102-107 compute sourceQdotArg (negated for HeatPumpEIRHeating, 'pass negative if heat pump heating'), but L108-118 pass `this->sourceSideHeatTransfer` (L114) to UpdateChillerComponentCondenserSide. sourceQdotArg is computed and never used.
- Sign of sourceSideHeatTransfer for heating: classesToInput L1658-1671 give Heating calcQsource = subtract (Qload - P, positive) and calcSourceOutletTemp = subtract (Tin - Q/mcp). calcSourceSideHeatTransferWSHP L604-626 sets sourceSideHeatTransfer (L608, positive extraction) and sourceSideOutletTemp = Tin - Q/(m cp) (L615), with the +-100 K clamp at L617-625. report() L2457-2479 writes Node(source outlet).Temp = sourceSideOutletTemp (L2474). That is the correct sign.
- PlantUtilities.cc UpdateChillerComponentCondenserSide L938-1024. Sign convention: L996-997 set outlet = Node(inlet).Temp + ModelCondenserHeatRate/(Node(inlet).mdot*Cp), so a positive rate means heat rejected into the loop. DidAnythingChange is set by L974-980 (node inlet/outlet mdot != model, inlet T != model, outlet T != model) or L984 (zero inlet flow with Q > 0). The recompute runs only if `DidAnythingChange || FirstHVACIteration` (L991) and the inlet mdot is above tolerance (L993).
  - For this caller the inlet-temperature test never fires, because ModelInletTemp was just copied from the node (L93).
  - The flow tests never fire either, because setOperatingFlowRatesWSHP calls SetComponentFlowRate. That routine writes the node flow and copies it back into the member (PlantUtilities.cc L187-270).
  - So the wrong-sign recompute happens on every source-side call during FirstHVACIteration, and in a later iteration only if Node(outlet).Temp no longer equals the member (for example, still left over from an earlier overwrite).
- Other callers pass the routine's sign convention correctly. Chillers pass +QCondenser (ChillerElectricEIR.cc v25.1 L150-156; PlantChillers.cc; absorption chillers), as does VRF (HVACVariableRefrigerantFlow.cc L325-335, QCondenser). HeatPump:WaterToWater:EquationFit passes +reportQSource for cooling (HeatPumpWaterToWaterSimple.cc v25.1 L139) and -reportQSource for heating (L159), where heating QSource = QLoad - Power is positive (L1765). HeatPumpWaterToWaterHEATING.cc passes -this->QSource (~24.2 tree L121-131). EIR Heating is the only heating-mode caller that does not negate.
- Separately, setOperatingFlowRatesWSHP L254 applies the PLR flow reduction only when `!FirstHVACIteration && flowControl == VariableSpeedPump`. On FirstHVACIteration the source flow is therefore design flow in both flow modes.

## when_it_bites
**When the wrong-sign outlet is written.** Every source-side call during the FirstHVACIteration plant solve. SimHVAC (HVACManager.cc) then always runs at least one non-first iteration with every plant loop side flagged for re-simulation (SetAllPlantSimFlagsToValue(true), plus at least 2 forced plant passes per ManagePlantLoops). In that iteration the heat pump's load-side call runs doPhysics and report(), which puts the correctly signed member Tout back on Node 46.

**Measured with a pyenergyplus probe** (snapshots at each HVAC-iteration calling point and at the end of the system timestep; 25.1 exe; January):
- Right after FirstHVACIteration, Node46 > Node45 in 100% of operating steps. This held in both the VS hotel model and the ConstantFlow/constant-speed-pump model (4964/4964 steps each). (T46 - T45) / (Q/(m45 * 3930)) = 0.9927 +- 0.0002, which is exactly inlet + Q/(m cp) for a glycol cp of about 3959. The flow was 100% of design.
- From the next iteration on, and at the end of every timestep, Node46 equals the heat pump's member Tout in 100% of steps. So the wrong temperature itself never survives to the end of the timestep.

**But its effect leaks.** The last doPhysics in each timestep used an inlet temperature equal to the condenser demand-inlet temperature (Node 13) left by the FirstHVAC solve:
- Constant-flow run: median difference 3.4e-5 K.
- VS run: median difference 5e-3 K.

That inlet is warmed by the wrong-sign pass. Later source-side calls then refresh the member Tin and flow without recomputing the outlet (no DidAnythingChange), so the outlet node stays anchored to the stale inlet. Which pass order produces this is inferred; I did not dump the plant calling order. I also did not verify whether the condenser demand side is solved before the heat pump's load side at the start of iteration 2, which would trigger one more wrong-sign recompute through the outlet-mismatch test.

**ConstantFlow:** later iterations also run at design flow, so the correct temperature drop (about 0.2 K) is the same size as the FirstHVAC error. At the end of the timestep:
- the outlet is warmer than the inlet in 8.1% of system steps;
- node-based extraction is 9% of reported (108 vs 1259 kWh in January, system-step weighted).

**VariableSpeedPumping:** later iterations run at about 3% of design flow (median m/design 0.026), so the correct drop is about 2.75 K and the FirstHVAC error (+0.087 K) is small by comparison:
- the outlet is never warmer than the inlet at the end of a step (0/4267);
- node-based extraction is 83% of reported (1026 vs 1241 kWh).

The trickle-flow runaway (+-100 K clamp) is on the correctly signed doPhysics path (L615-625) with flow = design x previous PLR. It is not caused by this sign bug (inferred).

## empirical_evidence
**1. The supplied January sql** (C:/tmp/run3_pump/run_ga_cs_jan_ts/eplusout.sql; ConstantFlow, constant-speed Intermittent pump, Zone Timestep averages; Heating HeatPump 1 source nodes 45 -> 46 verified in ga_cs_jan_ts.idf L12948-12954; HX supply side 12 -> 16):
- Node 46 temperature equals 'Heat Pump Source Side Outlet Temperature' and Node 45 equals the reported inlet in all 2976 steps (difference 0).
- Node-based m45 * 3930 * (T45 - T46) is 160 kWh against 1259 kWh reported extraction (12.7%).
- T46 > T45 in 337 of 2762 operating 15-minute steps (12.2%).
- Other January totals: HX -26 kWh, cooling heat pump +99 kWh, pump heat 222 kWh.
- Example at 01/01 00:15: Q = 4086 W, m = 4.949 kg/s, Tin 14.263, Tout 14.378.

**2. VS hotel January run** (copy at C:/tmp/eir_wf/sign_claim/vs_jan/in.idf, Detailed outputs):
- Node46 equals member Tout in 4267/4267 operating system steps; outlet warmer than inlet 0%.
- Node-based 1025 kWh vs 1241 kWh reported; HX -890 kWh vs net heat pump source about 1135 kWh.

**3. Probe** (C:/tmp/eir_wf/sign_claim/probe.py; results in probe/{vs,cs}/probe.csv; analysis in an_probe2.py and an_probe3.py):
- After FirstHVACIteration, node T46 - T45 averages +0.087 K in both runs, in 100% of operating steps, with flow at 100% of design. The node-based 'extraction' at that point is -1247 kWh (VS) and -1248 kWh (constant flow), the mirror image of what is reported.
- In the next iteration and at the end of every timestep, T46 equals member Tout in 100% of steps.
- Example (constant flow, t = 0.5 h): after FirstHVAC, T45 14.448 and T46 14.653. At the end of the step, Tin 14.299 and Tout 14.412; the inlet doPhysics used works out to 14.6165 (Tout + Q/(m cp)), which matches the post-FirstHVAC T13 of 14.6164.

**4. Raising ConvergenceLimits Minimum Plant Iterations to 10** (Max 20; Minimum System Timestep 1, so sub-stepping matches the default):
- VS: node closure 100% (1213 vs 1212 kWh); HX -1107 kWh vs net about 1106 kWh. The loop balance closes.
- Constant flow: closure improves only to 34% (417 vs 1249 kWh); HX -134 kWh.
- January runtime went from 5.4 s to 12.5 s.
- The FirstHVAC wrong-sign transient is still there (100% of steps).

Note: one curl briefly saved v251_eir.cc into the ComStock worktree. I moved it to C:/tmp/eir_wf/sign_claim/ right away; git status shows no change from this task.

## upstream_status
**Fixed upstream; 25.1 and 25.2 still have the bug.** The repo is now NatLabRockies/EnergyPlus (raw.githubusercontent.com/NREL/... redirects).
- Develop PlantLoopHeatPumpEIR.cc L101-117 now passes `sourceQdotArg,` (L113) to UpdateChillerComponentCondenserSide.
- The fix is commit 303ab6af30 'Pass correct load' (Michael J. Witte, 2025-11-18), in PR #11340 'Pass correct load for HeatPump:PlantLoop:EIR:Heating source side update', merged 2025-11-20: https://github.com/NatLabRockies/EnergyPlus/pull/11340
- It fixes issue #11339, 'User file with HeatPump:PlantLoop:EIR:Heating has source outlet temp > inlet at certain times' (filed against 25.2): https://github.com/NatLabRockies/EnergyPlus/issues/11339
- The same PR changed develop PlantUtilities.cc: the zero-flow trigger now uses std::abs(ModelCondenserHeatRate) > 0.0 (L997), and the checks became an if/else chain.
- Release check via the compare API: v25.2.0 is 107 commits behind the merge, and v25.2.0 L112 still passes this->sourceSideHeatTransfer. v26.1.0 and v26.2.0 contain the fix (v26.1.0 L112 passes sourceQdotArg).

**Related open issues:**
- #8147 (2020), 'HeatPump:PlantLoop:EIR:Heating adding heat to source loop instead of removing': https://github.com/NatLabRockies/EnergyPlus/issues/8147
- #10854 (2024), 'WaterSource HeatPump:PlantLoop:EIR:Heating heat imbalance': the reported Q does not match m*cp*dT, the flow used differs from the reported flow, and 25.1 reaches -90 C: https://github.com/NatLabRockies/EnergyPlus/issues/10854
- #8948, autosizing broken.

**The /0.5 source flow registration is unchanged on develop.** It sits at L1600, `PlantUtilities::RegisterPlantCompDesignFlow(state, this->sourceSideNodes.inlet, tmpSourceVolFlow / 0.5);`, under the comment 'only doing half of source because the companion is generally on the same loop'. Dividing by 0.5 actually registers twice the design flow. In 25.1 it is L1369. In the local tree it traces to commit aecd9cf4c5 (Matt Mitchell, 2019-09-04). I found no upstream issue about it.

## workaround_options
1. **ConvergenceLimits with Minimum Plant Iterations = 10 and Maximum Plant Iterations = 20.** Set Minimum System Timestep = 1 explicitly: leaving it blank makes it 0, which means the zone timestep and turns off sub-stepping. In the VS January test this made the condenser-loop energy balance close: heat pump node heat matched reported 100%, and HX transfer matched net heat pump source heat within about 1 kWh. Runtime rose about 2.3x. It does not remove the FirstHVAC wrong-sign transient, and it helps ConstantFlow much less (9% to 34% closure). This is the only input-level fix I verified.
2. **Keep VariableSpeedPumping rather than ConstantFlow.** With ConstantFlow the transient is the same size as the real temperature drop, and the end-of-step balance is badly wrong (9% closure, outlet warmer than inlet in 8% of steps).
3. **There is no input that stops the FirstHVACIteration recompute.** Design source flow is always used on FirstHVAC (L254), so a 30% minimum source flow neither causes nor cures the sign error. It only addresses the trickle-flow clamp, and only when a Pump:VariableSpeed is on the heat pump's own branch (sourceVSBranchPump, L260-262). I found no EMS actuator for plant node temperature (inferred).
4. **Real fix: EnergyPlus 26.1 or later (PR #11340).** It is not available in OpenStudio 3.10.0 / 25.1 or in the installed OS 3.11.0 (E+ 25.2.0). Which OpenStudio release bundles 26.1 is unverified. A counterfactual run on 26.1+ would need a download that I did not make.
5. **Model swap: HeatPump:WaterToWater:EquationFit:Heating** passes -QSource correctly, but it has a different performance model (untested).
6. **Hard-size the condenser loop flow** instead of relying on the 2x autosized registration. The #11339 reporter said this 'fixed' their case. I did not test it, and it does not change the sign bug itself.

====================================================================================================
## code_requirements
VERIFIED TEXT (90.1-2016/2019/2022, section 6.5.4; the wording relevant here is the same in all three editions. 2019 and 2016 are checked against the PNNL/DOE training slides. 2022 is checked against the 2025 NYC Energy Code text on up.codes, which is aligned with 90.1-2022.)

1) 6.5.4.2 Hydronic Variable Flow covers chilled- and hot-water DISTRIBUTION systems with 3 or more modulating/stepping control valves. They must be variable flow and able to reduce pump flow to "no more than the larger of 25% of the design flow rate or the minimum flow required by the heating/cooling equipment manufacturer." Pumps at or above the Table 6.5.4.2 nameplate hp need controls giving no more than 30% of design wattage at 50% flow. The dP setpoint must be no more than 110% of design, with valve-position reset under DDC.
- Exceptions include primary pumps in primary/secondary systems, freeze-protection coil pumps and runaround heat-recovery loops.
- Table 6.5.4.2 (new in 2016) depends on climate zone. Verified rows (NY): CHW 4A ≥5 hp; CHW 5A/6A ≥7.5 hp; HW 5A/6A ≥7.5 hp; HW 4A ≥10 hp.
- openstudio-standards ashrae_90_1_2019.PumpVariableSpeed.rb L25-131 encodes the full table one hp step lower. Its implied code values (inferred) are CHW 2-15 hp and HW 5 hp (CZ7/8) up to about 200 hp (CZ0/1A).
- This section does NOT cover condenser or ground (source) loops. openstudio-standards returns "No pump flow requirement" for loop types other than Heating/Cooling (L130-131).

2) 6.5.4.3.1 Chiller isolation, for plants with more than one chiller: "provisions shall be made so that all fluid flow through the chiller is automatically shut off when the chiller is shut down." Also: "Where constant-speed chilled-water or condenser water pumps are used to serve multiple chillers, the number of pumps shall be no less than the number of chillers and staged on and off with the chillers." (up.codes; PNNL 2019 slide 121: "Number of pumps ≥ number of chillers… Staged on and off".) 6.5.4.3.2 says the same for boilers.
- Heat pumps are NOT named in 2019/2022. ASHRAE Standards Actions (19 Jun 2026) lists first public review of Addendum a to 90.1-2025, which "adds heat recovery chillers and heat pumps to plant equipment isolation requirements". The draft text, seen only in a search snippet, says flow through the evaporator "and chiller condenser if applicable" is shut off.
- Inferred: under 2019/2022 a central water-to-water heat pump plant is code-consistent if each unit's source flow stops when it is off. Constant-speed source pumps would be one per heat pump and staged with them.

3) 6.5.4.5 Hydronic (water-loop) heat pumps and water-cooled unitary ACs. PNNL titles this section "Hydronic (water-loop) Heat Pumps", i.e. distributed water-to-air units.
- 6.5.4.5.1: a two-position valve at each unit, interlocked to shut off water when the compressor is off (exception: fluid economizer).
- 6.5.4.5.2: where total pump system power exceeds 5 hp, controls or VSD giving no more than 30% of design wattage at 50% flow.
- Applying this to the source loop of a central water-to-water plant is ambiguous (inferred). Even so, it only applies above 5 hp.

4) Other items:
- 6.5.4.6 pipe-sizing tables for chilled and condenser water have separate "Other" and "Variable flow/variable speed" columns, so both are permitted.
- 6.5.5.4 tower turndown assumes "multiple- or variable-speed condenser water pumps".
- 90.1-2019 added Table 6.8.1-16 "Heat pump and heat recovery chiller packages" (PNNL 2019 slide 43).
- Appendix G baseline (PNNL-36136, 90.1-2022 PRM reference manual, pdf pp.316, 333, 335, 341): one condenser pump per chiller, "fixed speed and fixed flow", operating when its chiller runs. Primary CHW pumps are constant speed; the secondary loop has a 25% minimum flow.

SUMMARY: For water-loop (water-to-air) heat pumps the code requires a valve per unit and a VSD above 5 hp. For chillers and heat pumps in a central plant, it requires flow shutoff through units that are off and staging of constant-speed pumps, and it says nothing either way about variable condenser/source flow. Variable-flow and VSD rules apply only to the CHW/HW distribution side.

## common_practice
CENTRAL WATER-TO-WATER GSHP PLANTS
- Trane SYS-APM009D-EN "Central Geothermal Systems" (Mar 2026):
  - Refrigerant-changeover plant (pdf p.53): the ground loop pump controls dP at the heat pump. Variable primary flow needs a modulating minimum-flow bypass.
  - Parallel plant for 3 or more heat pumps (pdf p.95, printed p.89): "2-way isolation valves are included for each heat pump, allowing manifolded primary pumps". Ground-loop flow is modulated to an optimal dT, but "limited to maintain minimum flow rate in operating heat pumps". The base design uses decoupled primary-secondary pumping on the load loops.
  - Control table 33 (pdf p.99): the ground pump P-1 "Modulates to maintain optimal ground loop differential temperature, with a minimum flow based on differential pressure at the condensers of operating heat pumps". Isolation valves open when their heat pump is enabled.
  - Dedicated primary pumps are used where packaged and modular heat pumps are mixed (pdf p.107-108).
  - A constant-flow primary loop "may" use a fixed-speed pump (pdf p.81).
  - "The ground loop does not require minimum flow bypass since the bores do not have control valves" (pdf p.109).
  - Ground loop dT of 10-12 F is a starting point. The optimum is about 2.0-2.4 gpm/ton (pdf p.38-39).
  - Head-pressure control for cooling with a cold ground return is done with a ground bypass valve, modulating condenser valves or condenser pump speed (pdf p.81, 97).
- Carrier 61WG/30WG (the units behind the measure's catalog data) are sold with a per-unit evaporator hydronic module (116R/T fixed speed; 116V/W/Y variable speed) and a per-unit condenser module (270R/T fixed; 270V/W/Y variable). The VS module "automatically adjusts the flow to maintain a constant pressure or constant temperature difference" (IOM 020-190, sec. 11.1 p.51, options table). So a dedicated VS pump per unit is a real catalog configuration.
- ClimateMaster TMW Large (360-840) IOM 97B0090N01:
  - Factory motorized valves on load and source sides. The source valve is required on heating-and-cooling units, for head-pressure regulation below 60 F EWT. The load valve "would be required for variable speed pumping" (p.57).
  - Pumps start after the valves prove open (p.36).

DISTRIBUTED GSHP (water-to-air), for context
- ORNL/TM-2017/302 (pp.7, 23): most US commercial GSHP systems are distributed. The "most typical" pumping is a central VFD pump on fixed dP with a two-way valve per heat pump. Field studies found VS pumps rarely slowed down, and pumping was 16-45% of system power.
- Meline & Kavanaugh 2019 (ASHRAE Trans. 125(2), pp.569-571):
  - The best performers include unitary loops with on-off circulators interlocked with compressors, and one-pipe loops.
  - Central loops are "discouraged in large footprint buildings".
  - Pump benchmark: 5 hp/100 tons (10.5 W/kWt) is high performance; 7.5 hp/100 tons (16 W/kWt) is acceptable (citing Kavanaugh & Rafferty 2014).

WHICH DOMINATE (inferred; I found no survey data)
- Multi-unit central plants: headered VS primary/ground pumps with a two-position isolation valve per heat pump (variable primary, or primary-secondary) look most common. The ground pump modulates with a floor set by the minimum flow of the units that are running.
- 1-2 unit plants: a dedicated constant-speed pump interlocked with each unit is common. This matches the Appendix G "one fixed-speed condenser pump per chiller" convention.
- Factory dedicated VS pumps per unit (Carrier 270V) exist but appear less common in US central plants.
- Hydraulically, the headered-plus-valve and dedicated-VS options give the same thing per unit (inferred): flow between a minimum and design while the unit runs, and zero when it is off.

## min_flow_values
CARRIER 61WG/30WG (size 090 = the measure's "90 kW" units)
Sources: IOM 61WG/30WG/30WGA 020-090 pp.25-27, identical values in IOM 020-190 pp.39-40; PSD pp.11, 15.
- Evaporator (61WG and 30WG, size 090):
  - Minimum 1.5 l/s for units without the hydronic module.
  - With the module: 2.0 l/s (low-pressure pump) or 1.6 l/s (high-pressure pump).
  - Maximum 12.5 l/s without the module; 7.8 / 8.7 l/s with it.
- 61WG option 272 (geothermal, glycol evaporator): minimum 2.2 / 2.0 l/s with the module, 1.5 l/s without.
- Condenser (61WG and 30WG, 090): minimum 0.6 l/s (with or without module), "for a water temperature difference of 18 K" (20 K permitted). Maximum 7.2 / 7.9 l/s with module, 9.3 l/s without.
- Operating limits (p.25):
  - Evaporator dT 2.5-7 K (standard); option 272 2.5-5 K; 30WG option 6 2.5-3 K.
  - Condenser dT 2.5-18 K.
  - With condenser EWT below 15 C a three-way (head-pressure) valve is recommended.
- The minimums are "for a maximum permitted temperature difference at the minimum leaving water temperature". Size 090 has 2 stages with a 50% minimum capacity (PSD p.11), so the table minimum effectively applies at the minimum stage.
- Variable flow (sec. 5.9/5.5): allowed if flow stays above the table minimum "and must not vary by more than 10% per minute". Faster changes need 6.5 L/kW of loop water.
- Below 7.5 C EWT at start-up, contact Carrier.

AS A FRACTION OF THE MEASURE'S OWN RATED SOURCE FLOWS (performance_curves.rb L536, L553-561)
- 61WG heating source = evaporator, rated 5.99 l/s per 86.7 kW (30% glycol, 3 K):
  - Table minimum without module: 1.5/5.99 = 25%.
  - With module: 33-37%.
  - The full-load dT limit (3 K design / 5 K max for option 272) means 60% at full capacity and 30% at the 50% stage.
- 30WG cooling source = condenser, rated 4.43 l/s per 94.1 kW:
  - 0.6/4.43 = 14%.
  - The full-load dT limit (5 K / 18 K) means 28%.
  - Side note (verified arithmetic): 4.43 l/s x 4.18 x 5 K = 92.6 kW, which is the evaporator duty. The condenser duty is about 114 kW (EER 4.68, PSD p.15), so the measure's condenser flow is about 19% low and its real dT is about 6.2 K.
- Against Eurovent nominal flows (computed from PSD): evaporator minimum is 20-26% (heating, 10/7 C and 0/-3 C) and 33% (cooling, 12/7 C). Condenser minimum is 11-12%.

OTHER MANUFACTURERS AND GUIDANCE
- ClimateMaster TMW360/600/840 (p.53): minimum source and load flow 45/75/105 gpm, maximum 90/150/210 gpm. The minimum is 50% of maximum, about 50-60% of the recommended 2.5-3 gpm/ton (p.11).
- Trane (Schwedler & Bradley, HPAC Apr 2000, pp.43-44):
  - Cataloged evaporator velocity range is "3 to 11 fps".
  - Flow changes under 10%/min where temperature control is strict; 30%/min is "permissible in most comfort-cooling applications".
  - VPF needs a bypass for minimum chiller flow.
- Trane support: catalog minimums are "for a WATER ONLY application"; with glycol "the minimum flow might be higher". Our loops are 20% PG.
- Trane packaged water-to-air GWSC120E (repo workbook "Trane 10 ton data fill"): catalog water range 19.5-36 gpm against 30 gpm rated, i.e. 65%.

PUMP / VFD SIDE
- Deppmann (N. Hall, 16 Dec 2019): about 20 Hz (33% speed) is the normally recommended VFD minimum. On a closed friction loop that is roughly 33% flow (affinity law, inferred).
- Deppmann (27 Sep 2021): example pump minimum of 230 gpm at full speed on a 1000 gpm design, dropping to about 91 gpm at 700 rpm. The pump itself is not the binding limit; the heat pump heat exchanger is.

REPO DATA
- Carrier_30WG_90kW_clg.csv (load LWT 5-18 C x source EWT 25-50 C) and Carrier_61WG_Glycol_90kW_htg.csv (load LWT 25-65 C x source EWT -5 to 0 C) carry capacity and EIR only.
- "Ground Loop Heat Pump Performance Data.xlsx" Carrier sheets carry capacity, COP and EIR only.
- No minimum-flow data for 30WG/61WG anywhere in resources/measures/upgrade_hvac_hydronic_gshp.

## verdict_30pct
YES. A per-heat-pump source flow that is zero when the unit is off and between 30% and 100% of design when it runs is realistic and consistent with 90.1-2019/2022.

WHY IT IS REALISTIC
- It is a catalog configuration: Carrier 30WG/61WG condenser/evaporator VS hydronic modules (270V/W/Y, 116V/W/Y).
- It is hydraulically the same as the dominant headered VS pump with a two-way isolation valve per unit (Trane SYS-APM009D; ClimateMaster motorized valves) (inferred equivalence).

WHY IT IS CODE-CONSISTENT
- 90.1 requires flow shutoff through units that are off and staging of constant-speed pumps (6.5.4.3.1; Addendum a to 90.1-2025 extends this to heat pumps). It neither requires nor forbids variable source flow.
- The code's own floor for variable-flow hydronic systems is the larger of 25% and the manufacturer minimum (6.5.4.2).
- A constant-speed pump per heat pump, staged with it, would be equally code-compliant at these pump sizes. The VS choice is about practice and modeling, not code.
- If the pump is VS, give it a VFD power curve, not the measure's linear 0/1/0/0 curve (after_measure.idf L12604-12607 gives 50% power at 50% flow). Either curve from openstudio-standards hvac/components/pump.rb L153-162 works: 'VSD No Reset' (0, 0.5726, -0.301, 0.7347) gives 30.3% power at 50% flow, which just meets 90.1's 30%/50%; 'VSD DP Reset' gives 18.5%.

WHY 30%
- 30% sits within the manufacturer data:
  - Carrier 090 heating source (glycol evaporator): 25% of the measure's rated flow without module, 33-37% with module, and 30% from the dT limit at the minimum stage.
  - Carrier 090 cooling source (condenser): 14% table minimum, 28% from the full-load dT limit.
  - ClimateMaster modular: 50%.
  - The VFD 20 Hz minimum is about 33%.
- 30% (about 1/3) is a defensible single value: at least the 90.1 25% floor and above every Carrier table minimum.
- A per-type split is possible: about 33-35% for the heating (evaporator, glycol) source and 25% for the cooling (condenser) source. Use 50% to mimic US modular water-to-water units.
- The floor also bounds the lag spike (inferred). Next-step dT can reach at most about 3.3x design: about 9-10 K heating and about 20 K cooling, far below the +-100 K clamp. A full 30-100% swing at 10-30%/min takes 2-7 minutes, within a 15-minute timestep.

ENERGYPLUS CAVEATS (verified code/docs; conclusions inferred)
1. In VariableSpeedPumping the EIR heat pump floors source flow at a pump minimum only when a Pump:VariableSpeed is on its own branch (PlantLoopHeatPumpEIR.cc L254-264; PlantUtilities.cc L1988-2040). The source side sits on the condenser loop's demand side, and that loop already has a supply-side pump. EnergyPlus forbids loop pumps and branch pumps together, and pumps on both sides without a common pipe (PlantManager.cc L1404-1408, L1610-1621). The I/O Reference says common pipe is "limited to simulating loop pumps". So a literal per-heat-pump branch pump probably cannot be built in this topology; the E+ thread should confirm.
2. The supply-side VS pump's minimum is not applied to the heat pump. Any loop-minimum flow would go down 'Condenser Loop Demand Bypass Branch' (after_measure.idf L12675).
3. Flow = design x max(PLR, MinPLR) for loop pumps too. MinPLR = 0.3 would therefore floor the flow, but it also triggers the cycling path that gave COP 14 at 0.2.
4. In the January run (run_ga_cs_jan_ts), the heating heat pump's PLR when on had median 0.024, 90th percentile 0.075 and maximum 0.123. A 30% floor would bind on essentially every operating timestep, so source flow would sit at a constant 30%. This reflects the 70 kW unit being far larger than its load. A real 2-stage 61WG-090 (50% minimum capacity) would cycle instead.

## ground_loop_pump
HOW THE MODEL'S GROUND PUMP ACTUALLY BEHAVES (verified)
- Setup: Pump:ConstantSpeed 'Intermittent' (measure.rb L511-517; Ground loop circulation pump in after_measure.idf L13419-13428). Design 0.005222 m3/s, 66,955 Pa, 498 W. The Heat pump circulation Pump (VS) is 334 W (EquipmentSummary).
- The I/O Reference says an intermittent constant-speed pump "will run at its capacity if a load is sensed".
- The HX controls the ground-side demand. With UncontrolledOn the HX requests the full ground-side design flow whenever the condenser loop has any flow (PlantHeatExchangerFluidToFluid.cc L947-962).
- Result in the January run: ground pump on in 99.5% of timesteps, because the heating heat pump runs nearly all the time at tiny PLR. In effect it is a constant-flow loop.
- Switching this pump to variable speed alone would change nothing while the HX stays UncontrolledOn.

CODE (90.1-2019/2022)
- No section requires VS on a closed ground loop of a central water-to-water plant. 6.5.4.2 covers CHW/HW distribution only.
- 6.5.4.5.2 (VSD or equivalent above 5 hp total pump power) is written for water-loop heat pump systems. Applying it here is ambiguous (inferred), and it only applies above 5 hp.
- The hotel's two source pumps total 0.83 kW (1.1 hp), well under 5 hp. That is about 11-12 W per kW of heating capacity, near Kavanaugh's high-performance benchmark of 10.5 W/kWt.
- Scaling (inferred): 5 hp is reached at roughly 300-350 kW (about 90-100 tons) of plant capacity.
- With several heat pumps, 6.5.4.3.1's logic (number of constant-speed pumps at least the number of chillers, staged with them) argues against one constant-speed ground pump at full flow regardless of how many units run. Addendum a to 90.1-2025 would make this explicit for heat pumps.

PRACTICE
- Small plants (one heating and one cooling heat pump, like the hotel): a constant-speed pump interlocked with the heat pump(s) is normal and realistic. Kavanaugh's on-off circulators work this way, and so does the Appendix G one-fixed-speed-condenser-pump-per-chiller convention.
- Multi-unit central plants: a VFD ground pump is standard. It modulates to a ground-loop dT of about 10-12 F, with a floor at the minimum flow of the running heat pumps and an EFT override (Trane SYS-APM009D pdf p.38-39, 95, 99). No bypass is needed on the ground side (pdf p.109).
- Minimum turbulence: IGSHPA practice is Re ≥ 2500 at design. Siegenthaler (PM Engineer, 2 Nov 2023) gives about 5 gpm per 1.25-in DR-11 circuit for 20% PG at 30 F. Lower flow is acceptable when the fluid is warmer.

RECOMMENDATION (inferred)
- Keep the constant-speed Intermittent pump when there is one heat pump per mode.
- Where no_hps > 1, or the plant is above about 5 hp, use a VS ground pump with a VSD curve and minimum of about 30%. Give the HX a modulating or tracking control so ground flow follows condenser flow. Alternatively drop the isolation HX: both loops now use the same 20% PG, and Trane treats the isolation HX as optional.

SIDE ISSUE FOUND (verified)
- GroundHeatExchanger:System design flow is 0.0002 m3/s: one 100 m borehole (ResponseFactors "Number of Boreholes" 1) at 0.2 l/s per borehole from borefield_defaults.json (after_measure.idf L13461, L13484). The HX and ground pump are sized at 5.22 l/s.
- In the January run the ground pump flow was only 0.102-0.204 kg/s, about 4% of the condenser side. This is consistent with the GHE design flow capping the loop (mechanism inferred).
- 0.2 l/s (3.2 gpm) per borehole is also below Siegenthaler's about 5 gpm turbulence flow (inferred comparison). Worth a separate look.

## sources
  - ASHRAE 90.1-2022-based text: NYC Energy Conservation Code 2025 sec. 6.5.4 (6.5.4.1-6.5.4.8), https://up.codes/s/hydronic-system-design-and-control
  - NYC ECC 2025 sec. 6.5.4.2 and Table 6.5.4.2 (NY climate zone rows), https://up.codes/s/hydronic-variable-flow-systems
  - Urban Green Council, Highlights of the 2025 NYC Energy Code (aligned with ASHRAE 90.1-2022), https://www.urbangreencouncil.org/highlights-of-the-2025-new-york-city-energy-code/
  - PNNL-SA-153210 (May 2020), ANSI/ASHRAE/IES Standard 90.1-2019: HVAC training, slides 43, 119-123, 131, https://www.oregon.gov/bcd/codes-stand/Documents/90.1-2019-HVAC-training.pdf
  - PNNL-SA-124554 (Mar 2017), ANSI/ASHRAE/IES Standard 90.1-2016: HVAC training, slides 108-113 (Table 6.5.4.2 new in 2016), https://www.oregon.gov/bcd/codes-stand/Documents/ashrae90.1-2016-hvac-final.pdf
  - ASHRAE Standards Actions Vol. XVI Issue 24, 19 Jun 2026, first public review of Addendum a to 90.1-2025 (adds heat recovery chillers and heat pumps to isolation requirements), https://www.ashrae.org/file%20library/technical%20resources/standards%20and%20guidelines/standards%20actions/sa-jun_19_2026.pdf
  - PNNL-36136 (Dec 2024), ANSI/ASHRAE/IES Standard 90.1-2022 Performance Rating Method Reference Manual, pdf pp. 316, 333 (printed 317), 335, 341 (baseline condenser pumps fixed speed, one per chiller), https://www.energycodes.gov/sites/default/files/2025-01/PerfRatingMethodRefMan9012022.pdf
  - Carrier IOM 61WG/30WG/30WGA 020-090, pp. 25 (operating limits), 26-27 (sec. 5.9 variable flow, 5.10 water flow rate tables), https://ahi-carrier.gr/wp-content/uploads/2025/12/Installation-Operation-Manual-61WG_30WG_30WGA_020_090.pdf
  - Carrier IOM 10226 (11-2020) 30WG/30WGA/61WG 020-190, pp. 39-40 (flow tables, 5.5 variable flow), 51 (sec. 11.1 VS pump control), 55, 60, options table (116R/T/V/W/Y, 270R/T/V/W/Y), https://brandportal.carrier.com/m/6bb589913de3dc44/original/10226_IOM_11_2020_30WG_30WGA_61WG_020_190_A.pdf
  - Carrier PSD 16121 (11-2020) 61WG/30WG/30WGA 020-190, pdf p.11 (61WG-090 117/109/103/97/87 kW, COP, 2 stages, 50% minimum capacity), p.15 (30WG-090 95 kW, EER 4.68), https://carrier.com/commercial/en/hk/media/16121_PSD_11_2020_61WG_30WG_30-WGA_020_190_tcm173-150069.pdf
  - Trane SYS-APM009D-EN, Central Geothermal Systems (B. Sykora, Mar 2026), pdf pp. 12, 14, 26, 31, 37-39, 53-54, 69, 81, 95, 97, 99, 107-109, https://www.trane.com/content/dam/trane-commercial/north-america/en/document/application-guides/sys-apm009-en.pdf
  - Schwedler M., Bradley B. (Trane), Variable-Primary-Flow Systems, HPAC Engineering, Apr 2000, pp. 41-44, https://Www.Trane.com/content/dam/Trane/Commercial/global/learning-center/ashrae-articles/Variable-Primary-Flow%20Systems.pdf
  - Trane Support, Minimum Evaporator Flow Rate (glycol raises minimum), https://support.trane.com/hc/en-us/articles/34551822539277-Minimum-Evaporator-Flow-Rate
  - ClimateMaster Tranquility Large Water-to-Water (TMW) IOM 97B0090N01 (rev. 29 Nov 2021), pp. 11, 12-13, 36, 53, 57, https://files.climatemaster.com/Commercial/Resources/IOMs/97B0090N01-TMW-Large-IOM.pdf
  - Liu X. et al., ORNL/TM-2017/302 Advanced Controls for Ground-Source Heat Pump Systems (Jun 2017), pp. 6-7, 23, https://info.ornl.gov/sites/publications/Files/Pub75387.pdf
  - Meline L., Kavanaugh S., Geothermal Heat Pumps - Simply Efficient, ASHRAE Transactions 125(2), KC-19-010 (2019), pp. 569-571, https://www.meline.com/pdfs/ASHRAE-D-KC-19-010.pdf
  - Siegenthaler J., Concepts for varying flow rate in geothermal earth loops, PM Engineer, 2 Nov 2023 (IGSHPA Re >= 2500), https://www.pmmag.com/articles/106081-concepts-for-varying-flow-rate-in-geothermal-earth-loops
  - Hall N. (R.L. Deppmann), HVAC Hydronic System Variable Speed Pump Operation, 16 Dec 2019 (20 Hz minimum), https://www.deppmann.com/blog/monday-morning-minutes/hvac-hydronic-system-variable-speed-pump-operation/
  - Hall N. (R.L. Deppmann), Minimum Flow in Variable Speed Pumps for Building Hydronic HVAC Systems Part 1 (27 Sep 2021), https://www.deppmann.com/wp-content/uploads/2021/09/Minimum-Flow-in-Variable-Speed-Pumps-for-Building-Hydronic-HVAC-Systems-Part-1.pdf and Part 2 (4 Oct 2021), https://www.deppmann.com/wp-content/uploads/2021/10/Minimum-Flow-in-Variable-Speed-Pumps-for-Building-Hydronic-HVAC-Systems-Part-2.pdf
  - EnergyPlus 24.2 I/O Reference, PlantLoop Common Pipe Simulation (common pipe limited to loop pumps), https://bigladdersoftware.com/epx/docs/24-2/input-output-reference/group-plant-condenser-loops.html
  - EnergyPlus 24.2 I/O Reference, Pumps (Continuous/Intermittent, Design Minimum Flow Rate), https://bigladdersoftware.com/epx/docs/24-2/input-output-reference/group-pumps.html
  - EnergyPlus 25.1 source copies: C:/tmp/eplus_src/PlantLoopHeatPumpEIR.cc L254-264; C:/tmp/eplus_src/PlantUtilities.cc L1988-2040 (MinFlowIfBranchHasVSPump); C:/tmp/eplus_src/PlantHeatExchangerFluidToFluid.cc L947-962 (UncontrolledOn)
  - EnergyPlus ~24.2 tree: C:/Users/ccaradon/Documents/GitHub/EnergyPlus/src/EnergyPlus/Plant/PlantManager.cc L1404-1408, L1610-1621 (pump placement checks)
  - Repo (read only): resources/measures/upgrade_hvac_hydronic_gshp/measure.rb L511-517, L654-678, L1311-1322; resources/performance_curves.rb L525-561, L622-651; resources/Carrier_30WG_90kW_clg.csv, Carrier_61WG_Glycol_90kW_htg.csv, Ground Loop Heat Pump Performance Data.xlsx, borefield_defaults.json (worktree on ccaradon/spacetype_refactor_measure_failures)
  - openstudio-standards (ComStock-Typical fork in C:/tmp/csgems): lib/openstudio-standards/hvac/components/pump.rb L142-162 (pump curves); standards/ashrae_90_1/ashrae_90_1_2019/ashrae_90_1_2019.PumpVariableSpeed.rb L4-5, L25-131
  - Model runs: C:/tmp/gshp_e2e/final_up08_bldg0000044/after_measure.idf L12595-12628, L12675, L12968-12991, L13419-13428, L13461, L13484 and eplus/eplusout.sql EquipmentSummary; C:/tmp/run3_pump/run_ga_cs_jan_ts/eplusout.sql (Jan timestep PLR and pump flows)

