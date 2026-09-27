"""Print the static feeding economics of tests/economics.lua: bulls on four rations, pigs, rams, dairy.

    python tests/economics.py                 # current rules and xml/animals.xml
    python tests/economics.py --legacy FILE   # pre-breed-traits rules on an older animals.xml

Needs lupa (pip install lupa).
"""
import os
import sys

import lupa

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)


def main():
    legacy = "--legacy" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--legacy"]
    animals = os.path.abspath(args[0]) if args else os.path.join(REPO, "xml", "animals.xml")

    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.REPO = REPO + "/"
    g.ANIMALS_XML = animals
    g.LEGACY = legacy
    g.REPORT = True
    for name in ("stubs.lua", "economics.lua"):
        with open(os.path.join(TESTS, name), encoding="utf-8") as f:
            lua.execute(f.read())
    for line in g.LOG.values():
        if "safeCall" in line or line.startswith("error"):
            print(line)


if __name__ == "__main__":
    main()
