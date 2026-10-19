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

FluidAudio's diarization docs (v0.17.7) report an Apple bug on **macOS 14** (all patches through at least 14.8.7):
Core ML predictions that fall back from the Neural Engine to the BNNS CPU path crash (`EXC_BAD_ACCESS` in
`libBNNS`). Apple fixed it in macOS 15. On Apple Silicon it is intermittent. Routing models to `.all` (GPU allowed)
reportedly stops it but is unverified, and the FBank model stays on CPU regardless.

Options were: (1) keep macOS 14, route diarization to `.all` there, and require a clean stress test; (2) raise the
floor to macOS 15; (3) keep macOS 14 without speaker detection.

**Measured** with `.github/workflows/diarization-stress.yml`
([run 39270446236](https://github.com/concava/wavepod/actions/runs/39270446236), 2026-10-19): 100 diarizations of a
4-minute VoxConverse clip per row, each in its own process, on GitHub's Apple Silicon runners (VMs without a Neural
Engine, so every prediction takes the BNNS path: the worst case).

| Runner | `ane` (.cpuAndNeuralEngine) | `default` (FluidAudio) | `app` (all four models `.all`) |
|---|---|---|---|
| macOS 14.8.9 | 0 ok, **100 crashed** | 0 ok, **100 crashed** | 0 ok, **100 crashed** |
| macOS 15.7.9 | 100 ok | 100 ok | 100 ok |

Every crash was a bus error (`EXC_BAD_ACCESS` in `libBNNS`). `.all` does not avoid it.

**Decision (owner, 2026-10-19): option 2, macOS 15 is the minimum.** Option 3 was built (concava/wavepod#6) and
closed: a podcast app without speakers on one OS version is a worse product than not installing there. A real
Mac with a Neural Engine may crash less often than these VMs, but it takes the same code path whenever Core ML falls
back to the CPU, so macOS 14 is not supported at all. The XPC engine service stays, since it also contains crashes
in any other model runtime. The stress workflow stays as a regression check: it fails if the shipping routing
crashes on macOS 15.

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
