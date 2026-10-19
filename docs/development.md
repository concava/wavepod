# Developing wavepod

How to build, test, measure and release. For what the code does, read [How wavepod works](architecture.md)
first.

## Build

Requirements are in the [README](../README.md#install): Apple Silicon, macOS 15, a current Xcode (tested with
Xcode 27), XcodeGen.
`project.yml` is the source of truth; `wavepod.xcodeproj` is generated and not committed.

```sh
xcodegen generate
xcodebuild -project wavepod.xcodeproj -scheme wavepod -configuration Debug -derivedDataPath build/dd -quiet build
open build/dd/Build/Products/Debug/wavepod.app
```

The **wavepod** scheme builds the app, the `WavepodEngine` XPC service and the `wavepod-feeds` checker, and
embeds the last two in the bundle.

MLX needs Xcode's Metal toolchain. If `xcrun metal --version` reports it missing:

```sh
xcodebuild -downloadComponent MetalToolchain
```

### Sample data

`AppModel()` without persistence is a fixed sample episode ("Low Tide", fictional) used by previews and
snapshots. Launch the app on it, without touching your library:

```sh
open build/dd/Build/Products/Debug/wavepod.app --args -WavepodSampleData YES
```

The README screenshot is taken this way.

## Code conventions

- Swift 6 with complete strict concurrency. `AppModel` is `@MainActor @Observable`; the queue, monitor and
  services are actors.
- All network requests go through `Networking.HTTPClient`, never `URLSession` directly.
- Models are read from installed files only; installing is the one place that downloads.
- Writes that must survive a crash are atomic (checkpoints) or one SQLite transaction (records and indexes).
- UI polish rules (press scale 0.96, elevation by shadow, motion off under Reduce Motion) live in `Theme.swift`
  as `PressScale`, `Elevated` and `motion(_:reduced:)`. Use them rather than new one-offs.

## Tests

```sh
(cd WavepodKit && swift test)
```

- **Unit tests** cover the resolver, queue recovery, published-transcript bypass, range restarts, network rules,
  persistence, search, speaker matching, citation validation, subscriptions and the battery policy. They run
  offline with fakes.
- **Snapshot tests** (`UITests/SnapshotTests.swift`) render every main view in light and dark, plus large text.
  They need a WindowServer display and are skipped on headless runners. After a deliberate UI change:

  ```sh
  (cd WavepodKit && SNAPSHOT_RECORD=1 swift test --filter SnapshotTests)
  ```

  Look at the new images before committing them.
- **Model smoke tests** are opt-in, so ordinary runs stay offline:

  ```sh
  WAVEPOD_NATIVE_MODELS=/abs/models WAVEPOD_SMOKE_AUDIO=/abs/audio.wav WAVEPOD_SMOKE_LANGUAGE=en \
    swift test --package-path WavepodKit --filter NativeSmokeTests

  WAVEPOD_AI_MODELS=/abs/models WAVEPOD_INSTALL_AI=1 \
    swift test --package-path WavepodKit --filter LocalAISmokeTests
  ```

  The native root holds `parakeet/`, `whisper/`, `vad/` and `diarizer/`; the AI root holds `language/` and
  `embeddings/`. Leave out `WAVEPOD_INSTALL_AI` to use weights already installed.

## Measuring quality

Two harnesses, neither of which ships in the app.

### Golden set (`eval/`)

Six real podcast episodes (Spanish, English, Catalan; up to 4 hours) defined in `eval/golden/manifest.json`,
see [0007](decisions/0007-golden-set.md). Audio and references stay in a local cache
(`~/Library/Caches/wavepod-golden`) and never enter the repository.

```sh
./eval/podeval fetch      # download, pin SHA-256, cut the 20-minute scored windows
./eval/podeval run wavepod
./eval/podeval score
./eval/podeval check      # exits 1 on a regression against eval/golden/baseline.json
```

`wavepod-transcribe` runs the same decode, windowing, recognition, diarization and alignment as the app,
in-process, so the score measures the code that ships. Details: [0009](decisions/0009-evaluation-harness.md).
The references are machine drafts until someone listens to them.

### Engine benchmark (`bench/`)

Public data (FLEURS, VoxConverse) comparing recognizers and diarizers. It produced the engine choices in
[0002](decisions/0002-asr-engine.md) and [0003](decisions/0003-diarization.md). See [bench/README](../bench/README.md).

### Profiling

`tools/wavepod.trace-template.md` describes an Instruments setup that records the app and the engine
service together.

## Continuous integration

| Workflow | Runs |
| --- | --- |
| `podeval.yml` | The golden-set check. |
| `diarization-stress.yml` | 100 diarizations per mode on macOS 14 and 15. It fails only if the shipping routing crashes on macOS 15; the macOS 14 rows record why 15 is the minimum ([0003](decisions/0003-diarization.md)). |

## Before a release

- Verify the golden-set references by ear, then turn the evaluation thresholds into hard gates.
- Evaluate the local model's citations and answer language on the golden set (20 questions per episode).
- Check a live Scriberr server and `SMAppService` registration of the feed checker on a clean Mac.
- Sign with Developer ID, notarize and staple; ship a `.dmg` on GitHub Releases with Sparkle updates
  ([0005](decisions/0005-distribution.md)).
