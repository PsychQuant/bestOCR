# External reference repos

Read-only clones of upstream OCR-engine source, kept for reading and adapter
alignment — **not vendored**. `references/repos/` is gitignored (clone-on-demand,
matching the macdoc `reference/*` convention); only this README is tracked.

## Repos

| Path | Upstream | Why it's here |
|------|----------|---------------|
| `repos/surya` | github.com/datalab-to/surya | The engine behind bestOCR's `ext.surya` adapter (protocol-v1). Reference for the layout/detection/recognition model API and output schema. ⚠️ 0.17.x and 0.22.x (surya-2) are different architectures — see #29 before assuming which one a clone matches. |
| `repos/marker` | github.com/datalab-to/marker | datalab's PDF→Markdown converter built *on* surya. No longer only a design comparison point: since #16 it is an **admitted engine**, `doc.marker`, driven through the `marker_single` CLI. Reference for its JSON renderer schema and CLI options. |
| `repos/chandra` | github.com/datalab-to/chandra | Chandra OCR 2 — datalab's OCR **VLM** (image/PDF → HTML/Markdown/JSON, layout-preserving). A candidate model for the article's VLM comparison and a reference for structured-output OCR. |

All three are the same org (datalab-to). **Licensing differs**: surya and
marker are Apache-2.0 (code); chandra's *code* is Apache-2.0 but its *model
weights* are OpenRAIL-M (not Apache) — relevant if chandra is admitted as a
benchmark model. Swift-port siblings of the pipeline engines live in the
`ocr-swift` dependency chain (`marker-swift`, `surya-swift`).

## Re-clone

```bash
mkdir -p references/repos && cd references/repos
git clone --depth 1 https://github.com/datalab-to/surya.git
git clone --depth 1 https://github.com/datalab-to/marker.git
git clone --depth 1 https://github.com/datalab-to/chandra.git
```

Shallow (`--depth 1`) is intentional — these are for reading current source, not
history. Add `--depth N` or `git fetch --unshallow` if you need history/tags.

## Which copy to read for version-specific behaviour

These clones track **upstream HEAD**, which is not necessarily the version
installed on the machine. When the question is "what does the tool actually do
here" — adapter alignment, a failure mode, a CLI flag's default — read the
**installed** copy instead:

```bash
head -1 "$(command -v marker_single)"        # → the venv that owns the CLI
ls -d <venv>/lib/*/site-packages/<pkg>-*.dist-info   # → its real version
```

That distinction is not academic: `doc.marker`'s adapter deliberately passes no
`--mode`, because the installed marker 2.0's `config/parser.py` shows the default
is **device-dependent** (`fast`, i.e. CPU layout detectors, on CPU/MPS) — which
is what keeps layout out of llama.cpp's grammar path. That was read from the
installed venv, not from this clone.
