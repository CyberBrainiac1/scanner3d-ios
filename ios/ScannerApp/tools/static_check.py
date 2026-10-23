"""Static sanity pass for UNBUILT Swift sources (Windows has no Swift compiler).

Checks, per .swift file under ios/StreamingCore and ios/ScannerApp:
- (), [], {} balance with awareness of comments, "..." and \"\"\"...\"\"\" strings and \\( ) interpolation;
- every `import X` is a module this project is allowed to use.
This is NOT a compile. It only catches truncated files and gross typos.
Usage: python -I ios/ScannerApp/tools/static_check.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ALLOWED_IMPORTS = {
    "Foundation", "CryptoKit", "Network", "XCTest", "ScannerStreamingCore", "PackageDescription",
    "SwiftUI", "UIKit", "ARKit", "AVFoundation", "CoreMotion", "CoreImage", "CoreVideo", "Accelerate",
    "Security", "Combine", "os", "Darwin", "ImageIO", "UniformTypeIdentifiers", "SceneKit", "simd",
    "ScannerApp", "Observation", "VisionKit",
    "WebKit",  # hot-updatable UI bundle in a WKWebView (docs/PHONE-UI-AND-DEBUG.md)
}
PAIRS = {")": "(", "]": "[", "}": "{"}


def balance(text: str) -> str:
    stack: list[tuple[str, int]] = []
    modes = ["code"]
    interpolation: list[tuple[int, str]] = []
    i, n, line = 0, len(text), 1
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
        mode = modes[-1]
        if mode == "code":
            if text.startswith("//", i):
                j = text.find("\n", i)
                i = n if j < 0 else j
                continue
            if text.startswith("/*", i):
                j = text.find("*/", i)
                if j < 0:
                    return f"unterminated block comment at line {line}"
                line += text[i:j].count("\n")
                i = j + 2
                continue
            if text.startswith('"""', i):
                modes.append("ml")
                i += 3
                continue
            if c == '"':
                modes.append("str")
                i += 1
                continue
            if c in "([{":
                stack.append((c, line))
            elif c in ")]}":
                if not stack or stack[-1][0] != PAIRS[c]:
                    return f"mismatched {c!r} at line {line}"
                stack.pop()
                if c == ")" and interpolation and interpolation[-1][0] == len(stack):
                    modes.append(interpolation.pop()[1])
            i += 1
            continue
        # inside a string literal
        if c == "\\" and i + 1 < n and text[i + 1] == "(":
            stack.append(("(", line))
            interpolation.append((len(stack) - 1, mode))
            modes.pop()
            i += 2
            continue
        if c == "\\":
            i += 2
            continue
        if mode == "str" and c == '"':
            modes.pop()
        elif mode == "str" and c == "\n":
            return f"unterminated string at line {line - 1}"
        elif mode == "ml" and text.startswith('"""', i):
            modes.pop()
            i += 3
            continue
        i += 1
    if len(modes) != 1:
        return "unterminated string at end of file"
    return "ok" if not stack else f"unclosed {stack[-1][0]!r} opened at line {stack[-1][1]}"


def main() -> int:
    ios = Path(__file__).resolve().parents[2]
    failures = 0
    files = sorted(list((ios / "StreamingCore").rglob("*.swift")) + list((ios / "ScannerApp").rglob("*.swift")))
    for path in files:
        text = path.read_text(encoding="utf-8")
        result = balance(text)
        bad_imports = [m for m in re.findall(r"^\s*(?:@testable\s+)?import\s+(\w+)", text, re.M)
                       if m not in ALLOWED_IMPORTS]
        if result != "ok" or bad_imports:
            failures += 1
            print(f"FAIL {path.relative_to(ios)}: {result}; unexpected imports {bad_imports}")
        else:
            print(f"ok   {path.relative_to(ios)}")
    print(f"{len(files)} files, {failures} failing. Static only: NOT a Swift compile.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
