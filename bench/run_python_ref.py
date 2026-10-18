"""Run a Python reference ASR engine over the manifest.

Engines:
  openai   openai/whisper large-v3, library defaults (the accuracy reference)
  fw       faster-whisper large-v3, int8 on CPU

Each file writes results/raw/<engine>/<id>.json = {text, proc_s, load_s}.
Run it under `/usr/bin/time -l` (run_all.sh does) to capture peak memory for the whole process.

Usage: uv run run_python_ref.py --engine openai [--ids fleurs-ca_es ...] [--device cpu]
"""

import argparse
import json
import time
from pathlib import Path

HERE = Path(__file__).parent


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--engine", choices=["openai", "fw"], required=True)
    p.add_argument("--model", default="large-v3")
    p.add_argument("--device", default="cpu")
    p.add_argument("--ids", nargs="*")
    args = p.parse_args()

    manifest = json.loads((HERE / "data" / "manifest.json").read_text())
    items = [m for m in manifest if m["kind"] == "asr" and (not args.ids or m["id"] in args.ids)]
    out = HERE / "results" / "raw" / (f"ref-{args.engine}")
    out.mkdir(parents=True, exist_ok=True)

    t0 = time.perf_counter()
    if args.engine == "openai":
        import whisper

        model = whisper.load_model(args.model, device=args.device)

        def run(path: str, lang: str) -> str:
            # fp16 is unsupported on CPU; everything else stays at library defaults.
            r = model.transcribe(path, language=lang, fp16=False)
            return r["text"]
    else:
        from faster_whisper import WhisperModel

        model = WhisperModel(args.model, device="cpu", compute_type="int8")

        def run(path: str, lang: str) -> str:
            # Pass samples, not a path: faster-whisper's PyAV decoder breaks with some PyAV versions.
            import soundfile as sf

            audio, _ = sf.read(path, dtype="float32")
            segments, _ = model.transcribe(audio, language=lang, beam_size=5)
            return " ".join(s.text.strip() for s in segments)
    load_s = time.perf_counter() - t0

    for m in items:
        t = time.perf_counter()
        text = run(str(HERE / m["audio"]), m["lang"])
        proc_s = time.perf_counter() - t
        (out / f"{m['id']}.json").write_text(
            json.dumps({"text": text, "proc_s": proc_s, "load_s": load_s}, ensure_ascii=False) + "\n"
        )
        print(f"{m['id']}: RTF {proc_s / m['duration_s']:.3f}")


if __name__ == "__main__":
    main()
