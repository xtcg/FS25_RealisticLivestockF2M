"""Sheep S5 offline calibration: run tests/sheepcalib.lua on the real modules and print each
route's metrics against the design's gates (sheep-finishing-design-v1 §5, S5 checklist D6) and the
AHDB/AFRC energy tables. No game, no network. Every item is PASS, FAIL or UNVERIFIED (no
independent reference, or not run here); the summary lists the failures and the unverified items,
and the exit code is 1 when anything failed (or the Lua run logged an error).

    python tests/sheepcalib.py [--json out.json] [--ab cattle-legacy=a.json --ab cattle-real=b.json --ab species=c.json]
"""
import argparse
import json
import os

from lua_test_support import new_runtime, to_python as lua_to_py

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)


def run(group="main"):
    lua = new_runtime()
    for name in ("sheepcalib.lua", "sheepcalib_scenarios.lua"):
        with open(os.path.join(TESTS, name), encoding="utf-8") as f:
            lua.execute(f.read())
    lua.globals().SheepCalibScenarios.run(group)
    # An observer that fails is only a warning in the game (RLFeed.notify): here it is an error,
    # since the measurements would miss what it should have recorded.
    log = [v for v in lua.globals().LOG.values() if v.startswith(("error", "safeCall")) or "observer failed" in v]
    return lua_to_py(lua.globals().CALIB), log


def fmt(v):
    return f"{v:.3f}" if isinstance(v, float) else str(v)


# Every judged or reported item: (status, name, detail). PASS / FAIL against a stated target;
# UNVERIFIED where there is no independent reference or the check was not run here (it is never
# counted as a pass).
RESULTS = []
# The report's four parts (S5 checklist F.5): every item belongs to the part it was judged in.
SECTIONS = ("1 history: the original baseline and earlier results", "2 checks matched to a reference",
            "3 management controls", "4 unmatched sources, proxies and what the game has not verified")
SECTION = [SECTIONS[0]]


def section(index):
    SECTION[0] = SECTIONS[index - 1]
    print(f"\n=== {SECTION[0]}")


def gate(name, ok, detail):
    status = "PASS" if ok else "FAIL"
    RESULTS.append((status, name, detail, SECTION[0]))
    print(f"{status} {name}: {detail}")
    return ok


def unverified(name, detail):
    RESULTS.append(("UNVERIFIED", name, detail, SECTION[0]))
    print(f"UNVERIFIED {name}: {detail}")


def info(text):
    print(f"INFO {text}")


# AHDB Feeding the ewe (older edition), AFRC 1993 tables, as printed.
# Table 8: ME (MJ/day) of housed pregnant ewes, 11 MJ/kg DM diet, no weight loss; (live weight,
# lambs) -> 7, 5, 3, 1 weeks to lambing.
TABLE8_WEEKS = (7, 5, 3, 1)
TABLE8 = {(50, 1): (7.9, 8.7, 9.8, 11.2), (50, 2): (8.8, 10.1, 11.9, 14.2), (60, 1): (9.1, 10.0, 11.2, 12.8),
          (60, 2): (10.1, 11.6, 13.7, 16.3), (70, 1): (10.2, 11.2, 12.6, 14.4), (70, 2): (11.4, 13.1, 15.3, 18.3),
          (70, 3): (12.0, 14.0, 16.7, 20.3), (80, 1): (11.3, 12.4, 13.9, 15.9), (80, 2): (12.6, 14.4, 17.0, 20.2),
          (80, 3): (13.3, 15.5, 18.5, 22.5)}
# Table 29: ME (MJ/day) of housed lactating ewes, 11.5 MJ/kg DM diet; (live weight, weight change
# g/day) -> milk 1, 2, 3 kg/day.
TABLE29 = {(60, 0): (15.6, 23.7, 32.2), (60, -50): (13.8, 22.0, 30.3), (60, -100): (12.1, 20.2, 28.5),
           (80, 0): (17.5, 25.6, 33.9), (80, -50): (15.8, 23.8, 32.0), (80, -100): (14.0, 22.0, 30.2)}
# Table 28: milk (kg/day, a ewe's monthly mean) by system and lambs suckled, months 1-3.
TABLE28 = {("LOWLAND", 1): (2.10, 1.70, 1.05), ("LOWLAND", 2): (3.00, 2.25, 1.50),
           ("HILL", 1): (1.25, 1.05, 0.70), ("HILL", 2): (1.90, 1.60, 1.10)}
# Tolerance for the energy anchors, set before the check: the model is ME-direct on any diet, the
# tables are AFRC at one diet's M/D, so a tenth either way.
ENERGY_TOL = 0.10
# Lambs reared a ewe in the V2 flock mix: scenario assumptions, not sourced figures (S0 evidence
# has only Teagasc Belclare crosses weaning 1.65-1.70 for a prolific lowland flock; nothing for hill).
FLOCK_LAMBS_PER_EWE = {"LOWLAND": 1.7, "HILL": 1.3}


def lamb_weights(n):
    """Shares of a flock's lambs born single and twin, by lambs (not ewes), when ewes rear only
    singles and twins and n lambs a ewe on average (1 <= n <= 2): singles (2 - n) / n, twins
    2 (n - 1) / n."""
    return (2 - n) / n, 2 * (n - 1) / n


