# How Wavepod works

This is the map of the app: what runs where, what happens to an episode from the moment a link is pasted, and
where everything is stored. The *why* behind each choice is in [decisions](decisions/README.md).

## The pieces

Wavepod is one macOS app bundle with three processes and one Swift package.

```
Wavepod.app
├── wavepod                 the app: SwiftUI window, library, queue, player, Ask
├── WavepodEngine.xpc       speech recognition and speaker detection, in its own process
└── wavepod-feeds           hourly background checker (LaunchAgent), works while the app is closed
```

| Process | Bundle ID | Why it is separate |
| --- | --- | --- |
| App | `app.wavepod.mac` | The window and everything you touch. |
| Engine (XPC service) | `app.wavepod.engine` | Model inference can use gigabytes and, on macOS 14, could crash inside Apple's frameworks. In its own process a crash or a memory overrun costs one stage, not the app. A stage above 3,500 MiB is stopped, keeping the whole app inside a 4 GB budget. |
| Feed checker | `app.wavepod.feeds` | Registered with `SMAppService` from Settings. Runs hourly, checks followed podcasts and runs their opted-in downloads, transcriptions and summaries. |

A file lease stops the app and the feed checker from running the queue at the same time, and a second lease
serializes model work across processes.

### Swift modules (`WavepodKit/`)

```
UI ──► Pipeline ──► Engine ◄── NativeEngine (WhisperKit, FluidAudio)
 │        │  │
 │        │  ├──► Resolver ──► Networking
 │        │  ├──► Speakers
 │        │  └──► LLM (MLX)
 ├──► Player
 └──► Library (GRDB / SQLite)
```

| Module | Does |
| --- | --- |
| `Networking` | The only HTTP client. Enforces the host allow-list and writes the network log. |
| `Resolver` | Turns a link into an episode or a show: Spotify, Apple Podcasts, YouTube, RSS, websites, files. |
| `Engine` | The contract every recognizer implements (native or Scriberr), plus model installation. |
| `NativeEngine` | Parakeet and WhisperKit recognition, Silero VAD and FluidAudio speaker detection, on local files only. |
| `Pipeline` | The durable job queue, decoding, 30-minute windows, alignment, subscriptions and the battery policy. |
| `Speakers` | Suggests speaker names from voice profiles, self-introductions and show notes. |
| `Library` | SQLite store: episodes, transcripts, speakers, notes, chat, full-text and vector search. |
| `LLM` | Local Qwen3-4B on MLX, embeddings, cited answers and summaries, the citation validator, optional ChatGPT and Claude plans. |
| `Player` | Audio playback, independent of which episode is on screen. |
| `UI` | `AppModel` and every view. |

Command-line tools built from the same code: `wavepod-resolve` (link → metadata), `wavepod-transcribe` (the
full pipeline on a file, used by the golden-set evaluation) and `wavepod-ask` (Ask on a stored transcript).

## The life of an episode

### 1. Resolve the link

`Resolver` classifies the input with `LinkClassifier`, then:

- **RSS or a show's website**: finds the feed and returns the show with its episodes.
- **Apple Podcasts**: looks the show up and reads its public RSS feed.
- **Spotify**: reads the episode's public title and show, searches Apple's podcast directory for the same show,
  and matches the episode in its RSS feed. A confident match continues; close matches are shown as candidates
  ("Choose the matching episode"). Spotify audio itself is never used.
- **YouTube**: a pinned, hash-verified `yt-dlp` reads metadata only (user config and plugins ignored); the
  chosen M4A audio is downloaded through Wavepod's own client.
- **A file**: used as is.

If the feed publishes a **timed transcript** (`podcast:transcript`), it is used directly and download and
recognition are skipped. Untimed published text falls back to processing the audio.

### 2. Queue

`JobQueue` is an actor and every state change is written to disk, so a quit, crash or restart resumes where it
stopped. Jobs can be paused, cancelled and retried. On battery, `PowerPolicy` pauses the queue below 20 % and
resumes at 25 % or on power; Low Power Mode always pauses it.

### 3. Download and decode

Downloads use HTTP ranges and keep partial bytes and validators, so a dropped connection continues rather than
restarting. Audio is decoded as a stream into 16 kHz mono WAV.

### 4. Transcribe and detect speakers, window by window

Long audio is cut into **30-minute windows that overlap by 10 seconds**. Each window is transcribed and
diarized on its own, and both results are checkpointed (`WindowedTranscriber`). Memory therefore does not grow
with episode length: a 4-hour episode peaks at the same ~0.9 GB as a 20-minute one.

- **Parakeet** (most languages) decodes a whole window with its own long-form mode.
- **WhisperKit** (languages Parakeet lacks, such as Catalan) decodes pieces of at most 28 seconds cut at
  silences found by Silero VAD, checkpointing after each.
- **FluidAudio** finds who speaks when and produces a voice embedding per speaker.
- Optionally, your own **Scriberr** server does the recognition instead (local network only, key in Keychain).

No audio is dropped: a stretch with no recognized words is marked in the transcript.

### 5. Stitch and align

Words are matched to speakers word by word. Windows are joined at the middle of their overlap so no word appears
twice, and voice embeddings link each window's local speaker labels into episode-wide speakers. The raw
recognizer and diarizer output is kept separate from the rendered transcript, so renaming or re-rendering never
reruns recognition.

### 6. Name the speakers

`Speakers` proposes names, never silently:

- **Voice**: a speaker confirmed in an earlier episode of the same show becomes a voice profile. A new voice
  matching it (cosine ≥ 0.75 and ≥ 0.08 ahead of the next) is suggested by name.
