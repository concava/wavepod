# wavepod

A private, podcast-native transcription app for macOS. Paste a podcast link or drop an audio/video file and get a
speaker-named, searchable transcript you can read, listen to and ask questions about — all on your Mac.

Status: **Phase 5 — library, local AI and shows**: a checkpointed on-device pipeline (or your own Scriberr
server) fills a persistent library; speakers are suggested from per-show voice profiles; keyword and meaning
search open the exact moment; summaries, chapters, translation and Ask run on a local model with every cited
timestamp checked; subscribed shows can be transcribed automatically. See
[implementation notes](docs/implementation.md) and the golden-set harness in [`eval/`](eval/).

Requires Apple Silicon and macOS 14 or later. **Speaker detection requires macOS 15 or later**: on macOS 14,
audio transcription uses a single speaker without voice embeddings to avoid an Apple BNNS crash. Publisher
transcripts retain their supplied speaker labels. See the [diarization decision](docs/decisions/0003-diarization.md).

- Decisions: [`docs/decisions/`](docs/decisions/)
- Engine benchmark: [`bench/`](bench/)
- Swift modules and tests: [`WavepodKit/`](WavepodKit/) (`Networking`, `Resolver`, `Engine`, `NativeEngine`, `Pipeline`, `Speakers`, `Library`, `LLM`, `Player`, `UI`)

```sh
brew install xcodegen
xcodegen generate && open wavepod.xcodeproj      # app
(cd WavepodKit && swift test)                      # unit + snapshot tests
(cd WavepodKit && SNAPSHOT_RECORD=1 swift test)    # re-record snapshots after a deliberate UI change
```

License: [Apache-2.0](LICENSE).
