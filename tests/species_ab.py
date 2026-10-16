"""Exact A/B of every type but cattle (pigs, goats, horses, chickens, sheep on the shipped config:
sheep v2 off) against an immutable local git revision; no network or game writes.

Run: python tests/species_ab.py --baseline bbb4573 --out /path/to/result.json
The probe (tests/species_ab.lua) runs the real modules of each tree in separate Lua 5.1 runtimes.
"""
import argparse
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

from sheep_s5_ab import fingerprint, probe

REPO = Path(__file__).resolve().parents[1]


def extract(sha, temp):
    archive = subprocess.check_output(["git", "archive", sha], cwd=REPO)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar.getmembers():
            relative = Path(member.name)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError(member.name)
            if member.isfile():
                target = Path(temp) / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(tar.extractfile(member).read())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    sha = subprocess.check_output(["git", "rev-parse", args.baseline], cwd=REPO, text=True).strip()
    source = (REPO / "tests/species_ab.lua").read_text()
    with tempfile.TemporaryDirectory(prefix="species-ab-") as temp:
        extract(sha, temp)
        before, after = probe(Path(temp), source), probe(REPO, source)
    diffs, expected = [], []
    for left, right in zip(before, after):
        for key in sorted(left.keys() | right.keys()):
            a, b = left.get(key), right.get(key)
            equal = a.hex() == b.hex() if isinstance(a, float) and isinstance(b, float) else a == b
            if not equal:
                row = {"case": left["case"], "field": key, "before": a, "after": b}
                # The one intended change: the SHEEP type has a feed section now, so its pen is
                # judged on its animals (sheep v2 off: UNCOVERED_ANIMAL) rather than refused by
                # type (NOT_CATTLE). It stays out of the mode either way.
                if (key == "reason" and a == "NOT_CATTLE" and b == "UNCOVERED_ANIMAL"
                        and left.get("active") is False and right.get("active") is False):
                    expected.append(row)
                else:
                    diffs.append(row)
    types = sorted({row["case"].split("/")[1] for row in after})
    result = {"baseline": sha, "runtime": "Lua 5.1", "cases": len(after), "subtypes": types,
              "scalarComparisons": sum(len(r) for r in after), "differences": diffs[:200], "differenceCount": len(diffs),
              "expectedDifferences": len(expected),
              "expectedNote": "SHEEP-type pens: reason NOT_CATTLE -> UNCOVERED_ANIMAL, inactive before and after",
              "baselineSHA256": fingerprint(before), "candidateSHA256": fingerprint(after),
              "scope": "every non-cattle subtype x ages 1/6/30 x food 0.3/1.0 x legacy/real mode; 48 hours of updateHealth; pen evaluation",
              "passed": len(before) == len(after) and len(after) > 0 and not diffs}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "differences"}, ensure_ascii=False))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
