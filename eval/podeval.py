"""podeval — scores wavepod's engines on the golden set (docs/decisions/0007, 0009).

    ./podeval fetch                 download each episode once, pin its SHA-256, cut the scored window
    ./podeval draft                 draft reference transcripts for the windows (for hand-correction)
    ./podeval run [engine ...]      run engines on windows and full episodes (default: all)
    ./podeval score                 WER, cpWER, DER, speaker names, RTF, memory, gaps -> results/summary.{json,md}
    ./podeval check                 compare the summary with golden/baseline.json; exit 1 on a regression
    ./podeval baseline              store the current summary as the new baseline (commit it)

Audio and references are copyrighted and live only in the cache (WAVEPOD_GOLDEN, default
~/Library/Caches/wavepod-golden). The repository holds the manifest and metric numbers, never text or audio.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
BENCH = REPO / "bench"
MANIFEST = HERE / "golden" / "manifest.json"
BASELINE = HERE / "golden" / "baseline.json"
CACHE = Path(os.environ.get("WAVEPOD_GOLDEN", Path.home() / "Library/Caches/wavepod-golden"))
RAW = CACHE / "results" / "raw"
WAVEBENCH = BENCH / "swift/.build/release/wavebench"
# Whichever build exists; podeval builds it only when neither does.
RESOLVE = next((p for p in (REPO / "WavepodKit/.build" / c / "wavepod-resolve" for c in ("release", "debug")) if p.exists()),
               REPO / "WavepodKit/.build/release/wavepod-resolve")
YT_DLP = "yt-dlp@2026.8.19"  # same pin as the app (docs/decisions/0005)
WK_MODEL = "large-v3-v20240930_turbo"

# Engine name -> (wavebench arguments, results directory, kind). Names match docs/decisions/0002 and 0003.
ENGINES = {
    "fa-parakeet": (["parakeet"], "fa-parakeet-ultra", "asr"),
    "wk-vad": (["whisperkit-vad", WK_MODEL], f"wk-vad-{WK_MODEL}", "asr"),
    "fa-offline": (["diarize"], "fa-offline", "diarization"),
}
# The pairs scored together for cpWER and speaker names: the shipping pipeline for Spanish, and the Whisper path.
PIPELINES = {"parakeet+fa-offline": ("fa-parakeet-ultra", "fa-offline"), "wk-vad+fa-offline": (f"wk-vad-{WK_MODEL}", "fa-offline")}
# Raw output of the draft step, scored as the openai/whisper large-v3 reference once references are verified.
REF_ENGINE = "ref-openai-turns"
REF_DIARIZATION = "fa-offline"

# Regression tolerances for `check`, relative to the baseline. Absolute gates come from docs/decisions/0002/0003.
TOLERANCE = {"wer": 1.0, "cpwer": 1.5, "der": 1.0}  # percentage points
RTF_FACTOR = 1.3  # wall-clock noise on a shared runner
MEMORY_FACTOR = 1.2
MAX_GAP_S = 30.0  # a longer stretch without words in a full run is reported as possibly dropped audio


def load_manifest() -> list[dict]:
    return json.loads(MANIFEST.read_text())


def save_manifest(episodes: list[dict]) -> None:
    MANIFEST.write_text(json.dumps(episodes, indent=2, ensure_ascii=False) + "\n")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def run(cmd: list, **kw) -> subprocess.CompletedProcess:
    print("$", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run([str(c) for c in cmd], check=True, **kw)


# MARK: fetch


def source_file(d: Path) -> Path | None:
    return next(iter(sorted(d.glob("source.*"))), None)


def download(ep: dict, d: Path) -> Path:
    if "youtube.com" in ep["link"] or "youtu.be" in ep["link"]:
        run(["uvx", YT_DLP, "-f", "bestaudio", "--no-playlist", "-o", d / "source.%(ext)s", ep["link"]])
        return source_file(d)
    if not RESOLVE.exists():
        run(["swift", "build", "-c", "release", "--product", "wavepod-resolve", "--package-path", REPO / "WavepodKit"])
    out = subprocess.run([str(RESOLVE), ep["link"]], check=True, capture_output=True, text=True).stdout
    resolved = json.loads(out)["episode"]["_0"]
    if ep.get("guid") and resolved.get("guid") != ep["guid"]:
        sys.exit(f"{ep['id']}: the link now resolves to GUID {resolved.get('guid')}, manifest says {ep['guid']}")
    url = resolved["enclosureURL"]
    ext = Path(urllib.parse.urlparse(url).path).suffix or ".mp3"
    target = d / f"source{ext}"
    print(f"{ep['id']}: downloading {url}", flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": "wavepod-eval/0.1"})
    with urllib.request.urlopen(req) as r, target.open("wb") as f:
        shutil.copyfileobj(r, f)
    return target


def cmd_fetch(args) -> None:
    episodes = load_manifest()
    for ep in episodes:
        d = CACHE / ep["id"]
        d.mkdir(parents=True, exist_ok=True)
        src = source_file(d) or download(ep, d)
        digest = sha256(src)
        if ep.get("sha256") is None:
            ep["sha256"] = digest
        elif ep["sha256"] != digest:
            # Hosts with dynamic ad insertion serve different audio per download, which moves every timestamp.
            if not args.accept_new:
                sys.exit(f"{ep['id']}: downloaded audio differs from the pinned SHA-256, so the reference timings no "
                         "longer apply. Restore the cached file, or rerun with --accept-new and redo the reference.")
            print(f"{ep['id']}: new audio accepted; its reference must be redone", file=sys.stderr)
            ep["sha256"] = digest
            ep["reference"] = "missing"
        audio = d / "audio.wav"
        if not audio.exists():
            run(["ffmpeg", "-v", "error", "-y", "-i", src, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", audio])
        import soundfile as sf

        ep["duration_s"] = round(sf.info(audio).duration, 2)
        start, end = ep["window"]
        window = d / "window.wav"
        if not window.exists():
            run(["ffmpeg", "-v", "error", "-y", "-ss", start, "-t", end - start, "-i", audio, "-c:a", "pcm_s16le", window])
        print(f"{ep['id']}: {ep['duration_s'] / 60:.1f} min, window {start}–{end} s, sha256 {digest[:12]}…")
    save_manifest(episodes)
    write_bench_manifest(episodes)


def write_bench_manifest(episodes: list[dict]) -> Path:
    """The manifest wavebench reads: each episode twice (scored window, full episode), for ASR and diarization."""
    items = []
    for ep in episodes:
        d = CACHE / ep["id"]
        start, end = ep["window"]
        for kind in ("asr", "diarization"):
            items.append({"id": f"{ep['id']}-win", "kind": kind, "lang": ep["lang"],
                          "audio": str(d / "window.wav"), "duration_s": end - start})
            items.append({"id": f"{ep['id']}-full", "kind": kind, "lang": ep["lang"],
                          "audio": str(d / "audio.wav"), "duration_s": ep["duration_s"]})
    path = CACHE / "bench-manifest.json"
    path.write_text(json.dumps(items, indent=1) + "\n")
    return path


# MARK: run


def run_engine(name: str, ids: list[str] | None = None) -> None:
    wb_args, outdir, _ = ENGINES[name]
    if not WAVEBENCH.exists():
        run(["swift", "build", "-c", "release", "--package-path", BENCH / "swift"])
    env = dict(os.environ, WB_MANIFEST=str(write_bench_manifest(load_manifest())), WB_RESULTS=str(RAW))
    (RAW / outdir).mkdir(parents=True, exist_ok=True)
    # Peak memory of the whole process, as in bench/run_all.sh. The full episodes dominate it.
    with (RAW / outdir / "time.txt").open("w") as err:
        run(["/usr/bin/time", "-l", WAVEBENCH, *wb_args, *(ids or [])], cwd=BENCH, env=env, stderr=err)


def cmd_run(args) -> None:
    unknown = set(args.engines) - set(ENGINES)
    if unknown:
        sys.exit(f"unknown engine(s): {', '.join(sorted(unknown))}; known: {', '.join(ENGINES)}")
    for name in args.engines or list(ENGINES):
        print(f"== {name}", flush=True)
        run_engine(name)


# MARK: draft references


def load_rttm(text: str, offset: float = 0.0) -> list[tuple[float, float, str]]:
    turns = []
    for line in text.splitlines():
        f = line.split()
        if f and f[0] == "SPEAKER":
            start = float(f[3]) + offset
            turns.append((start, start + float(f[4]), f[7]))
    return sorted(turns)


def draft_chunks(turns: list[tuple[float, float, str]], max_len: float = 28.0) -> list[tuple[float, float, str]]:
    """Diarization turns -> chunks for short-form decoding: same-speaker turns merged across gaps < 0.5 s,
    anything longer than max_len split evenly, turns under 0.3 s dropped."""
    merged: list[list] = []
    for s, e, spk in turns:
        if merged and merged[-1][2] == spk and s - merged[-1][1] < 0.5 and e - merged[-1][0] <= max_len:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e, spk])
    chunks = []
    for s, e, spk in merged:
        if e - s < 0.3:
            continue
        n = int((e - s) // max_len) + 1
        step = (e - s) / n
        chunks += [(s + i * step, s + (i + 1) * step, spk) for i in range(n)]
    return chunks


def ts(seconds: float) -> str:
    m, s = divmod(seconds, 60)
    return f"{int(m):02d}:{s:05.2f}"


def parse_ts(text: str) -> float:
    m, s = text.split(":")
    return int(m) * 60 + float(s)


REF_LINE = re.compile(r"^\[(\d+:\d+(?:\.\d+)?)\s*(?:→|->)\s*(\d+:\d+(?:\.\d+)?)\]\s*([^:]+):\s*(.*)$")


def cmd_draft(args) -> None:
    import soundfile as sf
    import torch
    import whisper

    episodes = load_manifest()
    todo = [ep for ep in episodes if args.force or not (CACHE / ep["id"] / "ref.txt").exists()]
    for ep in episodes:
        if ep not in todo and ep.get("published_transcript"):
            align_published(ep)
    if not todo:
        print("every window already has a reference (use --force to redraft)")
        return
    missing = [f"{ep['id']}-win" for ep in todo if not (RAW / REF_DIARIZATION / f"{ep['id']}-win.json").exists()]
    if missing:
        run_engine(REF_DIARIZATION, missing)
    device = args.device
    if device == "mps" and not torch.backends.mps.is_available():
        device = "cpu"
    t0 = time.perf_counter()
    model = whisper.load_model("large-v3", device=device)
    load_s = time.perf_counter() - t0
    for ep in todo:
        d = CACHE / ep["id"]
        start, end = ep["window"]
        audio, sr = sf.read(d / "window.wav", dtype="float32")
        rttm = json.loads((RAW / REF_DIARIZATION / f"{ep['id']}-win.json").read_text())["rttm"]
        chunks = draft_chunks(load_rttm(rttm, offset=start))
        labels = {spk: f"S{i + 1}" for i, spk in enumerate(dict.fromkeys(c[2] for c in chunks))}
        lines, words, t = [], [], time.perf_counter()
        for s, e, spk in chunks:
            clip = audio[int((s - start) * sr):int((e - start) * sr)]
            r = model.transcribe(clip, language=ep["lang"], fp16=False, condition_on_previous_text=False,
                                 temperature=0.0, without_timestamps=True)
            text = r["text"].strip()
            lines.append(f"[{ts(s)} → {ts(e)}] {labels[spk]}: {text}")
            words.append([s, e, text, labels[spk]])
        proc_s = time.perf_counter() - t
        header = [
            f"# wavepod golden reference: {ep['id']} — {ep['show']}: {ep['title']}",
            f"# Scored window {ts(start)}–{ts(end)} of the full episode (times below are in the full episode).",
            "# status: draft",
            "#",
            "# Draft made by openai/whisper large-v3 on FluidAudio diarization turns. To verify: listen to the window,",
            "# fix every word, replace S1/S2… with the speakers' names (the same spelling everywhere), fix a turn's",
            "# times only when a boundary is clearly off, write [inaudible] for words nobody can make out (ignored in",
            "# scoring), then change the status line to: # status: verified",
        ]
        (d / "ref.txt").write_text("\n".join(header + lines) + "\n", encoding="utf-8")
        # Kept apart, unedited: the reference engine's own output, scored once the reference is verified.
        out = RAW / REF_ENGINE
        out.mkdir(parents=True, exist_ok=True)
        (out / f"{ep['id']}-win.json").write_text(json.dumps(
            {"segments": words, "proc_s": proc_s, "load_s": load_s, "device": device}, ensure_ascii=False) + "\n")
        ep["reference"] = "draft"
        if ep.get("published_transcript"):
            align_published(ep)
        print(f"{ep['id']}: {len(lines)} lines drafted in {proc_s / 60:.1f} min ({device}) -> {d / 'ref.txt'}")
    save_manifest(episodes)


def align_published(ep: dict) -> None:
    """For a show that publishes a speaker-labelled but untimed transcript ("Name: text" paragraphs): align it to
    the timed draft and write ref-published.txt, the draft's turns carrying the published words and names. The
    corrector starts from that file instead (published transcripts are often lightly edited, so it still needs
    a listen: restore filler words and false starts that were said, or the engines are charged for them)."""
    import difflib

    d = CACHE / ep["id"]
    src = d / "published.txt"
    if not src.exists():
        req = urllib.request.Request(ep["published_transcript"], headers={"User-Agent": "wavepod-eval/0.1"})
        with urllib.request.urlopen(req) as r:
            src.write_bytes(r.read())
    pub_words, pub_speakers, speaker = [], [], "?"
    for para in src.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([A-Z][\w .'-]{0,40}):\s+(.*)$", para.strip())
        if m:
            speaker, para = m[1], m[2]
        for w in para.split():
            pub_words.append(w)
            pub_speakers.append(speaker)
    _, draft = read_reference(ep)
    draft_tokens, owner = [], []
    for i, (_, _, _, text) in enumerate(draft):
        for w in text.split():
            draft_tokens.append(w)
            owner.append(i)

    def key(w: str) -> str:
        return re.sub(r"[^\w]", "", w.lower())

    matcher = difflib.SequenceMatcher(None, [key(w) for w in draft_tokens], [key(w) for w in pub_words], autojunk=False)
    first = {}  # draft line -> first published index matched by one of its words
    matched = 0
    for a, b, size in matcher.get_matching_blocks():
        matched += size
        for k in range(size):
            first.setdefault(owner[a + k], b + k)
    lines_with_match = sorted(first)
    if matched < 0.5 * len(draft_tokens):
        print(f"{ep['id']}: only {matched}/{len(draft_tokens)} draft words found in the published transcript; skipped")
        return
    out = [
        f"# wavepod golden reference: {ep['id']} — {ep['show']}: {ep['title']}",
        f"# Scored window {ts(ep['window'][0])}–{ts(ep['window'][1])} of the full episode.",
        "# status: draft",
        "#",
        "# Built from the show's published transcript, aligned to the draft's turns. Listen and fix what the",
        "# published text left out or changed, check each turn's speaker, then set: # status: verified",
        "# When verified, replace ref.txt with this file.",
    ]
    for n, i in enumerate(lines_with_match):
        start = first[i]
        end = first[lines_with_match[n + 1]] if n + 1 < len(lines_with_match) else start + len(draft[i][3].split())
        words, names = pub_words[start:end], pub_speakers[start:end]
        if not words:
            continue
        name = max(set(names), key=names.count)
        out.append(f"[{ts(draft[i][0])} → {ts(draft[i][1])}] {name}: {' '.join(words)}")
    (d / "ref-published.txt").write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"{ep['id']}: {matched}/{len(draft_tokens)} draft words matched the published transcript -> ref-published.txt")


# MARK: score


def read_reference(ep: dict) -> tuple[str, list[tuple[float, float, str, str]]]:
    """(status, [(start, end, speaker, text)]) from the cached ref.txt."""
    path = CACHE / ep["id"] / "ref.txt"
    status, turns = "missing", []
    if not path.exists():
        return status, turns
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("# status:"):
            status = line.split(":", 1)[1].strip()
            continue
        m = REF_LINE.match(line.strip())
        if m:
            turns.append((parse_ts(m[1]), parse_ts(m[2]), m[3].strip(), m[4].strip()))
    return status, sorted(turns)


def assign_speakers(words: list, turns: list[tuple[float, float, str]]) -> list[str]:
    """Word -> speaker, the rule of docs/decisions/0003: the turn covering the word's midpoint (the shortest if
    several), else the nearest turn within 0.5 s, else the previous word's speaker."""
    speakers, previous = [], "?"
    for s, e, _ in words:
        mid = (s + e) / 2
        covering = [t for t in turns if t[0] <= mid <= t[1]]
        if covering:
            spk = min(covering, key=lambda t: t[1] - t[0])[2]
        else:
            near = min(turns, key=lambda t: min(abs(mid - t[0]), abs(mid - t[1])), default=None)
            spk = near[2] if near and min(abs(mid - near[0]), abs(mid - near[1])) <= 0.5 else previous
        speakers.append(spk)
        previous = spk
    return speakers


