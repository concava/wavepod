# wavepod

A private, podcast-native transcription app for macOS. Paste a podcast link or drop an audio/video file and get a
speaker-named, searchable transcript you can read, listen to and ask questions about — all on your Mac.

Status: **Phase 4 — speakers**: paste a link or open a file, and a checkpointed queue downloads, decodes,
transcribes and diarizes it on this Mac (or on your own Scriberr server) into a persistent library; speakers
are suggested from per-show voice profiles and the feed's people, with evidence, and confirmed in one click. See
[implementation notes](docs/implementation.md) and the golden-set harness in [`eval/`](eval/).

- Decisions: [`docs/decisions/`](docs/decisions/)
- Engine benchmark: [`bench/`](bench/)
- Swift modules and tests: [`WavepodKit/`](WavepodKit/) (`Networking`, `Resolver`, `Engine`, `NativeEngine`, `Pipeline`, `Speakers`, `Library`, `Player`, `UI`)

```sh
brew install xcodegen
xcodegen generate && open wavepod.xcodeproj      # app
(cd WavepodKit && swift test)                      # unit + snapshot tests
(cd WavepodKit && SNAPSHOT_RECORD=1 swift test)    # re-record snapshots after a deliberate UI change
```

License: [Apache-2.0](LICENSE).