def judge(c, ab_files):
    """The design's gates (sheep-finishing-design-v1 §5, S5 checklist D6) on the measured routes, as
    they have been judged so far (part 1), then parts 2-4."""
    section(1)
    fat_order = ["1", "2", "3L", "3H", "4L", "4H", "5"]

    def near_fat(f, target, slack=1):
        return f in fat_order and abs(fat_order.index(f) - fat_order.index(target)) <= slack

    for breed in ("LANDRACE", "TEXEL", "SUFFOLK", "SWISS_MOUNTAIN"):
        lamb = c[f"R1/{breed}/1"]["lambs"][0]
        a = lamb.get("ageAtRef")
        gate(f"V1 R1 {breed} single ram lamb 2.8-3.3 months to its market weight, 3L+-1",
             a is not None and 2.8 <= a <= 3.3 and near_fat(lamb.get("fatAtRef"), "3L"), f"{a} months, {lamb.get('fatAtRef')}")
        grass = c.get(f"R2/{breed}/1")
        extra = lamb["at3"] - grass["lambs"][0]["at3"] if grass is not None else None
        marginal = lamb["preWeanConc"] / extra if extra and extra > 0 else None
        unverified(f"V1 R1 {breed} creep feed conversion (the source's denominator is not settled; candidate 2-4)",
                   f"{lamb['preWeanConc']:.1f} kg fresh to weaning: {lamb['creepFCR']:.2f} per kg of all gain, "
                   f"{marginal if marginal is None else round(marginal, 2)} per kg of gain over grass alone")

    # V2: single and twin ram lambs are the results; the flock mean is a supplement on an assumed n.
    for n in (1.0, 2.0, FLOCK_LAMBS_PER_EWE["LOWLAND"], FLOCK_LAMBS_PER_EWE["HILL"]):
        s1, s2 = lamb_weights(n)
        assert abs(s1 + s2 - 1) < 1e-12 and s1 >= 0 and s2 >= 0
    assert lamb_weights(1.0) == (1.0, 0.0) and lamb_weights(2.0) == (0.0, 1.0)
    for breed, system, lo, hi in (("LANDRACE", "LOWLAND", 4.3, 5.5), ("TEXEL", "LOWLAND", 4.3, 5.5), ("STEINSCHAF", "HILL", 5.1, 5.5),
                                  ("BLACK_WELSH", "HILL", 5.1, 5.5), ("BLACKFACE", "HILL", 5.1, 5.5)):
        ages = [l.get("ageAtRef") for k in (1, 2) for l in c[f"R2/{breed}/{k}"]["lambs"] if l["sex"] == "male"]
        info(f"V2 R2 {breed} ram lamb on milk and grass: single {ages[0]:.2f} months, twin {ages[1]:.2f} months")
        n = FLOCK_LAMBS_PER_EWE[system]
        s1, s2 = lamb_weights(n)
        mean = s1 * ages[0] + s2 * ages[1] if all(ages) else None
        gate(f"V2 R2 {breed} flock mean {lo}-{hi} months +-0.5 (scenario: {n} lambs a ewe = {s1:.1%} singles, {s2:.1%} twins by lambs)",
             mean is not None and lo - 0.5 <= mean <= hi + 0.5, f"{mean:.2f}")

    base = c["R3/0"]["lambs"][0]["adg"]
    for kg, lo, hi in ((0.25, 1.5, 1.8), (0.5, 1.8, 2.2)):
        r = c[f"R3/{kg}"]["lambs"][0]["adg"] / base if base > 0 else 0
        gate(f"V3 R3 grass + {kg} kg barley {lo}-{hi} x grass alone", lo <= r <= hi, f"{r:.2f} (grass alone {base*1000:.0f} g)")
    ram = c["R4"]["lambs"][0]
    gate("V4 R4 ram ADG 220-280 g", 0.22 <= ram["adg"] <= 0.28, f"{ram['adg']*1000:.0f} g, {ram['dmPerDay']:.2f} kg DM ({ram['dmPctBW']:.1f}% BW)")
    gate("V4 R4 9-12.5 kg concentrate per kg carcass gain (kill-out 0.49)", 9 <= ram["concPerCarcassKg"] <= 12.5, f"{ram['concPerCarcassKg']:.2f}")
    wether, ewe = c["R4"]["lambs"][1], c["R4"]["lambs"][2]
    unverified("V6 R4 ADG ram : wether : ewe lamb 1 : 0.86 : 0.76 (the sex growth costs were calibrated on this ratio, SHEEP-C11: not an independent check)",
               f"1 : {wether['adg']/ram['adg']:.2f} : {ewe['adg']/ram['adg']:.2f}")
    for key in sorted(k for k in c if k.startswith("V6PARTS/")):
        l = c[key]["lambs"]
        info(f"V6 parts, {key[8:]}: ram {l[0]['adg']*1000:.0f} g, wether {l[1]['adg']/l[0]['adg']:.2f}, ewe lamb {l[2]['adg']/l[0]['adg']:.2f}")
    v5 = c["V5"]["lambs"]
    gate("V5 ad lib past the reference: 4L or fatter, saleable meat <= 0.97", all(l["yield"] <= 0.97 and l["fat"] in ("4L", "4H", "5") for l in v5),
         ", ".join(f"{l['sex']} {l['fat']} {l['yield']:.3f}" for l in v5))

    # The milk pool: Table 28's row at full feed over three months, what the ewe paid, what her lambs took.
    for key, system, k in (("R2/LANDRACE/1", "LOWLAND", 1), ("R2/LANDRACE/2", "LOWLAND", 2), ("R2/STEINSCHAF/2", "HILL", 2),
                           ("R1/LANDRACE/2", "LOWLAND", 2)):
        pool = c[key]["milkPool"]
        table = [v * 30 for v in TABLE28[(system, k)]]
        potential = [m["potential"] for m in pool]
        ok = all(abs(p - t) <= 0.01 * t for p, t in zip(potential, table))
        gate(f"MILK {key} potential = Table 28 {system} {'single' if k == 1 else 'twins'} x 30 days each month (within 1%)", ok,
             " / ".join(f"{p:.1f} vs {t:.1f}" for p, t in zip(potential, table)) + " kg")
        gate(f"MILK {key} the lambs took no more than the ewe paid", all(m["taken"] <= m["paid"] + 1e-6 for m in pool),
             "paid " + " / ".join(f"{m['paid']:.1f}" for m in pool) + " kg, took " + " / ".join(f"{m['taken']:.1f}" for m in pool) + " kg")

    # The ewe's year from mating to mating, one ewe (D6, FAS lowland: lambing 3, weaning 2.5, mating 3-3.5).
    year = c["EWE/year/twins"]
    info(f"EWE year: starts at mating at BCS {year['startBcs']:.2f} (the setup, not judged)")
    gate("EWE year, lowland twins: lambing BCS 3 +-0.25 (D6), the last 2 months housed on silage", 2.75 <= year["lambingBcs"] <= 3.25,
         f"{year['lambingBcs']:.2f}, gravid {year['gravidKg']:.1f} kg")
    gate("EWE year, lowland twins: weaning BCS >= 2.5 (D6)", year["weaningBcs"] >= 2.5 - 1e-9, f"{year['weaningBcs']:.2f}")
    gate("EWE year, lowland twins: next mating BCS 3.0-3.5 (D6)", 3.0 - 1e-9 <= year["matingBcs"] <= 3.5 + 1e-9, f"{year['matingBcs']:.2f}")
    print_ewe_months("EWE year", year)

    # Feeding control (cause diagnosis, not gates; plans fixed in sheepcalib.lua before they ran).
    # Rule, fixed with the plans: a control explains a D6 failure when it meets that target while
    # the lambs at weaning and the milk the ewe paid stay within 2% of the baseline; met only with
    # the lambs worse off is "met at the lambs' expense"; not met leaves the cause unresolved.
    print("INFO EWE feeding control: plan | lambing weaning mating BCS | lambs at weaning kg (ADG g) | milk paid / potential kg "
          "| ewe / lamb concentrate kg a day in lactation months 1-2")
    controls = [("baseline (as fed)", year)] + [(k[12:], c[k]) for k in sorted(c) if k.startswith("EWE/control/")]
    for name, r in controls:
        lact = [x for x in r["log"] if x["month"] in (6, 7)]
        ewe_c = sum(x["eweConcPerDay"] for x in lact) / len(lact)
        lamb_c = sum(x["lambConcPerDay"] for x in lact) / len(lact)
        print(f"     {name:28s} | {r['lambingBcs']:.2f} {r['weaningBcs']:.2f} {r['matingBcs']:.2f} | {r['lambsAtWeaningKg']:.1f} "
              f"({r['lambAdgToWeaning']*1000:.0f}) | {r['milkPaidKg']:.1f} / {r['milkPotentialKg']:.1f} | {ewe_c:.2f} / {lamb_c:.2f}")
    for name, r in controls[1:]:
        print_ewe_months(f"EWE control {name}", r)

    def verdict(target, ok_of, key):
        values = ", ".join(f"{n} {r[key]:.2f}" for n, r in controls)
        met = [(n, r) for n, r in controls[1:] if ok_of(r)]
        clean = [(n, r) for n, r in met if r["lambsAtWeaningKg"] >= 0.98 * year["lambsAtWeaningKg"]
                 and r["milkPaidKg"] >= 0.98 * year["milkPaidKg"]]
        if clean:
            return f"{target} ({values}): met by {', '.join(n for n, _ in clean)} without the lambs or the milk worse off -> the baseline's miss is the feeding plan, not the energy model"
        if met:
            return f"{target} ({values}): met by {', '.join(n for n, _ in met)} only with the lambs or the milk worse off -> unresolved"
        return f"{target} ({values}): not met by any control -> unresolved (these plans do not explain it)"
    info("EWE diagnosis " + verdict("weaning BCS >= 2.5", lambda r: r["weaningBcs"] >= 2.5 - 1e-9, "weaningBcs"))
    info("EWE diagnosis " + verdict("mating BCS 3.0-3.5", lambda r: 3.0 - 1e-9 <= r["matingBcs"] <= 3.5 + 1e-9, "matingBcs"))

    one = c["R1/LANDRACE/2"]["lambs"][0]["ageAtRef"]
    for d in (3, 7, 28):
        other = c[f"R1/LANDRACE/2/days{d}"]["lambs"][0]["ageAtRef"]
        gate(f"V8 month length 1 vs {d} days: same route within 1%", other is not None and abs(other - one) / one <= 0.01, f"{one} vs {other}")

    names = {"cattle-legacy": "V9 cattle, legacy budget (tests/sheep_s5_ab.py)", "cattle-real": "V9 cattle, real-equivalent mode (tests/feed_ab.py)",
             "species": "V9 pigs, goats, horses, chickens, sheep v2 off (tests/species_ab.py)"}
    for key, name in names.items():
        path = ab_files.get(key)
        if path is None:
            unverified(name, "not run with this calibration (pass --ab " + key + "=result.json)")
            continue
        with open(path, encoding="utf-8") as f:
            r = json.load(f)
        diffs = r.get("differenceCount", len(r.get("differences", [])))
        extra = f", {r['expectedDifferences']} expected ({r.get('expectedNote')})" if r.get("expectedDifferences") else ""
        gate(name + f" against {r['baseline'][:7]}", r.get("passed") is True,
             f"{r['cases']} cases, {r.get('scalarComparisons')} values, {diffs} unexpected differences{extra}")

    v10 = c["V10"]
    gate("V10 300 sheep pen runs the mode, under 60 ms a game hour (cattle reference about 60 ms / 100 head)", v10["active"] and v10["msPerHour"] < 60,
         f"{v10['msPerHour']:.1f} ms")

    section(2)
    judge_energy(c, year)
    judge_matched(c)
    section(3)
    judge_management(c, year)
    section(4)
    judge_unmatched_history(c)
    judge_candidates(c)
    production_guard()



