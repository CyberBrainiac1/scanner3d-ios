"""Inspect a prepared unsigned feasibility IPA; this does not prove signing or launch."""
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import zipfile
from pathlib import Path, PurePosixPath


def inspect(path: Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        names = [item.filename for item in infos]
        if len(names) != len(set(names)):
            raise ValueError("IPA contains duplicate entries")
        for name in names:
            parts = PurePosixPath(name).parts
            if not parts or name.startswith("/") or ".." in parts or "\\" in name:
                raise ValueError("Unsafe archive member")
        app_plists = [name for name in names if name.startswith("Payload/") and name.count("/") == 2 and name.endswith(".app/Info.plist")]
        if len(app_plists) != 1:
            raise ValueError("Expected one Payload/*.app/Info.plist")
        info = plistlib.loads(archive.read(app_plists[0]))
        app_root = app_plists[0].removesuffix("Info.plist")
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable or "/" in executable or "\\" in executable or executable in (".", ".."):
            raise ValueError("Invalid CFBundleExecutable")
        if app_root + executable not in names:
            raise ValueError("Missing app executable")
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise ValueError("Not a physical-device iPhoneOS app")
        if info.get("CFBundleIdentifier") != "org.scanner3d.capture":
            raise ValueError("Unexpected feasibility bundle identifier")
        if info.get("MinimumOSVersion") != "18.6":
            raise ValueError("Upstream minimum OS unexpectedly changed")
        if not info.get("NSCameraUsageDescription"):
            raise ValueError("Missing camera usage description")
        if app_root + "embedded.mobileprovision" in names or any(name.startswith(app_root) and "/_CodeSignature/" in name for name in names):
            raise ValueError("Expected an unsigned archive without provisioning/signatures")
        if archive.testzip() is not None:
            raise ValueError("ZIP integrity check failed")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return {
        "artifact": path.name,
        "bytes": path.stat().st_size,
        "sha256": digest.hexdigest(),
        "bundle_identifier": info["CFBundleIdentifier"],
        "minimum_ios": info["MinimumOSVersion"],
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "status": "unsigned-metadata-inspected; compilation/signing/device proof separate",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.ipa)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
