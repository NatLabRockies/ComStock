# Research: minimum source flow topology for EIR heat pumps in EnergyPlus 25.1 (2026-10-06)

Topology agent results: branch pumps, common pipe, OpenStudio support, balance and caveats. Test files were under C:/tmp/eir_wf/vs_branch_pump/.

## pump_min_field
Design Minimum Flow Rate (field N10, m3/s) is what sets the pump's MassFlowRateMin.

- **Code (Pumps.cc v25.1.0):**
  - L347: MinVolFlowRate = rNumericArgs(10).
  - L1512, at BeginEnvrn: MassFlowRateMin = MinVolFlowRate × density at InitConvTemp.
  - Design Minimum Flow Rate Fraction (N15, read at L505) is only used when N10 = Autosize. L349 sets minVolFlowRateWasAutosized, then SizePump L2146-2147 sets MinVolFlowRate = NomVolFlowRate × MinVolFlowRateFrac. If N10 is a number, it wins and the fraction is ignored.
- **Tested both ways:**
  - Variant b: N10 = 0.3 × V as a number, N15 = 0.
  - Variant b_frac: N10 = Autosize, N15 = 0.3. The eio reports "Design Minimum Flow Rate [m3/s], 1.44949E-003" for the heating pump and 1.17199E-004 for the cooling pump.
  - Both give the same floors and energies.
- **How the heat pump reads that minimum:**
  - It uses PlantUtilities::MinFlowIfBranchHasVSPump (PlantUtilities.cc L1988-2038; the copy in C:/tmp/eplus_src is identical to v25.1.0).
  - That function first looks for a VS pump on the heat pump's own branch (L1992-2001). If there is none, it looks on supply Branch(1), but only when the supply side has more than one branch (L2003-2019).
  - It is called in onInitLoopEquip at BeginEnvrn with setFlowStatus = false for the source side (PlantLoopHeatPumpEIR.cc L975-981).
  - The floor is applied in setOperatingFlowRatesWSHP L260-264, and only when the pump is on the heat pump's own branch (sourceVSBranchPump).

## openstudio_support
Yes, OpenStudio 3.10.0 (E+ 25.1.0) can put a PumpVariableSpeed on a heat pump's demand branch.

**Test script:** C:/tmp/eir_wf/vs_branch_pump/os/build_branch_pump.rb
- Builds a PlantLoop, adds a HeatPumpPlantLoopEIRHeating with addDemandBranchForComponent, then `pump.addToNode(hp.sourceSideWaterInletNode.get)`, which returns true. sourceSideWaterInletNode is the same node as demandInletModelObject.
- demandComponents(splitter, mixer) lists: Splitter -> Node 12 -> Pump -> Node 18 -> HP -> Node 17 -> Mixer.
- Forward-translated Branch 'Source Loop Demand Branch 1':
  - Component 1: Pump:VariableSpeed 'HP Htg Source Pump', Node 12 -> Node 18.
  - Component 2: HeatPump:PlantLoop:EIR:Heating 'HP Htg', Node 18 -> Node 17.
  - The heat pump's Source Side Inlet Node is Node 18.
  - No translation errors or warnings.

**Setting the minimum:**
- Both setters exist and work: setMinimumFlowRate(x) writes 'Design Minimum Flow Rate' (the translation wrote 0.0014494871832202), and setDesignMinimumFlowRateFraction(0.3) writes 'Design Minimum Flow Rate Fraction'.
- In the OpenStudio IDD, 'Minimum Flow Rate' is not autosizable (default 0.0). Translation always writes a number to N10, so the fraction does nothing in E+.
- You therefore need setMinimumFlowRate(0.3 × V) with a hard-sized heat pump source flow (hp.sourceSideReferenceFlowRate returns an OptionalDouble).

