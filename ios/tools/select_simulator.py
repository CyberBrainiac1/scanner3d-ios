"""Select an already installed simulator; never downloads, creates or boots a device."""
import argparse
import json
import re
from pathlib import Path


def select(document, newest=None):
    """newest: optional (major, minor) iOS SDK of the selected Xcode; newer runtimes are skipped."""
    choices = []
    for runtime, devices in document.get('devices', {}).items():
        match = re.search(r'\.iOS-(\d+)-(\d+)(?:-(\d+))?$', runtime)
        if not match:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        if version < (18, 6, 0) or (newest is not None and version[:2] > tuple(newest)):
            continue
        for device in devices:
            if device.get('isAvailable') is True and device.get('name', '').startswith('iPhone'):
                choices.append((version, device['name'], device['udid']))
    if not choices:
        raise ValueError('No existing iPhone simulator at iOS18.6 or newer. Preserve sources; select a compatible Xcode/runtime before testing.')
    return sorted(choices, reverse=True)[0][2]


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('inventory', type=Path)
    parser.add_argument('--sdk', help='iOS SDK version of the selected Xcode, e.g. 26.2')
    args = parser.parse_args()
    newest = tuple(int(part) for part in args.sdk.split('.')[:2]) if args.sdk else None
    print(select(json.loads(args.inventory.read_text()), newest))
