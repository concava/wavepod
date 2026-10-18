#!/bin/zsh
# Phase 0 ASR benchmark: prepare data, run every engine, score. Run from anywhere; AC power, nothing else heavy.
# Engines can be picked: ./run_all.sh wk-turbo fa-parakeet   (default: all)
set -euo pipefail
cd "${0:A:h}"
RAW=results/raw
mkdir -p $RAW

uv sync -q
[[ -f data/manifest.json ]] || uv run prepare_fleurs.py --minutes 10
swift build -c release --package-path swift >/dev/null
WB=swift/.build/release/wavebench

timed() {  # timed <engine-dir> <command...>: peak memory of the whole process -> <engine-dir>/time.txt
  local dir=$RAW/$1; shift
  mkdir -p $dir
  /usr/bin/time -l "$@" 2> >(tee $dir/time.txt >&2)
}

engines=(${@:-wk-turbo wk-626 fa-parakeet wcpp-turbo wcpp-v3 ref-fw ref-openai})
for e in $engines; do
  echo "== $e"
  case $e in
    wk-turbo)    timed wk-large-v3-v20240930_turbo $WB whisperkit large-v3-v20240930_turbo ;;
    wk-626)      timed wk-large-v3-v20240930_626MB $WB whisperkit large-v3-v20240930_626MB ;;
    fa-parakeet) timed fa-parakeet-ultra $WB parakeet ;;
    wcpp-turbo)  uv run run_whispercpp.py --model large-v3-turbo ;;
    wcpp-v3)     uv run run_whispercpp.py --model large-v3 ;;
    ref-fw)      timed ref-fw .venv/bin/python run_python_ref.py --engine fw ;;
    ref-openai)  timed ref-openai .venv/bin/python run_python_ref.py --engine openai ;;
    *) echo "unknown engine $e"; exit 2 ;;
  esac
done
uv run score.py