**Other findings:**
- OpenStudio does not stop you from keeping a supply pump plus a branch pump with Common Pipe None. Translation is clean, but E+ then fails (os/run_supply_pump).
- `setCommonPipeSimulation('CommonPipe')` works. os/run_common_pipe completes, with the constant-primary-flow warning.
- Removing the supply pump with pump.remove is fine: translation writes a Pipe:Adiabatic 'Source Loop Supply Inlet Pipe' on the supply inlet branch.

**Applied to the measure's model:**
- os/apply_to_hotel.rb applies this to C:/tmp/gshp_e2e/final_up08_bldg0000044/after_measure.osm and writes os/hotel_os_bp.idf.
- Its January run (runs/os_bp) matches the hand-edited variant b to 0.1 kWh: heating source 1,258.0, cooling source 98.8, HX -95.4, source pump electricity 74.7 kWh, floor 1.4847 kg/s.

## recommended_topology
**Recommended: variant b.**
- One Pump:VariableSpeed per EIR heat pump, just upstream of it on its own source branch on the Condenser Loop demand side.
- Remove the supply-side loop pump; the supply side is just the HX. Common Pipe stays None.
- Pump control Intermittent. Design Maximum Flow Rate = the heat pump's Source Side Reference Flow Rate; Design Minimum Flow Rate = 0.3 × that.
- Heat pump Flow Mode stays VariableSpeedPumping with Minimum PLR 0.
- Each branch pump carries the full loop head (44,834.7 Pa), because there is no supply pump any more.

**Rejected alternatives:**
- **Keeping the supply pump:** needs a common pipe, which holds the primary pump at full flow; pump energy is about 2× variant b.
- **A 30% minimum on the supply loop pump:** does not floor the heat pumps; the extra flow goes through the bypass.
- **Heat pump Minimum PLR = 0.3:** does give a 0.300 floor with no new pumps. In 25.1, though, L599-600 multiplies power by cyclingRatio although loadSideHeatTransfer already includes it (L562). January COP came out at 14.5 heating and 50.5 cooling (runs/minplr). v25.2.0 removed that extra factor.

**OpenStudio Ruby (tested as os/apply_to_hotel.rb):**
```ruby
loop = model.getPlantLoopByName('Condenser Loop').get
loop.supplyComponents.each do |c|
  p = c.to_PumpVariableSpeed
  p = c.to_PumpConstantSpeed unless p.is_initialized
  p.get.remove if p.is_initialized   # forward translation puts a Pipe:Adiabatic on the supply inlet branch
end
loop.demandComponents.each do |c|
  hp = c.to_HeatPumpPlantLoopEIRHeating
  hp = c.to_HeatPumpPlantLoopEIRCooling unless hp.is_initialized
  next unless hp.is_initialized
  hp = hp.get
  v = hp.sourceSideReferenceFlowRate.get   # must be hard-sized
  pump = OpenStudio::Model::PumpVariableSpeed.new(model)
  pump.setName("#{hp.nameString} Source Pump")
  pump.addToNode(hp.sourceSideWaterInletNode.get)
  pump.setRatedFlowRate(v)
  pump.setMinimumFlowRate(0.3 * v)   # not setDesignMinimumFlowRateFraction (inert from OpenStudio)
  pump.setRatedPumpHead(44834.7)
  pump.setPumpControlType('Intermittent')
  # optionally copy motor efficiency and part-load coefficients from the removed pump
end
```

**What it is good for:** it stops the trickle-flow runaway, so 0000112 and 0000286 now finish the year. It is not an energy-balance fix in E+ 25.1 (see balance_and_stability and caveats). Base the 30% on a right-sized source flow.

## balance_and_stability
**How the balance is measured.** "Phantom" = reported heating source heat − reported cooling source heat − HX heat into the Condenser Loop − pump heat to fluid. Positive means heat appeared in the loop from nowhere.
- Loop storage is negligible: the loop volume is 0.627 m3, about 0.7 kWh per K.
- The reported HX transfer matches the node-based m12·cp·(T16−T12) to within 0.1% in every run. cp comes from the E+ 20% propylene glycol table (3,929-3,973 J/kg-K at 0-20 C); design density is 1,024.3 kg/m3 at 5.05 C.

