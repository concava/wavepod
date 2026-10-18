# bench — Phase 0 engine benchmark

Reproduces the numbers in [docs/decisions/0002](../docs/decisions/0002-asr-engine.md) and
[0003](../docs/decisions/0003-diarization.md). Nothing here ships in the app.

## Run

```sh
brew install uv whisper-cpp
./run_all.sh                      # kept configurations + short-form reference (~1 h; the reference runs on CPU)
./run_all.sh wk-vad fa-parakeet    # selected engines
```

Then `results/asr.md` (and `results/diarization.md`) hold the tables.

| Piece | What it does |
|---|---|
| `prepare_fleurs.py` | Builds ~10 min long-form files per language from FLEURS test (CC-BY-4.0) |
| `swift/` (`wavebench`) | WhisperKit, FluidAudio Parakeet and FluidAudio offline diarization |
| `run_whispercpp.py` | whisper.cpp with Metal, via Homebrew's `whisper-cli` |
| `run_python_ref.py` | openai/whisper (reference) and faster-whisper, long- or short-form |
| `run_pyannote.py` | pyannote community-1 diarization reference |
| `score.py` | WER (whisper normalizers + jiwer), RTF, load time, peak memory, DER |

Each runner writes `results/raw/<engine>/<id>.json`. Peak memory is the macOS "peak memory footprint" from
`/usr/bin/time -l`, which includes Metal and Core ML allocations.

Models are cached in `~/Library/Caches/wavepod-bench/models` (WhisperKit, Parakeet, ggml) and
`~/.cache/huggingface` / `~/.cache/whisper` (Python). Delete those folders to reclaim the disk space (~12 GB).

## Data

- `prepare_fleurs.py`: FLEURS test en/es/ca, ~10 min each, with sentence boundaries for short-form runs.
- `prepare_voxconverse.py`: 13 VoxConverse test files (60 min, 2–14 speakers), fetched by HTTP range requests
  from the 4.3 GB archive without downloading it.

## Not yet included

- The pyannote reference needs a Hugging Face token with the `pyannote/speaker-diarization-community-1` terms
  accepted: `HF_TOKEN=… ./run_all.sh ref-pyannote`.
- Earnings-21 (1 h single file); the golden set replaces it as the long-form test in Phase 1.
