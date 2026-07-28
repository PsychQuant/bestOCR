/// Embedded protocol-v1 **assemble** adapters (document-assembly spec §8).
/// Same distribution story as `AdapterScripts`: the released binary is one
/// file, so adapters ship as string constants and materialize to
/// `~/.bestocr/adapters/` on first use.
///
/// Contract (extends OCR protocol v1):
///
///     probe                       -> {"protocol":1,"ok":true,"tool":…,"version":…}
///     assemble --image A [--image B …]
///                                 -> {"protocol":1,
///                                     "load_seconds": 12.3 | null,
///                                     "pages":  [{"page":1,"text":…,"seconds":4.2}],
///                                     "blocks": [{"page":1,"kind":"header","text":…,
///                                                 "bbox":{"x":…,"y":…,"width":…,"height":…}}]}
///
/// Two rules the adapters must honour, because the host enforces them:
/// 1. `pages[i].text` is built by joining that page's blocks in reading order,
///    so the spec §4.3 invariant holds by construction.
/// 2. `seconds` is reported ONLY when it is a real warm per-page measurement.
///    In `.perPage` invocation mode it is omitted and the host times the call.
enum DocumentAdapterScripts {
    static func script(for tool: String) -> String? {
        switch tool {
        case "marker": return marker
        case "paddleocr-pipeline": return paddleOCRPipeline
        default: return nil
        }
    }

