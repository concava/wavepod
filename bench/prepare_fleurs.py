"""Build long-form WER test files from FLEURS (CC-BY-4.0).

For each language, take one recording per unique sentence from the test split, in file order, until the target
duration is reached. Concatenate them with 0.5 s of silence into one 16 kHz mono WAV, so every engine runs its
long-form path. The reference is the joined raw transcriptions.

Usage: uv run prepare_fleurs.py [--minutes 10] [--langs en_us es_419 ca_es]
Writes data/fleurs/<lang>.wav, data/fleurs/<lang>.txt and adds entries to data/manifest.json.
"""

import argparse
import csv
import json
import tarfile
import urllib.request
from pathlib import Path

import numpy as np
import soundfile as sf

BASE = "https://huggingface.co/datasets/google/fleurs/resolve/main/data"
HERE = Path(__file__).parent
DATA = HERE / "data"
SR = 16_000
# FLEURS code -> ISO 639-1 code used by the engines.
ISO = {"en_us": "en", "es_419": "es", "ca_es": "ca"}


def fetch(url: str, dest: Path) -> Path:
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        print(f"download {url}")
        tmp = dest.with_suffix(dest.suffix + ".part")
        urllib.request.urlretrieve(url, tmp)
        tmp.rename(dest)
    return dest


def build(lang: str, minutes: float) -> dict:
    raw = DATA / "raw" / "fleurs" / lang
    tsv = fetch(f"{BASE}/{lang}/test.tsv", raw / "test.tsv")
    tar = fetch(f"{BASE}/{lang}/audio/test.tar.gz", raw / "test.tar.gz")

    rows, seen = [], set()
    with tsv.open(newline="", encoding="utf-8") as f:
        for row in csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            sentence_id, wav_name, raw_text = row[0], row[1], row[2]
            if sentence_id not in seen:
                seen.add(sentence_id)
                rows.append((wav_name, raw_text))

    wanted = {name for name, _ in rows}
    clips: dict[str, np.ndarray] = {}
    with tarfile.open(tar) as t:
        for member in t:
            name = Path(member.name).name
            if name in wanted:
                data, sr = sf.read(t.extractfile(member), dtype="float32")
                assert sr == SR, f"{name}: {sr} Hz"
                clips[name] = data if data.ndim == 1 else data.mean(axis=1)

    gap = np.zeros(SR // 2, dtype=np.float32)
    parts, texts, total = [], [], 0.0
    for name, text in rows:
        if name not in clips:
            continue
        parts += [clips[name], gap]
        texts.append(text)
        total += len(clips[name]) / SR + 0.5
        if total >= minutes * 60:
            break

    out = DATA / "fleurs"
    out.mkdir(parents=True, exist_ok=True)
    wav, ref = out / f"{lang}.wav", out / f"{lang}.txt"
    sf.write(wav, np.concatenate(parts), SR, subtype="PCM_16")
    ref.write_text(" ".join(texts) + "\n", encoding="utf-8")
    print(f"{lang}: {len(texts)} sentences, {total / 60:.1f} min")
    return {
        "id": f"fleurs-{lang}",
        "lang": ISO[lang],
        "audio": str(wav.relative_to(HERE)),
        "ref": str(ref.relative_to(HERE)),
        "duration_s": round(total, 2),
        "kind": "asr",
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--minutes", type=float, default=10)
    p.add_argument("--langs", nargs="+", default=list(ISO))
    args = p.parse_args()

    manifest_path = DATA / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else []
    for lang in args.langs:
        entry = build(lang, args.minutes)
        manifest = [m for m in manifest if m["id"] != entry["id"]] + [entry]
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
