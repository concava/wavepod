# wavepod

A private, podcast-native transcription app for macOS. Paste a podcast link or drop an audio/video file and get a
speaker-named, searchable transcript you can read, listen to and ask questions about — all on your Mac.

Requires **macOS 15 or later** on Apple Silicon.

Status: **Phase 5 — library, local AI and shows**: a checkpointed on-device pipeline (or your own Scriberr
server) fills a persistent library; speakers are suggested from per-show voice profiles; keyword and meaning
search open the exact moment; summaries, chapters, translation and Ask run on a local model with every cited
timestamp checked; subscribed shows can be transcribed automatically. See
[implementation notes](docs/implementation.md) and the golden-set harness in [`eval/`](eval/).

- Decisions: [`docs/decisions/`](docs/decisions/)
- Engine benchmark: [`bench/`](bench/)
- Ask: reads every transcript section, supports follow-up questions and cites the original words. Local is the
  default; **Settings → Ask → My ChatGPT plan** optionally connects your existing eligible plan for cloud
  answers. Questions, recent conversation and transcript text go to OpenAI in that mode; audio does not.
  See the [Ask decision](docs/decisions/0010-ask-long-transcripts.md) for coverage and validation limits.
- Swift modules and tests: [`WavepodKit/`](WavepodKit/) (`Networking`, `Resolver`, `Engine`, `NativeEngine`, `Pipeline`, `Speakers`, `Library`, `LLM`, `Player`, `UI`)

```sh
brew install xcodegen
xcodegen generate && open wavepod.xcodeproj      # app
(cd WavepodKit && swift test)                      # unit + snapshot tests
(cd WavepodKit && SNAPSHOT_RECORD=1 swift test)    # re-record snapshots after a deliberate UI change
```

License: [Apache-2.0](LICENSE).