    static let marker = #"""
#!/usr/bin/env python3
"""bestOCR assemble adapter for marker 2.0 (OCR protocol v1).

Drives the `marker_single` CLI — deliberately NOT `import marker`, because
marker lives in its own uv-tool venv that the host's python cannot import.

Mode: marker's own device default is used (no `--mode` flag). On Apple Silicon
that is `fast`, which uses CPU layout detectors instead of the VLM layout model,
keeping layout OUT of llama.cpp's json_schema -> GBNF path — the path that
degraded marker's reading order in bestOCR issue #15's `--mode balanced` runs.
Set BESTOCR_MARKER_MODE to force `balanced` or `fast` explicitly.
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
from html.parser import HTMLParser

# marker block_type -> bestOCR BlockKind
KIND_MAP = {
    "SectionHeader": "heading",
    "Title": "heading",
    "Text": "paragraph",
    "TextInlineMath": "paragraph",
    "Caption": "paragraph",
    "Footnote": "paragraph",
    "Reference": "paragraph",
    "ListGroup": "list",
    "ListItem": "list",
    "Table": "table",
    "TableGroup": "table",
    "TableCell": "table",
    "Form": "table",
    "Figure": "figure",
    "FigureGroup": "figure",
    "Picture": "figure",
    "PictureGroup": "figure",
    "Diagram": "figure",
    "Equation": "formula",
    "PageHeader": "header",
    "PageFooter": "footer",
}


def probe() -> None:
    cli = shutil.which("marker_single")
    if cli is None:
        print(json.dumps({"protocol": 1, "ok": False,
                          "reason": "marker_single not on PATH"}))
        return
    print(json.dumps({"protocol": 1, "ok": True, "tool": "marker",
                      "version": marker_version(cli)}))


def marker_version(cli: str) -> str:
    """Read the version from the venv's dist-info rather than importing marker
    (which the host's interpreter cannot do) or shelling out to --version
    (which would load torch)."""
    try:
        with open(cli, encoding="utf-8") as handle:
            shebang = handle.readline().strip()
        interpreter = shebang[2:] if shebang.startswith("#!") else ""
        venv = os.path.dirname(os.path.dirname(interpreter))
        for path in glob.glob(os.path.join(venv, "lib", "*", "site-packages",
                                           "marker_pdf-*.dist-info")):
            return os.path.basename(path).split("-")[1].replace(".dist-info", "")
    except Exception:  # noqa: BLE001 — a missing version must not fail a probe
        pass
    return "unknown"


class TextExtractor(HTMLParser):
    """marker's JSON carries HTML per block. Tags are dropped, <br> becomes a
    newline, and <math> is re-emitted as LaTeX in $ delimiters — marker's math
    fidelity is the whole reason this engine is admitted, so it must survive."""

    BLOCK_TAGS = {"p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "blockquote"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.math_depth = 0
        self.math_display = False
        self.math_parts = []

    def handle_starttag(self, tag, attrs):
        if tag == "math":
            self.math_depth += 1
            if self.math_depth == 1:
                self.math_display = dict(attrs).get("display") == "block"
                self.math_parts = []
            return
        if tag == "br":
            self.parts.append("\n")
        elif tag in self.BLOCK_TAGS and self.parts and self.parts[-1] != "\n":
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag == "math" and self.math_depth > 0:
            self.math_depth -= 1
            if self.math_depth == 0:
                latex = "".join(self.math_parts).strip()
                fence = "$$" if self.math_display else "$"
                if latex:
                    self.parts.append(fence + latex + fence)
            return
        if tag in self.BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data):
        if self.math_depth > 0:
            self.math_parts.append(data)
        else:
            self.parts.append(data)

    def text(self) -> str:
        joined = "".join(self.parts)
        lines = [" ".join(line.split()) for line in joined.split("\n")]
        return "\n".join(line for line in lines if line)


def html_to_text(html: str) -> str:
    parser = TextExtractor()
    parser.feed(html)
    parser.close()
    return parser.text()


def normalized_bbox(bbox, page_bbox):
    """marker reports [x1,y1,x2,y2] in page pixels; the host contract is
    normalized [0,1] page coordinates."""
    try:
        px1, py1, px2, py2 = page_bbox
        width, height = float(px2 - px1), float(py2 - py1)
        if width <= 0 or height <= 0:
            return None
        x1, y1, x2, y2 = bbox
        return {"x": (x1 - px1) / width, "y": (y1 - py1) / height,
                "width": (x2 - x1) / width, "height": (y2 - y1) / height}
    except Exception:  # noqa: BLE001 — geometry is optional, never fatal
        return None


def leaf_blocks(node, page_bbox, out) -> None:
    """Depth-first in child order — marker's child order IS reading order, and
    the host's DocumentStructure keeps that as its only ordering source."""
    children = node.get("children")
    block_type = str(node.get("block_type", ""))
    kind = KIND_MAP.get(block_type, "other")

    # Tables keep their native HTML: converting to a markdown pipe table would
    # silently drop colspan/rowspan, and a lossy table is worse than an honest
    # one the consumer can parse.
    if kind == "table":
        html = node.get("html") or ""
        text = html.strip() if html.strip() else ""
        if text:
            out.append({"kind": "table", "text": text,
                        "bbox": normalized_bbox(node.get("bbox"), page_bbox)})
        return

    if children:
        for child in children:
            leaf_blocks(child, page_bbox, out)
        return

    text = html_to_text(node.get("html") or "")
    if text:
        out.append({"kind": kind, "text": text,
                    "bbox": normalized_bbox(node.get("bbox"), page_bbox)})


def convert(image: str) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        command = ["marker_single", image, "--output_format", "json",
                   "--output_dir", tmp]
        mode = os.environ.get("BESTOCR_MARKER_MODE", "").strip()
        if mode:
            command += ["--mode", mode]
        proc = subprocess.run(command, capture_output=True, text=True)
        if proc.returncode != 0:
            print(proc.stderr[-2000:], file=sys.stderr)
            sys.exit(1)
        paths = sorted(glob.glob(os.path.join(tmp, "**", "*.json"), recursive=True))
        if not paths:
            print("marker_single produced no JSON output", file=sys.stderr)
            sys.exit(1)
        with open(paths[0], encoding="utf-8") as handle:
            return json.load(handle)


def assemble(images: list) -> None:
    blocks = []
    for offset, image in enumerate(images, start=1):
        document = convert(image)
        for page_node in document.get("children") or []:
            page_bbox = page_node.get("bbox") or [0, 0, 0, 0]
            page_blocks = []
            leaf_blocks(page_node, page_bbox, page_blocks)
            for block in page_blocks:
                block["page"] = offset
            blocks.extend(page_blocks)

    pages = []
    for offset in range(1, len(images) + 1):
        # Page text IS the joined block text, in reading order: that is what
        # makes the host's spec-4.3 invariant true by construction.
        texts = [b["text"] for b in blocks if b["page"] == offset]
        pages.append({"page": offset, "text": "\n\n".join(texts)})

    # No `seconds`: marker_single reloads its models on every invocation, so
    # there is no warm per-page time to report. The host measures the call.
    print(json.dumps({"protocol": 1, "load_seconds": None,
                      "pages": pages, "blocks": blocks}))


def main() -> None:
    parser = argparse.ArgumentParser(prog="bestocr-marker-adapter")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("probe")
    p_asm = sub.add_parser("assemble")
    p_asm.add_argument("--image", action="append", required=True)
    p_asm.add_argument("--lang", default="")
    args = parser.parse_args()
    if args.command == "probe":
        probe()
        return
    try:
        assemble(args.image)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
"""#

    static let paddleOCRPipeline = #"""
#!/usr/bin/env python3
"""bestOCR assemble adapter for the PaddleOCR document pipeline (protocol v1).

PP-DocLayoutV2 layout detection -> crop -> VL recognition -> assemble. The
layout stage is a DETECTION model, not a grammar-constrained VLM call, which is
why this pipeline gets reading order right on Apple Silicon where marker's
balanced-mode VLM layout does not (bestOCR #15).

The pipeline object is built ONCE and each page timed after it, so the reported
per-page seconds are warm — matching `speed.ms_per_page@v1`. Load time is
reported separately in `load_seconds` rather than folded into page 1.
"""
import argparse
import json
import sys
import time

# PaddleX block_label -> bestOCR BlockKind
KIND_MAP = {
    "doc_title": "heading",
    "paragraph_title": "heading",
    "figure_title": "heading",
    "table_title": "heading",
    "chart_title": "heading",
    "abstract": "paragraph",
    "content": "paragraph",
    "text": "paragraph",
    "number": "paragraph",
    "aside_text": "paragraph",
    "reference": "paragraph",
    "reference_content": "paragraph",
    "footnote": "paragraph",
    "formula": "formula",
    "table": "table",
    "image": "figure",
    "figure": "figure",
    "chart": "figure",
    "seal": "figure",
    "header": "header",
    "header_image": "header",
    "footer": "footer",
    "footer_image": "footer",
}


def pipeline_class():
    """PaddleOCR renamed its document pipeline across 3.x. Try the VL pipeline
    first (what #15 measured), then PP-StructureV3."""
    import paddleocr
    for name in ("PaddleOCRVL", "PPStructureV3"):
        cls = getattr(paddleocr, name, None)
        if cls is not None:
            return name, cls
    raise ImportError("neither PaddleOCRVL nor PPStructureV3 found in paddleocr")


def probe() -> None:
    try:
        import paddleocr
        name, _ = pipeline_class()
        version = getattr(paddleocr, "__version__", "unknown")
        print(json.dumps({"protocol": 1, "ok": True, "tool": "paddleocr-pipeline",
                          "version": f"{version} ({name})"}))
    except Exception as exc:  # noqa: BLE001 — probe reports, never raises
        print(json.dumps({"protocol": 1, "ok": False,
                          "reason": f"{type(exc).__name__}: {exc}"}))


def page_size(image: str):
    try:
        from PIL import Image
        with Image.open(image) as handle:
            return float(handle.width), float(handle.height)
    except Exception:  # noqa: BLE001 — geometry is optional
        return None, None


def normalized_bbox(bbox, width, height):
    if not bbox or not width or not height:
        return None
    try:
        x1, y1, x2, y2 = [float(v) for v in list(bbox)[:4]]
        return {"x": x1 / width, "y": y1 / height,
                "width": (x2 - x1) / width, "height": (y2 - y1) / height}
    except Exception:  # noqa: BLE001
        return None


def result_dict(item):
    """Paddle's result objects have moved between `.json`, `.json["res"]` and
    plain dicts across releases; accept any of them rather than pinning one."""
    for candidate in (getattr(item, "json", None), item):
        if isinstance(candidate, dict):
            if isinstance(candidate.get("res"), dict):
                return candidate["res"]
            return candidate
    return {}


def parsing_list(res: dict):
    for key in ("parsing_res_list", "parsing_result_list", "layout_parsing_result"):
        value = res.get(key)
        if isinstance(value, list):
            return value
    return []


def blocks_for(image: str, results) -> list:
    width, height = page_size(image)
    out = []
    for item in results:
        res = result_dict(item)
        for entry in parsing_list(res):
            if not isinstance(entry, dict):
                continue
            label = str(entry.get("block_label") or entry.get("label") or "")
            content = entry.get("block_content")
            if content is None:
                content = entry.get("content") or entry.get("text") or ""
            text = str(content).strip()
            if not text:
                continue
            out.append({"kind": KIND_MAP.get(label, "other"), "text": text,
                        "bbox": normalized_bbox(entry.get("block_bbox")
                                                or entry.get("bbox"), width, height)})
    return out


def assemble(images: list) -> None:
    t0 = time.monotonic()
    _, cls = pipeline_class()
    pipeline = cls()
    load_seconds = time.monotonic() - t0

    pages, blocks = [], []
    for offset, image in enumerate(images, start=1):
        start = time.monotonic()
        results = pipeline.predict(image)
        if not isinstance(results, list):
            results = list(results)
        elapsed = time.monotonic() - start

        page_blocks = blocks_for(image, results)
        for block in page_blocks:
            block["page"] = offset
        blocks.extend(page_blocks)
        # Page text IS the joined block text, in reading order (host invariant).
        pages.append({"page": offset, "seconds": elapsed,
                      "text": "\n\n".join(b["text"] for b in page_blocks)})

    print(json.dumps({"protocol": 1, "load_seconds": load_seconds,
                      "pages": pages, "blocks": blocks}))


def main() -> None:
    parser = argparse.ArgumentParser(prog="bestocr-paddleocr-pipeline-adapter")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("probe")
    p_asm = sub.add_parser("assemble")
    p_asm.add_argument("--image", action="append", required=True)
    p_asm.add_argument("--lang", default="")
    args = parser.parse_args()
    if args.command == "probe":
        probe()
        return
    try:
        assemble(args.image)
    except Exception as exc:  # noqa: BLE001
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
"""#
}
