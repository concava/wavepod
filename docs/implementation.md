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

## Phase 4: speakers

Confirmed names create per-feed voice profiles. Later episodes compare only against that feed's profiles;
ambiguous matches remain unnamed. Self-introductions require corroboration from feed people or description
text. Feed mentions remain candidates, with their transcript quotes and timestamps, rather than silently naming
a speaker. The speaker popover shows evidence, seeks to it, and confirms a candidate with one click. A rename
updates the speaker mapping and durable record; transcript words remain untouched.

Voice cosine thresholds (match ≥ 0.75, and ≥ 0.08 ahead of the runner-up) are conservative defaults, **not
calibrated accuracy claims**. First evidence (2026-10-19): across the two full Itnig episodes, one voice recurs
(cosine 0.89 between its two episode-level embeddings); every other cross-episode pair scores ≤ 0.31. A name
confirmed once would therefore be suggested for that voice in the other episode, and for nobody else. Calibrating
false matches and measuring the share of turns with the correct name need verified, named references.

## Phase 5: library, AI and shows

- GRDB/SQLite stores episode records, speaker maps, chapters, summaries, chat and raw voice embeddings. The
  sidebar fetches metadata only. FTS5 supports keyword search; multilingual E5-small supplies normalized vectors
  for cosine search. Vectors are revision-tagged and indexed incrementally. Search opens the exact episode/time.
- MLX Swift runs Qwen3-4B-Instruct-2507 at 4-bit locally. This Apache-2.0 model is a provisional implementation
  candidate, pending the golden-set citation/language evaluation. Contexts are bounded; summary/chapter
  generation covers successive sections of the whole transcript. Ask retrieves within the selected episode.
- Generated claims use `{claim, quote, start}`. A contiguous word-span validator checks normalized similarity
  >= 0.85 and a start within ±2 seconds. Invalid output is retried once; invalid claims are then dropped.
  Translations are displayed separately with source timestamps and never overwrite the original transcript.
- Shows support manual selection and per-subscription automatic downloads, transcription, summaries and chapters.
  New subscriptions enable all three; existing subscriptions preserve their previous transcription setting with
  downloads and summaries off. Summarizing implies transcription. Existing feed items are seeded as seen so
  automation does not import a back catalogue. Downloads keep audio for offline playback; optional per-show
  retention keeps the latest N downloads (unlimited by default) and deletes only audio, preserving transcripts
  and notes. Missing local language models leave summaries pending, retried on later checks or model installation.
  Requests are conditional and at most hourly. The embedded LaunchAgent is registered through Settings with
  `SMAppService`, checks hourly, and runs opted-in downloads, transcription and notes while the app is closed.
  macOS may require approving background items in System Settings.

The network log records hosts, purposes and response codes without API keys or signed URL query strings.
Native/MLX runtimes read installed files; feed/audio/model requests use `Networking`. yt-dlp remains an external
metadata extractor with its own network stack; its binary is pinned and verified, user configuration/plugins are
ignored, and the selected M4A audio is downloaded through the app client.

### Measured: Ask on a real transcript (2026-10-19)

`wavepod-ask` asked Qwen3-4B (4-bit, MLX) 12 Spanish questions about one 20-minute golden window
(itnig-cuantico, transcribed by the Phase 3 pipeline): 10 answerable from the window, 2 not.

| Citation rule | Answered (of 10) | Fully right | Partial | Not found (of 2 unanswerable) | Citations pointing at the wrong text |
|---|---|---|---|---|---|
| Quote must start within ±2 s of the cited time | 4 | 2 | 2 | 2 | 0 |
| Quote must lie in the cited segment; time replaced by the quote's own start | **9** | **6** | 2 | **2** | **0** |

The model only sees one timestamp per segment (segments last up to 30 s), so the first rule rejected most correct
quotes. The second keeps the guarantee — the timestamp shown is where the quoted words start — and accepts them.
An explicit empty answer is now accepted at once instead of being retried. Peak memory was 3.6 GB for generation
plus embeddings; the run took 7 minutes for 12 questions (about 35 s per question). One window and 12 questions is
a first check, not the 20-questions-per-episode evaluation the definition of done asks for.

## Verification

```sh
(cd WavepodKit && swift test)
xcodegen generate
xcodebuild -project wavepod.xcodeproj -scheme wavepod -configuration Debug build
```

Snapshot tests require a WindowServer display and are skipped on headless runners.
Model integration tests are opt-in so ordinary tests remain offline:

```sh
WAVEPOD_NATIVE_MODELS=/absolute/model/root \
WAVEPOD_SMOKE_AUDIO=/absolute/audio.wav \
WAVEPOD_SMOKE_LANGUAGE=en \
swift test --package-path WavepodKit --filter NativeSmokeTests

WAVEPOD_AI_MODELS=/absolute/model/root WAVEPOD_INSTALL_AI=1 \
swift test --package-path WavepodKit --filter LocalAISmokeTests
```

The AI root contains `language/` and `embeddings/`. Omit `WAVEPOD_INSTALL_AI` to use already-installed weights
without downloading. Xcode's Metal Toolchain is needed for MLX; install it with
`xcodebuild -downloadComponent MetalToolchain` if `xcrun metal --version` reports it missing.

The golden-set run scores the same pipeline end to end: `wavepod-transcribe` runs decode, windowed ASR,
diarization and word alignment in-process (no XPC helper, no library), and `./eval/podeval run wavepod` drives it.

The native model root contains `parakeet/`, `whisper/` (including tokenizer files), `vad/`, and `diarizer/`.
Synthetic fixtures test queue crash recovery, published transcript bypass, range restart, network restrictions,
persistence, search/vector retention, speaker matching and citation rejection/retry.

## Remaining release evidence

Still needed before release: verified golden-set references (the drafts are machine-made), a Catalan episode,
the local model's citation and language evaluation on the golden set. A live Scriberr installation and
SMAppService registration need their own deployment checks. Developer ID signing/notarization remains a separate
release step.
