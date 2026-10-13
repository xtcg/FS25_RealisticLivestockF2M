"""Sheep S5 offline calibration: run tests/sheepcalib.lua on the real modules and print each
route's metrics against the design's gates (sheep-finishing-design-v1 §5). No game, no network.

    python tests/sheepcalib.py [--json out.json]
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


def gate(name, ok, detail):
    print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}")
    return ok


def judge(c):
    """The design's gates (sheep-finishing-design-v1 §5) on the measured routes."""
    print("\n== gates")
    fat_order = ["1", "2", "3L", "3H", "4L", "4H", "5"]
    def near_fat(f, target, slack=1):
        return f in fat_order and abs(fat_order.index(f) - fat_order.index(target)) <= slack
    for breed in ("LANDRACE", "TEXEL", "SUFFOLK", "SWISS_MOUNTAIN"):
        lamb = c[f"R1/{breed}/1"]["lambs"][0]
        a = lamb.get("ageAtRef")
        gate(f"V1 R1 {breed} single ram lamb 2.8-3.3 months to its market weight, 3L+-1",
             a is not None and 2.8 <= a <= 3.3 and near_fat(lamb.get("fatAtRef"), "3L"), f"{a} months, {lamb.get('fatAtRef')}")
        # Creep feed conversion: reported both ways until the source's denominator is settled
        # (S5 checklist V1): creep per kg of all live gain to weaning, and per kg of gain over the
        # same lamb on milk and grass alone (R2 single).
        grass = c.get(f"R2/{breed}/1")
        extra = lamb["at3"] - grass["lambs"][0]["at3"] if grass is not None else None
        marginal = lamb["preWeanConc"] / extra if extra and extra > 0 else None
        print(f"INFO V1 R1 {breed} creep {lamb['preWeanConc']:.1f} kg fresh to weaning: {lamb['creepFCR']:.2f} kg per kg of all gain, "
              f"{marginal if marginal is None else round(marginal, 2)} per kg of extra gain over grass alone (candidate 2-4)")
    # A typical flock's lamb: lowland flocks rear about 1.7 lambs a ewe (singles 0.3, twins 0.7 of
    # lambs), hill flocks about 1.3 (singles 0.7, twins 0.3).
    for breed, lo, hi, single in (("LANDRACE", 4.3, 5.5, 0.3), ("TEXEL", 4.3, 5.5, 0.3), ("STEINSCHAF", 5.1, 5.5, 0.7),
                                  ("BLACK_WELSH", 5.1, 5.5, 0.7), ("BLACKFACE", 5.1, 5.5, 0.7)):
        ages = [l.get("ageAtRef") for k in (1, 2) for l in c[f"R2/{breed}/{k}"]["lambs"] if l["sex"] == "male"]
        mean = single * ages[0] + (1 - single) * ages[1] if all(ages) else None
        gate(f"V2 R2 {breed} ram lambs, flock mix ({single:.0%} singles) {lo}-{hi} months +-0.5", mean is not None and lo - 0.5 <= mean <= hi + 0.5,
             f"single {ages[0]:.2f}, twin {ages[1]:.2f}, flock {mean:.2f}")
    base = c["R3/0"]["lambs"][0]["adg"]
    for kg, lo, hi in ((0.25, 1.5, 1.8), (0.5, 1.8, 2.2)):
        r = c[f"R3/{kg}"]["lambs"][0]["adg"] / base if base > 0 else 0
        gate(f"V3 R3 grass + {kg} kg barley {lo}-{hi} x grass alone", lo <= r <= hi, f"{r:.2f} (grass alone {base*1000:.0f} g)")
    ram = c["R4"]["lambs"][0]
    gate("V4 R4 ram ADG 220-280 g", 0.22 <= ram["adg"] <= 0.28, f"{ram['adg']*1000:.0f} g, {ram['dmPerDay']:.2f} kg DM ({ram['dmPctBW']:.1f}% BW)")
    gate("V4 R4 9-12.5 kg concentrate per kg carcass gain (kill-out 0.49)", 9 <= ram["concPerCarcassKg"] <= 12.5, f"{ram['concPerCarcassKg']:.2f}")
    wether, ewe = c["R4"]["lambs"][1], c["R4"]["lambs"][2]
    gate("V6 R4 ADG ram : wether : ewe lamb 1 : 0.86 : 0.76 (+-0.05)",
         abs(wether["adg"] / ram["adg"] - 0.86) <= 0.05 and abs(ewe["adg"] / ram["adg"] - 0.76) <= 0.05,
         f"1 : {wether['adg']/ram['adg']:.2f} : {ewe['adg']/ram['adg']:.2f}")
    v5 = c["V5"]["lambs"]
    gate("V5 ad lib past the reference: 4L or fatter, saleable meat <= 0.97", all(l["yield"] <= 0.97 and l["fat"] in ("4L", "4H", "5") for l in v5),
         ", ".join(f"{l['sex']} {l['fat']} {l['yield']:.3f}" for l in v5))
    ewe = c["EWE/grass/twins"]["ewe"]
    at3 = [b for m, b, w in ewe if abs(m - 3) < 1e-6][0]
    last = ewe[-1][1]
    gate("EWE lowland twins on grass: weaning BCS about 2.5 (2.25-2.75), back to 3+ before mating", 2.25 <= at3 <= 2.75 and last >= 2.9,
         f"weaning {at3:.2f}, month {ewe[-1][0]:.0f} {last:.2f}")
    for feed in ("silage", "silageBarley"):
        twin = c[f"PREG/{feed}/2"]
        gate(f"EWE twins, late pregnancy on {feed}: lambing BCS 3 +-0.25 (lowland target), ME about AHDB's 18 MJ at term",
             2.75 <= twin["bcsAtTerm"] <= 3.25, f"BCS {twin['bcsAtTerm']:.2f}, {twin['dmPerDay']:.2f} kg DM, {twin['mePerDay']:.1f} MJ, gravid {twin['gravidKg']:.1f} kg")
    hay = c["PREG/hay/2"]
    print(f"INFO EWE twins, late pregnancy on hay alone: BCS {hay['bcsAtTerm']:.2f} at lambing (forage-only twin ewes lose condition)")
    one = c["R1/LANDRACE/2"]["lambs"][0]["ageAtRef"]
    for d in (7, 28):
        other = c[f"R1/LANDRACE/2/days{d}"]["lambs"][0]["ageAtRef"]
        gate(f"V8 month length 1 vs {d} days: same route within 1%", other is not None and abs(other - one) / one <= 0.01, f"{one} vs {other}")
    v10 = c["V10"]
    gate("V10 300 sheep pen runs the mode, under 60 ms a game hour (cattle reference about 60 ms / 100 head)", v10["active"] and v10["msPerHour"] < 60,
         f"{v10['msPerHour']:.1f} ms")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json")
    args = parser.parse_args()
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
            if k not in ("lambs", "ewe"):
                print(f"   {k}={fmt(v)}")
    judge(calib)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(calib, f, indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
