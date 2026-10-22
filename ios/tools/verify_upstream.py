"""Verify the unmodified Stray source snapshot, using only the standard library."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path


def verify(ios_root: Path) -> int:
    manifest = json.loads((ios_root / "UPSTREAM.json").read_text(encoding="utf-8"))
    root = ios_root / "upstream"
    expected = {entry["path"]: entry for entry in manifest["files"]}
    actual = {path.relative_to(root).as_posix(): path for path in root.rglob("*") if path.is_file()}
    errors = [f"Missing: {name}" for name in expected.keys() - actual.keys()]
    errors += [f"Unexpected: {name}" for name in actual.keys() - expected.keys()]
    for name in expected.keys() & actual.keys():
        data = actual[name].read_bytes()
        record = expected[name]
        git_hash = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
        if len(data) != record["bytes"] or hashlib.sha256(data).hexdigest() != record["sha256"] or git_hash != record["git_blob_sha1"]:
            errors.append(f"Modified: {name}")
    if errors:
        raise SystemExit("Upstream verification failed:\n" + "\n".join(sorted(errors)))
    print(f"PASS: {len(expected)} original files match Stray {manifest['tag']} at {manifest['commit']}.")
    return len(expected)


if __name__ == "__main__":
    verify(Path(__file__).resolve().parents[1])
