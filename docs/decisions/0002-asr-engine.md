# 0002 — ASR engine for shipping

- Status: **Accepted for Phase 1, provisional** — confirmed or reopened by the golden-set run (see "Decision")
- Date: 2026-10-18
- Deciders: engineering (default), owner informed

## Question

Which speech recognizer runs inside Wavepod on Apple Silicon, and how close is it to the reference?

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

## Results (2026-10-18, M3 16 GB, macOS 27, AC power)

FLEURS test, ~10 min per language (60 en / 51 es / 51 ca sentences). WER after whisper's normalizers.
Timing and memory from a pass on an idle machine; peak memory from `/usr/bin/time -l` (footprint excludes
memory-mapped model weights, RSS includes them, so both are shown).

### Short-form: each sentence decoded on its own (model accuracy, the fair comparison)

| Engine | WER ca | WER en | WER es | Δ vs reference (worst language) |
|---|---|---|---|---|
| `ref-openai` openai/whisper large-v3, CPU | **7.89** | **5.44** | **2.96** | — |
| `wk-turbo` WhisperKit large-v3-turbo | 9.30 | 6.90 | 3.19 | +1.46 (en) — passes, narrowly |
| `fa-parakeet` Parakeet TDT v3 Ultra | n/a | 6.44 | 2.96 | +1.00 (en) — passes |

### Long-form: the same sentences concatenated into one ~10 min file per language (robustness)

| Engine (long-form mode) | WER ca | WER en | WER es | RTF | ×real time | Footprint GB | RSS GB |
|---|---|---|---|---|---|---|---|
| `ref-openai` sequential, library defaults | — | 30.60 | — | 2.71 | 0.4 | — | — |
| `ref-fw` faster-whisper, sequential | 31.40 | 22.16 | 26.29 | 2.34 | 0.4 | 6.17 | 4.96 |
| `wk-turbo` WhisperKit built-in VAD chunking | 10.22 | 100.0 | 96.20 | 0.094 | 10.7 | 2.17 | 4.11 |
| `wk-turbo` sequential, no chunking | — | 16.49 | — | 0.28 | 3.5 | — | — |
| **`wk-turbo` + Silero VAD windows ≤ 28 s, decoded independently** | **8.64** | **11.66** | **2.74** | **0.094** | **10.7** | **0.26** | **1.70** |
| `wcpp-turbo` whisper.cpp Metal, sequential | 11.21 | 59.36 | 3.42 | 0.19 | 5.4 | 2.13 | — |
| `wcpp-turbo` whisper.cpp, `--max-context 0` | 8.64 | 19.94 | 3.27 | 0.11 | 8.7 | 2.13 | — |
| **`fa-parakeet`** (its own sliding window) | n/a | **6.06** | 3.57 | **0.0057** | **174** | **0.08** | **0.18** |

`ref-openai` long-form was stopped after English; `wcpp-v3` and `wk-626` were not run (dominated: same family,
no accuracy reason to expect better long-form behaviour). RTF of rows without memory figures was measured while other
jobs ran and is indicative only.

### What the numbers say

1. **Sequential Whisper long-form is unreliable** on audio with frequent speaker changes and short pauses: whole
   sentences are skipped (openai/whisper itself: 30.6 % on English, mostly deletions) or a window loops
   (whisper.cpp: one sentence repeated 70 times). This is the decoder's timestamp-driven seeking, not the port.
2. **WhisperKit's built-in VAD chunking is broken for this case** (empty English output). Our own windowing —
   Silero VAD regions merged into windows of at most 28 s, each decoded with no text carried over — fixes most of
   it and is the best Whisper long-form result for every language.
3. **The remaining English loss is the VAD, not Whisper**: the deleted sentences sit in stretches the VAD calls
   silence because that speaker is 18 dB quieter (FLEURS has uncontrolled recording levels). Lowering the threshold
   (0.85 → 0.5) did not catch them; levelling the VAD input recovered them in English (9.66 %) but added
   insertions in es/ca. Tiling the whole file (cut at silences, never drop audio) traded deletions for insertions.
   Podcasts are mastered, so this needs to be tuned on the golden set, not on FLEURS.
4. **Parakeet is robust and very fast**: 174× real time with 0.18 GB, no long-form failure, but no Catalan.

## Decision

- **Two native engines behind one `Engine` protocol, chosen per language:**
  - **Parakeet TDT v3 Ultra (FluidAudio)** for the 25 languages it covers (English and Spanish included).
  - **WhisperKit large-v3-turbo** for Catalan and every other language, always through **our** VAD windowing
    (never WhisperKit's built-in chunking, never sequential long-form).
- whisper.cpp is dropped: same accuracy family as WhisperKit, slower here, and a C++ build to maintain.
- Language comes from the feed (`<language>`) when present; otherwise Whisper's language ID on the first minute
  picks the engine.

### Open points, settled on the golden set in Phase 1

- **Code-switching** (EN↔ES, CA↔ES): Parakeet has no notion of a language switch; Whisper with a forced language
  translates or drops the other language. Both get measured on the code-switching episode; the per-language rule
  may become "Whisper with auto language per window" for mixed shows.
- **WhisperKit margin is thin** (+1.46 on English short-form). If the golden set puts it beyond 1.5 points for
  Catalan, test the full large-v3 CoreML model (slower, larger) before anything else.
- **VAD tuning**: threshold, padding, window length and whether to level the VAD input, chosen on real podcasts.
  The pipeline rule from point 3 stands regardless: VAD may decide where to cut, a stage must never silently drop
  audio without the transcript marking it.
- Peak memory: both engines are far under the 4 GB cap; the 3 h episode run in Phase 3 confirms it.
