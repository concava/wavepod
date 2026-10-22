# Decisions

Each record answers one question that had real alternatives, with the evidence that settled it. They are kept
because the reasons outlive the code: when someone asks "why not WhisperKit for English?" or "why not macOS 14?",
the answer and the measurements are here. A record is not rewritten when it changes; it gets an update with the
date, or a newer record supersedes it.

For how the app works today, read [How Wavepod works](../architecture.md); these records explain why.

| # | Question | Decided | Status |
| --- | --- | --- | --- |
| [0001](0001-references.md) | Which open-source projects do we learn from, and what may we take? | openai/whisper is the accuracy reference; WhisperKit and FluidAudio are dependencies; GPL projects are ideas only, no code. | Accepted |
| [0002](0002-asr-engine.md) | Which speech recognizer ships? | Parakeet TDT v3 for the 25 languages it covers; WhisperKit large-v3-turbo with our own VAD windows for the rest (Catalan included). whisper.cpp dropped. | Accepted, provisional until the golden-set references are verified |
| [0003](0003-diarization.md) | Which speaker detection ships, and on which macOS? | FluidAudio offline diarization (15.2 % DER on VoxConverse, 170× real time) in its own XPC process. macOS 14 crashed 100/100 runs inside Apple's BNNS, so **macOS 15 is the minimum**. | Accepted; pyannote comparison pending |
| [0004](0004-scriberr-engine.md) | Can users use their own GPU server? | Yes: Scriberr behind the same `Engine` protocol, local network only, key in Keychain. | Implemented |
| [0005](0005-distribution.md) | How is Wavepod distributed? | Free, a signed and notarized `.dmg` on GitHub Releases, Sparkle updates. | Accepted. Release pipeline ready, waiting on a Developer ID (build from source today) |
| [0006](0006-license-and-brand.md) | License and look? | Apache-2.0; a calm, editorial brand. | Accepted |
| [0007](0007-golden-set.md) | What do we measure quality on? | Six real episodes chosen by the owner (ES, EN, CA; 31 min to 4 h), scored on 20-minute windows; audio never in the repository. | Accepted (v1); references are drafts |
| [0008](0008-engineering-defaults.md) | Defaults the brief left open | macOS 15, Apple Silicon, Swift 6 strict concurrency, SQLite via GRDB, 4 GB memory budget, and others, each with a one-line reason. | Accepted; citation threshold superseded by 0010 |
| [0009](0009-evaluation-harness.md) | How is every change scored? | `eval/podeval`: fetch, draft, run, score, check against a committed baseline, in CI. | Accepted |
| [0010](0010-ask-long-transcripts.md) | How does Ask cover a 4-hour episode? | Read the whole transcript in bounded passes, keep recent conversation, exact-quote citations; local by default, ChatGPT or Claude plan optional. | Accepted; live cloud sign-in needs a manual check |

## Writing a new record

Add `NNNN-short-name.md` with: the question, the options considered, the decision rule (written before the
results when there are measurements), the results, the decision, and its status. Add a row here.
