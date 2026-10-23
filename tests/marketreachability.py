"""Measure Broker package windows over existing physiology without changing it.

    python3 tests/marketreachability.py --output /private/tmp/market-windows.json

This is measurement, not a production admission catalog or an economic/MP test.
Missing published policy facts remain unknown and prevent admission. Each scenario
gets a fresh runtime so nutrition caches and animal clocks cannot leak across runs.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import lupa

ROOT = Path(__file__).resolve().parents[1]


ARRAY_FIELDS = {"packages", "completeWindows", "measuredWindows", "unknownCapabilities", "observedFailureCodes"}


def plain(value, field=None):
    if lupa.lua_type(value) != "table":
        return value
    keys = list(value.keys())
    if (keys or field in ARRAY_FIELDS) and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
        return [plain(value[k]) for k in sorted(keys)]
    return {str(k): plain(value[k], str(k)) for k in keys}


def measure(options, hashes=None):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().REPO = str(ROOT) + "/"
    def record(path):
        if hashes is not None:
            relative = str(Path(path).resolve().relative_to(ROOT))
            checksum = hashlib.sha256(Path(path).read_bytes()).hexdigest()
            assert relative not in hashes or hashes[relative] == checksum, "SOURCE_CHANGED_DURING_SCAN"
            hashes[relative] = checksum

    lua.globals().recordMeasurementSource = record
    record(ROOT / "tests/stubs.lua")
    lua.execute((ROOT / "tests/stubs.lua").read_text())
    record(ROOT / "tests/marketreachability.lua")
    lua.execute((ROOT / "tests/marketreachability.lua").read_text())
    return plain(lua.globals().MarketReachability.cattle(lua.table_from(options)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--months", type=int, default=36, choices=range(1, 49))
    parser.add_argument("--subtype", action="append")
    parser.add_argument("--mode", action="append", choices=("REAL", "LEGACY"))
    args = parser.parse_args()
    names = args.subtype or ["BULL_SWISS_BROWN", "BULL_HOLSTEIN", "BULL_ANGUS", "BULL_LIMOUSIN", "BULL_HEREFORD", "BULL_HIGHLAND_CATTLE", "BULL_WATERBUFFALO"]
    hashes = {str(Path(__file__).relative_to(ROOT)): hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    report = {"schemaVersion": 1, "verificationType": "PHYSIOLOGY_MEASUREMENT_ONLY", "admissionReady": False,
              "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "sourceSha256": hashes, "scenarios": []}
    for name in names:
        for mode in args.mode or ["REAL", "LEGACY"]:
            for castrated in (False, True):
                options = {"subTypeName": name, "months": args.months, "mode": mode, "castrated": castrated}
                row = measure(options, hashes)
                report["scenarios"].append(row)
                print(name, mode, "castrated" if castrated else "intact", [(p["packageId"], p["status"]) for p in row["packages"]], flush=True)
    # Detect any concurrent source edit; an artifact must describe one file set.
    assert all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == h for p, h in hashes.items()), "SOURCE_CHANGED_DURING_SCAN"
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"Wrote {len(report['scenarios'])} measured scenarios to {args.output}")


if __name__ == "__main__":
    main()
