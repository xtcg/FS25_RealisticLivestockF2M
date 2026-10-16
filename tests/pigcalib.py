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


def positive(value):
    return finite(value) and value > 0


def fmt(value, spec):
    """A number formatted for the log, or its repr when it is missing or not a number."""
    return format(value, spec) if finite(value) else repr(value)


def section(items, body, label):
    """Run one report section; any exception it raises (malformed input the checks did not foresee) is an
    explicit FAIL on each of its items not yet judged (or on the section when it has no required item), and
    the report goes on to the next section."""
    try:
        body()
    except Exception as exc:  # noqa: BLE001 - a calibration report never stops on bad input
        detail = f"malformed input: {type(exc).__name__}: {exc}"
        pending = [item for item in items if item not in SEEN]
        for item in pending:
            gate(item, False, detail, item)
        if not pending:
            gate(f"{label} section", False, detail)


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
    """Drop each required route, inject non-finite, zero, missing or wrongly typed values, empty the intake
    and pen tables: each must give an explicit FAIL on its item, every other item still judged, exit 1."""
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

    def setter(group, index, field, value):
        def mutate(data):
            row = data[group][index] if group != "monthLength" else data["routes"][group][index]
            if value is KeyError:
                row.pop(field)
            else:
                row[field] = value
        return mutate
    # Malformed values inside a row (2026-10-16 follow-up review, f4-mutations.json): checked before any error is computed.
    cases += [("V1 NaN nrcMJ", setter("intake", 0, "nrcMJ", float("nan")), "V1 intake"),
              ("V1 zero nrcMJ", setter("intake", 0, "nrcMJ", 0), "V1 intake"),
              ("V1 negative nrcMJ", setter("intake", 3, "nrcMJ", -1.0), "V1 intake"),
              ("V1 missing plannedMePerDay", setter("intake", 0, "plannedMePerDay", KeyError), "V1 intake"),
              ("V1 string plannedMePerDay", setter("intake", 5, "plannedMePerDay", "12"), "V1 intake"),
              ("V1 row not a table", lambda d: d["intake"].__setitem__(0, 7), "V1 intake"),
              ("V6 zero 1-day weight", setter("monthLength", 0, "kg", 0), "V6 weight"),
              ("V6 missing feedKg", setter("monthLength", 2, "feedKg", KeyError), "V6 feed"),
              ("V8 row without case", setter("penGate", 0, "case", KeyError), "V8 growers"),
              ("routes not a table", lambda d: d.__setitem__("routes", 3), "V2 boar ADG"),
              ("V3 route a list", lambda d: d["routes"].__setitem__("berkshireGilt24_122", [1, 2]), "V3 gilt ADFI")]
    failures = 0
    for label, change, item in cases:
        mutated = copy.deepcopy(calib)
        if callable(change):
            change(mutated)
        else:
            group, key, field = change
            if group == "routes" and field is None:
                mutated["routes"].pop(key, None)
            elif group == "routes":
                mutated["routes"][key][field] = float("nan")
            else:
                mutated[group] = []
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                code = report(mutated, log, [], None)
        except Exception as exc:  # noqa: BLE001 - an exception escaping the report is itself a selftest failure
            code = f"exception {type(exc).__name__}: {exc}"
            RESULTS.clear()
        failed = any(status == "FAIL" and it == item for status, _, _, it in RESULTS)
        ok = code == 1 and failed and not MISSING and len(SEEN) == len(REQUIRED)
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'} selftest {label}: exit {code}, {item} failed explicitly, missing {MISSING}")
    print(f"selftest: {len(cases) - failures}/{len(cases)}")
    return 1 if failures else 0


MISSING = []