def peak_gb(engine_dir: Path, field: str = "peak memory footprint") -> float | None:
    f = engine_dir / "time.txt"
    m = re.search(r"(\d+)\s+" + field, f.read_text()) if f.exists() else None
    return int(m.group(1)) / 1e9 if m else None


def cmd_score(args) -> None:
    import jiwer
    from meeteval.wer.wer.cp import cp_word_error_rate
    from pyannote.core import Annotation, Segment, Timeline
    from pyannote.metrics.diarization import DiarizationErrorRate
    from whisper.normalizers import BasicTextNormalizer, EnglishTextNormalizer

    episodes = load_manifest()
    norms = {"en": EnglishTextNormalizer()}
    basic = BasicTextNormalizer()

    def result(engine_dir: str, item: str) -> dict | None:
        f = RAW / engine_dir / f"{item}.json"
        return json.loads(f.read_text()) if f.exists() else None

    def windowed(words: list, start: float, end: float) -> list:
        """Window-run words, shifted to episode time and kept inside the scored window."""
        shifted = [(w[0] + start, w[1] + start, w[2]) for w in words]
        return [w for w in shifted if start <= (w[0] + w[1]) / 2 <= end]

    summary = {"generated": time.strftime("%Y-%m-%d %H:%M"), "episodes": {}, "engines": {}}
    for ep in episodes:
        status, ref = read_reference(ep)
        norm = norms.get(ep["lang"], basic)
        start, end = ep["window"]
        row = {"reference": status}
        summary["episodes"][ep["id"]] = row
        if not ref:
            continue
        ref_text = norm(" ".join(t[3] for t in ref))
        ref_by_speaker: dict[str, list[str]] = {}
        for t in ref:
            ref_by_speaker.setdefault(t[2], []).append(t[3])
        ref_speakers = [norm(" ".join(v)) for v in ref_by_speaker.values()]
        ref_ann = Annotation()
        for s, e, spk, _ in ref:
            ref_ann[Segment(s, e)] = spk
        uem = Timeline([Segment(start, end)])
        row["ref_words"] = len(ref_text.split())
        row["ref_speakers"] = len(ref_by_speaker)

        # WER of every ASR engine on the window.
        for _, outdir, kind in ENGINES.values():
            if kind != "asr" or not (r := result(outdir, f"{ep['id']}-win")):
                continue
            hyp = " ".join(w[2] for w in windowed(r.get("words", []), start, end)) if "words" in r else r["text"]
            row.setdefault("wer", {})[outdir] = 100 * jiwer.wer(ref_text, norm(hyp))
        if r := result(REF_ENGINE, f"{ep['id']}-win"):
            row.setdefault("wer", {})[REF_ENGINE] = 100 * jiwer.wer(ref_text, norm(" ".join(s[2] for s in r["segments"])))

        # DER on the window.
        if r := result(REF_DIARIZATION, f"{ep['id']}-win"):
            hyp_ann = Annotation()
            for s, e, spk in load_rttm(r["rttm"], offset=start):
                hyp_ann[Segment(s, e)] = spk
            metric = DiarizationErrorRate(collar=0.25, skip_overlap=False)
            d = metric(ref_ann, hyp_ann, uem=uem, detailed=True)
            total = d["total"]
            row["der"] = {REF_DIARIZATION: {
                "der": 100 * d["diarization error rate"], "miss": 100 * d["missed detection"] / total,
                "fa": 100 * d["false alarm"] / total, "confusion": 100 * d["confusion"] / total,
                "speakers": len(hyp_ann.labels()),
            }}

        # cpWER and speaker names for each ASR + diarization pipeline.
        for name, (asr_dir, dia_dir) in PIPELINES.items():
            a, dz = result(asr_dir, f"{ep['id']}-win"), result(dia_dir, f"{ep['id']}-win")
            if not a or not dz or "words" not in a:
                continue
            words = windowed(a["words"], start, end)
            spk = assign_speakers(words, load_rttm(dz["rttm"], offset=start))
            by_speaker: dict[str, list[str]] = {}
            for w, s in zip(words, spk):
                by_speaker.setdefault(s, []).append(w[2])
            hyp_speakers = [norm(" ".join(v)) for v in by_speaker.values()]
            cp = cp_word_error_rate(ref_speakers, hyp_speakers)
            row.setdefault("cpwer", {})[name] = 100 * cp.error_rate
            # Correct-name rate: a reference turn counts when most of its words carry the reference name.
            # Diarization labels are anonymous until Phase 4 names them, so this stays empty for now.
            if set(by_speaker) & set(ref_by_speaker):
                hits = 0
                for s, e, name_ref, _ in ref:
                    inside = [x for w, x in zip(words, spk) if s <= (w[0] + w[1]) / 2 <= e]
                    hits += bool(inside) and max(set(inside), key=inside.count) == name_ref
                row.setdefault("names", {})[name] = 100 * hits / len(ref)

    # Speed, memory and dropped-audio check from the full-episode runs.
    for _, outdir, kind in ENGINES.values():
        proc = dur = 0.0
        gaps = {}
        for ep in episodes:
            r = result(outdir, f"{ep['id']}-full")
            if not r:
                continue
            proc += r["proc_s"]
            dur += ep["duration_s"]
            if kind == "asr" and "words" in r:
                times = sorted((w[0], w[1]) for w in r["words"])
                edges = [0.0] + [t for w in times for t in w] + [ep["duration_s"]]
                gaps[ep["id"]] = max((b - a for a, b in zip(edges[::2], edges[1::2])), default=ep["duration_s"])
        if dur:
            summary["engines"][outdir] = {"rtf": proc / dur, "audio_h": dur / 3600, "footprint_gb": peak_gb(RAW / outdir),
                                          "rss_gb": peak_gb(RAW / outdir, "maximum resident set size"),
                                          "longest_gap_s": gaps}
    out = CACHE / "results"
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    md = render(summary)
    (out / "summary.md").write_text(md)
    print(md)


