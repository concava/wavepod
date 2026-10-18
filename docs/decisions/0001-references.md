# 0001 — Reference projects: what we take and why

- Status: Accepted
- Date: 2026-10-18
- Context: wavepod ships under Apache-2.0 (see [0006](0006-license-and-brand.md)). Every reference was read at
  the commit listed below. Licenses were confirmed from each repository's LICENSE file, not the README.

| Project | Commit read | License (from LICENSE) | How we use it |
|---|---|---|---|
| openai/whisper | `8609812` (2026-08-31) | MIT | Accuracy reference in evaluation; text normalizers ported for scoring |
| rishikanthc/scriberr | `a353078` (2026-09-20) | MIT | Design ideas; its HTTP API is the target of our optional Scriberr engine |
| kaixxx/noScribe | `03d4d18` (2026-10-06) | GPL-3.0 | Ideas only. No code is copied |
| argmaxinc/WhisperKit | `9f99b5c` (2026-10-10) | MIT | Candidate shipping ASR dependency (Swift package) |
| FluidInference/FluidAudio | `2d6c42c` (2026-10-16) | Apache-2.0 | Candidate shipping ASR, VAD and diarization dependency (Swift package) |

WhisperKit and FluidAudio were not on the original list. They are here because they are the two Swift-native
candidates in the engine benchmark ([0002](0002-asr-engine.md), [0003](0003-diarization.md)).

## openai/whisper (MIT)

Role: the accuracy reference. It runs in the Python harness only (`bench/`). It never ships in the app.

What we take:

- **Decoding defaults** from `transcribe()`: temperature fallback `(0.0, 0.2, …, 1.0)`, triggered when
  `compression_ratio > 2.4` or `avg_logprob < -1.0`; segment treated as silence when
  `no_speech_prob > 0.6` and the log-prob test also fails. The benchmark runs the reference with these defaults
  so that "within 1.5 WER points of openai/whisper large-v3" has a fixed meaning.
- **Long-form behaviour**: `condition_on_previous_text` (default `True`) helps consistency but causes repetition
  loops on music and long silences. `hallucination_silence_threshold` together with `word_timestamps` skips
  silent stretches. We test both settings in the benchmark and record which one each engine uses.
- **Word timestamps** (`timing.py`): DTW over cross-attention weights of the model's alignment heads, then
  punctuation is merged into the neighbouring word (`prepend_punctuations` / `append_punctuations`). Our word
  model keeps the same merge rule, so word boundaries compare 1:1 with the reference.
- **Text normalizers** (`whisper/normalizers`: `EnglishTextNormalizer`, `BasicTextNormalizer`). Every WER we report
  is computed after this normalization. `podeval` uses a Swift port of these normalizers, with the MIT notice kept
  in the file header and in `THIRD_PARTY_LICENSES.md`. A parity test checks the port against the Python output on
  the golden-set references.

What we do not take: the PyTorch model code, the Triton kernels, the CLI.

## rishikanthc/scriberr (MIT)

Role: the closest existing product. It is a self-hosted Go server plus Python model workers, with a web UI.
We study its design. Because it is MIT we may reuse code, but almost nothing ports directly from Go/Python into
a Swift app, so we expect to reuse ideas and its API contract, not source.

What we take:

- **Adapter registry with declared capabilities** (`internal/transcription/interfaces/interfaces.go`):
  `ModelAdapter` → `TranscriptionAdapter` / `DiarizationAdapter`, each declaring `ModelCapabilities`
  (languages, memory requirement, features) and a `ParameterSchema` list (type, default, min/max, UI group).
  Our `Engine` protocol has the same shape: an engine declares what it supports and the UI is built from that
  declaration. This is how the native engine and the Scriberr engine sit behind one protocol.
- **Pipeline split**: ASR → word alignment (WhisperX) → diarization (pyannote `speaker-diarization-community-1`,
  or NVIDIA Sortformer) → merge words with speakers (`unified_service.go`). Our pipeline has the same stages,
  run natively.
