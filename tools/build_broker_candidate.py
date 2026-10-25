"""Build and verify the installable candidate using the release workflow's file set."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ("modDesc.xml", "LICENSE", "icon_RealisticLivestock.dds")
DIRS = ("animals", "fonts", "gui", "mod_support", "objects", "scripts", "translations", "xml")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "diff", "--check"], cwd=ROOT, check=True)
    files = [ROOT / name for name in FILES]
    for name in DIRS:
        files.extend(p for p in (ROOT / name).rglob("*") if p.is_file() and not p.name.startswith("."))
    files.sort()
    archive = out / "FS25_RealisticLivestockF2M.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as handle:
        for path in files:
            handle.write(path, path.relative_to(ROOT).as_posix())
    with zipfile.ZipFile(archive) as handle:
        assert handle.testzip() is None
        assert "modDesc.xml" in handle.namelist()
        assert len(handle.namelist()) == len(set(handle.namelist())) == len(files)
        for path in files:
            data = handle.read(path.relative_to(ROOT).as_posix())
            assert data == path.read_bytes(), f"source changed while packaging: {path}"
            if path.suffix == ".xml":
                ET.fromstring(data)
    sha = hashlib.sha256(archive.read_bytes()).hexdigest()
    version = ET.parse(ROOT / "modDesc.xml").findtext("version")
    manifest = {
        "version": version,
        "candidate": True,
        "basePR": 95,
        "baseCommit": "a5bf1ec53e96b14d93cfb368087df630d2011b1a",
        "implementationCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "modelEvidenceDigest": json.loads((ROOT / "docs/evidence/broker-cattle-release.json").read_text())["sourceDigest"],
        "sha256": sha,
        "files": len(files),
        "scope": "single player / Angus weaned calves / farm pickup",
        "gameValidated": False,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (out / "SHA256SUMS").write_text(f"{sha}  {archive.name}\n")
    print(json.dumps(manifest, indent=2))
    print(archive)


if __name__ == "__main__":
    main()
