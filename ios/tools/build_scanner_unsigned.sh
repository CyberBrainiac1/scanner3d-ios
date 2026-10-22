#!/usr/bin/env bash
# Prepared macOS-only route for OUR app. Do not confuse with the historical upstream feasibility build.
# No credentials, signing, phone connection, installation or publication.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_root="${BUILD_ROOT:-${RUNNER_TEMP:-/tmp}/scanner3d-native-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}}"
if [[ -e "$build_root" ]]; then
  echo "Refusing to reuse existing evidence directory: $build_root" >&2
  exit 2
fi
mkdir -p "$build_root/artifacts" "$build_root/packaging/Payload"
cd "$repo_root"
if [ -d ios/upstream ]; then python3 ios/tools/verify_upstream.py; else echo "ios/upstream not in this checkout (public repo); provenance pinned in ios/UPSTREAM.json"; fi
python3 ios/ScannerApp/tools/generate_project.py --check
python3 ios/ScannerApp/tools/static_check.py
python3 -m unittest discover -s ios/tests -v
{
  xcodebuild -version
  xcode-select -p
  xcodebuild -showsdks
  sw_vers
} > "$build_root/artifacts/toolchain.txt"

# Pure streaming state-machine tests first. Network.framework and CryptoKit are available on macOS.
swift test --package-path ios/StreamingCore --scratch-path "$build_root/StreamingCoreBuild" \
  2>&1 | tee "$build_root/artifacts/streaming-tests.log"

# Pick an available iPhone simulator with a runtime >= the app's unchanged 18.6 deployment target.
xcrun simctl list devices available --json > "$build_root/artifacts/simulators.json"
sim_id=$(python3 ios/tools/select_simulator.py "$build_root/artifacts/simulators.json")
settings=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=)
common=(-project ios/ScannerApp/ScannerApp.xcodeproj -scheme ScannerApp -derivedDataPath "$build_root/DerivedData")
xcodebuild "${common[@]}" -configuration Debug -destination "platform=iOS Simulator,id=$sim_id" \
  "${settings[@]}" -resultBundlePath "$build_root/AppTests.xcresult" test \
  2>&1 | tee "$build_root/artifacts/app-tests.log"

xcodebuild "${common[@]}" -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  "${settings[@]}" -showBuildSettings > "$build_root/artifacts/build-settings.txt"
xcodebuild "${common[@]}" -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  "${settings[@]}" -archivePath "$build_root/ScannerApp.xcarchive" \
  -resultBundlePath "$build_root/Archive.xcresult" archive \
  2>&1 | tee "$build_root/artifacts/xcodebuild.log"

app="$build_root/ScannerApp.xcarchive/Products/Applications/ScannerApp.app"
test -d "$app"
xcrun lipo -archs "$app/ScannerApp" > "$build_root/artifacts/binary-architectures.txt"
grep -qw arm64 "$build_root/artifacts/binary-architectures.txt"
ditto "$app" "$build_root/packaging/Payload/ScannerApp.app"
(
  cd "$build_root/packaging"
  ditto -c -k --sequesterRsrc --keepParent Payload "$build_root/artifacts/Scanner3D-unsigned.ipa"
)
python3 ios/tools/inspect_ipa.py "$build_root/artifacts/Scanner3D-unsigned.ipa" --out "$build_root/artifacts/ipa-inspection.json"
cp ios/UPSTREAM.json "$build_root/artifacts/upstream-provenance.json"
cp ios/ScannerApp/THIRD-PARTY.md "$build_root/artifacts/THIRD-PARTY.md"
if [ -d ios/upstream ]; then python3 ios/tools/verify_upstream.py; else echo "ios/upstream not in this checkout (public repo); provenance pinned in ios/UPSTREAM.json"; fi
echo "Unsigned custom-app artifact prepared. Device signing/install/capture/renewal remain UNTESTED."
