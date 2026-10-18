"""Run whisper.cpp (Metal) over the manifest.

whisper-cli loads the model on every call, so each file runs in its own process under `/usr/bin/time -l`.
load_s and proc_s come from whisper.cpp's own timing printout; peak memory is the max over all files and is
written to results/raw/<engine>/time.txt in the same format run_all.sh produces for the other engines.

Usage: uv run run_whispercpp.py --model large-v3-turbo [--ids ...]
Needs: brew install whisper-cpp
"""

import argparse
import json
import re
import subprocess
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
MODELS = Path.home() / "Library/Caches/wavepod-bench/models/ggml"
MODEL_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{}.bin"


def ms(pattern: str, log: str) -> float:
    m = re.search(pattern + r"\s*=\s*([\d.]+) ms", log)
    return float(m.group(1)) / 1000 if m else 0.0


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--model", default="large-v3-turbo")
    p.add_argument("--ids", nargs="*")
    p.add_argument("--no-context", action="store_true",
                   help="--max-context 0: do not condition each window on the previous text (stops repetition loops)")
    args = p.parse_args()

    model = MODELS / f"ggml-{args.model}.bin"
    if not model.exists():
        MODELS.mkdir(parents=True, exist_ok=True)
        print(f"download {model.name}")
        urllib.request.urlretrieve(MODEL_URL.format(args.model), model.with_suffix(".part"))
        model.with_suffix(".part").rename(model)

    manifest = json.loads((HERE / "data" / "manifest.json").read_text())
    items = [m for m in manifest if m["kind"] == "asr" and (not args.ids or m["id"] in args.ids)]
    out = HERE / "results" / "raw" / (f"wcpp-{args.model}" + ("-noctx" if args.no_context else ""))
    out.mkdir(parents=True, exist_ok=True)

    peak = 0
    for m in items:
        cmd = ["/usr/bin/time", "-l", "whisper-cli", "-m", str(model), "-f", str(HERE / m["audio"]),
               "-l", m["lang"], "-otxt", "-of", str(out / m["id"])] + (["-mc", "0"] if args.no_context else [])
        t = time.perf_counter()
        log = subprocess.run(cmd, capture_output=True, text=True, check=True).stderr
        fp = re.search(r"(\d+)\s+peak memory footprint", log)
        peak = max(peak, int(fp.group(1)) if fp else 0)
        load_s = ms("load time", log)
        total_s = time.perf_counter() - t  # wall time of the whole process, so load is subtracted below
        text = (out / f"{m['id']}.txt").read_text(encoding="utf-8")
        (out / f"{m['id']}.json").write_text(
            json.dumps({"text": text, "proc_s": total_s - load_s, "load_s": load_s}, ensure_ascii=False) + "\n"
        )
        print(f"{m['id']}: RTF {(total_s - load_s) / m['duration_s']:.4f}")
    (out / "time.txt").write_text(f"{peak}  peak memory footprint\n")


if __name__ == "__main__":
    main()
