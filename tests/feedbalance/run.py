"""Full feed balance matrix, using the real planner and feeding/growth path.

python3 tests/feedbalance/run.py [output_dir] [cow_pack_animals_xml]
Requires lupa.lua54; defaults to the sibling FS25_CowBreedsRLRM pack.
Writes only report files, never game/save files. Prices and yields are proxies below.
"""
import csv
import json
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from lupa.lua54 import LuaRuntime

HARNESS = Path(__file__).resolve().parent
REPO = HARNESS.parent.parent
ROOT = REPO.parent
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'FEED_平衡验收_2026-10-11'
OUT.mkdir(parents=True, exist_ok=True)
PACK = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else ROOT / 'FS25_CowBreedsRLRM/animals.xml'
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip()
dirty = subprocess.check_output(['git', 'status', '--porcelain'], cwd=REPO, text=True).strip()

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().REPO = str(REPO) + '/'
lua.execute((REPO / 'tests/stubs.lua').read_text())
lua.execute('loadMod("tests/feedsim.lua")')


def table(value):
    if isinstance(value, dict):
        return lua.table_from({k: table(v) for k, v in value.items()})
    if isinstance(value, list):
        return lua.table_from([table(v) for v in value])
    return value


def plain(value):
    if hasattr(value, 'items'):
        items = list(value.items())
        if items and all(isinstance(k, int) for k, _ in items):
            return [plain(value[i]) for i in range(1, len(items) + 1)]
        return {k: plain(v) for k, v in items}
    return value


# Base animals.xml, then the Cow Breeds pack (full definitions and overrides), as the v2 audit did.
definitions = {}
for path in [REPO / 'xml/animals.xml', PACK]:
    for animal in ET.parse(path).getroot().findall('animal'):
        if animal.get('type') != 'COW':
            continue
        for sub in animal.findall('subType'):
            def curve(key):
                return [[float(k.get('ageMonth')), float(k.get('value'))] for k in sub.findall(key + '/key')]
            name = sub.get('subType')
            d = definitions.get(name, {'name': name})
            for key in ['breed', 'gender', 'minWeight', 'targetWeight']:
                if sub.get(key) is not None:
                    d[key] = float(sub.get(key)) if 'Weight' in key else sub.get(key)
            reproduction = sub.find('reproduction')
            if reproduction is not None and reproduction.get('minAgeMonth') is not None:
                d['reproductionMinAgeMonth'] = float(reproduction.get('minAgeMonth'))
            for key, xmlkey in [('food', 'input/food'), ('milk', 'output/milk'), ('sellPriceCurve', 'sellPrice')]:
                if sub.find(xmlkey) is not None:
                    d[key] = curve(xmlkey)
            definitions[name] = d
lua.globals().REPORT_DEFINITIONS = table(list(definitions.values()))
lua.execute((HARNESS / 'report.lua').read_text())
R = lua.globals().Report

# Hof Bergmann 1.5 prices per liter (economy pricePerLiter, before difficulty or EconomyTuner) and
# base-game yields (litersPerSqm x 10000; grass 3 cuts a year; hay and grass silage 1:1 from grass;
# maize silage = maize x 7.8 chaff; TMR proxy liters = half hay, half maize silage).
PRICE = {'FORAGE': 0.124, 'SILAGE': 0.121, 'DRYGRASS_WINDROW': 0.056, 'GRASS_WINDROW': 0.045, 'WHEAT': 0.337,
         'MAIZE': 0.380, 'BARLEY': 0.313, 'OAT': 0.532, 'CALFMILK': 0.7}
GRASS = 4.37 * 10000 * 3
MAIZE_SILAGE = 0.92 * 7.8 * 10000
YIELD = {'DRYGRASS_WINDROW': GRASS, 'GRASS_WINDROW': GRASS, 'SILAGE': MAIZE_SILAGE, 'WHEAT': 8900, 'MAIZE': 9200,
         'BARLEY': 9600, 'OAT': 5700}


def land(liters):  # ha x years of crop for these liters
    total = 0
    for name, amount in liters.items():
        if name == 'FORAGE':
            total += amount * (0.5 / GRASS + 0.5 / MAIZE_SILAGE)
        elif name in YIELD:
            total += amount / YIELD[name]
    return total


def cost(liters):
    return sum(amount * PRICE.get(name, 0) for name, amount in liters.items())


started = time.time()
finish = []
bulls = plain(R.subTypes('male'))
for name in bulls:
    for route in ['TMR', 'SILAGE', 'HAY', 'GRASS', 'HAY_MAIZE', 'SILAGE_MAIZE', 'GRASS_MAIZE', 'HAY_WHEAT', 'TMR_MAIZE']:
        finish.append(plain(R.finish(name, route, True)))
    for route in ['TMR', 'SILAGE', 'HAY', 'GRASS']:
        finish.append(plain(R.finish(name, route, False)))