EPS_DAYS = 1e-9
CONVERGED_DAYS = 0.05   # engineering precision: two finer steps' crossing estimates this close
STRADDLED = []          # verdicts that had to fall back to a finer step's estimate


STEPS = (0.25, 0.125, 0.0625, 0.03125, 0.015625)


def crossing_verdict(name, lo, hi, interval, estimates, unit="days", extra_ok=True, extra=""):
    """Judge a crossing on the step-end interval it happened in (lastBelow, firstAtOrAbove] at the
    production step; only an interval across a bound falls back to the finest steps' estimate, and
    only when the two finest agree within CONVERGED_DAYS (otherwise numerical resolution is
    unresolved). estimates: the interpolated estimates at STEPS (None where not run), same unit."""
    below, above = interval
    scale = 30 if unit == "months" else 1
    estimates = list(estimates) + [None] * (len(STEPS) - len(estimates))
    e25 = estimates[0]
    run = [e for e in estimates if e is not None]
    e125, e0625 = (run[-2], run[-1]) if len(run) >= 3 else (None, None)
    fmt_e = lambda e: "-" if e is None else f"{e:.3f}"
    detail = (f"interval ({below:.3f}, {above:.3f}] {unit} at 0.25 d; estimates " + " / ".join(fmt_e(e) for e in estimates)
              + f" at {' / '.join(str(x) for x in STEPS)} d{extra}")
    eps = EPS_DAYS / scale
    if lo - eps <= below and above <= hi + eps:
        return gate(name, extra_ok, detail + " (inside the window)")
    if above < lo - eps or below > hi + eps:
        return gate(name, False, detail + " (outside the window)")
    STRADDLED.append(name)
    if e125 is not None and e0625 is not None and abs(e125 - e0625) * scale <= CONVERGED_DAYS + EPS_DAYS:
        return gate(name, extra_ok and lo - eps <= e0625 <= hi + eps, detail + " (across a bound: judged on the converged estimate)")
    unverified(name, detail + " - numerical resolution unresolved")
    return None


def lamb_of(c, key, sex="male", group=None):
    rows = c if group is None else c["groups"][group]
    r = rows.get(key)
    if r is None:
        return None
    return [l for l in r["lambs"] if l["sex"] == sex][0]