def report(calib, log, ab_items, json_path):
    RESULTS.clear()
    SEEN.clear()
    r = calib.get("routes") if isinstance(calib.get("routes"), dict) else {}

    def v1():
        print("=== V1 intake against NRC 2012 Eqs. 8-10 to 8-12 (PIGFOOD, eaten freely)")
        rows = calib.get("intake")
        rows = rows if isinstance(rows, list) else []
        worst, bad = 0, []
        # Fields, finite values and a positive NRC denominator are checked before any error is computed.
        for i, row in enumerate(rows):
            if not isinstance(row, dict) or not finite(row.get("plannedMePerDay")) or not positive(row.get("nrcMJ")):
                bad.append(i + 1)
                print(f"  point {i + 1}: malformed {row!r}")
                continue
            err = row["plannedMePerDay"] / row["nrcMJ"] - 1
            worst = max(worst, abs(err))
            print(f"  {row.get('sex')!s:8} {row.get('kg')!s:>4} kg: planned {row['plannedMePerDay']:.2f} MJ/d, NRC {row['nrcMJ']:.2f} "
                  f"({100 * err:+.1f}%), physical cap {fmt(row.get('physicalCapKgDM'), '.2f')} kg DM, {row.get('limit')}")
        detail = f"worst {100 * worst:.1f}%, {len(rows) - len(bad)} of 15 points valid"
        if bad:
            detail += f"; points {bad} missing plannedMePerDay or with a non-finite / non-positive nrcMJ"
        gate("V1 intake within 3% of NRC at 30-120 kg, all sexes (an implementation check of the same equations, not a real-world validation)",
             len(rows) == 15 and not bad and worst <= 0.03, detail, "V1 intake")
    section(("V1 intake",), v1, "V1")

    def v2():
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
    section(("V2 boar ADG", "V2 boar FCR", "V2 gilt ADG", "V2 nursery"), v2, "V2")

    def v3():
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
    section(("V3 gilt ADG", "V3 gilt ADFI", "V3 gilt F:G", "V3 barrow ADG", "V3 barrow ADFI", "V3 barrow F:G"), v3, "V3")

    def v4():
        print("\n=== V4 Teagasc finisher 32-118 kg FCE 2.6-2.7 (mixed sexes; Landrace gilt and barrow as the proxy)")
        g = window(r, "landraceGilt32_118", "V4 FCE", ("fcr",))
        b = window(r, "landraceBarrow32_118", "V4 FCE", ("fcr",)) if g else None
        if g and b:
            fce = (g["fcr"] + b["fcr"]) / 2
            gate("V4 FCE within 2.6-2.7 +-10% (2.34-2.97; a two-farm cost example, not a matched trial)", 2.34 <= fce <= 2.97,
                 f"gilt {g['fcr']:.2f}, barrow {b['fcr']:.2f}, mean {fce:.2f} (no feed wastage in the model)", "V4 FCE")
    section(("V4 FCE",), v4, "V4")

    def v5():
        print("\n=== V5 lysine: barley alone, barley + soybean, PIGFOOD (Landrace gilt 30-105 kg)")
        p, ba, bs = r.get("giltPigfood30_105"), r.get("giltBarley30_105"), r.get("giltBarleySoy30_105")
        if all(isinstance(x, dict) and finite(x.get("adg")) and finite(x.get("reserveEnd")) for x in (p, ba, bs)):
            print(f"  PIGFOOD ADG {p['adg']:.3f} FCR {fmt(p.get('fcr'), '.2f')} reserve {p['reserveEnd']:.3f}; barley {ba['adg']:.3f} / "
                  f"{fmt(ba.get('fcr'), '.2f')} / {ba['reserveEnd']:.3f}; barley+soy {bs['adg']:.3f} / {fmt(bs.get('fcr'), '.2f')} / "
                  f"{bs['reserveEnd']:.3f}")
            gate("V5 barley alone grows slower than PIGFOOD and barley+soybean", ba["adg"] < bs["adg"] and ba["adg"] < p["adg"], "direction", "V5 slower")
            gate("V5 barley alone ends fatter (reserve) than PIGFOOD", ba["reserveEnd"] > p["reserveEnd"], "direction", "V5 fatter")
        else:
            gate("V5 barley alone grows slower", False, "a route has no finite result", "V5 slower")
            gate("V5 barley alone ends fatter", False, "a route has no finite result", "V5 fatter")
    section(("V5 slower", "V5 fatter"), v5, "V5")

    def v6():
        print("\n=== V6 month length (gilt, 60 model days from weaning)")
        lengths = r.get("monthLength")
        lengths = lengths if isinstance(lengths, list) else []
        if len(lengths) != 4 or not all(isinstance(x, dict) and finite(x.get("kg")) and finite(x.get("feedKg")) for x in lengths) \
                or not positive(lengths[0]["kg"]) or not positive(lengths[0]["feedKg"]):
            gate("V6 end weight within 0.1%", False, f"{len(lengths)} of 4 month lengths, not all finite with a positive 1-day reference", "V6 weight")
            gate("V6 feed eaten within 0.2%", False, f"{len(lengths)} of 4 month lengths, not all finite with a positive 1-day reference", "V6 feed")
        else:
            ref = lengths[0]
            worstKg = worstFeed = 0
            for row in lengths:
                worstKg = max(worstKg, abs(row["kg"] / ref["kg"] - 1))
                worstFeed = max(worstFeed, abs(row["feedKg"] / ref["feedKg"] - 1))
                print(f"  {row.get('daysPerPeriod')!s:>2}-day month: {fmt(row.get('day'), '.2f')} days, {row['kg']:.3f} kg, feed {row['feedKg']:.3f} kg")
            gate("V6 end weight within 0.1%", worstKg <= 0.001, f"worst {100 * worstKg:.3f}%", "V6 weight")
            gate("V6 feed eaten within 0.2%", worstFeed <= 0.002, f"worst {100 * worstFeed:.3f}%", "V6 feed")
    section(("V6 weight", "V6 feed"), v6, "V6")

    def v7():
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
    section((), v7, "V7 A/B")

    def v8():
        print("\n=== V8 pens left to the old rules")
        pens = calib.get("penGate")
        pens = [row for row in pens if isinstance(row, dict)] if isinstance(pens, list) else []
        for row in pens:
            print(f"  {row.get('case')!s:20} active={row.get('active')} reason={row.get('reason')}")
        rows = {row.get("case"): row for row in pens}
        legacy = ("piglet 0.5 months", "pregnant gilt", "sow that farrowed")
        gate("V8 growers run the mode", rows.get("growers", {}).get("active") is True, str(rows.get("growers", {}).get("reason")), "V8 growers")
        gate("V8 piglet / pregnant gilt / farrowed sow keep the old rules (PIG_BREEDING_LEGACY)",
             all(rows.get(k, {}).get("active") is False and rows.get(k, {}).get("reason") == "PIG_BREEDING_LEGACY" for k in legacy),
             f"{sum(1 for k in legacy if k in rows)} of 3 cases", "V8 legacy")
    section(("V8 growers", "V8 legacy"), v8, "V8")
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
