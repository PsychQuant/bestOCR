/// Embedded adapter scripts (M3): the released bestocr / bestocr-mcp is ONE
/// binary, so protocol-v1 adapters ship as string constants and materialize
/// to ~/.bestocr/adapters/ on first use (BESTOCR_ADAPTER_DIR overrides).
/// Source of truth: these constants; the original .py files live in git
/// history (pre-M3) and are regenerated here verbatim.
enum AdapterScripts {
    static func script(for tool: String) -> String? {
        switch tool {
        case "rapidocr": return rapidocr
        case "cnocr": return cnocr
        case "surya": return surya
        default: return nil
        }
    }

    static let rapidocr = #"""
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
"""#

    static let cnocr = #"""
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
"""#

    static let surya = #"""
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
"""#

}