def judge_matched(c):
    """Part 2: the measurements on the lambs' own model time, judged on step intervals."""
    fat_order = ["1", "2", "3L", "3H", "4L", "4H", "5"]

    def near_fat(f, target, slack=1):
        return f in fat_order and abs(fat_order.index(f) - fat_order.index(target)) <= slack

    est = lambda l: None if l is None else l["model"].get("crossingEstimateDays")
    conv = {}   # route -> [(lamb, e25, e125, e0625)]
    for breed in ("LANDRACE", "TEXEL", "SUFFOLK", "SWISS_MOUNTAIN"):
        key = f"R1/{breed}/1"
        l = lamb_of(c, key)
        m = l["model"]
        fines = [est(lamb_of(c, key, group=f"step:{x}")) for x in STEPS[1:]]
        conv.setdefault("R1 (about 3 months)", []).append((key, m["crossingEstimateDays"], *fines))
        crossing_verdict(f"V1 R1 {breed} single ram lamb 84-99 model days to its market weight, 3L+-1 (model time)", 84, 99,
                         (m["lastBelow"]["days"], m["firstAtOrAbove"]["days"]), [m["crossingEstimateDays"]] + fines,
                         extra_ok=near_fat(l.get("fatAtRef"), "3L"),
                         extra=f"; game-hour end {l['ageAtRefGameHour'] * 30:.2f} d; fat {l.get('fatAtRef')}")
    for breed, system, lo, hi in (("LANDRACE", "LOWLAND", 4.3, 5.5), ("TEXEL", "LOWLAND", 4.3, 5.5), ("STEINSCHAF", "HILL", 5.1, 5.5),
                                  ("BLACK_WELSH", "HILL", 5.1, 5.5), ("BLACKFACE", "HILL", 5.1, 5.5)):
        s1, s2 = lamb_weights(FLOCK_LAMBS_PER_EWE[system])
        lambs = [lamb_of(c, f"R2/{breed}/{k}") for k in (1, 2)]
        ests = []
        for x in STEPS[1:]:
            g = [est(lamb_of(c, f"R2/{breed}/{k}", group=f"step:{x}")) for k in (1, 2)]
            ests.append((s1 * g[0] + s2 * g[1]) / 30)
        for k, l in zip((1, 2), lambs):
            fines = [est(lamb_of(c, f"R2/{breed}/{k}", group=f"step:{x}")) for x in STEPS[1:]]
            conv.setdefault("R2 (4-7 months)", []).append((f"R2/{breed}/{k}", l["model"]["crossingEstimateDays"], *fines))
            info(f"V2 R2 {breed} {'single' if k == 1 else 'twin'} ram lamb (model time): crossing ({l['model']['lastBelow']['days']:.2f}, "
                 f"{l['model']['firstAtOrAbove']['days']:.2f}] d, estimate {l['model']['crossingEstimateDays'] / 30:.3f} months; "
                 f"game-hour end {l['ageAtRefGameHour']:.3f}")
        interval = tuple((s1 * lambs[0]["model"][k]["days"] + s2 * lambs[1]["model"][k]["days"]) / 30 for k in ("lastBelow", "firstAtOrAbove"))
        e25 = (s1 * lambs[0]["model"]["crossingEstimateDays"] + s2 * lambs[1]["model"]["crossingEstimateDays"]) / 30
        crossing_verdict(f"V2 R2 {breed} flock mean {lo}-{hi} months +-0.5 (model time; scenario n = {FLOCK_LAMBS_PER_EWE[system]})",
                         lo - 0.5, hi + 0.5, interval, [e25] + ests, unit="months")
    # Convergence, per route, on CONVERGED_DAYS: the 0.125 / 0.0625 d pair as first judged (kept),
    # and the finest pair, 0.03125 / 0.015625 d. The ratio of successive differences (about 2: first
    # order) and the extrapolated limit 2 x finest - next are reported; no verdict above needed a
    # finer step unless STRADDLED lists it.
    for route, rows in conv.items():
        for i, j, label in ((2, 3, "0.125 and 0.0625"), (4, 5, "0.03125 and 0.015625")):
            worst = max(rows, key=lambda r: abs(r[i] - r[j]))
            ratios = [abs(r[i - 1] - r[i]) / abs(r[i] - r[j]) for r in rows if abs(r[i] - r[j]) > 1e-12]
            gate(f"NUMERICS {route}: crossing estimates at {label} d agree within {CONVERGED_DAYS} d (engineering precision)",
                 all(abs(r[i] - r[j]) <= CONVERGED_DAYS + EPS_DAYS for r in rows),
                 f"worst {worst[0]} {abs(worst[i] - worst[j]):.4f} d (" + " / ".join(f"{x:.3f}" for x in worst[1:]) +
                 f" at {' / '.join(str(x) for x in STEPS)} d, extrapolated {2 * worst[j] - worst[i]:.3f}); successive difference ratio "
                 f"{min(ratios):.2f}-{max(ratios):.2f}; verdicts that needed a finer step: {len(STRADDLED)}")
    # Month length: the same route at 1 / 3 / 7 / 28-day months, on model time.
    one = lamb_of(c, "R1/LANDRACE/2")
    parts, ok = [], True
    for d in (3, 7, 28):
        other = lamb_of(c, f"R1/LANDRACE/2/days{d}")
        a, b = one["model"]["crossingEstimateDays"], other["model"]["crossingEstimateDays"]
        w1, w2 = one["at3"], other["at3"]
        ok = ok and abs(b - a) / a <= 0.01 and abs(w2 - w1) / w1 <= 0.01
        parts.append(f"{d} d: crossing {b:.2f} vs {a:.2f} d, at 3 months {w2:.2f} vs {w1:.2f} kg, model days run {other['model']['elapsedModelDays']:.2f}")
    gate("V8 month length on model time: R1 Landrace twin ram lamb's crossing and weight at 3 months within 1% at 3 / 7 / 28 vs 1-day months",
         ok, "; ".join(parts))
    # The budget's ledger closes step by step: supply + mobilised + catabolism = paid + deposit + lost.
    worst_c, n = 0, 0
    for key, r in c.items():
        if not isinstance(r, dict):
            continue
        models = [l.get("model") for l in r.get("lambs", []) or []] + [r.get("eweModel")] + list(r.get("lambModels") or [])
        for m in models:
            if m is not None and m.get("ledgerTotal"):
                n += 1
                worst_c = max(worst_c, abs(m["ledgerClosureNU"]) / max(abs(m["ledgerTotal"].get("supplyNU", 0)), 1))
    gate("LEDGER the budget's energy closes on every tracked animal (|residual| / supply <= 1e-9)", worst_c <= 1e-9,
         f"{n} animals, worst {worst_c:.2e}")
    # R4 rebuilt on the study's conditions (Suffolk proxy, castrates, 39 kg, 54 model days).
    for diet in ("game diet", "study recipe"):
        l = lamb_of(c, f"R4STUDY/wether/{diet}", sex="wether")
        info(f"R4 study design, castrates, {diet}: {l['actualDays']:.2f} model days ({l['hours']} hours at a {l['daysPerPeriod']}-day month); "
             f"ADG {l['adg'] * 1000:.0f} g; intake {l['dmPerDay']:.2f} kg DM a day, concentrate {l['conc'] / l['actualDays']:.2f} kg fresh a day; "
             f"FCR live x 0.49 {l['fcrLive049']:.2f}, x 0.491 {l['fcrLive0491']:.2f} (proxies); game saleable meat {l['fcrMeat']:.2f}")
    for sex in ("male", "female"):
        for diet in ("game diet", "study recipe"):
            l = lamb_of(c, f"R4STUDY/{sex}/{diet}", sex=sex)
            info(f"R4 study design supplement, {'ram' if sex == 'male' else 'ewe'} lambs, {diet} (reported only): ADG {l['adg'] * 1000:.0f} g, "
                 f"{l['dmPerDay']:.2f} kg DM, FCR x 0.491 {l['fcrLive0491']:.2f}")
    l = lamb_of(c, "R4STUDY/wether/study recipe", sex="wether")
    unverified("R4 study design against Teagasc (248 g a day, about 1.5 kg concentrate, 10.7 kg concentrate a kg carcass gain at 49.1% kill-out)",
               f"castrates on the study recipe proxy: {l['adg'] * 1000:.0f} g, {l['conc'] / l['actualDays']:.2f} kg concentrate, "
               f"{l['fcrLive0491']:.2f}. The summary's figures are not yet traced to the castrate / 39 kg / 54 day treatment, and the "
               "recipe is a proxy (barley ad lib, peas <= 0.5 kg, silage 0.5 kg fresh)")
    for age in (5, 6, 7):
        r = c.get(f"R4STUDYAGE/{age}")
        if r is not None:
            info(f"R4 study design castrates at {age} months (the age is an assumption; reported only): game diet "
                 f"{r['game']['adg'] * 1000:.0f} g / FCR x 0.491 {r['game']['fcrLive0491']:.2f}, recipe {r['recipe']['adg'] * 1000:.0f} g / "
                 f"{r['recipe']['fcrLive0491']:.2f}")
    rows = lamb_of(c, "R4", sex="male")
    info(f"R4 original (Landrace, 32 kg, three sexes in one pen): {rows['actualDays']:.2f} model days; ram ADG {rows['adg'] * 1000:.0f} g "
         f"(nominal {rows['adgNominal'] * 1000:.0f} g); FCR x 0.49 {rows['fcrLive049']:.2f}, x 0.491 {rows['fcrLive0491']:.2f}, meat {rows['fcrMeat']:.2f}")


