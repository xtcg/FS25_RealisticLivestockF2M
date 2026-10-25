"""Run the Lua tests in tests/test_*.lua against tests/stubs.lua.

Each test file runs in a fresh Lua 5.4 state (via lupa) with REPO set to the repository root,
so it can loadMod() real mod scripts. It then runs tests/check_structure.py (source order, global
collisions, private copies of the shared primitives). Exits non-zero when any check fails.

    pip install lupa
    python tests/run.py
"""
import glob
import os
import sys
import xml.etree.ElementTree as ET

from lua_test_support import new_runtime
import check_structure
import lupa

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)


def run(path):
    lua = new_runtime()
    with open(path, encoding="utf-8") as f:
        lua.execute(f.read())
    return [(r["name"], r["ok"]) for r in lua.globals().RESULTS.values()]


def main():
    # The Lua XML stub is permissive; validate syntax with a standard parser first.
    ET.parse(os.path.join(REPO, "xml", "breedTraits.xml"))
    failed = 0
    total = 0
    for path in sorted(glob.glob(os.path.join(TESTS, "test_*.lua"))):
        print(f"== {os.path.basename(path)}")
        for name, ok in run(path):
            total += 1
            failed += not ok
            print(f"  {'PASS' if ok else 'FAIL'} {name}")
    # Source order, global collisions and private copies of the shared primitives (tests/check_structure.py).
    print("== check_structure")
    for message in check_structure.check() or ["source order, collisions and shared primitives ok"]:
        ok = message == "source order, collisions and shared primitives ok"
        total += 1
        failed += not ok
        print(f"  {'PASS' if ok else 'FAIL'} {message}")
    print(f"{total - failed}/{total} passed")
    return 1 if failed or total == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
