"""FEED-12 dam and calf economics: a dam from calving with one calf or twins in an ordinary pen for 12
months (TMR route, and the pea starter route), on the real feeding path.

python3 tests/feedbalance/dam.py [output_dir] [cow_pack_animals_xml]

Writes dam_calf.csv and dam_calf.json: the pen's feed per fill type, the dam's milk paid / to her
calves / to the store (game liters), her BCS and health, the calves' weight against their curves at 6
and 12 months. Her next conception is not simulated. Never writes game or save files.
"""
import csv
import json
from pathlib import Path

HARNESS = Path(__file__).resolve().parent
source = (HARNESS / "run.py").read_text()
exec(compile(source.split("# Hof Bergmann 1.5 prices")[0], str(HARNESS / "run.py"), "exec"))

CASES = [("COW_HOLSTEIN", ["BULL_HOLSTEIN"]), ("COW_HOLSTEIN", ["BULL_HOLSTEIN", "COW_HOLSTEIN"]),
         ("COW_ANGUS", ["BULL_ANGUS"]), ("COW_ANGUS", ["BULL_ANGUS", "COW_ANGUS"])]
rows = []
for dam, calves in CASES:
    for route in ["TMR", "STARTER"]:
        r = plain(R.nursing(dam, lua.table_from(calves), None if route == "TMR" else route, 12))
        row = {k: v for k, v in r.items() if not isinstance(v, (dict, list))}
        for name, liters in (r["liters"] or {}).items():
            row["L_" + name] = round(liters, 1)
        for c in r["calvesAt"]:
            row[f"calf{c['calf']}_m{c['month']}_kg"] = round(c["weightKg"], 1)
            row[f"calf{c['calf']}_m{c['month']}_curve"] = round(c["curveKg"], 1)
        row["route"] = route
        rows.append(row)
        print(dam, len(calves), route, "paid %.0f calves %.0f store %.0f BCS min %.2f health %.0f" % (
            r["milkPaidL"], r["milkToCalvesL"], r["milkToStoreL"], r["bcsMin"], r["minHealth"]), flush=True)
fields = []
for row in rows:
    for key in row:
        if key not in fields:
            fields.append(key)
with (OUT / "dam_calf.csv").open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields); w.writeheader(); w.writerows(rows)
(OUT / "dam_calf.json").write_text(json.dumps({"head": head, "dirty": bool(dirty), "rows": rows}, indent=2))