def judge_management(c, year):
    """Part 3: management controls (S5 checklist F.5). A met target supports a management
    explanation of a failure; it does not verify the energy model."""
    s1, s2 = lamb_weights(FLOCK_LAMBS_PER_EWE["HILL"])
    for breed in ("STEINSCHAF", "BLACK_WELSH", "BLACKFACE"):
        lambs = [lamb_of(c, f"MGMT/R2clover/{breed}/{k}") for k in (1, 2)]
        for k, l in zip((1, 2), lambs):
            info(f"MGMT hill on clover, {breed} {'single' if k == 1 else 'twin'} ram lamb: game-hour end {l['ageAtRefGameHour']:.3f} months, "
                 f"model estimate {l['model']['crossingEstimateDays'] / 30:.3f}")
        interval = tuple((s1 * lambs[0]["model"][k]["days"] + s2 * lambs[1]["model"][k]["days"]) / 30 for k in ("lastBelow", "firstAtOrAbove"))
        e25 = (s1 * lambs[0]["model"]["crossingEstimateDays"] + s2 * lambs[1]["model"]["crossingEstimateDays"]) / 30
        hour = s1 * lambs[0]["ageAtRefGameHour"] + s2 * lambs[1]["ageAtRefGameHour"]
        crossing_verdict(f"MGMT hill lambs on clover, {breed} flock mean 5.1-5.5 months +-0.5 (the original window; n = 1.3 assumed)",
                         4.6, 6.0, interval, (e25, None, None), unit="months", extra=f"; game-hour end {hour:.3f}")
    base = year
    for key, checks in (("MGMT/EWE/lactation intensified", ("weaning",)), ("MGMT/EWE/controlled recovery", ("mating",)),
                        ("MGMT/EWE/joint", ("weaning", "mating"))):
        r = c[key]
        name = key[9:]
        if "weaning" in checks:
            gate(f"MGMT ewe {name}: weaning BCS >= 2.5", r["weaningBcs"] >= 2.5 - 1e-9, f"{r['weaningBcs']:.3f} (baseline {base['weaningBcs']:.3f})")
        if "mating" in checks:
            sw = r.get("capSwitch")
            gate(f"MGMT ewe {name}: next mating BCS 3.0-3.5", 3.0 - 1e-9 <= r["matingBcs"] <= 3.5 + 1e-9,
                 f"{r['matingBcs']:.3f} (baseline {base['matingBcs']:.3f}); FINISH -> MAINTAIN at month "
                 f"{'-' if sw is None else format(sw['month'], '.2f')}, BCS {'-' if sw is None else format(sw['bcs'], '.3f')}")
        gate(f"MGMT ewe {name}: lambs at weaning and milk paid at least 98% of the baseline",
             r["lambsAtWeaningKg"] >= 0.98 * base["lambsAtWeaningKg"] and r["milkPaidKg"] >= 0.98 * base["milkPaidKg"],
             f"lambs {r['lambsAtWeaningKg']:.2f} vs {base['lambsAtWeaningKg']:.2f} kg (ADG {r['lambAdgToWeaning'] * 1000:.0f} vs "
             f"{base['lambAdgToWeaning'] * 1000:.0f} g); milk {r['milkPaidKg']:.1f} vs {base['milkPaidKg']:.1f} kg of {r['milkPotentialKg']:.1f}")
        print_ewe_months(f"MGMT ewe {name}", r)
    info("MGMT a control that meets its target supports a management explanation of the baseline's failure only; "
         "it is not an independent check of the energy model")


