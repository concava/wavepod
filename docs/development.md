# Developing Wavepod

How to build, test, measure and release. For what the code does, read [How Wavepod works](architecture.md)
first.

## Build

Requirements are in the [README](../README.md#install): Apple Silicon, macOS 15, a current Xcode (tested with
Xcode 27), XcodeGen.
`project.yml` is the source of truth; `wavepod.xcodeproj` is generated and not committed.

```sh
xcodegen generate
xcodebuild -project wavepod.xcodeproj -scheme wavepod -configuration Debug -derivedDataPath build/dd -quiet build
open build/dd/Build/Products/Debug/Wavepod.app
```

The **Wavepod** scheme builds the app, the `WavepodEngine` XPC service and the `wavepod-feeds` checker, and
embeds the last two in the bundle.

MLX needs Xcode's Metal toolchain. If `xcrun metal --version` reports it missing:

```sh
xcodebuild -downloadComponent MetalToolchain
```

### Sample data

`AppModel()` without persistence is a fixed sample episode ("Low Tide", fictional) used by previews and
snapshots. Launch the app on it, without touching your library:

```sh
open build/dd/Build/Products/Debug/Wavepod.app --args -WavepodSampleData YES
```

The README screenshot is taken this way.

## Code conventions

- Swift 6 with complete strict concurrency. `AppModel` is `@MainActor @Observable`; the queue, monitor and
  services are actors.
- All network requests go through `Networking.HTTPClient`, never `URLSession` directly. The one exception is
  Sparkle, which fetches the appcast and updates itself.
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
| `release.yml` | A `v*` tag builds the `.dmg` and publishes a GitHub Release. See [Release](#release). |
| `diarization-stress.yml` | 100 diarizations per mode on macOS 14 and 15. It fails only if the shipping routing crashes on macOS 15; the macOS 14 rows record why 15 is the minimum ([0003](decisions/0003-diarization.md)). |

## Before a release

- Verify the golden-set references by ear, then turn the evaluation thresholds into hard gates.
- Evaluate the local model's citations and answer language on the golden set (20 questions per episode).
- Check a live Scriberr server and `SMAppService` registration of the feed checker on a clean Mac.
- Add the Developer ID, notary and Sparkle secrets (see [Release](#release)) so the tag produces a notarized
  build ([0005](decisions/0005-distribution.md)).

## Release

`tools/release.sh` builds the Release configuration, signs it, packages `dist/Wavepod-$VERSION.dmg` and, when it
has the keys, notarizes and staples it. Each stage runs only when its inputs are set, so locally it makes an
ad-hoc test build:

```sh
VERSION=0.2.0 tools/release.sh
```

In CI, pushing a tag runs `.github/workflows/release.yml`:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

Without secrets the tag gives an ad-hoc pre-release marked "testing only". A manual run (Actions → release →
Run workflow) builds the `.dmg` as a workflow artifact and publishes nothing.

| Repository setting | Kind | What it is |
| --- | --- | --- |
| `DEVELOPER_ID_P12` | secret | Developer ID Application certificate and key, exported as `.p12`, base64-encoded. |
| `DEVELOPER_ID_P12_PASSWORD` | secret | The `.p12` export password. |
| `NOTARY_KEY_P8` | secret | App Store Connect API key (Developer role) for `notarytool`, base64-encoded. |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER` | secrets | That key's ID and issuer ID. |
| `SPARKLE_PRIVATE_KEY` | secret | Sparkle EdDSA private key. Also keep one offline backup; never commit it. |
| `SPARKLE_PUBLIC_KEY` | variable | The matching public key, stamped into the app as `SUPublicEDKey`. |

Encode files with `base64 -i file | pbcopy`. Make the Sparkle key pair once with `generate_keys`, which ships in
the Sparkle package (`build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/` after a build). It stores the
private key in your login keychain; `generate_keys -x sparkle_private_key` exports it for the secret.

Updates:

- A build with no `SPARKLE_PUBLIC_KEY` never starts Sparkle, and "Check for Updates…" stays disabled. That
  covers every local build.
- Only a notarized tag build with `SPARKLE_PRIVATE_KEY` is added to the appcast. The workflow signs it with
  `generate_appcast` and pushes `appcast.xml` to the `gh-pages` branch. Installed copies read it from
  `https://concava.github.io/wavepod/appcast.xml`, so turn on GitHub Pages for `gh-pages` once.
- `CFBundleVersion` is the workflow run number, so every release's version is higher than the last.
