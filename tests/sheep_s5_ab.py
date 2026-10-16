"""Exact cattle A/B against an immutable local git revision; no network or game writes.

Run: python tests/sheep_s5_ab.py --out /path/to/result.json
The same Lua probe executes the real adapters from each tree in separate Lua 5.1 runtimes.
This is a numerical regression check, not sheep nutrition calibration or a game test.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

from lupa.lua51 import LuaRuntime

REPO = Path(__file__).resolve().parents[1]
BASE = "f9a6d9369cf66fcfeb441af3943c4c3e4cd9cbd0"


def probe(repo, source):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("table.unpack = unpack; load = loadstring")
    lua.globals().REPO = str(repo) + "/"
    lua.globals().listRepoLua = lambda sub: lua.table_from(sorted(
        str(p.relative_to(repo)) for p in (repo / sub).rglob("*.lua")))
    lua.execute((repo / "tests/stubs.lua").read_text())
    lua.execute(source)
    errors = [v for v in lua.globals().LOG.values() if v.startswith(("error", "safeCall", "warning"))]
    if errors:
        raise RuntimeError(errors)
    return [dict(row.items()) for row in lua.globals().AB_ROWS.values()]


def fingerprint(rows):
    return hashlib.sha256(json.dumps(rows, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default=BASE)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    sha = subprocess.check_output(["git", "rev-parse", args.baseline], cwd=REPO, text=True).strip()
    source = (REPO / "tests/sheep_s5_ab.lua").read_text()
    archive = subprocess.check_output(["git", "archive", sha], cwd=REPO)
    with tempfile.TemporaryDirectory(prefix="sheep-s5-ab-") as temp:
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            # Python 3.9-compatible extraction of regular git files only.
            for member in tar.getmembers():
                relative = Path(member.name)
                if relative.is_absolute() or ".." in relative.parts:
                    raise ValueError(member.name)
                if member.isfile():
                    target = Path(temp) / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(tar.extractfile(member).read())
        before, after = probe(Path(temp), source), probe(REPO, source)
    diffs = []
    for left, right in zip(before, after):
        for key in sorted(left.keys() | right.keys()):
            a, b = left.get(key), right.get(key)
            # Float.hex checks the represented value exactly, including signed zero.
            equal = a.hex() == b.hex() if isinstance(a, float) and isinstance(b, float) else a == b
            if not equal:
                diffs.append({"case": left["case"], "field": key, "before": a, "after": b})
    result = {"baseline": sha, "runtime": "Lua 5.1", "cases": len(after),
              "scalarComparisons": sum(len(r) for r in after), "differences": diffs,
              "baselineSHA256": fingerprint(before), "candidateSHA256": fingerprint(after),
              "scope": "22 cattle profiles x 2 sexes x 3 genes x 3 stages; 120 budget steps per case",
              "passed": len(before) == len(after) == 396 and not diffs}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
