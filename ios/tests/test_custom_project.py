"""Preparation checks only. These do not execute Swift or prove an app can run."""
import importlib.util
import plistlib
import unittest
from pathlib import Path
import xml.etree.ElementTree as ET

IOS = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


class CustomProjectTests(unittest.TestCase):
    def test_generated_project_is_current_and_scheme_uses_our_app_and_tests(self):
        generated = module('project', IOS / 'ScannerApp/tools/generate_project.py').generate()
        for relative, text in generated.items():
            self.assertEqual((IOS / 'ScannerApp' / relative).read_text(encoding='utf-8'), text)
        scheme = ET.fromstring(generated['ScannerApp.xcodeproj/xcshareddata/xcschemes/ScannerApp.xcscheme'])
        refs = [item.attrib['BlueprintName'] for item in scheme.findall('.//BuildableReference')]
        self.assertIn('ScannerApp', refs)
        self.assertIn('ScannerAppTests', refs)
        self.assertNotIn('StrayScanner', refs)

    def test_sensor_permissions_and_local_network_only_transport(self):
        info = plistlib.loads((IOS / 'ScannerApp/App/Info.plist').read_bytes())
        for key in ('NSCameraUsageDescription', 'NSMotionUsageDescription', 'NSLocalNetworkUsageDescription'):
            self.assertTrue(info[key])
        self.assertEqual(info['NSAppTransportSecurity'], {'NSAllowsLocalNetworking': True})
        self.assertNotIn('NSBonjourServices', info)
        self.assertEqual(info['UIApplicationSceneManifest']['UIApplicationSupportsMultipleScenes'], False)

    def test_simulator_selection_rejects_old_missing_and_unavailable(self):
        choose = module('simulator', IOS / 'tools/select_simulator.py').select
        old = {'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-18-5': [{'name': 'iPhone 16', 'udid': 'old', 'isAvailable': True}]}}
        with self.assertRaises(ValueError): choose(old)
        with self.assertRaises(ValueError): choose({'devices': {}})
        old['devices']['com.apple.CoreSimulator.SimRuntime.iOS-26-0'] = [
            {'name': 'iPhone 17', 'udid': 'good', 'isAvailable': True},
            {'name': 'iPhone 18', 'udid': 'missing', 'isAvailable': False}]
        self.assertEqual(choose(old), 'good')


if __name__ == '__main__': unittest.main()
