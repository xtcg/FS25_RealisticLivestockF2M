"""Run the Lua tests in tests/test_*.lua against tests/stubs.lua.

Each test file runs in a fresh Lua 5.4 state (via lupa) with REPO set to the repository root,
so it can loadMod() real mod scripts. Exits non-zero when any check fails.

    pip install lupa
    python tests/run.py
"""
import glob
import os
import sys
import xml.etree.ElementTree as ET

import lupa

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)


def run(path):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().REPO = REPO + "/"
    # Repository-relative paths of the .lua files under a directory (Lua has no directory listing here).
    lua.globals().listRepoLua = lambda sub: lua.table_from(sorted(
        os.path.relpath(p, REPO) for p in glob.glob(os.path.join(REPO, sub, "**", "*.lua"), recursive=True)))
    with open(os.path.join(TESTS, "stubs.lua"), encoding="utf-8") as f:
        lua.execute(f.read())
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
    print(f"{total - failed}/{total} passed")
    return 1 if failed or total == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