- **Introductions**: "I'm Marta Vidal" counts only when the show notes or feed people corroborate it.
- **Show notes**: names in the description stay candidates, with the quote and time that support them.

Suggestions show a confidence. Confirming one, or renaming, updates every paragraph and the show's profile.

### 7. Store and index

The record (transcript, speakers, evidence, summary, chat) goes into SQLite in one transaction.
Every later change, such as an answer, a summary, a speaker name, artwork or a download, goes through
`LibraryStore.update`. It reads, changes and saves the record in one write transaction, so two writers never
overwrite each other, and a deleted episode stays deleted. `LibraryStore.changes()` says which parts changed, and
the app updates only those parts. `Workspace` wires the store, network client, engine, answer model and job queue
the same way in the app and the feed checker.
Text is indexed for keyword search (FTS5) and, when the embeddings model is installed, as multilingual E5-small
vectors for search by meaning. Search results open the exact moment.

### 8. Summary

A finished episode gets a summary automatically (`EpisodeNotesService`, shared by the app and the feed checker).
`AnswerModel` decides which model writes it: the local model, or the ChatGPT or Claude plan chosen in
Settings → Ask, which reads larger sections. The model reads the whole transcript in bounded sections and writes a
summary in sections: who's there, main discussion, industry news, audience Q&A, closing. If the model is missing,
the notes are marked pending and written once it is installed. The feed checker has no window, so it can't read
the ChatGPT sign-in from the Keychain: a ChatGPT summary waits for the app, which writes it on the plan.

## Ask

Ask reads the **whole** transcript in bounded passes, keeps recent conversation for follow-ups, and answers in
the language of the question. It runs on the local model by default. Settings › Ask can instead use an
eligible **ChatGPT** plan or **Claude** plan (through an isolated Claude Code sign-in). Those send the question,
recent conversation and transcript text to the provider, never audio.

`AskSession` owns one question from start to finish: it saves the question, asks `AnswerModel` for the model and
part size, and saves the answer, "Stopped…" or the error to the episode the question was asked on.
`AnswerModel` is the one place that knows the choice, whether it is ready and what it needs. Ask, summaries, the
job queue and the feed checker all use it.

### Every citation is checked

Generated answers and summaries are claims of the form `{claim, quote, start}`. The validator accepts
a claim only if its quote appears word for word (normalized) in the transcript segment at that time, and in
the context the model was given. The timestamp shown is where the quoted words actually start. Invalid output
is retried once. If nothing survives, the answer is "not found", which is different from an error.
Translations are shown beside the original with its timestamps and never replace it.

## Podcasts you follow

Following a show stores a subscription. Its existing episodes are marked as seen, so following never imports a
back catalogue. Feeds are checked conditionally (ETag / Last-Modified), at most hourly, by the app or the feed
checker. Each subscription has its own settings: transcribe, summarize (which implies transcribe), download
audio for offline playback, and keep only the latest N downloads. Retention deletes audio only, never
transcripts or notes. The Podcasts page shows each show's five newest episodes with their state.

## Where data lives

Everything is in `~/Library/Application Support/wavepod/`:

| Path | Holds |
| --- | --- |
| `library.sqlite` | Episodes, transcripts, speakers, notes, chat, subscriptions, search indexes (WAL mode) |
| `jobs/<UUID>/` | Queue state and per-window checkpoints (`window-N.wav`, `asr-N.json`, `diar-N.json`) |
| `models/` | Downloaded models, pinned to a revision and SHA-256-verified |
| `audio/` | Downloaded episode audio |
| `network.json` | The network log |

Checkpoints are written atomically.

## Privacy and the network

Audio and transcripts never leave the Mac unless you choose a cloud plan for Ask, and even then audio is never
sent. All app traffic goes through `Networking`, which allows only the hosts a feature needs and logs each
request's host, purpose and response code (never keys or signed query strings). The log is in Settings › Data and
Privacy. Two tools own their own network stacks and are logged as invocations: `yt-dlp` (YouTube metadata) and
Claude Code (Claude plan answers).

## The interface

`AppModel` (`@Observable`, main actor) holds all UI state. The window is a sidebar plus one content card:

- **Home**: start card, jobs in progress, the library by date, stats.
- **Podcasts**: the show you just opened plus every followed show, five newest episodes each.
- **Episode**: two cards. Left, the episode header (artwork, podcast menu, title), Ask, answers and the summary;
  right, transcript or about (closable).
- **Settings** and the first-run **welcome** are overlays: General, Transcription, Ask, Queue,
  Data and Privacy.

The episode on screen and the episode in the player are independent: browsing never stops or swaps playback.
Only Play, a timestamp or a citation loads the viewed episode into the player.

## Measured

On an M3 with 16 GB and cached models (2026-10-19):

| Audio | Length | Time | Speed | Peak memory |
| --- | --- | --- | --- | --- |
| Golden windows (ES) | 3 × 20 min | 27–29 s each | 43× real time | 0.90 GB |
| Acquired "Ferrari" (EN) | 3 h 58 min | 5 min 19 s | 45× real time | 0.93 GB |
| Two full Itnig episodes (ES) | 1 h 44, 2 h 05 | 2 min 23 s, 2 min 48 s | 44× real time | n/a |

Ask on the local model peaks at about 3.6 GB. Accuracy figures are in [0002](decisions/0002-asr-engine.md) and
[0010](decisions/0010-ask-long-transcripts.md); the golden-set references are still machine drafts, so they
compare engines rather than prove absolute accuracy.