**Hotel bldg0000044, G1300850 weather, annual kWh:**

| Variant | Heating src (reported) | Cooling src (reported) | HX to ground | Phantom net / gross | Pump elec | Loop temp range |
|---|---|---|---|---|---|---|
| base (VS loop pump, no floor) | 4,238 | 7,264 | 11,696 | +8,632 | 46 | 9.6-33.4 C |
| b (recommended) | 4,220 | 7,178 | 2,462 | −1,287 / 6,817 | 880 (19×) | 12.7-19.1 C |
| a_cp (common pipe) | 4,191 | 7,190 | 3,467 | −1,097 / 5,033 | 1,740 | 11.5-20.0 C |
| b, source flows at E+ design sizes | 4,189 | 7,208 | 6,692 | +3,460 | 234 | not checked |

- Gross phantom is the sum of |monthly| values.
- **base:** node-based heat at the heat pump nodes was 4,083 for heating and 15,650 for cooling (2.15× the reported 7,264). The cooling source ΔT reached 35.8 K.
- **b:** the phantom is +998 in January (79% of January heating source heat) and about −750 to −800 per month in July-September.
  - At the heat pump nodes, the heating heat pump removed 827 while on and 2,923 while off with forced flow. The off-time heat is from stale outlet temperatures (inferred). Cooling: 7,205 node-based vs 7,178 reported.
  - Maximum source ΔT was 6.1 K.
- **E+ design sizes** are 1.18e-3 m3/s heating and 2.18e-4 m3/s cooling. The measure uses 4.83e-3 and 3.91e-4.
- Heat pump electricity and load-side heat are essentially unchanged across variants.
- For comparison, your earlier ConstantFlow result on this hotel was 85 MWh/yr of phantom heat. I did not rerun it.

**run_3 failing buildings, G1300850 weather.** The committed VariableSpeedPumping models of 0000112 and 0000286 fail in January with "Plant temperatures are getting far too cold" on CONDENSER LOOP. With the branch-pump transform both finish the year with 0 severe errors.

| Building | Variant | Heating src | Cooling src | HX to ground | Phantom (gross) | Pump elec |
|---|---|---|---|---|---|---|
| 0000286 | branch pumps | 46.8 MWh | 679.0 MWh | 633.2 MWh | −7.4 MWh (7.8, about 1%) | 9.4 MWh |
| 0000286 | ConstantFlow | | | 2,330 MWh | +1,671 MWh | 30.4 MWh |
| 0000112 (81 heat pumps) | branch pumps | 1,048 MWh | 13,317 MWh | 12,077 MWh | −333 MWh (359) | 158 MWh |
| 0000112 | ConstantFlow | | | 69,157 MWh | +56,536 MWh | 372 MWh |

- 0000112 with branch pumps: January's phantom is −112 MWh, 29% of January heating source heat.
- **0000368 and 0000383:** both finish with or without the branch pumps on this weather file, so their run_3 failure (during warmup, on the Augusta weather) was not reproduced.
  - 0000368: phantom +1.9 / −3.3 MWh (gross 28.6 / 28.5 MWh) out of about 3.35 GWh of source heat; pump electricity 9.1 → 56.5 MWh.
  - 0000383: phantom −76.2 / −53.7 MWh out of about 878 MWh; pump electricity 2.4 → 11.9 MWh.

**Why the balance stays off in 25.1:**
- **The bug (verified in the code):**
  - PlantLoopHeatPumpEIR.cc L102-106 computes sourceQdotArg, which is negative for a heating heat pump. L114 then passes this->sourceSideHeatTransfer (positive) to UpdateChillerComponentCondenserSide instead.
  - That routine sets the source outlet temperature to inlet + Q/(m·cp) with no clamp (PlantUtilities.cc L996-997). It does this whenever anything changed, and on the first HVAC iteration.
  - So in those iterations the heating heat pump adds its source heat to the loop instead of removing it.
