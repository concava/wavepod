# wavepod

A private, podcast-native transcription app for macOS. Paste a podcast link or drop an audio/video file and get a
speaker-named, searchable transcript you can read, listen to and ask questions about — all on your Mac.

Status: **Phase 0 — decisions**, with the UI shell running on an invented sample episode.

- Decisions: [`docs/decisions/`](docs/decisions/)
- Engine benchmark: [`bench/`](bench/)
- Swift modules and tests: [`WavepodKit/`](WavepodKit/) (`Library`, `Player`, `UI`)

```sh
brew install xcodegen
xcodegen generate && open wavepod.xcodeproj      # app
(cd WavepodKit && swift test)                      # unit + snapshot tests
(cd WavepodKit && SNAPSHOT_RECORD=1 swift test)    # re-record snapshots after a deliberate UI change
```

License: [Apache-2.0](LICENSE).
