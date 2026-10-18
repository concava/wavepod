# 0002 — ASR engine for shipping

- Status: **Proposed — numbers pending** (filled in by `bench/` runs; see "Results")
- Date: 2026-10-18
- Deciders: engineering (default), owner informed

## Question

Which speech recognizer runs inside wavepod on Apple Silicon, and how close is it to the reference?

## Candidates

| ID | Engine | Model | Runs on | In app? |
|---|---|---|---|---|
| `ref-openai` | openai/whisper (Python) | large-v3 | CPU (fp32) | Reference only |
| `ref-fw` | faster-whisper / WhisperX (Python) | large-v3 | CPU int8 | Reference only |
| `wk-turbo` | WhisperKit | `large-v3-v20240930_turbo` | ANE + GPU | Candidate |
| `wk-626` | WhisperKit | `large-v3-v20240930_626MB` (compressed turbo) | ANE + GPU | Candidate |
| `wcpp-turbo` | whisper.cpp (Metal) | `ggml-large-v3-turbo` | GPU | Candidate |
| `wcpp-v3` | whisper.cpp (Metal) | `ggml-large-v3` | GPU | Candidate |
| `fa-parakeet` | FluidAudio | Parakeet TDT v3 "Ultra" | ANE | Candidate, EN/ES only |

Parakeet has no Catalan, so `fa-parakeet` can only be a per-language fast path, never the sole engine.

## Method

Phase 0 runs on **public, redistributable data** so that the numbers are reproducible by anyone. Phase 1 reruns
the same harness on the golden set ([0007](0007-golden-set.md)) and sets the CI thresholds from that run.

| Set | Use | License |
|---|---|---|
| FLEURS test, `en_us`, `es_419`, `ca_es` | WER per language. Utterances are concatenated into ~10 min files so that every engine runs its long-form path, not single short clips | CC-BY-4.0 |
| Earnings-21 (one ~1 h call) | Long-form WER, RTF and memory on a single long file | CC-BY-SA-4.0 |
| VoxConverse test (subset) | DER for [0003](0003-diarization.md) | CC-BY-4.0 |

Metrics, all produced by `bench/score.py`:

- **WER**: after whisper's normalizer (`EnglishTextNormalizer` for English, `BasicTextNormalizer` otherwise),
  corpus-level (total edits / total reference words).
- **RTF**: processing wall time / audio duration, model load excluded and reported separately as `load_s`.
  Lower is better (we also print RTFx = 1/RTF).
- **Peak memory**: macOS "peak memory footprint" from `/usr/bin/time -l` for the whole engine process. This counts
  unified memory used by Metal and CoreML, which RSS alone would miss.
- Same machine for every run (dev machine: M3, 16 GB, macOS 27), on AC power, no other heavy jobs.

Decoding settings: openai/whisper defaults for the reference. Candidates use their own recommended long-form
settings, with temperature fallback on. Language is **forced** per file (the app passes the feed's language when it
has one); a second pass with auto-detect is reported for the code-switching case in Phase 1.

## Decision rule

1. Eliminate any candidate whose WER on any language is more than **1.5 points** worse than `ref-openai`.
2. Eliminate any candidate whose peak memory exceeds **4 GB** (leaves room on a 16 GB Mac for the app, the local
   LLM and other apps; see [0008](0008-engineering-defaults.md)).
3. Among the rest, pick the lowest RTF. Prefer a Swift package over a vendored C++ build when RTF is within 20 %.
4. `fa-parakeet` is adopted as an EN/ES fast path only if it passes rules 1–2 for those languages.

## Expected outcome (hypothesis, to be confirmed or rejected by the numbers)

`wk-turbo` as the default engine for all languages, with word timestamps from WhisperKit; `fa-parakeet` possibly as
a faster EN/ES option. `wcpp-turbo` is the fallback if WhisperKit fails rule 1 or 2.

## Results

_Pending. `bench/run_all.sh` writes `bench/results/asr.md`; this section is replaced with that table and the
decision once the run finishes._
