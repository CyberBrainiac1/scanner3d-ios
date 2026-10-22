"""Select an already installed, non-beta Xcode whose iOS SDK supports the app's deployment target.

The runner's default Xcode can be older than the unchanged iOS 18.6 target; this never installs anything.
Prints the chosen Developer directory (for DEVELOPER_DIR) and its iOS SDK version.
"""
import argparse
import re
from pathlib import Path

MINIMUM_SDK = (18, 6)


def version(text):
    return tuple(int(part) for part in text.split('.'))


def select(candidates, minimum=MINIMUM_SDK):
    """candidates: iterable of (developer_dir, app_name, [iOS SDK versions as 'major.minor'])."""
    choices = []
    for developer, name, sdks in candidates:
        if re.search(r'beta|release.?candidate|_rc\b', name, re.IGNORECASE):
            continue
        for sdk in sdks:
            if version(sdk) >= minimum:
                choices.append((version(sdk), name, developer, sdk))
    if not choices:
        raise ValueError('No installed non-beta Xcode has an iOS SDK at 18.6 or newer.')
    best = sorted(choices, reverse=True)[0]
    return best[2], best[3]


def installed(applications=Path('/Applications')):
    seen = set()
    for app in sorted(applications.glob('Xcode*.app')):
        real = app.resolve()
        if real in seen:
            continue
        seen.add(real)
        developer = real / 'Contents/Developer'
        sdk_dir = developer / 'Platforms/iPhoneOS.platform/Developer/SDKs'
        sdks = [m.group(1) for p in sdk_dir.glob('iPhoneOS*.sdk') if (m := re.fullmatch(r'iPhoneOS(\d+\.\d+)\.sdk', p.name))]
        yield str(developer), app.name, sdks


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--applications', type=Path, default=Path('/Applications'))
    args = parser.parse_args()
    developer, sdk = select(installed(args.applications))
    print(developer, sdk)