def judge_candidates(c):
    """Part 4: candidate parameters, each in its own Lua state against candidate:base on the same
    scenarios. Adoption needs diet, time, sex and measurement matched to a traced reference, and
    ADG, intake and FCR improved together; the study's figures are not traced, so none is adopted."""
    groups = c["groups"]
    base = groups["candidate:base"]

    def row(g):
        st = lamb_of(g, "R4STUDY/wether/game diet", sex="wether")
        rc = lamb_of(g, "R4STUDY/wether/study recipe", sex="wether")
        r4 = lamb_of(g, "R4", sex="male")
        tx = lamb_of(g, "R1/TEXEL/1")["model"]["crossingEstimateDays"]
        return (f"study castrates game {st['adg'] * 1000:.0f} g / {st['dmPerDay']:.2f} kg DM / FCR {st['fcrLive0491']:.2f}, recipe "
                f"{rc['adg'] * 1000:.0f} g / {rc['dmPerDay']:.2f} / {rc['fcrLive0491']:.2f}; R4 ram {r4['adg'] * 1000:.0f} g / FCR "
                f"{r4['fcrLive049']:.2f}; Texel R1 {tx:.2f} d")
    info("CANDIDATE base (shipped values, own state): " + row(base))
    for name in ("growth cost 30", "growth cost 36", "growing intake 0.087", "ewe reserve deposit 100"):
        g = groups[f"candidate:{name}"]
        line = row(g)
        if "EWE/year/twins" in g:
            line += "; ewe year weaning / mating " + ", ".join(
                f"{k.split('/')[-1]} {g[k]['weaningBcs']:.3f} / {g[k]['matingBcs']:.3f} (base {base[k]['weaningBcs']:.3f} / {base[k]['matingBcs']:.3f})"
                for k in ("EWE/year/twins", "MGMT/EWE/lactation intensified", "MGMT/EWE/controlled recovery", "MGMT/EWE/joint"))
        info(f"CANDIDATE {name}: " + line)
    unverified("Candidate parameters (growth cost 30 / 36, growing intake 0.087, ewe reserve deposit 100)",
               "none adopted: the reference conditions are not matched (study recipe a proxy, the 248 g / 10.7 not traced to the treatment); "
               "production keeps 33, 0.092, 50")
    unverified("Concentrate adaptation 14 days (game) against the trial's build-up to ad lib within 10 days", "recorded, not matched")


# Production values that must not change in this round (S5 checklist F.5).
PRODUCTION = (
    ("xml/feedProfiles.xml", "species[@name='SHEEP']/physiology", "pregnancyThirdLambFactor", "0.50"),
    ("xml/feedProfiles.xml", "species[@name='SHEEP']/physiology", "youngMaintenanceMEPerKgMetabolic", "0.475"),
    ("xml/feedProfiles.xml", "species[@name='SHEEP']/physiology", "growthCostMale", "0.80"),
    ("xml/feedProfiles.xml", "species[@name='SHEEP']/physiology", "growthCostCastrate", "1.0"),
    ("xml/feedProfiles.xml", "species[@name='SHEEP']/physiology", "growthCostFemale", "1.25"),
    ("xml/feedProfiles.xml", "species[@name='SHEEP']/requirements", "growthMEPerKgAt500", "33"),
    ("xml/feedProfiles.xml", "species[@name='SHEEP']/requirements", "reserveDepositMEPerKg", "50"),
    ("xml/feedProfiles.xml", "species[@name='SHEEP']/requirements", "reserveMobilizeMEPerKg", "35"),
    ("xml/feedProfiles.xml", "species[@name='SHEEP']/intake", "growingPerKgMetabolic", "0.092"),
    ("xml/feedProfiles.xml", "species[@name='SHEEP']/intake", "lactatingPerKgMetabolic", "0.050"),
    ("xml/feedProfiles.xml", "species[@name='SHEEP']/intake", "lactatingPerKgMilk", "0.50"),
    ("xml/feedProfiles.xml", "species[@name='SHEEP']/intake", "ndfFillLactating", "0.018"),
    ("xml/feedProfiles.xml", "species[@name='SHEEP']/ration", "adaptationDays", "14"),
    ("xml/bodyCondition.xml", "species[@name='SHEEP']", "reserveCapacityRatio", "0.48"),
    ("xml/bodyCondition.xml", "species[@name='SHEEP']", "referenceReserve", "0.50"),
    ("xml/weightProfiles.xml", "animalType[@name='SHEEP']", "enabled", "false"),
)


def production_guard():
    import xml.etree.ElementTree as ET
    bad = []
    for path, xpath, attr, want in PRODUCTION:
        node = ET.parse(os.path.join(REPO, path)).getroot().find(xpath)
        got = node.get(attr) if node is not None else None
        if got != want:
            bad.append(f"{path} {xpath}@{attr} = {got} (want {want})")
    gate(f"PRODUCTION the {len(PRODUCTION)} kept values are as shipped (third lamb 0.50, lamb maintenance 0.475, lactation intake "
         "0.050 / 0.50 / 0.018, reserve 0.48 / 0.50, growth 33 and 0.80 / 1.00 / 1.25, intake 0.092, adaptation 14, deposit 50, "
         "mobilise 35, sheep v2 off)", not bad, "; ".join(bad) or "all equal")


def print_ewe_months(title, r):
    """A ewe year by month: condition, what she ate, the budget's ledger (per day, summed step by
    step: supply, demand, paid, unmet, deposited, mobilised), her milk and her lambs."""
    print(f"INFO {title} by month: month BCS weight gravid reserveKg | ewe ate fresh/DM kg, ME MJ a day | ledger MJ a day: "
          "supply demand paid unmet deposit mobilised | milk potential/paid/lambs took kg a day | lambs ate (each, a day): fresh kg trough + milk = total, "
          "DM kg, ME MJ | lamb kg | target")
    for x in r["log"]:
        if x["month"] == 0:
            print(f"     0  {x['bcs']:.2f} {x['weight']:6.1f} {x['gravid']:5.1f} {x['reserveKg']:5.1f}")
            continue
        led, ei, li = x.get("ledger") or {}, x.get("eweIntake") or {}, x.get("lambIntake")
        def v(d, k, f=".1f"):
            return "-" if d is None or d.get(k) is None else format(d[k], f)
        lamb = "-" if li is None else (f"{v(li, 'troughFreshKg', '.3f')} + {v(li, 'milkFreshKg', '.3f')} = {v(li, 'freshKg', '.3f')}, "
                                        f"{v(li, 'dmKg', '.3f')} {v(li, 'meMJ')}")
        print(f"    {x['month']:2d}  {x['bcs']:.2f} {x['weight']:6.1f} {x['gravid']:5.1f} {x['reserveKg']:5.1f} | "
              f"{v(ei, 'freshKg', '.2f')}/{v(ei, 'dmKg', '.2f')} {v(ei, 'meMJ')} | {v(led, 'supplyNU')} {v(led, 'demandNU')} {v(led, 'paidNU')} "
              f"{v(led, 'unmetNU')} {v(led, 'depositNU')} {v(led, 'mobilizedNU')} | {x['milkPotential']:.2f}/{x['milkPaid']:.2f}/{x['lambsTook']:.2f} | "
              f"{lamb} | {'-' if x.get('lambKg') is None else format(x['lambKg'], '.1f')} | {x.get('target')}")


