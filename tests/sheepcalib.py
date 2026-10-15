"""Sheep S5 offline calibration: run tests/sheepcalib.lua on the real modules and print each
route's metrics against the design's gates (sheep-finishing-design-v1 §5, S5 checklist D6) and the
AHDB/AFRC energy tables. No game, no network. Every item is PASS, FAIL or UNVERIFIED (no
independent reference, or not run here); the summary lists the failures and the unverified items,
and the exit code is 1 when anything failed (or the Lua run logged an error).

    python tests/sheepcalib.py [--json out.json] [--ab cattle-legacy=a.json --ab cattle-real=b.json --ab species=c.json]
"""
import argparse
import glob
import json
import os

import lupa

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)


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
    with open(os.path.join(TESTS, "sheepcalib.lua"), encoding="utf-8") as f:
        lua.execute(f.read())
    log = [v for v in lua.globals().LOG.values() if v.startswith(("error", "safeCall"))]
    return lua_to_py(lua.globals().CALIB), log


def fmt(v):
    return f"{v:.3f}" if isinstance(v, float) else str(v)


# Every judged or reported item: (status, name, detail). PASS / FAIL against a stated target;
# UNVERIFIED where there is no independent reference or the check was not run here (it is never
# counted as a pass).
RESULTS = []


def gate(name, ok, detail):
    status = "PASS" if ok else "FAIL"
    RESULTS.append((status, name, detail))
    print(f"{status} {name}: {detail}")
    return ok


def unverified(name, detail):
    RESULTS.append(("UNVERIFIED", name, detail))
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
    """The design's gates (sheep-finishing-design-v1 §5, S5 checklist D6) on the measured routes."""
    print("\n== gates")
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
    print("INFO EWE year by month: month BCS weight gravid | ate kgDM/d MJ/d | milk potential paid took kg/d | requirement MJ/d")
    for r in year["log"]:
        if r["month"] == 0:
            print(f"     0  {r['bcs']:.2f} {r['weight']:6.1f} {r['gravid']:5.1f}")
            continue
        need = r.get("need")
        print(f"    {r['month']:2d}  {r['bcs']:.2f} {r['weight']:6.1f} {r['gravid']:5.1f} | {r['dmPerDay']:.2f} {r['mePerDay']:5.1f} | "
              f"{r['milkPotential']:.2f} {r['milkPaid']:.2f} {r['lambsTook']:.2f} | {need if need is None else round(need, 1)}")

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
        print(f"INFO EWE control {name} by month: month BCS reserveKg | ate MJ/d need balance | milk paid lambs took | lamb kg")
        for x in r["log"]:
            if x["month"] == 0:
                continue
            bal = x.get("balance")
            print(f"    {x['month']:2d} {x['bcs']:.2f} {x['reserveKg']:5.1f} | {x['mePerDay']:5.1f} {x['need']:5.1f} "
                  f"{'' if bal is None else format(bal, '+.1f')} | {x['milkPaid']:.2f} {x['lambsTook']:.2f} | "
                  f"{'' if x.get('lambKg') is None else format(x['lambKg'], '.1f')}")

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
    unverified("Game test (single player short test, S5 checklist F)", "not done")


def summary():
    counts = {s: sum(1 for r in RESULTS if r[0] == s) for s in ("PASS", "FAIL", "UNVERIFIED")}
    print(f"\n== summary: {counts['PASS']} PASS, {counts['FAIL']} FAIL, {counts['UNVERIFIED']} UNVERIFIED")
    for status in ("FAIL", "UNVERIFIED"):
        for s, name, detail in RESULTS:
            if s == status:
                print(f"   {status} {name}: {detail}")
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json")
    parser.add_argument("--ab", action="append", default=[], metavar="KIND=FILE",
                        help="an A/B result to judge as V9: cattle-legacy, cattle-real or species")
    args = parser.parse_args()
    ab_files = dict(item.split("=", 1) for item in args.ab)
    calib, log = run()
    for line in log:
        print("LOG", line)
    for key in sorted(calib):
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
            json.dump({"results": [{"status": s, "name": n, "detail": d} for s, n, d in RESULTS], "counts": counts,
                       "calibration": calib}, f, indent=1, ensure_ascii=False)
    return 1 if counts["FAIL"] > 0 or log else 0


if __name__ == "__main__":
    raise SystemExit(main())