def render(summary: dict) -> str:
    def f(x, fmt=".2f"):
        return "—" if x is None else format(x, fmt)

    eps = summary["episodes"]
    asr = sorted({k for r in eps.values() for k in r.get("wer", {})})
    pipes = sorted({k for r in eps.values() for k in r.get("cpwer", {})})
    out = ["| Episode | Ref | " + " | ".join(f"WER `{a}`" for a in asr) + " | DER | Miss | FA | Conf | Spk ref/hyp | "
           + " | ".join(f"cpWER `{p}`" for p in pipes) + " |", "|" + "---|" * (len(asr) + len(pipes) + 7)]
    for eid, r in eps.items():
        d = r.get("der", {}).get(REF_DIARIZATION, {})
        out.append(f"| {eid} | {r['reference']} | " + " | ".join(f(r.get('wer', {}).get(a)) for a in asr)
                   + f" | {f(d.get('der'))} | {f(d.get('miss'))} | {f(d.get('fa'))} | {f(d.get('confusion'))} | "
                   + f"{r.get('ref_speakers', '—')}/{d.get('speakers', '—')} | "
                   + " | ".join(f(r.get('cpwer', {}).get(p)) for p in pipes) + " |")
    out += ["", "| Engine (full episodes) | Audio h | RTF | ×real time | Footprint GB | RSS GB | Longest gap without words s |",
            "|---|---|---|---|---|---|---|"]
    for name, e in summary["engines"].items():
        gap = max(e["longest_gap_s"].values(), default=None)
        out.append(f"| `{name}` | {e['audio_h']:.2f} | {e['rtf']:.4f} | {1 / e['rtf']:.0f} | {f(e['footprint_gb'])} | "
                   f"{f(e['rss_gb'])} | {f(gap, '.1f')} |")
    return "\n".join(out) + "\n"


