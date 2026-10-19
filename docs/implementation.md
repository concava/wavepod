# Implementation notes

The app now uses the persistent workspace. `AppModel()` without persistence remains the deterministic sample
used by previews and snapshots; the app creates `AppModel(persistent: true)`.

## Phase 3: processing

- `Engine` defines the shared native/Scriberr contract. `NativeEngine` loads **local** model files only. Settings
  installs immutable Hugging Face snapshots through the logged app client, verifies LFS SHA-256 hashes, and
  records the resolved model revision. Missing models produce a recoverable queue error.
- Native inference lives in the embedded `app.wavepod.engine` XPC service. The service routes Core ML to `.all`
  and terminates a stage above 3,500 MiB physical footprint, leaving room for the app within the 4 GB budget.
  See `tools/wavepod.trace-template.md` for profiling both processes.
- `JobQueue` is an actor. Every state transition is durable. Range downloads retain partial bytes and validators;
  decode is streamed into 16 kHz mono WAV. Audio is processed in 30-minute windows (below); each window's ASR and
  diarization output is checkpointed. Parakeet decodes a whole window with its own long-form mode (overlapping
  chunks, merged tokens). An earlier version cut windows into independent 14 s pieces and lost words at every cut
  (golden-set WER 11.91 → 14.06 % and 5.30 → 6.66 %, deletions doubled). Whisper decodes pieces of at most
  28 seconds cut at silences (Silero VAD), checkpointing after each. **No audio is discarded**; a stretch
  with no recognized words is marked in the transcript.
- Diarization uses 30-minute windows with 10-second overlap. Voice embeddings join window-local labels, and
  midpoint ownership avoids duplicate overlap words. Per-word alignment follows decision 0003. Raw ASR and
  diarization outputs remain separate from rendered segments, so rendering and renaming never rerun ASR.
- A timed publisher transcript bypasses download and native inference. Publisher speaker names retain source
  evidence. Untimed text cannot substitute for a timed transcript and falls back to processing the audio.
- Pause, cancel, retry, recovery after quit, battery pause and Low Power Mode are wired to the app. A file lease
  prevents the background checker and app from owning the queue together; a second inference lease serializes
  model work across processes.
- Scriberr accepts only loopback/private literal addresses or `.local`. Keys use Keychain. Submission IDs are
  checkpointed, polling backs off to 10 seconds, cancellation calls `kill`, and the pinned API's transcript
  envelope and WhisperX word speakers are decoded. Local diarization supplies voice embeddings while retaining
  remote labels. If a remote result lacks word timing, the current fallback uses native recognition for timing.

Data lives in `~/Library/Application Support/wavepod/`: `library.sqlite`, `jobs/<UUID>/`, `models/`, `audio/`, and
`network.json`. Checkpoints use atomic writes. SQLite uses WAL; record/index changes use one transaction.

### Measured (2026-10-19, M3 16 GB, `wavepod-transcribe`, cached models)

| Audio | Length | Wall time | RTF | Peak footprint | Notes |
|---|---|---|---|---|---|
| Golden windows (ES) | 3 × 20 min | 27–29 s each | 0.023 | 0.90 GB | WER equal to Phase 0 Parakeet against the draft references (11.91 %, 5.30 %); cpWER only 0.13–0.18 points above WER |
| Acquired "Ferrari" (EN) | 3 h 58 min | 5 min 19 s | 0.022 | **0.93 GB** | 8 windows; 2 hosts kept consistent across all windows (+1 short clip voice); longest gap between words 2.9 s |
| Itnig, two full episodes (ES) | 1 h 44, 2 h 05 | 2 min 23 s, 2 min 48 s | 0.023 | — | |

The 3 h requirement holds with a wide margin: memory does not grow with length, because every stage works on one
30-minute window. The references are machine drafts, so the WER figures compare engines, not absolute accuracy.

## Verification

```sh
(cd WavepodKit && swift test)
xcodegen generate
xcodebuild -project wavepod.xcodeproj -scheme wavepod -configuration Debug build
```

Model integration tests are opt-in so ordinary tests remain offline:

```sh
WAVEPOD_NATIVE_MODELS=/absolute/model/root \
WAVEPOD_SMOKE_AUDIO=/absolute/audio.wav \
WAVEPOD_SMOKE_LANGUAGE=en \
swift test --package-path WavepodKit --filter NativeSmokeTests
```

The golden-set run scores the same pipeline end to end: `wavepod-transcribe` runs decode, windowed ASR,
diarization and word alignment in-process (no XPC helper, no library), and `./eval/podeval run wavepod` drives it.

The native model root contains `parakeet/`, `whisper/` (including tokenizer files), `vad/`, and `diarizer/`.
Synthetic fixtures test queue crash recovery, published transcript bypass, range restart, network restrictions
and persistence.

## Remaining release evidence

Still needed before release: verified golden-set references (the drafts are machine-made), a Catalan episode,
and the macOS 14 diarization stress run. A live Scriberr installation and
SMAppService registration need their own deployment checks. Developer ID signing/notarization remains a separate
release step.