def judge_energy(c, year):
    """Energy against AHDB Tables 8 and 29 (part 2)."""
    # Energy anchors, judged on their own (never read off the BCS gates).
    energy = c["ENERGY"]

    def table8_errors(cells):
        out = []
        for cell in cells:
            table = TABLE8.get((cell["w"], cell["n"]))
            if table is not None:
                t = table[TABLE8_WEEKS.index(cell["weeks"])]
                out.append(((cell["model"] - t) / t, cell, t))
        return out

    errors, old_errors = table8_errors(energy["table8"]), table8_errors(energy["table8Old"])
    for label, errs in (("now", errors), ("before (every lamb 0.55)", old_errors)):
        parts = []
        for n in (1, 2, 3):
            e = [abs(x[0]) for x in errs if x[1]["n"] == n]
            signed = [x[0] for x in errs if x[1]["n"] == n]
            parts.append(f"{n} lamb(s) {min(signed):+.1%}..{max(signed):+.1%} (mean |{sum(e)/len(e):.1%}|)")
        info(f"ENERGY Table 8 by litter, {label}: " + "; ".join(parts))
    worst = max(errors, key=lambda e: abs(e[0]))
    gate(f"ENERGY late pregnancy against AHDB Table 8, all {len(errors)} cells within +-{ENERGY_TOL:.0%} "
         f"(maintenance 0.37 x W^0.75, pregnancy 0.55 a lamb, a third lamb x {energy['thirdLambFactor']}, ramp from 60%)",
         all(abs(e[0]) <= ENERGY_TOL for e in errors),
         f"mean |error| {sum(abs(e[0]) for e in errors) / len(errors):.1%}, worst {worst[0]:+.1%} ({worst[1]['w']} kg, {worst[1]['n']} lambs, "
         f"{worst[1]['weeks']} weeks: {worst[1]['model']:.1f} vs {worst[2]})")
    same = all(a[1]["model"] == b[1]["model"] for a, b in zip(errors, old_errors) if a[1]["n"] <= 2)
    gate("ENERGY singles and twins exactly as before the third-lamb factor (only the third lamb changed)", same,
         f"{sum(1 for e in errors if e[1]['n'] <= 2)} cells compared")
    held = [e for e in errors if e[1]["n"] == 3 and e[1]["w"] == 80]
    gate("ENERGY held out: Table 8's 80 kg triplet row (the factor was taken from the 70 kg row) within +-10%",
         all(abs(e[0]) <= ENERGY_TOL for e in held), " ".join(f"{e[1]['weeks']}w {e[1]['model']:.1f}/{e[2]}({e[0]:+.1%})" for e in held))

    def table8_at(w, n, weeks):
        """Table 8 interpolated linearly in weight and in weeks to lambing (between its rows and columns)."""
        ws = sorted(k[0] for k in TABLE8 if k[1] == n)
        lo = max(x for x in ws if x <= w)
        hi = min(x for x in ws if x >= w)

        def row_at(weight):
            row = TABLE8[(weight, n)]
            cols = list(TABLE8_WEEKS)
            for i in range(len(cols) - 1):
                if cols[i] >= weeks >= cols[i + 1]:
                    f = (cols[i] - weeks) / (cols[i] - cols[i + 1])
                    return row[i] + f * (row[i + 1] - row[i])
            raise ValueError(weeks)
        if lo == hi:
            return row_at(lo)
        f = (w - lo) / (hi - lo)
        return row_at(lo) + f * (row_at(hi) - row_at(lo))

    between = [((b["model"] - table8_at(b["w"], b["n"], b["weeks"])) / table8_at(b["w"], b["n"], b["weeks"]), b) for b in energy["between"]]
    between_old = [((b["model"] - table8_at(b["w"], b["n"], b["weeks"])) / table8_at(b["w"], b["n"], b["weeks"]), b) for b in energy["betweenOld"]]
    worst_b = max(between, key=lambda e: abs(e[0]))
    gate(f"ENERGY new check points between Table 8's ({len(between)}: 55 / 65 / 75 kg x 6 / 4 / 2 weeks, triplets at 75 kg) within +-10% of the table interpolated",
         all(abs(e[0]) <= ENERGY_TOL for e in between),
         f"worst {worst_b[0]:+.1%} ({worst_b[1]['w']} kg, {worst_b[1]['n']} lambs, {worst_b[1]['weeks']} weeks); triplets now "
         + " ".join(f"{e[1]['weeks']}w {e[0]:+.1%}" for e in between if e[1]["n"] == 3)
         + "; before " + " ".join(f"{e[1]['weeks']}w {e[0]:+.1%}" for e in between_old if e[1]["n"] == 3))
    series = energy["series"]
    rows = {int(k): v for k, v in series.items()} if isinstance(series, dict) else {i + 1: v for i, v in enumerate(series)}
    rising = all(rows[n][i + 1][0] >= rows[n][i][0] - 1e-9 for n in rows for i in range(len(rows[n]) - 1))
    nonneg = all(p >= 0 for n in rows for _, p in rows[n])
    ordered = all(rows[3][i][0] >= rows[2][i][0] - 1e-9 and rows[2][i][0] >= rows[1][i][0] - 1e-9 for i in range(len(rows[1])))
    jump = max(abs(rows[n][i + 1][0] - rows[n][i][0]) for n in rows for i in range(len(rows[n]) - 1))
    gate("ENERGY through the pregnancy (70 kg, every 1%): never falling, pregnancy cost never negative, triplets >= twins >= single, no jump over 0.5 MJ",
         rising and nonneg and ordered and jump <= 0.5, f"rising {rising}, non-negative {nonneg}, ordered {ordered}, largest 1% step {jump:.3f} MJ")
    info(f"ENERGY maintenance and pregnancy apart (70 kg; a dry ewe {energy['nonPregnant70']:.2f} MJ): "
         + "; ".join(f"{e[1]['n']} lamb(s) {e[1]['weeks']}w {e[1]['maintenance']:.2f} + {e[1]['pregnancy']:.2f}"
                     for e in errors if e[1]["w"] == 70))
    for w in (70, 80):
        parts = []
        for weeks in TABLE8_WEEKS:
            i = TABLE8_WEEKS.index(weeks)
            model = {e[1]["n"]: e[1]["model"] for e in errors if e[1]["w"] == w and e[1]["weeks"] == weeks}
            t1, t2, t3 = TABLE8[(w, 1)][i], TABLE8[(w, 2)][i], TABLE8[(w, 3)][i]
            parts.append(f"{weeks}w 2nd {model[2]-model[1]:.2f}/{t2-t1:.1f} 3rd {model[3]-model[2]:.2f}/{t3-t2:.1f}")
        info(f"ENERGY a lamb's increment, model/table, {w} kg: " + "; ".join(parts))
    for n in (1, 2, 3):
        rows_txt = []
        for (w, k), _ in sorted(TABLE8.items()):
            if k != n:
                continue
            cells = [e for e in errors if e[1]["w"] == w and e[1]["n"] == n]
            rows_txt.append(f"{w} kg " + " ".join(f"{e[1]['model']:.1f}/{e[2]}({e[0]:+.0%})" for e in sorted(cells, key=lambda e: -e[1]["weeks"])))
        info(f"ENERGY Table 8, {n} lamb(s), model/table at 7/5/3/1 weeks: " + "; ".join(rows_txt))
    m, milk_me, mob = energy["maintenancePerKgMetabolic"], energy["milkMePerKg"], energy["mobilizePerKg"]
    nursing = energy["nursing70"]
    formula = m * nursing["weight"] ** 0.75 + milk_me * nursing["milk"]
    gate("ENERGY Table 29's sum is the model's (a 70 kg ewe nursing twins: describeAnimal maintenance + milk)",
         abs(formula - nursing["model"]) < 1e-6, f"{nursing['model']:.3f} vs {formula:.3f} MJ at {nursing['milk']:.2f} kg milk")
    errors29 = []
    for (w, loss), row in sorted(TABLE29.items()):
        for y, t in zip((1, 2, 3), row):
            model = m * w ** 0.75 + milk_me * y + mob * loss / 1000
            errors29.append(((model - t) / t, w, loss, y, model, t))
    worst29 = max(errors29, key=lambda e: abs(e[0]))
    gate(f"ENERGY lactation against AHDB Table 29, all {len(errors29)} cells within +-{ENERGY_TOL:.0%} (8.3 MJ a kg of milk, 35 MJ a kg of reserve lost)",
         all(abs(e[0]) <= ENERGY_TOL for e in errors29),
         f"mean |error| {sum(abs(e[0]) for e in errors29)/len(errors29):.1%}, worst {worst29[0]:+.1%} "
         f"({worst29[1]} kg, {worst29[2]} g/d, {worst29[3]} kg milk: {worst29[4]:.1f} vs {worst29[5]})")
    info("ENERGY Table 29 model/table: " + "; ".join(f"{w}kg {loss}g {y}kg {mo:.1f}/{t}({e:+.0%})" for e, w, loss, y, mo, t in errors29))
    info(f"ENERGY the year's ewe ({year['lateNeedWeight']:.0f} kg without her lambs, past Table 8's 80 kg): one week before lambing she needs "
         f"{year['lateNeed']:.1f} MJ (Table 8 at 80 kg, twins: 20.2); in her first month of milk {year['lactNeed']:.1f} MJ at "
         f"{year['lactMilk']:.2f} kg milk (Table 29 at 80 kg, 3 kg, no loss: 33.9). Requirement, not what she ate")



