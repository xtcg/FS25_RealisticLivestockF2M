"""Pig P5 offline calibration: run tests/pigcalib.lua on the real modules and judge each route
against the design's frozen references (FS25_PigBreeds_离线准备_2026-10-16/PIG_P5_单胃营养设计.md §7).
Every item is PASS, FAIL or UNVERIFIED (no matched reference); tolerances are the design's and are
never widened to pass. Exit code 1 when anything fails or the Lua run logged an error.

    python tests/pigcalib.py [--json out.json] [--ab species=species_ab.json --ab cattle=...]
"""
import argparse
import glob
import json
import math
import os

import lupa

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)
RESULTS = []

# Every item the report must judge, each exactly once (a missing route, result or non-finite value is
# a FAIL, never a silently shorter report; only a missing real-world reference may be UNVERIFIED).
REQUIRED = [
    "V1 intake", "V2 boar ADG", "V2 boar FCR", "V2 gilt ADG", "V2 nursery",
    "V3 gilt ADG", "V3 gilt ADFI", "V3 gilt F:G", "V3 barrow ADG", "V3 barrow ADFI", "V3 barrow F:G",
    "V4 FCE", "V5 slower", "V5 fatter", "V6 weight", "V6 feed",
    "V8 growers", "V8 legacy", "game test",
]
SEEN = {}


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


def judge(status, name, detail, item=None):
    if item is not None:
        if item in SEEN:
            status, detail = "FAIL", f"judged twice ({detail})"
        SEEN[item] = True
    RESULTS.append((status, name, detail, item))
    print(f"{status} {name}: {detail}")


def gate(name, ok, detail, item=None):
    judge("PASS" if ok else "FAIL", name, detail, item)


def finite(value):
    return isinstance(value, (int, float)) and math.isfinite(value)


def within(value, target, tol):
    return finite(value) and abs(value / target - 1) <= tol


def window(routes, key, item, fields):
    """A route's window, or an explicit FAIL for `item` when it is missing or not finite."""
    w = routes.get(key)
    if not isinstance(w, dict):
        gate(item, False, f"route {key} has no result (end weight not reached or not measured)", item)
        return None
    bad = [f for f in fields if not finite(w.get(f))]
    if bad:
        gate(item, False, f"route {key}: non-finite {', '.join(bad)}", item)
        return None
    return w


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=str)
    parser.add_argument("--ab", action="append", default=[])
    parser.add_argument("--selftest", action="store_true", help="judge mutated copies: every missing item must FAIL")
    args = parser.parse_args()
    calib, log = run()
    if args.selftest:
        return selftest(calib, log)
    return report(calib, log, args.ab, args.json)


def selftest(calib, log):
    """Drop each required route, inject a non-finite value, empty the intake and pen tables: each must
    give an explicit FAIL on its item and a non-zero exit."""
    import copy
    import contextlib
    import io
    cases = [(f"drop {key}", ("routes", key, None), item) for key, item in (
        ("landraceBoar30_105", "V2 boar ADG"), ("landraceBoar30_100", "V2 boar FCR"), ("landraceGilt30_105", "V2 gilt ADG"),
        ("landraceGiltBirth30", "V2 nursery"), ("berkshireGilt24_122", "V3 gilt F:G"), ("berkshireBarrow27_124", "V3 barrow ADFI"),
        ("landraceGilt32_118", "V4 FCE"), ("landraceBarrow32_118", "V4 FCE"), ("giltBarley30_105", "V5 slower"),
        ("monthLength", "V6 feed"))]
    cases += [("NaN boar ADG", ("routes", "landraceBoar30_105", "adg"), "V2 boar ADG"),
              ("empty intake", ("intake", None, None), "V1 intake"), ("empty pen gate", ("penGate", None, None), "V8 legacy")]
    failures = 0
    for label, (group, key, field), item in cases:
        mutated = copy.deepcopy(calib)
        if group == "routes" and field is None:
            mutated["routes"].pop(key, None)
        elif group == "routes":
            mutated["routes"][key][field] = float("nan")
        else:
            mutated[group] = []
        with contextlib.redirect_stdout(io.StringIO()):
            code = report(mutated, log, [], None)
        failed = any(status == "FAIL" and it == item for status, _, _, it in RESULTS)
        ok = code != 0 and failed and not MISSING
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'} selftest {label}: exit {code}, {item} failed explicitly, missing {MISSING}")
    print(f"selftest: {len(cases) - failures}/{len(cases)}")
    return 1 if failures else 0


MISSING = []


