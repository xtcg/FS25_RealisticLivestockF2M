"""Offline candidate sweep (Codex, 2026-10-11). Does not mutate shipped mod parameters.

Historical: it tunes intake.calfPerKgMetabolic, the calf appetite FEED-11 replaced (the calf's milk
allowance and solid capacity are separate since); its calf sections reproduce only on commit
5ff7f71 or earlier. The FEED-11 calibration is tests/feedbalance/calf.py.
Run: python3 tests/feedbalance/calibrate.py [output_directory]
Uses the same pack and Lua54 harness bootstrap as run.py.
"""
import csv
import json
import sys
from pathlib import Path

HARNESS = Path(__file__).resolve().parent
# Execute bootstrap only; never execute the full report or overwrite its outputs.
source = (HARNESS / "run.py").read_text()
exec(compile(source.split("# Hof Bergmann 1.5 prices")[0], str(HARNESS / "run.py"), "exec"))

rows = []
for appetite in [0.060, 0.075, 0.090, 0.105, 0.120, 0.140]:
    lua.globals().CANDIDATE_APPETITE = appetite
    lua.execute("RLFeed.getConfig().intake.calfPerKgMetabolic = CANDIDATE_APPETITE")
    for name in ["BULL_HOLSTEIN", "COW_HOLSTEIN", "BULL_ANGUS", "BULL_JERSEY_PACK"]:
        calf = plain(R.calf(name))
        for m in calf["months"]:
            rows.append(dict(appetite=appetite, subType=name, **m))
    print("candidate", appetite, flush=True)
lua.execute("RLFeed.getConfig().intake.calfPerKgMetabolic = 0.060")
with (OUT / "calf_appetite_sweep.csv").open("w", newline="") as f:
    w=csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
(OUT / "calf_appetite_sweep.json").write_text(json.dumps({"head":head, "dirty":bool(dirty), "resourceScale":lua.eval("RLFeed.getConfig().resourceScale"), "rows":rows}, indent=2))

# Two-factor diagnosis: apply a growth-cost multiplier only within isolated calf runs.
# This is NOT a proposed adult parameter change or a shipped patch.
lua.execute("BASE_CALF_COST = RLFeedMath.getGrowthCost")
combined=[]
for appetite in [0.075, 0.090, 0.105]:
    for cost in [0.85, 0.70, 0.55]:
        lua.globals().CANDIDATE_APPETITE=appetite
        lua.globals().CANDIDATE_COST=cost
        lua.execute("RLFeed.getConfig().intake.calfPerKgMetabolic=CANDIDATE_APPETITE; RLFeedMath.getGrowthCost=function(w,r) return BASE_CALF_COST(w,r)*CANDIDATE_COST end")
        for name in ["BULL_HOLSTEIN", "COW_HOLSTEIN", "BULL_ANGUS", "BULL_JERSEY_PACK"]:
            calf=plain(R.calf(name))
            for m in calf["months"]: combined.append(dict(appetite=appetite,costFactor=cost,subType=name,**m))
        print("two-factor",appetite,cost,flush=True)
lua.execute("RLFeedMath.getGrowthCost=BASE_CALF_COST; RLFeed.getConfig().intake.calfPerKgMetabolic=0.060")
with (OUT / "calf_two_factor_sweep.csv").open("w",newline="") as f:
    w=csv.DictWriter(f,fieldnames=list(combined[0]));w.writeheader();w.writerows(combined)

# Isolated implementation of an age-limited candidate, never write shipped Lua/XML.
feed_source=(REPO / 'scripts/feed/RLFeed.lua').read_text()
old='RLFeedMath.getGrowthCost(animal.weight or 0, config.requirements)'
assert feed_source.count(old)==2
lua.execute('''function CALIBRATION_COST(animal,config)
    local age=RLGrowth.getContinuousAge(animal)
    local factor=CALIBRATION_FACTOR + (1-CALIBRATION_FACTOR)*math.clamp((age-6)/2,0,1)
    return RLFeedMath.getGrowthCost(animal.weight or 0,config.requirements)*factor
end''')
names=plain(R.subTypes('male'))+plain(R.subTypes('female'))
matrix=[]
for candidate in [1.0,0.55,0.525,0.50,0.475,0.45,0.425]:
    lua.globals().CALIBRATION_FACTOR=candidate
    lua.execute(feed_source.replace(old,'CALIBRATION_COST(animal, config)') if candidate<1 else feed_source)
    lua.execute('RLFeed.getConfig().intake.calfPerKgMetabolic='+('0.105' if candidate<1 else '0.060'))
    for name in names:
        c=plain(R.calf(name))
        lua.globals().CALIBRATION_SUBTYPE=name
        goal6=lua.eval('(function() local a=GrowthSim.newborn(CALIBRATION_SUBTYPE); return RLGrowth.getCurve(a):value(6) end)()')
        birth=lua.eval('GrowthSim.newborn(CALIBRATION_SUBTYPE).weight')
        for m in c['months']:matrix.append(dict(candidate=candidate,subType=name,target6Kg=goal6,birthKg=birth,**m))
    print('full calf matrix',candidate,len(names),flush=True)
with (OUT/'calf_age_limited_matrix.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(matrix[0]));w.writeheader();w.writerows(matrix)
# Restore real implementation for month experiments.
lua.execute(feed_source)
lua.execute('RLFeed.getConfig().intake.calfPerKgMetabolic=0.060')
planner_source=(REPO/'scripts/feed/RLFeedRationPlanner.lua').read_text()
needle='''            a.adapted = adapted
            if best ~= nil and best.c'''
assert planner_source.count(needle)==1
replacement='''            local previous = a.animal and a.animal.calibrationPreviousShare
            if previous ~= nil and previous <= cLimit and best ~= nil then
                local option = evaluate(a, previous, forageMix, concMix, request)
                if option ~= nil and option.score >= best.score * (1 - CALIBRATION_HYSTERESIS) then best = option end
            end
            if a.animal ~= nil and best ~= nil then a.animal.calibrationPreviousShare = best.c end
            a.adapted = adapted
            if best ~= nil and best.c'''
month_results=[]
for threshold in [0,0.001,0.0025,0.005,0.01]:
    lua.globals().CALIBRATION_HYSTERESIS=threshold
    lua.execute(planner_source if threshold==0 else planner_source.replace(needle,replacement))
    results=plain(R.invariance())
    for row in results:month_results.append(dict(threshold=threshold,**row))
    print('month threshold',threshold,flush=True)
with (OUT/'auto_hysteresis_sweep.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(month_results[0]));w.writeheader();w.writerows(month_results)
lua.execute(planner_source)
