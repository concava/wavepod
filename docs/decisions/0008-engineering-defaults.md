# 0008 — Engineering defaults

- Status: Accepted (engineering defaults; any can be reopened)
- Date: 2026-10-18

Choices the brief left open. Each has a one-line reason.

## Platform and build

- **Deployment target macOS 14**, Apple Silicon only. Built with the current Xcode (27) and Swift 6 language mode,
  strict concurrency complete.
- **One Swift package `WavepodKit`** with the modules `Resolver`, `Engine`, `Pipeline`, `Speakers`, `Library`,
  `LLM`, `Player`, `UI`, plus a thin app target. The Xcode project is generated with **XcodeGen** from `project.yml`
  so it never causes merge conflicts. Reason: modules are testable with `swift test`, the app stays a shell.
- Dependencies via SwiftPM only, versions pinned in `Package.resolved`.

## Data and features

- **Storage**: GRDB 7 over SQLite, FTS5 for keyword search, WAL mode. Raw ASR output (words, confidences,
  embeddings) is stored separately from rendered paragraphs, so re-rendering never re-runs ASR.
- **Semantic search**: a small multilingual embedding model (MIT/Apache) run with MLX or CoreML; vectors stored in
  SQLite, brute-force cosine (a few hundred thousand chunks fit; revisit only if search exceeds 100 ms).
- **Local LLM**: MLX-Swift with a ~4B-parameter Apache-2.0 instruct model, 4-bit (≈ 2.5 GB). Ollama is optional.
  The model is chosen in Phase 5 with the chat-citation eval.
- **Citations**: the LLM returns JSON `{claim, quote, start}`. A validator checks that a word span at `start ± 2 s`
  exists and that `quote` matches it (normalized fuzzy match ≥ 0.85). If not, the answer is rejected and retried
  once with the failure; if that fails too, the claim is dropped and the user sees "not found in this episode".

## Resource limits (16 GB Mac is the design floor)

- Pipeline peak memory cap: **4 GB** (ASR + diarization), measured by `podeval`.
- LLM and ASR never run at the same time; the job queue serialises them.
- Long audio is processed in 30-minute windows with 10 s overlap for diarization and the engine's own chunking
  for ASR. A 3 h episode must stay under the cap.

## Testing and CI

- XCTest per module (Swift Testing where it is simpler). Snapshot tests with `swift-snapshot-testing` (MIT), light
  and dark, three Dynamic Type sizes.
- **CI**: GitHub Actions. Unit and snapshot tests run on GitHub-hosted macOS runners. `podeval` runs on a
  **self-hosted Apple Silicon runner** (the dev Mac to start), because models are large and the golden set is
  private.
- Python reference tooling (openai/whisper, faster-whisper, pyannote, jiwer, meeteval) lives only in `bench/`,
  managed with `uv`, Python 3.12.

## Privacy

- One `HTTPClient` actor through which every request goes. It checks the allow-list and writes the Network log.
  A unit test fails if any module uses `URLSession` directly.
- Allow-list hosts: feed hosts the user subscribes to, `itunes.apple.com`, `api.podcastindex.org`, Spotify oEmbed
  (`open.spotify.com/oembed`, metadata only), Hugging Face model downloads, GitHub (yt-dlp, Sparkle appcast),
  the user's Scriberr host.

## Observability

- `os_signpost` intervals per pipeline stage; an Instruments template in `tools/`. `os.Logger` per module, no
  third-party analytics and no crash reporter that sends data.