# MARK: check


def cmd_check(args) -> None:
    current = json.loads((CACHE / "results" / "summary.json").read_text())
    base = json.loads(BASELINE.read_text()) if BASELINE.exists() else None
    failures, notes = [], []
    for eid, r in current["episodes"].items():
        b = (base or {}).get("episodes", {}).get(eid, {})
        if base and b.get("reference") != r["reference"]:
            notes.append(f"{eid}: reference is {r['reference']}, baseline was made on {b.get('reference')}; rebaseline")
            continue
        for metric in ("wer", "cpwer"):
            for k, v in r.get(metric, {}).items():
                if (old := b.get(metric, {}).get(k)) is not None and v > old + TOLERANCE[metric]:
                    failures.append(f"{eid} {metric} {k}: {v:.2f} vs baseline {old:.2f}")
        for k, v in r.get("der", {}).items():
            if (old := b.get("der", {}).get(k, {}).get("der")) is not None and v["der"] > old + TOLERANCE["der"]:
                failures.append(f"{eid} DER {k}: {v['der']:.2f} vs baseline {old:.2f}")
        # Absolute gate (docs/decisions/0002): the shipping engine within 1.5 points of openai/whisper large-v3.
        # Only meaningful on a verified reference: a draft is the reference engine's own output.
        wer = r.get("wer", {})
        if r["reference"] == "verified" and REF_ENGINE in wer:
            for k, v in wer.items():
                if k != REF_ENGINE and k.startswith("fa-parakeet") and v > wer[REF_ENGINE] + 1.5:
                    failures.append(f"{eid} {k}: WER {v:.2f} is more than 1.5 points above {REF_ENGINE} ({wer[REF_ENGINE]:.2f})")
        elif r["reference"] != "verified":
            notes.append(f"{eid}: reference is {r['reference']}; the absolute WER gate is skipped")
    for name, e in current["engines"].items():
        b = (base or {}).get("engines", {}).get(name)
        if not b:
            continue
        if e["rtf"] > b["rtf"] * RTF_FACTOR:
            failures.append(f"{name}: RTF {e['rtf']:.4f} vs baseline {b['rtf']:.4f}")
        if e["footprint_gb"] and b["footprint_gb"] and e["footprint_gb"] > b["footprint_gb"] * MEMORY_FACTOR:
            failures.append(f"{name}: footprint {e['footprint_gb']:.2f} GB vs baseline {b['footprint_gb']:.2f} GB")
        for eid, gap in e["longest_gap_s"].items():
            if gap > MAX_GAP_S:
                notes.append(f"{name} {eid}: {gap:.0f} s without words (music, or dropped audio?)")
    if base is None:
        notes.append("no baseline yet: run ./podeval baseline and commit eval/golden/baseline.json")
    for n in notes:
        print("note:", n)
    for x in failures:
        print("REGRESSION:", x)
    print("podeval check:", "FAILED" if failures else "passed")
    sys.exit(1 if failures else 0)


def cmd_baseline(args) -> None:
    shutil.copy(CACHE / "results" / "summary.json", BASELINE)
    print(f"baseline written to {BASELINE.relative_to(REPO)}; commit it")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    f = sub.add_parser("fetch")
    f.add_argument("--accept-new", action="store_true", help="accept audio whose SHA-256 changed (redo references)")
    d = sub.add_parser("draft")
    # CPU: openai/whisper large-v3 ran 3x slower on MPS here (57.7 s vs 16.9 s for 30 s of audio, M3).
    d.add_argument("--device", default="cpu", help="torch device for openai/whisper (cpu or mps)")
    d.add_argument("--force", action="store_true", help="overwrite existing ref.txt files")
    r = sub.add_parser("run")
    r.add_argument("engines", nargs="*", help=f"any of {', '.join(ENGINES)}")
    sub.add_parser("score")
    sub.add_parser("check")
    sub.add_parser("baseline")
    args = p.parse_args()
    {"fetch": cmd_fetch, "draft": cmd_draft, "run": cmd_run, "score": cmd_score, "check": cmd_check,
     "baseline": cmd_baseline}[args.command](args)


if __name__ == "__main__":
    main()