def report(calib, log, ab_items, json_path):
    RESULTS.clear()
    SEEN.clear()
    r = calib.get("routes") or {}

    print("=== V1 intake against NRC 2012 Eqs. 8-10 to 8-12 (PIGFOOD, eaten freely)")
    worst = 0
    for row in calib.get("intake") or []:
        err = row["plannedMePerDay"] / row["nrcMJ"] - 1
        worst = max(worst, abs(err))
        print(f"  {row['sex']:8} {row['kg']:>4} kg: planned {row['plannedMePerDay']:.2f} MJ/d, NRC {row['nrcMJ']:.2f} "
              f"({100 * err:+.1f}%), physical cap {row['physicalCapKgDM']:.2f} kg DM, {row['limit']}")
    rows = calib.get("intake") or []
    ok = len(rows) == 15 and all(finite(row.get("plannedMePerDay")) for row in rows)
    gate("V1 intake within 3% of NRC at 30-120 kg, all sexes (an implementation check of the same equations, not a real-world validation)",
         ok and worst <= 0.03, f"worst {100 * worst:.1f}%, {len(rows)} of 15 points", "V1 intake")

    print("\n=== V2 DanBred 2025 Landrace (nucleus boars / gilts; station boars FCR 30-100 kg)")
    w = window(r, "landraceBoar30_105", "V2 boar ADG", ("adg", "days"))
    if w:
        gate("V2 boar ADG 30 kg-slaughter 1.164 kg/d +-10%", within(w["adg"], 1.164, 0.10), f"{w['adg']:.3f} kg/d over {w['days']:.1f} days",
             "V2 boar ADG")
    w = window(r, "landraceBoar30_100", "V2 boar FCR", ("fcr", "feedPerDay"))
    if w:
        gate("V2 boar FCR 1.75 +-10% (source window 30 kg-slaughter; the script ends at 100 kg: PROXY window)", within(w["fcr"], 1.75, 0.10),
             f"{w['fcr']:.2f} kg as fed per kg ({w['feedPerDay']:.2f} kg/d)", "V2 boar FCR")
    w = window(r, "landraceGilt30_105", "V2 gilt ADG", ("adg", "fcr"))
    if w:
        gate("V2 gilt ADG 30 kg-slaughter 1.117 kg/d +-10%", within(w["adg"], 1.117, 0.10), f"{w['adg']:.3f} kg/d, FCR {w['fcr']:.2f}", "V2 gilt ADG")
    w = window(r, "landraceGiltBirth30", "V2 nursery", ("adg",))
    if w:
        judge("UNVERIFIED", "V2 gilt 9-30 kg on nursery feed",
              f"ADG {w['adg']:.3f} kg/d (DanBred's 364 g/d is birth-30 kg, milk included: no matched route)", "V2 nursery")

    print("\n=== V3 Iowa State 2014, purebred Berkshire in bedded hoops (PIGFOOD for the corn-soy ration)")
    for key, label, tag, adg, adfi, fg in (("berkshireGilt24_122", "gilt 24-122 kg", "gilt", 0.771, 2.49, 3.23),
                                           ("berkshireBarrow27_124", "barrow 27-124 kg", "barrow", 0.835, 2.85, 3.42)):
        w = r.get(key)
        bad = not isinstance(w, dict) or not all(finite(w.get(f)) for f in ("adg", "feedPerDay", "fcr"))
        for item in (f"V3 {tag} ADG", f"V3 {tag} ADFI", f"V3 {tag} F:G"):
            if bad:
                gate(item, False, f"route {key} has no finite result", item)
        if bad:
            continue
        gate(f"V3 {label} ADG {adg} +-10%", within(w["adg"], adg, 0.10), f"{w['adg']:.3f}", f"V3 {tag} ADG")
        gate(f"V3 {label} ADFI {adfi} kg +-10%", within(w["feedPerDay"], adfi, 0.10), f"{w['feedPerDay']:.2f}", f"V3 {tag} ADFI")
        gate(f"V3 {label} F:G {fg} +-10%", within(w["fcr"], fg, 0.10), f"{w['fcr']:.2f}", f"V3 {tag} F:G")

    print("\n=== V4 Teagasc finisher 32-118 kg FCE 2.6-2.7 (mixed sexes; Landrace gilt and barrow as the proxy)")
    g = window(r, "landraceGilt32_118", "V4 FCE", ("fcr",))
    b = window(r, "landraceBarrow32_118", "V4 FCE", ("fcr",)) if g else None
    if g and b:
        fce = (g["fcr"] + b["fcr"]) / 2
        gate("V4 FCE within 2.6-2.7 +-10% (2.34-2.97; a two-farm cost example, not a matched trial)", 2.34 <= fce <= 2.97,
             f"gilt {g['fcr']:.2f}, barrow {b['fcr']:.2f}, mean {fce:.2f} (no feed wastage in the model)", "V4 FCE")

    print("\n=== V5 lysine: barley alone, barley + soybean, PIGFOOD (Landrace gilt 30-105 kg)")
    p, ba, bs = r.get("giltPigfood30_105"), r.get("giltBarley30_105"), r.get("giltBarleySoy30_105")
    if all(isinstance(x, dict) and finite(x.get("adg")) and finite(x.get("reserveEnd")) for x in (p, ba, bs)):
        print(f"  PIGFOOD ADG {p['adg']:.3f} FCR {p['fcr']:.2f} reserve {p['reserveEnd']:.3f}; barley {ba['adg']:.3f} / {ba['fcr']:.2f} / "
              f"{ba['reserveEnd']:.3f}; barley+soy {bs['adg']:.3f} / {bs['fcr']:.2f} / {bs['reserveEnd']:.3f}")
        gate("V5 barley alone grows slower than PIGFOOD and barley+soybean", ba["adg"] < bs["adg"] and ba["adg"] < p["adg"], "direction", "V5 slower")
        gate("V5 barley alone ends fatter (reserve) than PIGFOOD", ba["reserveEnd"] > p["reserveEnd"], "direction", "V5 fatter")
    else:
        gate("V5 barley alone grows slower", False, "a route has no finite result", "V5 slower")
        gate("V5 barley alone ends fatter", False, "a route has no finite result", "V5 fatter")

    print("\n=== V6 month length (gilt, 60 model days from weaning)")
    lengths = r.get("monthLength") or []
    if len(lengths) != 4 or not all(finite(x.get("kg")) and finite(x.get("feedKg")) for x in lengths) or lengths[0]["feedKg"] <= 0:
        gate("V6 end weight within 0.1%", False, f"{len(lengths)} of 4 month lengths with finite results", "V6 weight")
        gate("V6 feed eaten within 0.2%", False, f"{len(lengths)} of 4 month lengths with finite results", "V6 feed")
    else:
        ref = lengths[0]
        worstKg = worstFeed = 0
        for row in lengths:
            worstKg = max(worstKg, abs(row["kg"] / ref["kg"] - 1))
            worstFeed = max(worstFeed, abs(row["feedKg"] / ref["feedKg"] - 1))
            print(f"  {row['daysPerPeriod']:>2}-day month: {row['day']:.2f} days, {row['kg']:.3f} kg, feed {row['feedKg']:.3f} kg")
        gate("V6 end weight within 0.1%", worstKg <= 0.001, f"worst {100 * worstKg:.3f}%", "V6 weight")
        gate("V6 feed eaten within 0.2%", worstFeed <= 0.002, f"worst {100 * worstFeed:.3f}%", "V6 feed")

    print("\n=== V7 A/B (other species unchanged)")
    if not ab_items:
        judge("UNVERIFIED", "V7 A/B", "not given (run tests/species_ab.py and pass --ab)")
    for item in ab_items:
        name, path = item.split("=", 1)
        data = json.load(open(path))
        diffs = data.get("differenceCount")
        if diffs is None:
            diffs = len(data.get("differences") or [])
        expected = data.get("expectedDifferences", 0)
        gate(f"V7 A/B {name}", data.get("passed", False) and diffs == 0,
             f"{diffs} unexpected differences ({expected} expected: {data.get('expectedNote', 'none')}), {data.get('cases')} cases")

    print("\n=== V8 pens left to the old rules")
    for row in calib.get("penGate") or []:
        print(f"  {row['case']:20} active={row['active']} reason={row['reason']}")
    rows = {row["case"]: row for row in calib.get("penGate") or []}
    legacy = ("piglet 0.5 months", "pregnant gilt", "sow that farrowed")
    gate("V8 growers run the mode", rows.get("growers", {}).get("active") is True, str(rows.get("growers", {}).get("reason")), "V8 growers")
    gate("V8 piglet / pregnant gilt / farrowed sow keep the old rules (PIG_BREEDING_LEGACY)",
         all(rows.get(k, {}).get("active") is False and rows.get(k, {}).get("reason") == "PIG_BREEDING_LEGACY" for k in legacy),
         f"{sum(1 for k in legacy if k in rows)} of 3 cases", "V8 legacy")
    judge("UNVERIFIED", "game test", "not run in game", "game test")
    if log:
        gate("Lua log has no errors", False, "; ".join(log[:3]))
    missing = [item for item in REQUIRED if item not in SEEN]
    MISSING[:] = missing
    for item in missing:
        gate(item, False, "required item not judged")
    unknown = [item for item in SEEN if item not in REQUIRED]
    for item in unknown:
        gate(item, False, "judged but not in the required list")
    counts = {s: sum(1 for x in RESULTS if x[0] == s) for s in ("PASS", "FAIL", "UNVERIFIED")}
    print(f"\nrequired {len(REQUIRED)}, evaluated {len(REQUIRED) - len(missing)}, missing {len(missing)}")
    print(f"{counts['PASS']} PASS, {counts['FAIL']} FAIL, {counts['UNVERIFIED']} UNVERIFIED")
    if json_path:
        with open(json_path, "w") as f:
            json.dump({"results": RESULTS, "calib": calib, "counts": counts, "required": REQUIRED, "missing": missing}, f, indent=1)
    return 1 if counts["FAIL"] or log else 0


if __name__ == "__main__":
    raise SystemExit(main())
