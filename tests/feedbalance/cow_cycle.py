"""Calving-lactation-dry cycle of a dairy or suckler cow, on the real feeding path, both nutrition modes.

python3 tests/feedbalance/cow_cycle.py [output_dir] [subtype] [lactating_ration] [dry_ration] [lag_strength]

Three calvings 13 months apart (lactating 10 months, dry 3, pregnant from month 3). The report is the
third cycle: per month the live weight, the gravid mass (calf, membranes and fluids), the tissue weight
(live weight without it), the BCS and the milk paid; and the calving hour's weight before and after.
The first three months are sampled every quarter month. lag_strength overrides the early-lactation
intake lag (weightProfiles lactationIntakeStrength, 0 = off) to show what it does. Writes cow_cycle_<mode>.csv; never writes game or save files.
"""
import csv
import sys
from pathlib import Path
from lupa.lua54 import LuaRuntime

HARNESS = Path(__file__).resolve().parent
REPO = HARNESS.parent.parent
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else HARNESS
SUB = sys.argv[2] if len(sys.argv) > 2 else "COW_HOLSTEIN"
LACT = sys.argv[3] if len(sys.argv) > 3 else "TMR"
DRY = sys.argv[4] if len(sys.argv) > 4 else "hay"
STRENGTH = sys.argv[5] if len(sys.argv) > 5 else None
STOCK = {"TMR": "FORAGE", "hay": "DRYGRASS_WINDROW", "silage": "SILAGE", "grass": "GRASS_WINDROW"}

LUA = r'''
loadMod("tests/feedsim.lua")
local FILL = FeedSim.FILL
function cycleRun(real, sub, lactName, dryName, lactFill, dryFill, strength)
    if strength ~= nil then RLGrowth.getSettings().lactationIntakeStrength, RLGrowth.getSettings().lactationCapacityStrength = strength, strength end
    FeedSim.setMode(real)
    GrowthSim.setDaysPerPeriod(1)
    local cow, subType = GrowthSim.makeAnimal(sub, { age = 48, isParent = true, genetics = { metabolism = 1, quality = 1,
        productivity = 1, fertility = 1, health = 1 } })
    cow.weight = cow.targetWeight
    local pen = FeedSim.makePen({ cow })
    cow.clusterSystem = { owner = pen }
    cow.bodyCondition = RLBodyCondition.createState(cow, "test")
    local rows, calving = {}, nil
    local function refill(p)
        local name = cow.isLactating and lactFill or dryFill
        local other = cow.isLactating and dryFill or lactFill
        if p:level(name) < 4000 then p:add(name, 4000 - p:level(name)) end
        if other ~= name and p:level(other) > 0 then p:removeFood(p:level(other), FILL[other]) end
    end
    local milk, hours = 0, 0
    for cycle = 1, 3 do
        for m = 0, 12 do
            cow.monthsSinceLastBirth, cow.isLactating = m, m < 10
            if m == 0 and cycle > 1 then
                -- Calving: the game ends the pregnancy and resets the clock; the model sees only that.
                cow.isPregnant, cow.reproduction, cow.pregnancy = false, 0, nil
                calving = { before = cow.weight, gravid = cow.rlGrowth ~= nil and cow.rlGrowth.gravidKg or 0 }
            end
            milk = 0
            for h = 1, 24 do
                local day = h / 24
                if m >= 3 then
                    cow.isPregnant = true
                    cow.reproduction = math.min(((m - 3) + day) / 9 * 100, 99.9)
                    cow.pregnancy = { pregnancies = { {} } }
                end
                refill(pen)
                FeedSim.hour(pen)
                local paid = cow.rlMilkPaid
                if paid ~= nil and paid.tick == RLBodyCondition.getTickId() then milk = milk + (paid.litersPerHour or 0) end
                if m == 0 and h == 1 and cycle == 3 then calving.after = cow.weight end
                if cycle == 3 and m < 3 and h % 6 == 0 and h < 24 then
                    local g = cow.rlGrowth ~= nil and cow.rlGrowth.gravidKg or 0
                    rows[#rows + 1] = { month = m + h / 24, weight = cow.weight, gravid = g, tissue = cow.weight - g,
                        reserve = cow.rlGrowth ~= nil and cow.rlGrowth.reserveMassKg or 0, bcs = RLBodyCondition.getBCS(cow),
                        milkPerDay = (paid ~= nil and paid.litersPerHour or 0) * 24, lactating = 1, pregnant = 0 }
                end
            end
            if cycle == 3 then
                local gravid = cow.rlGrowth ~= nil and cow.rlGrowth.gravidKg or 0
                rows[#rows + 1] = { month = m + 1, weight = cow.weight, gravid = gravid, tissue = cow.weight - gravid,
                    reserve = cow.rlGrowth ~= nil and cow.rlGrowth.reserveMassKg or 0, bcs = RLBodyCondition.getBCS(cow),
                    milkPerDay = milk, lactating = cow.isLactating and 1 or 0, pregnant = cow.isPregnant and 1 or 0 }
            end
            if m < 12 then
                cow.age = cow.age + (m < 12 and 1 or 0) * 0
            end
        end
        cow.age = cow.age + 13
    end
    return rows, calving
end
'''
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().REPO = str(REPO) + "/"
lua.execute((REPO / "tests/stubs.lua").read_text())
lua.execute(LUA)
OUT.mkdir(parents=True, exist_ok=True)
for real in (False, True):
    rows, calving = lua.globals().cycleRun(real, SUB, LACT, DRY, STOCK[LACT], STOCK[DRY], float(STRENGTH) if STRENGTH is not None else None)
    rows = sorted((dict(r.items()) for r in rows.values()), key=lambda r: r['month'])
    c = dict(calving.items())
    mode = "real" if real else "legacy"
    print(f"== {SUB} {LACT}/{DRY} mode={mode}")
    print(f"calving hour: weight {c['before']:.1f} -> {c['after']:.1f} kg (gravid carried {c['gravid']:.1f})")
    print("month   weight  gravid  tissue  reserve   BCS  milk/day  lact preg")
    for r in rows:
        print(f"{r['month']:6.2f} {r['weight']:7.1f} {r['gravid']:7.1f} {r['tissue']:7.1f} {r['reserve']:8.1f} {r['bcs']:5.2f} "
              f"{r['milkPerDay']:9.1f}  {int(r['lactating'])}    {int(r['pregnant'])}")
    with (OUT / f"cow_cycle_{mode}.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
