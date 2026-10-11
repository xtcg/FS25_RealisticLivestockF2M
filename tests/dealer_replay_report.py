"""Numerical probes of candidate dealer recipes; no game files or config edits.

Run: python tests/dealer_replay_report.py /private/tmp/dealer-d3-3-calibration.json
Synthetic pack/map subtypes borrow engine food/milk curves (dealerreplaysim.lua).
This is physical-profile coverage, not installed-map or multiplayer acceptance.
"""
import json
import sys
from pathlib import Path

import run

lua = run.lupa.LuaRuntime(unpack_returned_tuples=True)
lua.globals().REPO = run.REPO + "/"
lua.execute((Path(run.TESTS) / "stubs.lua").read_text())
lua.execute('loadMod("tests/dealerreplaysim.lua")')
lua.execute("""
function probe(profile, sex, gene, days, template)
    local s = DealerReplaySim.seed(profile, sex, gene)
    local h = DealerReplaySim.history(s, 12.5, template)
    local r,e = RLDealerReplay.run(s,h,{daysPerMonth=days})
    if r == nil then return {reason=e.reason,atMonths=e.atMonths} end
    local ok,reason = RLDealerReplay.screen(r)
    return {weightKg=r.state.weightKg,reserveKg=r.state.reserveMassKg,
        fraction=r.state.reserveMassKg/r.state.weightKg,development=r.state.developmentMonths,
        health=r.state.health,steps=r.steps,screened=ok,reason=reason,
        energyError=r.ledger.maxEnergyError,massError=r.ledger.maxMassError}
end
""")
profiles = sorted(lua.eval("RLGrowth.getConfig().profiles").keys())
rows = []
for template in ("NORMAL_REARING", "MODERATE_SLOW_REARING"):
    for profile in profiles:
        for sex in ("female", "male"):
            for gene in (0.25, 1, 1.75):
                for days in (1, 3, 7):
                    probe = dict(lua.globals().probe(profile, sex, gene, days, template))
                    rows.append(dict(template=template, profile=profile, sex=sex, gene=gene, days=days, **probe))
    print(template, "done", flush=True)
summary = {}
normal_rows = {(r["profile"], r["sex"], r["gene"], r["days"]): r for r in rows if r["template"] == "NORMAL_REARING"}
for template in ("NORMAL_REARING", "MODERATE_SLOW_REARING"):
    group = [r for r in rows if r["template"] == template]
    successes = [r for r in group if "weightKg" in r]
    summary[template] = dict(
        cases=len(group), replays=len(successes), screened=sum(bool(r.get("screened")) for r in group),
        rejections={reason: sum(r.get("reason") == reason for r in group)
                    for reason in sorted({r["reason"] for r in group if "reason" in r})},
        minHealth=min(r["health"] for r in successes),
        minReserveFraction=min(r["fraction"] for r in successes),
        maxReserveFraction=max(r["fraction"] for r in successes),
        maxEnergyError=max(r["energyError"] for r in successes),
        maxMassError=max(r["massError"] for r in successes),
    )
    phase_lags = [normal_rows[(r["profile"], r["sex"], r["gene"], r["days"])]["development"] - r["development"] for r in successes]
    weight_lags = [normal_rows[(r["profile"], r["sex"], r["gene"], r["days"])]["weightKg"] - r["weightKg"] for r in successes]
    summary[template].update(minDevelopmentLag=min(phase_lags), maxDevelopmentLag=max(phase_lags),
                             minWeightLagKg=min(weight_lags), maxWeightLagKg=max(weight_lags))
output = dict(schemaVersion=1, replayVersion=1, recipeVersion=1,
              evidence="MODEL_ASSUMED_NUMERICAL_PROBE", ageMonths=12.5,
              limitations="Synthetic subtype engine food/milk curves; no game, transaction, or release acceptance.",
              summary=summary, cases=rows)
Path(sys.argv[1]).write_text(json.dumps(output, indent=2) + "\n")
print(json.dumps(summary, indent=2))