def judge_unmatched_history(c):
    """Sensitivity and the calibration values beyond their routes (part 4)."""
    print("\n== sensitivity (reported, not judged)")
    for key in sorted(k for k in c if k.startswith("SENS/")):
        r = c[key]
        print(f"   {key[5:]:40s} R2 twin ram {r['r2RamAge']:.2f} months (at 3: {r['r2RamAt3']:.1f} kg); "
              f"R1 single ram {r['r1RamAge']:.2f} months (at 3: {r['r1RamAt3']:.1f} kg); R4 ram {r['r4Adg']*1000:.0f} g")
    unverified("Ewe milk DM 19%, ME 25 MJ/kg DM, CP 28% DM (PROXY: GE from Sebek & Everts, ME/GE 0.9475 assumed)", "sensitivity above, no source")
    print("\n== growth cost beyond R4 (reported; no trial data for these)")
    for key in sorted(k for k in c if k.startswith("GROWTH/")):
        r = c[key]
        print(f"   {key[7:]:14s} ad lib {r['adlib']['adg']*1000:.0f} g on {r['adlib']['dmPerDay']:.2f} kg DM; "
              f"silage + 0.5 kg barley {r['limited']['adg']*1000:.0f} g on {r['limited']['dmPerDay']:.2f} kg DM")
    unverified("Growth cost 33 MJ/kg at 40 kg (calibration value, set on R1/R4)", "other breeds, weights and diets above have no reference to judge")
    unverified("Game short test (docs/SHEEP_S5_GAME_TEST.md: feed supply, ewe and lamb allocation, weaning, mixed-pen fallback, "
               "save and load, BCS recovery by hand, 300 sheep)", "not done")



def summary():
    counts = {s: sum(1 for r in RESULTS if r[0] == s) for s in ("PASS", "FAIL", "UNVERIFIED")}
    print(f"\n== summary: {counts['PASS']} PASS, {counts['FAIL']} FAIL, {counts['UNVERIFIED']} UNVERIFIED")
    for part in SECTIONS:
        n = {s: sum(1 for r in RESULTS if r[0] == s and r[3] == part) for s in ("PASS", "FAIL", "UNVERIFIED")}
        print(f"   part {part}: {n['PASS']} PASS, {n['FAIL']} FAIL, {n['UNVERIFIED']} UNVERIFIED")
    for status in ("FAIL", "UNVERIFIED"):
        for s, name, detail, part in RESULTS:
            if s == status:
                print(f"   {status} [{part[0]}] {name}: {detail}")
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json")
    parser.add_argument("--ab", action="append", default=[], metavar="KIND=FILE",
                        help="an A/B result to judge as V9: cattle-legacy, cattle-real or species")
    args = parser.parse_args()
    ab_files = dict(item.split("=", 1) for item in args.ab)
    calib, log = run("main")
    # The other groups, each in a Lua state of its own (tests/sheepcalib_scenarios.lua).
    groups = {}
    for group in ("step:0.125", "step:0.0625", "step:0.03125", "step:0.015625", "candidate:base", "candidate:growth cost 30", "candidate:growth cost 36",
                  "candidate:growing intake 0.087", "candidate:ewe reserve deposit 100"):
        groups[group], glog = run(group)
        log = log + [f"{group}: {line}" for line in glog]
    calib["groups"] = groups
    for line in log:
        print("LOG", line)
    for key in sorted(k for k in calib if k != "groups"):
        row = calib[key]
        print(f"== {key}")
        for lamb in row.get("lambs", []) or []:
            print("   lamb " + " ".join(f"{k}={fmt(v)}" for k, v in sorted(lamb.items())))
        if "ewe" in row:
            print("   ewe (month, BCS, kg): " + " ".join(f"({m:.1f},{b:.2f},{w:.1f})" for m, b, w in row["ewe"]))
        for k, v in row.items():
            if k not in ("lambs", "ewe", "log", "table8", "milkPool"):
                print(f"   {k}={fmt(v)}")
    judge(calib, ab_files)
    counts = summary()
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump({"results": [{"status": s, "name": n, "detail": d, "part": p} for s, n, d, p in RESULTS], "counts": counts,
                       "calibration": calib}, f, indent=1, ensure_ascii=False)
    return 1 if counts["FAIL"] > 0 or log else 0


if __name__ == "__main__":
    raise SystemExit(main())
