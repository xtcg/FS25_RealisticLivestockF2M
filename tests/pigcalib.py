"""Pig P5 offline calibration: run tests/pigcalib.lua on the real modules and judge each route
against the design's frozen references (FS25_PigBreeds_离线准备_2026-10-16/PIG_P5_单胃营养设计.md §7).
Every item is PASS, FAIL or UNVERIFIED (no matched reference); tolerances are the design's and are
never widened to pass. Exit code 1 when anything fails or the Lua run logged an error.

    python tests/pigcalib.py [--json out.json] [--ab species=species_ab.json --ab cattle=...]
"""
import argparse
import glob
import json
import os

import lupa

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)
RESULTS = []


def lua_to_py(value):
    if lupa.lua_type(value) == "table":
        keys = list(value.keys())
        if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [lua_to_py(value[k]) for k in sorted(keys)]
        return {str(k): lua_to_py(value[k]) for k in keys}
    return value


def run():
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().REPO = REPO + "/"
    lua.globals().listRepoLua = lambda sub: lua.table_from(sorted(
        os.path.relpath(p, REPO) for p in glob.glob(os.path.join(REPO, sub, "**", "*.lua"), recursive=True)))
    with open(os.path.join(TESTS, "stubs.lua"), encoding="utf-8") as f:
        lua.execute(f.read())
    with open(os.path.join(TESTS, "pigcalib.lua"), encoding="utf-8") as f:
        lua.execute(f.read())
    lua.globals().PigCalib.run()
    log = [v for v in lua.globals().LOG.values() if v.startswith(("error", "safeCall")) or "observer failed" in v]
    return lua_to_py(lua.globals().CALIB), log


def judge(status, name, detail):
    RESULTS.append((status, name, detail))
    print(f"{status} {name}: {detail}")


def gate(name, ok, detail):
    judge("PASS" if ok else "FAIL", name, detail)


