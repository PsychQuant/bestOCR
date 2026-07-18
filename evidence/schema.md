# Evidence schema — the labelling contract

Every measurement bestOCR stores or serves carries three labels. A number
without all three is not evidence and must not enter `recommend`.

## 1. Provenance tier

| Tier | Meaning | Example |
|------|---------|---------|
| **T1 pre-registered** | From a frozen, pre-registered design; analysis script pinned before data collection | article 1 sweep `results.tsv` (pending OSF freeze → run) |
| **T2 internal** | Measured on our hardware by our instrument, but exploratory (pilot, smoke test, autotune) | 2026-07-17 pilot: GLM-OCR q4_K_M ≈ 30% faster than f16 at recall ≈ 0.98 |
| **T3 third-party** | Self-reported by the model vendor or an external benchmark we did not run | a model card's OmniDocBench score |

Tier ordering is strict: T1 > T2 > T3. `recommend` ranks on the highest tier
available and *names the tier* in its answer. T3-only candidates are labelled
"unverified — candidate for the next sweep", never ranked beside T1/T2 numbers.

## 2. Estimand

State *what* the number is, precisely enough that two numbers with different
definitions can never be conflated:

- `speed.ms_per_page` — wall-clock per page, warm model, single stream
- `quality.word_recall` — vs `pdftotext` reference (LaTeX-compiled docs) or
  archive.org ABBYY layer (scanned docs) — these are *different referents*;
  label which
- derived scores (e.g. Pareto proxies) must name their formula version

The mac-benchmark lesson (issues #18–#21) applies verbatim: shares/means that
differ only in estimand or fit are *both true* — report them side by side with
labels, never average them, never pick one silently.

## 3. Condition tuple

`(model, quant, dpi, doc_type, platform, hardware, instrument_commit)` —
every row records the full tuple. A comparison is valid only within matching
tuples (or across a factor the design deliberately varies).

## Row format (evidence tables, future results ingestion)

```json
{
  "estimand": "speed.ms_per_page",
  "value": 1981,
  "condition": {"model": "glm-ocr", "quant": "8bit", "dpi": 100,
                "doc_type": "math_compiled", "platform": "mlx",
                "hardware": "M5 Max 128GB", "instrument": "6af8919"},
  "tier": "T2",
  "source": "phase-1 pilot 2026-05, mcs.pdf pp.196–200",
  "caveat": "MLX rows provisional — see article1 reproducibility warning"
}
```

## Hard rules

1. No cross-tier mixing in a single ranking.
2. No cross-estimand arithmetic without a named, versioned formula.
3. Disagreeing numbers for the same question → surface both with labels.
4. Every `recommend` answer cites the evidence rows it used.
5. Thermal state matters: rows measured under throttle-suspect conditions
   carry a caveat (measureOCR records `ProcessInfo.thermalState`; the
   mac-benchmark sibling article shows why unmodelled throttle regimes
   corrupt naïve summaries).