- **Job queue** (`internal/queue/queue.go`): a channel of job IDs, a worker count sized below the CPU count for
  transcription workloads, per-OS process kill for cancel. We take the job states and the cancel semantics. We
  change two things: our queue is a Swift actor, and every stage writes a checkpoint so a job resumes after quit
  or crash. Scriberr restarts the job.
- **Speaker mappings as data** (`GET/POST /transcription/:id/speakers`): a rename stores a mapping
  `SPEAKER_00 → "Ana"` and never rewrites the transcript. We do the same, so a rename applies everywhere at once
  and can be undone.
- **Summary and chat** (`internal/llm`, chat sessions per transcript): LLM behind a small provider interface
  (Ollama, OpenAI-compatible), with a per-model context-window lookup. We keep the provider interface (MLX-Swift
  local by default, Ollama optional). We add what Scriberr does not have: retrieval over transcript chunks and
  validation that every cited timestamp exists and supports the claim ([0008](0008-engineering-defaults.md)).
- **HTTP API** (`/api/v1`, auth with `X-API-Key` or Bearer JWT, `POST /transcription/submit` with model, language,
  diarization and speaker-count fields, then `GET /:id/status` and `GET /:id/transcript`). This is the contract of
  our optional Scriberr engine ([0004](0004-scriberr-engine.md)).

What we do not take: multi-user auth, the web UI, the Docker/CUDA packaging, Python environment management with
`uv` at runtime.

## kaixxx/noScribe (GPL-3.0) — ideas only

wavepod is Apache-2.0, so no noScribe code may enter this repository. These notes describe behaviour. Our
implementation is written from the descriptions below, not from the source.

Ideas we take:

- **Speaker assignment by best-fitting segment**: for each transcript span, choose the *shortest* diarization
  segment that covers at least 80 % of the span; if none reaches 80 %, take the segment with the largest overlap.
  A span that matches a short segment inside a longer turn of another speaker indicates overlapping speech.
  We do this per word rather than per segment ([0003](0003-diarization.md)).
- **Overlap marking**: overlapping speech is marked in the transcript (noScribe prefixes the speaker with `//`).
  We store an `overlap` flag per word and render it as a style, not as text.
- **Pause marking**: pauses above a user threshold (none, 1 s+, 2 s+, 3 s+) are written into the transcript as a
  marker with the duration. We store pauses as data (gap between words) and render them on demand.
- **Disfluency control**: optionally keep "um/uh" by prompting the decoder. We expose it as a setting and measure
  its WER effect in the benchmark (the human references in the golden set mostly drop disfluencies).
- **Format limits**: VTT cannot carry pause and overlap markers. Our exporters drop them there and keep them in
  Markdown, DOCX and JSON.

## argmaxinc/WhisperKit (MIT)

Swift package that runs Whisper converted to CoreML on the Neural Engine and GPU. It supports word timestamps,
VAD-based chunking and every language Whisper supports, including Catalan. Argmax recommends
`large-v3-v20240930_626MB` (compressed large-v3-turbo) for multilingual accuracy and `large-v3-v20240930_turbo` for
speed on macOS. Both are benchmark candidates.

## FluidInference/FluidAudio (Apache-2.0)

Swift package with CoreML models for ASR (Parakeet TDT v3 and its "Ultra" re-training, 25 European languages),
VAD (Silero) and diarization (offline pyannote community-1 pipeline, Sortformer, LS-EEND), plus speaker embeddings.

Important limit: **Parakeet v3 does not cover Catalan.** It cannot be the only ASR engine. It is a candidate
fast path for English and Spanish if its WER holds on podcasts.

The model weights have their own licenses (Parakeet: CC-BY-4.0; pyannote community-1: CC-BY-4.0). They are
listed in the license audit, not covered by FluidAudio's Apache-2.0.