def within(value, target, tol):
    return value is not None and abs(value / target - 1) <= tol


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=str)
    parser.add_argument("--ab", action="append", default=[])
    args = parser.parse_args()
    calib, log = run()
    r = calib["routes"]

    print("=== V1 intake against NRC 2012 Eqs. 8-10 to 8-12 (PIGFOOD, eaten freely)")
    worst = 0
    for row in calib["intake"]:
        err = row["plannedMePerDay"] / row["nrcMJ"] - 1
        worst = max(worst, abs(err))
        print(f"  {row['sex']:8} {row['kg']:>4} kg: planned {row['plannedMePerDay']:.2f} MJ/d, NRC {row['nrcMJ']:.2f} "
              f"({100 * err:+.1f}%), physical cap {row['physicalCapKgDM']:.2f} kg DM, {row['limit']}")
    gate("V1 intake within 3% of NRC at 30-120 kg, all sexes", worst <= 0.03, f"worst {100 * worst:.1f}% (the descriptor reads the weight halfway through the step)")

    print("\n=== V2 DanBred 2025 Landrace (nucleus boars / gilts; station boars FCR 30-100 kg)")
    w = r.get("landraceBoar30_105")
    if w:
        gate("V2 boar ADG 30 kg-slaughter 1.164 kg/d +-10%", within(w["adg"], 1.164, 0.10), f"{w['adg']:.3f} kg/d over {w['days']:.1f} days")
    else:
        gate("V2 boar ADG", False, "105 kg not reached")
    w = r.get("landraceBoar30_100")
    if w:
        gate("V2 boar FCR 30-100 kg 1.75 +-10%", within(w["fcr"], 1.75, 0.10), f"{w['fcr']:.2f} kg as fed per kg ({w['feedPerDay']:.2f} kg/d)")
    w = r.get("landraceGilt30_105")
    if w:
        gate("V2 gilt ADG 30 kg-slaughter 1.117 kg/d +-10%", within(w["adg"], 1.117, 0.10), f"{w['adg']:.3f} kg/d, FCR {w['fcr']:.2f}")
    w = r.get("landraceGiltBirth30")
    if w:
        judge("UNVERIFIED", "V2 gilt 9-30 kg on nursery feed", f"ADG {w['adg']:.3f} kg/d (DanBred's 364 g/d is birth-30 kg, milk included: no matched route)")

    print("\n=== V3 Iowa State 2014, purebred Berkshire in bedded hoops (PIGFOOD for the corn-soy ration)")
    for key, label, adg, adfi, fg in (("berkshireGilt24_122", "gilt 24-122 kg", 0.771, 2.49, 3.23),
                                      ("berkshireBarrow27_124", "barrow 27-124 kg", 0.835, 2.85, 3.42)):
        w = r.get(key)
        if not w:
            gate(f"V3 {label}", False, "end weight not reached")
            continue
        gate(f"V3 {label} ADG {adg} +-10%", within(w["adg"], adg, 0.10), f"{w['adg']:.3f}")
        gate(f"V3 {label} ADFI {adfi} kg +-10%", within(w["feedPerDay"], adfi, 0.10), f"{w['feedPerDay']:.2f}")
        gate(f"V3 {label} F:G {fg} +-10%", within(w["fcr"], fg, 0.10), f"{w['fcr']:.2f}")

    print("\n=== V4 Teagasc finisher 32-118 kg FCE 2.6-2.7 (mixed sexes; Landrace gilt and barrow as the proxy)")
    g, b = r.get("landraceGilt32_118"), r.get("landraceBarrow32_118")
    if g and b:
        fce = (g["fcr"] + b["fcr"]) / 2
        gate("V4 FCE within 2.6-2.7 +-10% (2.34-2.97)", 2.34 <= fce <= 2.97, f"gilt {g['fcr']:.2f}, barrow {b['fcr']:.2f}, mean {fce:.2f} (no feed wastage in the model)")

    print("\n=== V5 lysine: barley alone, barley + soybean, PIGFOOD (Landrace gilt 30-105 kg)")
    p, ba, bs = r.get("giltPigfood30_105"), r.get("giltBarley30_105"), r.get("giltBarleySoy30_105")
    if p and ba and bs:
        print(f"  PIGFOOD ADG {p['adg']:.3f} FCR {p['fcr']:.2f} reserve {p['reserveEnd']}; barley {ba['adg']:.3f} / {ba['fcr']:.2f} / {ba['reserveEnd']}; "
              f"barley+soy {bs['adg']:.3f} / {bs['fcr']:.2f} / {bs['reserveEnd']}")
        gate("V5 barley alone grows slower than PIGFOOD and barley+soybean", ba["adg"] < bs["adg"] and ba["adg"] < p["adg"], "direction")
        gate("V5 barley alone ends fatter (reserve) than PIGFOOD", (ba["reserveEnd"] or 0) > (p["reserveEnd"] or 0), "direction")
    else:
        gate("V5 lysine routes", False, "a route did not reach 105 kg")

    print("\n=== V6 month length (gilt, 60 model days from weaning)")
    ref = r["monthLength"][0]
    worstKg = worstFeed = 0
    for row in r["monthLength"]:
        dk = abs(row["kg"] / ref["kg"] - 1)
        df = abs(row["feedKg"] / ref["feedKg"] - 1) if ref["feedKg"] > 0 else 0
        worstKg, worstFeed = max(worstKg, dk), max(worstFeed, df)
        print(f"  {row['daysPerPeriod']:>2}-day month: {row['day']:.2f} days, {row['kg']:.3f} kg, feed {row['feedKg']:.3f} kg")
    gate("V6 end weight within 0.1%", worstKg <= 0.001, f"worst {100 * worstKg:.3f}%")
    gate("V6 feed eaten within 0.2%", worstFeed <= 0.002, f"worst {100 * worstFeed:.3f}%")

    print("\n=== V7 A/B (other species unchanged)")
    if not args.ab:
        judge("UNVERIFIED", "V7 A/B", "not given (run tests/species_ab.py and pass --ab)")
    for item in args.ab:
        name, path = item.split("=", 1)
        data = json.load(open(path))
        diffs = data.get("differenceCount")
        if diffs is None:
            diffs = len(data.get("differences") or [])
        expected = data.get("expectedDifferences", 0)
        gate(f"V7 A/B {name}", data.get("passed", False) and diffs == 0,
             f"{diffs} unexpected differences ({expected} expected: {data.get('expectedNote', 'none')}), {data.get('cases')} cases")

    print("\n=== V8 pens left to the old rules")
    for row in calib["penGate"]:
        print(f"  {row['case']:20} active={row['active']} reason={row['reason']}")
    rows = {row["case"]: row for row in calib["penGate"]}
    gate("V8 growers run the mode", rows["growers"]["active"] is True, rows["growers"]["reason"])
    gate("V8 piglet / pregnant gilt / farrowed sow keep the old rules (PIG_BREEDING_LEGACY)",
         all(rows[k]["active"] is False and rows[k]["reason"] == "PIG_BREEDING_LEGACY" for k in ("piglet 0.5 months", "pregnant gilt", "sow that farrowed")), "")

    judge("UNVERIFIED", "game test", "not run in game")
    if log:
        gate("Lua log has no errors", False, "; ".join(log[:3]))
    counts = {s: sum(1 for x in RESULTS if x[0] == s) for s in ("PASS", "FAIL", "UNVERIFIED")}
    print(f"\n{counts['PASS']} PASS, {counts['FAIL']} FAIL, {counts['UNVERIFIED']} UNVERIFIED")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"results": RESULTS, "calib": calib, "counts": counts}, f, indent=1)
    return 1 if counts["FAIL"] or log else 0


if __name__ == "__main__":
    raise SystemExit(main())
