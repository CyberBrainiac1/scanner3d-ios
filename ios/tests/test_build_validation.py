"""Packaging rejection tests; never compile, sign, install or execute an app."""
from __future__ import annotations

import importlib.util
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("inspect_ipa", Path(__file__).resolve().parents[1] / "tools" / "inspect_ipa.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


class PackagingTests(unittest.TestCase):
    def make_ipa(self, root: Path, *, edits=None, extra=None, executable=True):
        info = {
            "CFBundleExecutable": "StrayScanner",
            "CFBundleIdentifier": "org.scanner3d.capture",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "MinimumOSVersion": "18.6",
            "NSCameraUsageDescription": "Record RGB-D for the feasibility test.",
        }
        info.update(edits or {})
        path = root / "example.ipa"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Payload/StrayScanner.app/Info.plist", plistlib.dumps(info))
            if executable:
                archive.writestr("Payload/StrayScanner.app/StrayScanner", b"fixture-not-an-executable")
            for name, value in (extra or {}).items():
                archive.writestr(name, value)
        return path

    def test_metadata_only_success_is_explicit(self):
        with tempfile.TemporaryDirectory() as temp:
            result = module.inspect(self.make_ipa(Path(temp)))
            self.assertEqual(result["minimum_ios"], "18.6")
            self.assertIn("compilation/signing/device proof separate", result["status"])

    def test_rejects_simulator_wrong_id_and_changed_minimum(self):
        for edits in ({"CFBundleSupportedPlatforms": ["iPhoneSimulator"]},
                      {"CFBundleIdentifier": "dev.keke.StrayScanner"},
                      {"MinimumOSVersion": "14.2"}):
            with self.subTest(edits=edits), tempfile.TemporaryDirectory() as temp:
                with self.assertRaises(ValueError):
                    module.inspect(self.make_ipa(Path(temp), edits=edits))

    def test_rejects_missing_executable(self):
        with tempfile.TemporaryDirectory() as temp, self.assertRaises(ValueError):
            module.inspect(self.make_ipa(Path(temp), executable=False))

    def test_rejects_signed_or_provisioned_archive(self):
        for filename in ("embedded.mobileprovision", "_CodeSignature/CodeResources"):
            with self.subTest(filename=filename), tempfile.TemporaryDirectory() as temp:
                with self.assertRaises(ValueError):
                    module.inspect(self.make_ipa(Path(temp), extra={"Payload/StrayScanner.app/" + filename: b"fixture"}))

    def test_rejects_traversal_duplicate_app_and_missing_camera_purpose(self):
        for extra, edits in (({"../unexpected": b""}, {}),
                             ({"Payload/Other.app/Info.plist": b""}, {}),
                             ({}, {"NSCameraUsageDescription": ""})):
            with self.subTest(extra=extra, edits=edits), tempfile.TemporaryDirectory() as temp:
                with self.assertRaises(ValueError):
                    module.inspect(self.make_ipa(Path(temp), edits=edits, extra=extra))


if __name__ == "__main__":
    unittest.main()
