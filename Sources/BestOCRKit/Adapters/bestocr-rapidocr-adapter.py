#!/usr/bin/env python3
"""bestOCR external-tool adapter for RapidOCR (OCR protocol v1).

probe        -> {"protocol":1,"ok":true,"tool":"rapidocr","version":"..."} (exit 0)
                {"protocol":1,"ok":false,"reason":"..."}                    (exit 0)
ocr --image  -> {"protocol":1,"text":"..."}; failure: non-zero exit + stderr.

Containment (bestASR design D3): upstream churn breaks THIS file, never the
host. The host reads only the LAST stdout line, so download noise is safe.
"""
import argparse
import json
import sys


def probe() -> None:
    try:
        import rapidocr
        version = getattr(rapidocr, "__version__", "unknown")
        print(json.dumps({"protocol": 1, "ok": True, "tool": "rapidocr", "version": version}))
    except Exception as exc:  # noqa: BLE001 — probe reports, never raises
        print(json.dumps({"protocol": 1, "ok": False, "reason": f"{type(exc).__name__}: {exc}"}))


def ocr(image: str, lang: str) -> None:
    from rapidocr import RapidOCR
    engine = RapidOCR()
    result = engine(image)
    texts: list[str] = []
    if result is not None:
        txts = getattr(result, "txts", None)
        if txts:
            texts = [t for t in txts if t]
        elif isinstance(result, (list, tuple)):  # older tuple-shaped outputs
            for item in result:
                if isinstance(item, (list, tuple)) and len(item) >= 2:
                    texts.append(str(item[1]))
    print(json.dumps({"protocol": 1, "text": "\n".join(texts)}))


def main() -> None:
    parser = argparse.ArgumentParser(prog="bestocr-rapidocr-adapter")
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
