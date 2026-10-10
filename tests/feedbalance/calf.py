"""FEED-11 calf calibration matrix, on the real feeding path (planner, trough, budget, health).

python3 tests/feedbalance/calf.py [output_dir] [cow_pack_animals_xml]

Every cattle subtype with a weight profile (20 male, 20 female), standard genes, a calf rearing
pen from birth for 6 months, on the STANDARD route (calf milk + the adult TMR) and the STARTER route
(calf milk + TMR + field peas, grain after weaning). Candidates: solid capacity
(intake calfSolidPerKgMetabolic) x the reference calf's milk allowance (calfMilk realLitersPerDay),
and the size rule of the allowance (linear in mean birth weight, or ^0.75). The gate at 6 months:
growth phase >= 5.5 months, weight within 5% of the calf's own curve, health 100 throughout.
Writes calf_matrix.csv, calf_summary.csv and calf_summary.json; never game or save files.
"""
import csv
import json
import sys
import time
from pathlib import Path

HARNESS = Path(__file__).resolve().parent
source = (HARNESS / "run.py").read_text()
exec(compile(source.split("# Hof Bergmann 1.5 prices")[0], str(HARNESS / "run.py"), "exec"))

SOLIDS = [0.075, 0.090, 0.105]
MILK = [8, 9, 10]
SIZE = [1.0, 0.75]
ROUTES = ["STANDARD", "STARTER"]
names = plain(R.subTypes("male")) + plain(R.subTypes("female"))

lua.execute("""
function SET_CALF_CANDIDATE(solid, liters, exponent)
    local config = RLFeed.getConfig()
    config.intake.calfSolidPerKgMetabolic = solid
    config.calfMilk.realLitersPerDay = liters
    config.calfMilk.sizeExponent = exponent
end
""")
shipped = (lua.eval("RLFeed.getConfig().intake.calfSolidPerKgMetabolic"), lua.eval("RLFeed.getConfig().calfMilk.realLitersPerDay"),
           lua.eval("RLFeed.getConfig().calfMilk.sizeExponent"))

rows, summary = [], []
started = time.time()
for exponent in SIZE:
    for solid in SOLIDS:
        for liters in MILK:
            lua.globals().SET_CALF_CANDIDATE(solid, liters, exponent)
            for route in ROUTES:
                passed, worstPhase, worstError, minHealth = 0, 99.0, 0.0, 100.0
                for name in names:
                    calf = plain(R.calf(name, route))
                    six = calf["months"][-1]
                    error = six["weightKg"] / six["curveKg"] - 1
                    ok = six["development"] >= 5.5 and abs(error) <= 0.05 and six["minHealth"] >= 100
                    passed += ok
                    worstPhase = min(worstPhase, six["development"])
                    worstError = max(worstError, abs(error))
                    minHealth = min(minHealth, six["minHealth"])
                    for m in calf["months"]:
                        rows.append(dict(sizeExponent=exponent, solid=solid, allowanceL=liters, route=route, subType=name,
                                         birthKg=calf["birthKg"], **m))
                summary.append(dict(sizeExponent=exponent, solid=solid, allowanceL=liters, route=route, passed=passed, of=len(names),
                                    worstPhase=round(worstPhase, 3), worstWeightError=round(worstError, 4), minHealth=minHealth))
                print(exponent, solid, liters, route, f"{passed}/{len(names)}", round(worstPhase, 2), round(worstError, 4),
                      f"{time.time() - started:.0f}s", flush=True)
lua.globals().SET_CALF_CANDIDATE(*shipped)

with (OUT / "calf_matrix.csv").open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
with (OUT / "calf_summary.csv").open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(summary[0])); w.writeheader(); w.writerows(summary)
(OUT / "calf_summary.json").write_text(json.dumps({"head": head, "dirty": bool(dirty), "summary": summary}, indent=2))

# Sensitivity at the shipped defaults (STARTER): metabolism gene 0.75 / 1.0 / 1.25 and birth weight
# -10% / mean / +10%, for a dairy, a beef and a small breed and the steepest curve.
sensitivity = []
for name in ["BULL_HOLSTEIN", "BULL_ANGUS", "COW_JERSEY_PACK", "BULL_SIMMENTAL_PACK"]:
    for gene in [0.75, 1.0, 1.25]:
        for birth in [0.9, 1.0, 1.1]:
            lua.globals().CALF_OPTS = lua.table_from({"gene": gene, "birthFactor": birth})
            calf = plain(lua.eval("Report.calf")(name, "STARTER", lua.globals().CALF_OPTS))
            six = calf["months"][-1]
            sensitivity.append(dict(subType=name, gene=gene, birthFactor=birth, birthKg=round(calf["birthKg"], 2),
                                    weightKg=round(six["weightKg"], 2), curveKg=round(six["curveKg"], 2),
                                    weightError=round(six["weightKg"] / six["curveKg"] - 1, 4), phase=round(six["development"], 3),
                                    minHealth=six["minHealth"]))
with (OUT / "calf_sensitivity.csv").open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(sensitivity[0])); w.writeheader(); w.writerows(sensitivity)
print("sensitivity", len(sensitivity), "runs; min health", min(r["minHealth"] for r in sensitivity), flush=True)
