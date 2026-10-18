# bench — Phase 0 engine benchmark

Reproduces the numbers in [docs/decisions/0002](../docs/decisions/0002-asr-engine.md) and
[0003](../docs/decisions/0003-diarization.md). Nothing here ships in the app.

## Run

```sh
brew install uv whisper-cpp
./run_all.sh                      # all engines (several hours: the openai/whisper reference runs on CPU)
./run_all.sh wk-turbo fa-parakeet # selected engines
```

Then `results/asr.md` (and `results/diarization.md`) hold the tables.

| Piece | What it does |
|---|---|
| `prepare_fleurs.py` | Builds ~10 min long-form files per language from FLEURS test (CC-BY-4.0) |
| `swift/` (`wavebench`) | WhisperKit, FluidAudio Parakeet and FluidAudio offline diarization |
| `run_whispercpp.py` | whisper.cpp with Metal, via Homebrew's `whisper-cli` |
| `run_python_ref.py` | openai/whisper (reference) and faster-whisper |
| `score.py` | WER (whisper normalizers + jiwer), RTF, load time, peak memory, DER |

Each runner writes `results/raw/<engine>/<id>.json`. Peak memory is the macOS "peak memory footprint" from
`/usr/bin/time -l`, which includes Metal and Core ML allocations.

Models are cached in `~/Library/Caches/wavepod-bench/models` (WhisperKit, Parakeet, ggml) and
`~/.cache/huggingface` / `~/.cache/whisper` (Python). Delete those folders to reclaim the disk space (~12 GB).

## Not yet included

- Diarization data (VoxConverse test subset) and the pyannote reference: needs a Hugging Face token with the
  `pyannote/speaker-diarization-community-1` terms accepted.
- Earnings-21 long-form file (1 h) for memory on a single long input.
