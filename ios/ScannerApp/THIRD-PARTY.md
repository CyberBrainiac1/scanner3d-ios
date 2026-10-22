# Capture source reuse

MoviePart.swift follows the AVAssetWriter/HEVC/pixel-buffer-adaptor structure in Stray Scanner's
Helpers/VideoEncoder.swift, pinned at ec3e1dc9d33f8df2289ede6a5c59f7991d1a6bbb (https://github.com/strayrobots/scanner;
the unchanged snapshot is kept privately under ../upstream and recorded in ../UPSTREAM.json).
The upstream snapshot is unchanged. Our recording layout, timestamp handling, close barrier and
durable catalog are adaptations for contracts/stream/README.md. The full original notice follows.

MIT License

Copyright 2023 Stray Robots, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
