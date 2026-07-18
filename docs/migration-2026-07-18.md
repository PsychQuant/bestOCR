# Migration record — MeasureOCR: macdoc/cli → bestOCR umbrella (2026-07-18)

One-page audit trail for the instrument's relocation. Everything here was
executed on 2026-07-18/19; all commands verified at execution time.

## Why

1. **Identity follows purpose, not dependency.** macdoc is document tooling
   (Word/OOXML, PDF→LaTeX). MeasureOCR consumes the macdoc-family library
   `ocr-swift` but *is* a research instrument (benchmark → TSV → ANOVA). Its
   home under `macdoc/cli/` was an accident of where the prototype started.
2. **Product-family symmetry.** bestOCR is a product line (benchmark →
   evidence → recommendation) parallel to bestASR — an umbrella of its own,
   not a subdirectory of a tools repo.
3. **Pre-registration timing.** article 1's OSF freeze bakes the instrument
   path/pin into the pre-registration. Moving *before* the freeze means the
   frozen references are final; moving after would be a deviation.

The design decision that made this a zero-risk move was made in June 2026:
MeasureOCR depends on `ocr-swift` as a **published SPM package**
(`PsychQuant/ocr-swift`), not a relative path into macdoc — so physical
location never mattered to the build.

## What moved, exactly

| Step | Action | Verification |
|------|--------|--------------|
| 1 | GitHub repo renamed `PsychQuant/FastOCR` → `PsychQuant/measureOCR` (`gh repo rename`; old URL redirects) | rename confirmed |
| 2 | Local remote re-pointed + 3 unpushed commits pushed (`689ba0a`, `a3c987e`, `3f8f5ab`) | `aa99d14..3f8f5ab main -> main` |
| 3 | macdoc: submodule entry `cli/FastOCR` removed (`.gitmodules` section + gitlink + local config; no absorbed gitdir existed under `.git/modules/`) | macdoc commit `ae6aa3f` |
| 4 | Working tree moved wholesale: `macdoc/cli/MeasureOCR` → `bestOCR/repos/measureOCR` (`.git` is a full directory, history intact) | post-move `HEAD = 3f8f5ab` |
| 5 | bestOCR umbrella `git init` + `git submodule add https://github.com/PsychQuant/measureOCR.git repos/measureOCR` (absorbed the existing checkout) | `git submodule status` → `3f8f5ab … (heads/main)` |
| 6 | macdoc `CLAUDE.md` submodule table + sub-repo prose updated; migration pointer note added | commit `ae6aa3f` |
| 7 | article side: 8 path references updated across `README.md` (theme root), `article1-vlm-ocr-anova/{CLAUDE.md, README.md, TODO.md}`; decisions-log entry added | article1 `9ee103b`, theme root `b83818e` |

## What did NOT change

- **The pinned instrument commit** — `3f8f5ab` before and after; only path
  strings in prose changed. The article's §Methods citation is unaffected.
- **Build dependencies** — `Package.swift` pulls `ocr-swift` (and everything
  else) from GitHub URLs. No path-based dependency existed.
- **macdoc's OCR capability** — `macdoc ocr` / PDF tools consume
  `packages/ocr-swift` exactly as before; only the benchmark instrument left.
- **Historical design docs** — `article1-vlm-ocr-anova/design/fastocr-cli-*.md`
  keep the FastOCR-era name and old paths on purpose (frozen decision records).

## Known follow-ups

- [ ] bestOCR umbrella has **no GitHub remote yet** — user decision pending
      (name suggestion: `PsychQuant/bestOCR`, private until the sweep lands).
- [ ] `.build/` in measureOCR contains stale absolute paths from the old
      location; first `make release` in the new path rebuilds cleanly (SPM
      regenerates). Not an error, just expect a full rebuild.
- [ ] measureOCR's own README still opens with the rename note; add a
      "part of bestOCR" line at the next instrument release (post-freeze,
      to avoid touching the pinned commit's tree before OSF push).
