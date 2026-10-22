# iPhone application — current source status

**Owner: Codex, by direct full takeover. Native source is UNBUILT. No IPA, signing, installation, live capture or renewal has been tested.**

`ScannerApp/` is now our custom SwiftUI application target. It connects to `StreamingCore/`, the existing protocol/state-machine package. `upstream/` remains the unchanged, verified Stray reference; do not deliver the historical upstream feasibility application as our scanner.

Prepared source includes bounded ARKit capture, raw float depth/confidence, independently timestamped accelerometer/gyro logs, high-resolution JPEG stills with their own calibration, fragmented HEVC parts, an append-only durable closed-file catalog, pinned TLS, Keychain credentials, two WebSockets, resumable originals, preview flow control, local scan listing, pairing confirmation and background close handling. Files are never automatically deleted. JPEG stills at quality0.95 are used for reliable Windows OpenCV decoding without adding a new phone app or codec installation. Available still depth is preserved separately but is not yet used by hybrid fusion.

Windows photo-only preparation can consume these stills using their own poses/intrinsics. Current hybrid uses video-associated RGB/depth; it rejects a still-prepared dataset until calibrated depth reprojection is implemented and validated. Raw IMU is retained as a diagnostic stream, not counted as independent proof of ARKit accuracy.

Local preparation checks: `python -m unittest discover -s ios/tests -v`, `python ios/ScannerApp/tools/generate_project.py --check`, `python -I ios/ScannerApp/tools/static_check.py`, and `python ios/tools/verify_upstream.py`. These do not execute Swift. XCTest source covers storage integrity, incomplete journals, read-only file behavior, CSV rotation, pose storage, rates, stale completion and writer replacement; **native XCTest has not run**.

The prepared custom-app Mac route is `ios/tools/build_scanner_unsigned.sh` and `.github/workflows/ios-scanner.yml`. It runs StreamingCore tests, simulator app tests, then archives and inspects an unsigned physical-device IPA. The scheme/project are generated deterministically without installing an extra generator. Running hosted CI/publication remains paused. No Mac compiler is available on this Windows host. Preserve sources and fix actual native diagnostics once that route is authorized.

Saved recordings now have **prepared, UNBUILT** recovery inspection source. A damaged file catalog stays visible in Scans; `Check saved files` checks catalog identity, closed-file sizes/SHA-256, unlisted originals and unfinished files. It runs off the UI thread, checks cancellation between hash chunks and file entries, and offers a shareable diagnostic report. It never repairs a partial journal, fabricates an end marker, closes an unfinished video, uploads a partial file or removes originals. A hash match is file-integrity evidence, not reconstruction/physical-accuracy evidence. Native regression test source covers these cases, including corrupt/duplicate catalogs, symlinks, cancellation, bounded detail counts and unchanged bytes; **those XCTest cases have not run**.

Remaining native validation/features include real compilation, device permissions/camera behavior/thermal/storage/clock testing, actual interrupted-session salvage/repair, explicitly confirmed local removal after fresh PC verification, actual pairing/upload/reconnect interoperation, and visual comparison with approved `ui/README.md`. The proposed hardware rates and accuracy are unmeasured. See `docs/INSTALL-IPHONE.md` for the prepared direct AltServer Shift-click route: only our app goes on the phone, with manual renewal; its actual installation/retained-data cycle is untested.

Apple references: [high-resolution ARFrame capture](https://developer.apple.com/documentation/arkit/arsession/capturehighresolutionframe(completion:)), [movie fragments](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval), [writer session timestamps](https://developer.apple.com/documentation/avfoundation/avassetwriter/startsession(atsourcetime:)). `ScannerApp/THIRD-PARTY.md` retains the Stray notice.

## Historical M0-X1 upstream feasibility preparation

Owner: Codex. Reviewer: Claude. Status: **locally prepared; no macOS build or phone install has run**.

`upstream/` is the byte-for-byte Stray Scanner v1.4 source snapshot at commit `ec3e1dc9d33f8df2289ede6a5c59f7991d1a6bbb` (MIT, original notice in `upstream/LICENSE.md`). It includes the upstream shared Xcode scheme and vendored, empty CocoaPods project. Do not run `pod update` or regenerate dependencies for this baseline.

No upstream source, project settings or UI is modified for M0. `UPSTREAM.json` records every original file's SHA-256 and Git blob ID. `python ios/tools/verify_upstream.py` verifies the exact set and contents before every build. The source archive download/hash is recorded there too.

## Prepared CI

`.github/workflows/ios-feasibility.yml` is manual-dispatch only. It uses the standard `macos-15` runner, pinned checkout/upload actions, read-only repository permissions and no Apple credentials/secrets. GitHub documents standard public macOS runners as free; the repository must actually be public before running this no-paid route.

The script `ios/tools/build_unsigned.sh`:

1. Checks source integrity and logs selected Xcode/SDK/toolchain versions.
2. Archives the existing `StrayScanner` workspace/scheme for a generic physical iOS device with signing disabled. Only build-time overrides remove the original developer team/signing identity and use `org.scanner3d.capture` as a local feasibility bundle identifier.
3. Packages `Payload/StrayScanner.app` into an unsigned IPA, inspects its metadata, and writes artifact hashes. Logs, build settings, archive metadata and binary architectures remain reviewable.

The upstream application target requires **iOS 18.6** even though the repository Podfile mentions 14.2. Confirm the actual phone OS before installation. Do not lower the target or change capture code just to conceal a build/install incompatibility. This baseline still displays the upstream Stray Scanner name/UI; the approved Inspo interface comes later.

## M0-X1 completion evidence

- Claude cross-review of the source provenance, workflow and build script.
- The exact public repository/file list approved through Claude before publication.
- A successful hosted build log plus inspected unsigned IPA and SHA-256. Local Python checks are not an Xcode compile.

## M0-X2 device proof (not yet performed)

Historical feasibility instructions are superseded by the single-phone-app route in docs/INSTALL-IPHONE.md. Do not install AltStore Classic on the phone. Actual signing/install/recording/renewal remains paused and untested; the custom target above is the intended app.

Keep recordings and device/account identifiers out of this source folder/public artifacts. The baseline does not yet stream, so local-network permission and transport changes belong to the later custom fork.

References: [Stray source](https://github.com/strayrobots/scanner/tree/ec3e1dc9d33f8df2289ede6a5c59f7991d1a6bbb), [GitHub runner conditions](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [AltStore Windows guide](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows).
