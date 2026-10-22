"""Export/check XCTest inputs from the existing Python contract reference.

This exercises the Python reference only, NEVER compiles or executes Swift.
--write modifies only this package's synthetic Fixtures directory.
"""
from __future__ import annotations
import argparse
import base64
from dataclasses import asdict
import hashlib
import json
from pathlib import Path
import sys

PACKAGE = Path(__file__).resolve().parents[1]
ROOT = PACKAGE.parents[1]
REFERENCE = ROOT / "contracts" / "stream" / "reference"
sys.path.insert(0, str(REFERENCE))
import preview_codec as ref


def encoded(data):
    return base64.b64encode(data).decode("ascii")


def resources():
    frames = []
    output = {}
    for name, frame in ref.golden_frames().items():
        binary = ref.encode_preview(frame)
        assert binary == (REFERENCE / "golden" / name).read_bytes(), f"Reference golden differs: {name}"
        output[name] = binary
        rgb = None if frame.rgb is None else {"jpeg": encoded(frame.rgb.data), "intrinsics": asdict(frame.rgb.intrinsics)}
        depth = None if frame.depth is None else {
            "codec": 1 if frame.depth.codec == "f32" else 2,
            "bytes": encoded(frame.depth.values.astype("<f4" if frame.depth.codec == "f32" else "<u2").tobytes()),
            "intrinsics": asdict(frame.depth.intrinsics),
            "scaleMetersPerUnit": frame.depth.scale_m_per_unit,
        }
        frames.append({"expectedFile": name, "sessionID": frame.session_id, "segment": frame.segment,
                       "frameID": frame.frame_id, "previewSequence": frame.preview_seq,
                       "deviceTime": frame.t_device_s, "sentTime": frame.t_device_sent_s,
                       "cameraToWorld": frame.camera_to_world.reshape(-1).tolist(),
                       "trackingState": {"not_available": 0, "limited": 1, "normal": 2}[frame.tracking_state],
                       "trackingReason": {"none": 0, "initializing": 1, "excessive_motion": 2,
                                          "insufficient_features": 3, "relocalizing": 4, "unknown": 255}[frame.tracking_reason],
                       "source": asdict(frame.source_intrinsics),
                       "scaling": 0 if frame.intrinsics_scaling == "multiplicative" else 1,
                       "rgb": rgb, "depth": depth,
                       "confidence": None if frame.confidence is None else encoded(frame.confidence.tobytes()),
                       "flags": int(frame.depth_original_saved) | (int(frame.still_captured) << 1) | (int(frame.depth_smoothed) << 2)})
    chunk_binary = ref.golden_chunk()
    assert chunk_binary == (REFERENCE / "golden" / "chunk_v1_last.s3dc").read_bytes()
    chunk = ref.decode_chunk(chunk_binary, 65536)
    output["chunk_v1_last.s3dc"] = chunk_binary
    vectors = {"frames": frames, "chunk": {"sessionID": chunk.session_id, "fileID": chunk.file_id,
               "index": chunk.chunk_index, "chunkBytes": 65536, "payload": encoded(chunk.payload),
               "last": chunk.last, "expectedFile": "chunk_v1_last.s3dc"}}
    output["vectors.json"] = (json.dumps(vectors, indent=2, allow_nan=False) + "\n").encode("utf-8")
    # Byte-identical contract copies: goldens, the stream JSON examples and the shared RFC 8785 (JCS) vectors.
    for golden in sorted((REFERENCE / "golden").iterdir()):
        if golden.is_file():
            output["golden/" + golden.name] = golden.read_bytes()
    for example in sorted((ROOT / "contracts" / "stream" / "examples").glob("*.json")):
        output["examples/" + example.name] = example.read_bytes()
    for negative in sorted((ROOT / "contracts" / "stream" / "negative").glob("pairing.qr--*.json")):
        output["negative/" + negative.name] = negative.read_bytes()
    output["jcs_vectors.json"] = (ROOT / "workers" / "tests" / "data" / "jcs_vectors.json").read_bytes()
    output["reference.json"] = (json.dumps({"reference_sha256": hashlib.sha256((REFERENCE / "preview_codec.py").read_bytes()).hexdigest(),
        "status": "Python reference vectors only; Swift remains UNBUILT",
        "files": {name: hashlib.sha256(data).hexdigest() for name, data in output.items()}}, indent=2) + "\n").encode("utf-8")
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    destination = PACKAGE / "Tests" / "ScannerStreamingCoreTests" / "Fixtures"
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in resources().items():
        target = destination / name
        if args.write:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        elif not target.exists() or target.read_bytes() != data:
            raise SystemExit(f"Fixture differs/missing: {target}. Review the contract change before --write.")
    print("PASS: 2 preview vectors + 1 chunk match Python golden bytes; goldens, stream examples and JCS vectors "
          "are byte-identical copies. Swift NOT compiled.")
