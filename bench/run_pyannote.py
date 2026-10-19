"""Reference diarization: pyannote/speaker-diarization-community-1 over the diarization entries of the manifest.

The model is gated on Hugging Face: accept its terms with your account, log in once with
    uv run --with huggingface_hub hf auth login
(or set HF_TOKEN), then
    ./run_all.sh ref-pyannote
Run it under `/usr/bin/time -l` for peak memory (run_all.sh does). Output matches wavebench:
results/raw/ref-pyannote/<id>.json = {rttm, proc_s, load_s}.
"""

import json
import os
import time
from pathlib import Path

import soundfile as sf
import torch
from pyannote.audio import Pipeline

HERE = Path(__file__).parent


def main() -> None:
    # None makes huggingface_hub use the token saved by `hf auth login`.
    token = os.environ.get("HF_TOKEN")
    manifest = json.loads((HERE / "data" / "manifest.json").read_text())
    items = [m for m in manifest if m["kind"] == "diarization"]
    out = HERE / "results" / "raw" / "ref-pyannote"
    out.mkdir(parents=True, exist_ok=True)

    t0 = time.perf_counter()
    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-community-1", token=token)
    if torch.backends.mps.is_available():
        pipeline.to(torch.device("mps"))
    load_s = time.perf_counter() - t0

    for m in items:
        audio, sr = sf.read(HERE / m["audio"], dtype="float32", always_2d=True)
        waveform = torch.from_numpy(audio.T)
        t = time.perf_counter()
        result = pipeline({"waveform": waveform, "sample_rate": sr})
        proc_s = time.perf_counter() - t
        # pyannote 4 returns an object with .speaker_diarization; 3.x returns the Annotation itself.
        annotation = getattr(result, "speaker_diarization", result)
        rttm = "\n".join(
            f"SPEAKER {m['id']} 1 {turn.start:.3f} {turn.duration:.3f} <NA> <NA> {speaker} <NA> <NA>"
            for turn, _, speaker in annotation.itertracks(yield_label=True)
        )
        (out / f"{m['id']}.json").write_text(json.dumps({"rttm": rttm, "proc_s": proc_s, "load_s": load_s}) + "\n")
        print(f"{m['id']}: RTF {proc_s / m['duration_s']:.4f}")


if __name__ == "__main__":
    main()
