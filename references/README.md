# External reference repos

Read-only clones of upstream OCR-engine source, kept for reading and adapter
alignment — **not vendored**. `references/repos/` is gitignored (clone-on-demand,
matching the macdoc `reference/*` convention); only this README is tracked.

## Repos

| Path | Upstream | Why it's here |
|------|----------|---------------|
| `repos/surya` | github.com/datalab-to/surya | The engine behind bestOCR's `ext.surya` adapter (protocol-v1). Reference for the layout/detection/recognition model API and output schema. |
| `repos/marker` | github.com/datalab-to/marker | datalab's PDF→Markdown converter built *on* surya. Reference for document-level assembly (reading order, tables, math) — a design comparison point for bestOCR's own markdown assembly. |

Both are Apache-2.0, same org (datalab-to). Swift-port siblings live in the
`ocr-swift` dependency chain (`marker-swift`, `surya-swift`).

## Re-clone

```bash
mkdir -p references/repos && cd references/repos
git clone --depth 1 https://github.com/datalab-to/surya.git
git clone --depth 1 https://github.com/datalab-to/marker.git
```

Shallow (`--depth 1`) is intentional — these are for reading current source, not
history. Add `--depth N` or `git fetch --unshallow` if you need history/tags.
