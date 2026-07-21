#!/usr/bin/env python3
"""bestOCR external-tool adapter for surya (OCR protocol v1).

Wraps the `surya_ocr` CLI (0.17.x): runs it into a temp dir, then extracts
every text line from the result JSON, whatever its exact nesting."""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile


def probe() -> None:
    try:
        import surya  # noqa: F401
        if shutil.which("surya_ocr") is None:
            print(json.dumps({"protocol": 1, "ok": False,
                              "reason": "surya importable but surya_ocr CLI not on PATH"}))
            return
        version = getattr(surya, "__version__", "unknown")
        print(json.dumps({"protocol": 1, "ok": True, "tool": "surya", "version": str(version)}))
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"protocol": 1, "ok": False, "reason": f"{type(exc).__name__}: {exc}"}))


def collect_text(node) -> list:
    out = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "text_lines" and isinstance(value, list):
                out.extend(str(line.get("text", "")) for line in value if isinstance(line, dict))
            else:
                out.extend(collect_text(value))
    elif isinstance(node, list):
        for item in node:
            out.extend(collect_text(item))
    return out


def ocr(image: str, lang: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        proc = subprocess.run(["surya_ocr", image, "--output_dir", tmp],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            print(proc.stderr[-2000:], file=sys.stderr)
            sys.exit(1)
        texts = []
        for path in sorted(glob.glob(os.path.join(tmp, "**", "*.json"), recursive=True)):
            with open(path, encoding="utf-8") as handle:
                texts.extend(collect_text(json.load(handle)))
        print(json.dumps({"protocol": 1, "text": "\n".join(t for t in texts if t)}))


def main() -> None:
    parser = argparse.ArgumentParser(prog="bestocr-surya-adapter")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("probe")
    p_ocr = sub.add_parser("ocr")
    p_ocr.add_argument("--image", required=True)
    p_ocr.add_argument("--lang", default="")
    args = parser.parse_args()
    if args.command == "probe":
        probe()
        return
    try:
        ocr(args.image, args.lang)
    except Exception as exc:  # noqa: BLE001
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
