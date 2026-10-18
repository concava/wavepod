"""Score every engine in results/raw/ against the manifest and write results/asr.md (and diarization.md).

WER: whisper's EnglishTextNormalizer for English, BasicTextNormalizer otherwise, then corpus-level WER
(total edits / total reference words) with jiwer.
RTF: sum(proc_s) / sum(duration). Model load is reported separately.
Peak memory: "peak memory footprint" from /usr/bin/time -l (results/raw/<engine>/time.txt).
DER: pyannote.metrics, 0.25 s collar, overlap scored.
"""

import json
import re
from pathlib import Path

import jiwer
from whisper.normalizers import BasicTextNormalizer, EnglishTextNormalizer

HERE = Path(__file__).parent
RAW = HERE / "results" / "raw"
NORMALIZERS = {"en": EnglishTextNormalizer()}
BASIC = BasicTextNormalizer()


def peak_gb(engine_dir: Path, field: str = "peak memory footprint") -> float | None:
    f = engine_dir / "time.txt"
    if not f.exists():
        return None
    m = re.search(r"(\d+)\s+" + field, f.read_text())
    return int(m.group(1)) / 1e9 if m else None


def rss_gb(engine_dir: Path) -> float | None:
    """Max RSS also counts memory-mapped model weights, which the footprint leaves out."""
    return peak_gb(engine_dir, "maximum resident set size")


def score_asr(manifest: list[dict]) -> str:
    items = [m for m in manifest if m["kind"] == "asr"]
    langs = sorted({m["lang"] for m in items})
    rows = []
    for engine_dir in sorted(p for p in RAW.iterdir() if p.is_dir()):
        per_lang, proc, dur, load = {}, 0.0, 0.0, None
        for lang in langs:
            refs, hyps = [], []
            for m in (m for m in items if m["lang"] == lang):
                f = engine_dir / f"{m['id']}.json"
                if not f.exists():
                    continue
                r = json.loads(f.read_text())
                if "text" not in r:
                    break
                norm = NORMALIZERS.get(lang, BASIC)
                refs.append(norm((HERE / m["ref"]).read_text(encoding="utf-8")))
                hyps.append(norm(r["text"]))
                proc += r["proc_s"]
                dur += m["duration_s"]
                load = r["load_s"]
            if refs:
                per_lang[lang] = 100 * jiwer.wer(refs, hyps)
        if not per_lang:
            continue
        rows.append((engine_dir.name, per_lang, proc / dur, load, peak_gb(engine_dir), rss_gb(engine_dir)))

    def cell(x, fmt):
        return format(x, fmt) if x is not None else "—"

    head = "| Engine | " + " | ".join(f"WER {l} %" for l in langs) + " | RTF | RTFx | Load s | Footprint GB | RSS GB |"
    lines = [head, "|" + "---|" * (len(langs) + 6)]
    for name, per_lang, rtf, load, peak, rss in rows:
        wers = " | ".join(cell(per_lang.get(l), ".2f") for l in langs)
        lines.append(f"| `{name}` | {wers} | {rtf:.4f} | {1 / rtf:.1f} | {cell(load, '.1f')} | {cell(peak, '.2f')} | {cell(rss, '.2f')} |")
    return "\n".join(lines) + "\n"


def score_diarization(manifest: list[dict]) -> str | None:
    items = [m for m in manifest if m["kind"] == "diarization"]
    if not items:
        return None
    from pyannote.core import Annotation, Segment
    from pyannote.metrics.diarization import DiarizationErrorRate

    def load_rttm(text: str) -> Annotation:
        ann = Annotation()
        for line in text.splitlines():
            f = line.split()
            if f and f[0] == "SPEAKER":
                start, length = float(f[3]), float(f[4])
                ann[Segment(start, start + length)] = f[7]
        return ann

    lines = ["| System | DER % | Miss % | FA % | Confusion % | RTF | Peak GB |", "|---|---|---|---|---|---|---|"]
    for engine_dir in sorted(p for p in RAW.iterdir() if p.is_dir()):
        metric = DiarizationErrorRate(collar=0.25, skip_overlap=False)
        proc = dur = 0.0
        found = False
        for m in items:
            f = engine_dir / f"{m['id']}.json"
            if not f.exists():
                continue
            r = json.loads(f.read_text())
            if "rttm" not in r:
                break
            found = True
            metric(load_rttm((HERE / m["ref"]).read_text()), load_rttm(r["rttm"]))
            proc += r["proc_s"]
            dur += m["duration_s"]
        if not found:
            continue
        d = metric[:]
        total = d["total"]
        peak = peak_gb(engine_dir)
        lines.append(
            f"| `{engine_dir.name}` | {100 * abs(metric):.2f} | {100 * d['missed detection'] / total:.2f} | "
            f"{100 * d['false alarm'] / total:.2f} | {100 * d['confusion'] / total:.2f} | {proc / dur:.4f} | "
            f"{'—' if peak is None else f'{peak:.2f}'} |"
        )
    return "\n".join(lines) + "\n"


def main() -> None:
    manifest = json.loads((HERE / "data" / "manifest.json").read_text())
    out = HERE / "results"
    asr = score_asr(manifest)
    (out / "asr.md").write_text(asr)
    print(asr)
    dia = score_diarization(manifest)
    if dia:
        (out / "diarization.md").write_text(dia)
        print(dia)


if __name__ == "__main__":
    main()