for row in finish:
    years = max(row['months'], 1e-9) / 12
    row['feedCost'] = cost(row['liters'])
    row['landHaYears'] = land(row['liters'])
    row['landHaPerHeadYear'] = row['landHaYears'] / years
    row['costPerKgGain'] = row['feedCost'] / row['gainKg'] if row['gainKg'] > 0 else None

dairy = []
for name in ['COW_HOLSTEIN', 'COW_SWISS_BROWN', 'COW_JERSEY_PACK', 'COW_ANGUS', 'COW_WATERBUFFALO']:
    if name not in definitions:
        continue
    for route in ['TMR', 'SILAGE', 'HAY', 'GRASS', 'TMR_MAIZE']:
        dairy.append(plain(R.dairy(name, route, True)))
    for route in ['TMR', 'HAY']:
        dairy.append(plain(R.dairy(name, route, False)))
for row in dairy:
    row['feedCost'] = cost(row['liters'])
    row['landHaPerHeadYear'] = land(row['liters'])

calves = [plain(R.calf(name)) for name in ['BULL_HOLSTEIN', 'COW_HOLSTEIN', 'BULL_ANGUS', 'BULL_JERSEY_PACK'] if name in definitions]
invariance = plain(R.invariance())
ledger = plain(R.ledger)
config = plain(lua.eval('RLFeedProfiles.getConfig()'))

json.dump({'repo': str(REPO), 'head': head, 'dirty': bool(dirty), 'seconds': time.time() - started, 'feedHash': config['hash'], 'resourceScale': config['resourceScale'],
           'ledger': ledger, 'finish': finish, 'dairy': dairy, 'calves': calves, 'invariance': invariance},
          open(OUT / 'results.json', 'w'), ensure_ascii=False, indent=1, default=str)

with open(OUT / 'finish.csv', 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['subType', 'breed', 'mode', 'route', 'reached', 'months', 'finishAge', 'startKg', 'endKg', 'referenceKg', 'gainKg',
                'kgDM', 'kgDMPerKgGain', 'dmiPctBW', 'concShare', 'proteinFactor', 'lastLimit', 'litersTotal', 'litersPerKgGain',
                'feedCost', 'costPerKgGain', 'landHaPerHeadYear', 'finishScore', 'minHealth', 'liters'])
    for r in finish:
        w.writerow([r['subType'], r['breed'], r['mode'], r['route'], r['reached'], round(r['months'], 3), round(r['finishAge'], 3),
                    round(r['startKg'], 1), round(r['endKg'], 1), r.get('referenceKg'), round(r['gainKg'], 1), r.get('kgDM') and round(r['kgDM'], 1),
                    r.get('kgDMPerKgGain') and round(r['kgDMPerKgGain'], 2), r.get('dmiPctBW') and round(r['dmiPctBW'], 2),
                    r.get('concShare') and round(r['concShare'], 3), r.get('proteinFactor') and round(r['proteinFactor'], 2), r.get('lastLimit'),
                    round(r['litersTotal'], 1), r.get('litersPerKgGain') and round(r['litersPerKgGain'], 2), round(r['feedCost'], 1),
                    r.get('costPerKgGain') and round(r['costPerKgGain'], 3), round(r['landHaPerHeadYear'], 4), round(r['finishScore'], 1),
                    r['minHealth'], json.dumps({k: round(v, 1) for k, v in r['liters'].items()})])

with open(OUT / 'dairy.csv', 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['subType', 'mode', 'route', 'milkShare', 'milkPaidL', 'milkPotentialL', 'bcsStart', 'bcsMin', 'bcsEnd', 'endKg', 'health',
                'kgDM', 'litersTotal', 'feedCost', 'landHaPerHeadYear', 'liters'])
    for r in dairy:
        w.writerow([r['subType'], r['mode'], r['route'], round(r['milkShare'], 3), round(r['milkPaidL'], 1), round(r['milkPotentialL'], 1),
                    round(r['bcsStart'], 2), round(r['bcsMin'], 2), round(r['bcsEnd'], 2), round(r['endKg'], 1), r['health'],
                    r.get('kgDM') and round(r['kgDM'], 1), round(r['litersTotal'], 1), round(r['feedCost'], 1), round(r['landHaPerHeadYear'], 4),
                    json.dumps({k: round(v, 1) for k, v in r['liters'].items()})])

with open(OUT / 'calves.csv', 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['subType', 'month', 'weightKg', 'development', 'milkL', 'tmrL', 'health'])
    for c in calves:
        for m in c['months']:
            w.writerow([c['subType'], m['month'], round(m['weightKg'], 1), round(m['development'], 2), round(m['milkL'], 2), round(m['tmrL'], 2), m['health']])

with open(OUT / 'invariance.csv', 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['scale', 'daysPerMonth', 'weightKg', 'hayL', 'maizeL', 'health', 'adapted'])
    for r in invariance:
        w.writerow([r['scale'], r['days'], round(r['weightKg'], 4), round(r['hayL'], 2), round(r['maizeL'], 2), r['health'], round(r['adapted'], 4)])

print('head', head, 'dirty', bool(dirty), 'seconds', round(time.time() - started, 1), 'ledger', ledger)
