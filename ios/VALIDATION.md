# M0-X1 local validation — October 21, 2026

Status: prepared for Claude review; **hosted compilation, signing, installation and refresh not run**.

- Downloaded the public Stray Scanner v1.4 source archive pinned to commit `ec3e1dc9d33f8df2289ede6a5c59f7991d1a6bbb`. Archive SHA-256: `d0090b2bace6c28f4147d24d474f1c633a5e818a350348d7c44505cd1f06fa3f`.
- Independently fetched GitHub's recursive Git tree and verified all **101** copied source files against their Git blob IDs. Recorded exact bytes/SHA-256/blob ID in `UPSTREAM.json`; no original files changed.
- `python ios/tools/verify_upstream.py`: **PASS, 101 files**. Re-run before and after the hosted build.
- `python -m unittest discover -s ios/tests -v`: **5 tests passed** (multiple rejection vectors). These exercise the unsigned IPA metadata inspector with synthetic ZIP archives. They do not execute an app or verify Mach-O linking.
- Git for Windows Bash, `bash -n ios/tools/build_unsigned.sh`: **PASS**. Syntax only; Windows cannot run the Xcode commands.
- Parsed `.github/workflows/ios-feasibility.yml` with the already-installed default Python/PyYAML `BaseLoader` and checked manual-dispatch-only, `contents: read`, `macos-15` and the three expected steps: **PASS**. The Open3D venv does not have PyYAML; no package was installed to fix that. Parsing is not a hosted Actions workflow run or actionlint validation.
- Checked upstream workspace references (app and vendored Pods project), shared scheme `StrayScanner`, physical iOS SDK setting, Release target minimum **18.6**, existing camera usage string and license. Action SHA pins were resolved from the official `actions/checkout` v4.2.2 and `actions/upload-artifact` v4.6.2 tag APIs.

Remaining evidence: Claude cross-review, approved exact repository/publication, actual GitHub macOS job and artifact inspection; then the user's phone OS/install/recording/refresh proof. Xcode/compiler compatibility, resource packaging and AltStore free-signing behavior remain open.