- **Upstream status:** this is NREL/EnergyPlus issue #11339, fixed by PR #11340 (commit 303ab6af30, merged 2025-11-20). From the release source: the bug is present in v25.1.0 and v25.2.0 and fixed in v26.1.0 and v26.2.0.
- **Evidence it is happening here (inferred link):** hotel b, January, TimeIndex 501.
  - The heating heat pump reported Q = 5,298 W at 1.4847 kg/s with a source outlet of 13.825 C, which implies its calculation saw a 14.727 C inlet.
  - Every converged loop node was 13.82-13.98 C. The exception was the idle cooling heat pump's stale outlet, Node 44, at 14.726 C.
  - So the calculation ran on a loop about 0.8 K warmer than the converged state, which fits one of those wrong-sign writes.

## caveats
1. The E+ 25.1 heating-EIR source-side sign bug (#11339, fixed in v26.1.0) affects every variant, so no plant layout can make the energy balance right in 25.1. There is no E+ 26.x on this machine and I did not download one. The obvious next step is to rerun variant b on E+ 26.1 or later.
2. The branch pumps never stop. They run at 30% for all 8,760 hours, so pump electricity goes up 19× on the hotel and about 5-6× on 0000383 and 0000368. Idle heat pumps with forced flow also become a stale-temperature heat path. Both EMS ways of turning them off failed: one was fatal, the other had no effect.
3. The measure hard-sizes heat pump source flows well above E+'s own sizing: hotel heating 4.83e-3 vs 1.18e-3 m3/s (4.1×), cooling 1.8×. 30% of 4.83e-3 is 123% of the E+-sized flow, and the hotel heating heat pump's PLR never exceeded 0.125, so it always ran at the floor. Basing the 30% on right-sized flows cut hotel pump electricity from 880 to 234 kWh and gross phantom from 6.8 to 3.5 MWh, but did not remove the phantom.
4. In OpenStudio the minimum flow is not autosizable. The measure needs hard-sized heat pump source flows and setMinimumFlowRate; setDesignMinimumFlowRateFraction does nothing.
5. Minimum PLR 0.3 is an alternative way to get the floor, but it is unusable in 25.1 (the cycling-ratio power double count, fixed in 25.2) and it changes the model to on/off cycling.
6. The run_3 buildings were run on G1300850 (Lee Gilmer Mem GA), because the Augusta Bush Field EPW used for /c/tmp/run3_hyd was not found. The 0000368 and 0000383 failures did not reproduce on this file.
7. Node-based per-heat-pump balances use zone-timestep averages of flow and temperature taken separately, and reported values are last-iteration snapshots. Treat those numbers as approximate; the HX-based loop balances are solid.
8. The first-HVAC-iteration behaviour comes from reading the code only.
9. The common pipe variants hold the primary flow constant.
10. Nothing in the ComStock repo was changed.

Files are under C:/tmp/eir_wf/vs_branch_pump/:
- **Variant builders:** make_variants.py (hotel variants), branch_pump_transform.py (generic transform).
- **Analysis scripts:** analyze.py, monthly.py, balance.py, implied.py, bldg_annual.py, bldg_monthly.py.
- **Runs:** runs/{base,a_none,a_cp,a_tw,b,b_nomin,b_frac,minplr,loopmin,b_ems,b_ems2,os_bp} and runs/{base,b,a_cp,b_rs}_year; building runs are in bldg/.
- **OpenStudio:** os/build_branch_pump.rb, os/apply_to_hotel.rb, os/ft_*.idf, os/hotel_os_bp.idf.
- **E+ source copies:** src25/ (v25.1.0 Pumps.cc, PlantManager.cc, LoopSide.cc, PlantUtilities.cc, and PlantLoopHeatPumpEIR.cc for v25.1/v25.2/v26.1/v26.2/develop).

