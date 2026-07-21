#!/usr/bin/env python3
"""bestOCR external-tool adapter for CnOCR (OCR protocol v1). See rapidocr
adapter docstring for the contract."""
import argparse
import json
import sys


def probe() -> None:
    try:
        import cnocr  # noqa: F401
        from cnocr import CnOcr  # noqa: F401
        version = getattr(cnocr, "__version__", "unknown")
        if not isinstance(version, str):  # cnocr exposes a module here
            version = getattr(version, "__version__", "unknown")
        print(json.dumps({"protocol": 1, "ok": True, "tool": "cnocr", "version": str(version)}))
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"protocol": 1, "ok": False, "reason": f"{type(exc).__name__}: {exc}"}))


def ocr(image: str, lang: str) -> None:
    from cnocr import CnOcr
    engine = CnOcr()
    lines = engine.ocr(image)
    texts = [str(line.get("text", "")) for line in lines if isinstance(line, dict)]
    print(json.dumps({"protocol": 1, "text": "\n".join(t for t in texts if t)}))


def main() -> None:
    parser = argparse.ArgumentParser(prog="bestocr-cnocr-adapter")
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
