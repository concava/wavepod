# 0003 — Diarization: ship CoreML, measure against pyannote

- Status: **Accepted for Phase 1** — pyannote reference pending (needs the owner's Hugging Face token)
- Date: 2026-10-18

## Question

Which diarizer ships in the app, and what do we compare it with?

## Options

| ID | System | Speakers | Embeddings exposed? | In app? |
|---|---|---|---|---|
| `ref-pyannote` | pyannote.audio, `speaker-diarization-community-1` (Python) | unbounded | yes | Reference only |
| `fa-offline` | FluidAudio `OfflineDiarizerManager` (CoreML port of community-1: segmentation + WeSpeaker embeddings + clustering) | unbounded | yes | **Proposed** |
| `fa-sortformer` | FluidAudio Sortformer | max 4 | no | Rejected unless much better |
| `fa-lseend` | FluidAudio LS-EEND | max 10 | no | Compared only |

## Proposal

Ship **`fa-offline`**:

- Podcasts can have more than 4 voices (panels, clips, ads), so Sortformer's 4-speaker cap is a hard limit.
- Phase 4 needs a voice embedding per speaker to recognise a host across episodes. The pyannote-style pipeline
  produces WeSpeaker embeddings as part of clustering; end-to-end models (Sortformer, LS-EEND) do not.
- It is the same model family as the reference, so a DER gap points to the port, not the model.

`ref-pyannote` runs only in `bench/`. Its weights are gated on Hugging Face: the owner must accept the
community-1 terms and provide an HF token for the reference run (CC-BY-4.0 weights; the gate is a click-through,
not a license change).

Also noted: WhisperKit 1.x now ships **SpeakerKit** (Argmax's diarization) in the same package. It joins the
comparison in the Phase 1 rerun if it exposes per-speaker embeddings.

## Risk: macOS 14 crash in Apple's BNNS

**Decision (2026-10-19, owner approved): keep the app's macOS 14 minimum, but require macOS 15 for
FluidAudio offline speaker detection.** Audio transcribed on macOS 14 has one speaker (`S1`) and no voice
embeddings. The Transcription and Queue panes in Settings explain the limitation and the reason to upgrade.
Publisher transcripts keep their supplied labels because they bypass local inference.

FluidAudio [issue #878](https://github.com/FluidInference/FluidAudio/issues/878) reports an Apple BNNS defect:
Core ML predictions falling back to CPU can crash with `EXC_BAD_ACCESS` / `SIGBUS` in `libBNNS`. Its
[closing comment](https://github.com/FluidInference/FluidAudio/issues/878#issuecomment-5604575505) explicitly
calls the `.all` workaround unverified. Wavepod's own measurements refute `.all` as a general macOS 14 remedy.

### Measured results

[Actions run 39270446236](https://github.com/concava/wavepod/actions/runs/39270446236), workflow
[diarization-stress.yml](../../.github/workflows/diarization-stress.yml), 2026-10-19. Counts come from its
`result-*` artifacts. Each attempt launches `wavebench stress-diarize` in a fresh process on the same audio;
100 attempts per OS and mode. A green control job does **not** mean its attempts succeeded: only `app` mode
gates the workflow. Crashed means a signal exit; ordinary failures are counted separately.
The `stress-inputs` artifact's `clip.wav` is 306.432 s, mono, 16 kHz PCM16, SHA-256
`908dcc73b486bb86be7210f7ae84993bfed7f097f3d24122eb2e850ce3853f17`.

| Runner / measured OS | Mode | Runs | OK | Crashed | Failed |
|---|---|---:|---:|---:|---:|
| macos-14 / 14.8.9 | `ane` | 100 | 0 | 100 | 0 |
| macos-14 / 14.8.9 | `default` | 100 | 0 | 100 | 0 |
| macos-14 / 14.8.9 | `app` | 100 | 0 | 100 | 0 |
| macos-15 / 15.7.9 | `ane` | 100 | 100 | 0 | 0 |
| macos-15 / 15.7.9 | `default` | 100 | 100 | 0 | 0 |
| macos-15 / 15.7.9 | `app` | 100 | 100 | 0 | 0 |

**All 300 attempts crashed on macOS 14.8.9; all 300 succeeded on macOS 15.7.9.**

Modes: `ane` uses `.cpuAndNeuralEngine`; `default` uses FluidAudio's built-in routing (including CPU-only
FBank); `app` uses Wavepod's shipped routing, loading **all four** offline models with `.all`. This test
measures the runtime's behavior directly, bypassing the new app OS guard.

The macOS 14 runners are Apple Silicon VMs without an ANE. The results establish failure on that environment;
they do not establish a physical Mac crash rate or prove that `.all` fails on every GPU/ANE combination.
This run did not measure usable GPU availability or stress-test a physical Mac.
However, #878 also reports intermittent field crashes on a physical M2 Pro running 14.6.1. A usable ANE can
reduce CPU fallback, but is not evidence of safety. We therefore disable offline diarization on **all**
macOS 14 Macs rather than gate by hardware or advertise `.all` as a fix. Upstream reports the defect fixed
in macOS 15; the macOS 15 controls above test Wavepod's own configurations on runners, not every Mac or workload.

### Alternatives and implementation

- **Raise the whole app to macOS 15:** consistent features, but unnecessarily removes macOS 14 transcription,
  playback, search and publisher transcripts. Rejected in favor of keeping those available.
- **Keep macOS 14 with speaker detection disabled (chosen):** avoid the known crash before loading any
  diarizer model; expose `diarization = false` and `embeddings = false` in native engine capabilities.
  `NativeEngine` guards direct in-process/CLI and helper calls; `IsolatedEngine` returns the same fallback
  before connecting to XPC; `WindowedTranscriber` bypasses both diarizer calls and diarization checkpoints.
  After stitching it normalizes all generated words and turns to one speaker, clears overlap flags and
  embeddings, and preserves ASR text, language and timings. Existing ASR checkpoints remain reusable.
  No synthetic diarization checkpoint is written: resuming on macOS 15 runs actual diarization.
- **Attempt diarization in XPC, then retry without it after a crash:** the shipped app already isolates native
  inference in its engine XPC service, but currently reports a failed job on worker loss. Automatic fallback
  would add recovery complexity and a predictably crashing attempt on these runners; it would not protect
  direct in-process callers. Retain XPC isolation for other runtime failures, without deliberately entering
  this known crash path or adding automatic crash retries in this change.

Tests inject macOS 14, 15 and later versions to verify capabilities, model/XPC bypass, a single speaker across
windows, checkpoint handling and re-enabling diarization after an OS upgrade. The app's minimum remains 14
in `project.yml` and `WavepodKit/Package.swift`.

## Word-level speaker alignment (pipeline, Phase 3)

Diarization gives speaker turns; ASR gives words. For each word we assign the speaker whose turn covers the word's
midpoint; if several turns cover it, the shortest covering turn wins (it is most likely the interjection), and the
word is flagged `overlap = true`. If no turn covers it, the word takes the nearest turn within 0.5 s, else the
previous word's speaker. Paragraphs break on speaker change or a pause ≥ 1.5 s. (Idea credited to noScribe in
[0001](0001-references.md); implemented independently, per word.)

## Metrics

- **DER** with `pyannote.metrics`, 0.25 s forgiveness collar, overlap included. Reported with its parts (miss,
  false alarm, confusion) and with speaker-count accuracy.
- **cpWER** (Phase 1, needs both ASR and diarization) with `meeteval`.
- RTF and peak memory, measured the same way as in [0002](0002-asr-engine.md).

## Decision rule

Ship `fa-offline` if its DER is within **2 points** of `ref-pyannote` on VoxConverse and on the golden set, with
RTF < 0.05 and peak memory < 1 GB. Otherwise reopen this record.

## Results (2026-10-18, M3 16 GB, idle machine)

VoxConverse test subset: 13 files, 60 min, 2–14 speakers (2, 3–4, 5–7 and 8+ speakers equally represented),
fetched with `bench/prepare_voxconverse.py`.

| System | DER % | Miss % | False alarm % | Confusion % | RTF | ×real time | Peak footprint GB |
|---|---|---|---|---|---|---|---|
| `fa-offline` FluidAudio offline pipeline (community-1 CoreML) | **15.24** | 5.34 | 2.29 | 7.61 | 0.0059 | 170 | 0.99 |
| `ref-pyannote` community-1 (Python) | _pending_ | | | | | | |

- Matches FluidAudio's own published figure on the full VoxConverse test set (15.07 %), so the subset is
  representative.
- Meets the speed and memory criteria (RTF < 0.05, < 1 GB, with no margin on memory).
- Confusion (wrong speaker) is half the error: the part Phase 4's per-show voice profiles can reduce.
- Sortformer and LS-EEND were not run: neither exposes speaker embeddings, which Phase 4 needs.

To run the reference: accept the terms of `pyannote/speaker-diarization-community-1` on Hugging Face, then
`hf auth login` once, then `./bench/run_all.sh ref-pyannote`.
