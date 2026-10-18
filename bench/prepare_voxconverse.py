"""Fetch a VoxConverse test subset (CC-BY-4.0) for the DER benchmark without downloading the 4.3 GB archive.

The zip is read over HTTP range requests: Python's zipfile reads the central directory from the end of the file,
then only the chosen members are fetched. Files are picked to spread speaker counts, up to --minutes of audio.

Usage: uv run prepare_voxconverse.py [--minutes 60]
Writes data/voxconverse/<id>.wav, <id>.rttm and adds kind="diarization" entries to data/manifest.json.
"""

import argparse
import io
import json
import urllib.request
import zipfile

import soundfile as sf
from pathlib import Path

ZIP_URL = "https://www.robots.ox.ac.uk/~vgg/data/voxconverse/data/voxconverse_test_wav.zip"
RTTM_URL = "https://raw.githubusercontent.com/joonson/voxconverse/master/test/{}.rttm"
RTTM_INDEX = "https://api.github.com/repos/joonson/voxconverse/contents/test"
HERE = Path(__file__).parent
DATA = HERE / "data"


class HTTPRangeFile(io.RawIOBase):
    """Read-only, seekable view of a remote file. Reads are served in 1 MB blocks."""

    BLOCK = 1 << 20

    def __init__(self, url: str):
        self.url = url
        head = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(head) as r:
            self.size = int(r.headers["Content-Length"])
        self.pos = 0
        self.cache: dict[int, bytes] = {}

    def seekable(self) -> bool:
        return True

    def readable(self) -> bool:
        return True

    def tell(self) -> int:
        return self.pos

    def seek(self, offset: int, whence: int = io.SEEK_SET) -> int:
        self.pos = {io.SEEK_SET: offset, io.SEEK_CUR: self.pos + offset, io.SEEK_END: self.size + offset}[whence]
        return self.pos

    def _block(self, index: int) -> bytes:
        if index not in self.cache:
            start = index * self.BLOCK
            end = min(self.size, start + self.BLOCK) - 1
            req = urllib.request.Request(self.url, headers={"Range": f"bytes={start}-{end}"})
            with urllib.request.urlopen(req) as r:
                self.cache = {index: r.read()}  # keep one block: members are read sequentially
        return self.cache[index]

    def read(self, n: int = -1) -> bytes:
        if n < 0:
            n = self.size - self.pos
        out = bytearray()
        while n > 0 and self.pos < self.size:
            block = self._block(self.pos // self.BLOCK)
            offset = self.pos % self.BLOCK
            chunk = block[offset : offset + n]
            out += chunk
            self.pos += len(chunk)
            n -= len(chunk)
        return bytes(out)

    def readinto(self, b) -> int:
        data = self.read(len(b))
        b[: len(data)] = data
        return len(data)


def speakers_and_duration(rttm: str) -> tuple[int, float]:
    speakers, end = set(), 0.0
    for line in rttm.splitlines():
        f = line.split()
        if f and f[0] == "SPEAKER":
            speakers.add(f[7])
            end = max(end, float(f[3]) + float(f[4]))
    return len(speakers), end


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--minutes", type=float, default=60)
    args = p.parse_args()

    out = DATA / "voxconverse"
    out.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(RTTM_INDEX) as r:
        ids = sorted(Path(x["name"]).stem for x in json.load(r) if x["name"].endswith(".rttm"))

    # Read every reference (small), then pick files round-robin over speaker-count buckets.
    refs = {}
    for i in ids:
        cached = out / f"{i}.rttm"
        if not cached.exists():
            with urllib.request.urlopen(RTTM_URL.format(i)) as r:
                cached.write_bytes(r.read())
        refs[i] = speakers_and_duration(cached.read_text())

    buckets: dict[str, list[str]] = {"2": [], "3-4": [], "5-7": [], "8+": []}
    for i, (n, d) in sorted(refs.items(), key=lambda kv: kv[1][1]):  # shortest first within a bucket
        if n < 2 or d > 15 * 60:
            continue
        key = "2" if n == 2 else "3-4" if n <= 4 else "5-7" if n <= 7 else "8+"
        buckets[key].append(i)
    chosen, total = [], 0.0
    while total < args.minutes * 60 and any(buckets.values()):
        for key in buckets:
            if buckets[key] and total < args.minutes * 60:
                i = buckets[key].pop(len(buckets[key]) // 2)  # mid-length file of the bucket
                chosen.append(i)
                total += refs[i][1]

    remote = HTTPRangeFile(ZIP_URL)
    with zipfile.ZipFile(remote) as z:
        members = {Path(n).stem: n for n in z.namelist() if n.endswith(".wav")}
        manifest_path = DATA / "manifest.json"
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else []
        for i in chosen:
            wav = out / f"{i}.wav"
            if not wav.exists():
                print(f"fetch {i} ({refs[i][0]} speakers, {refs[i][1] / 60:.1f} min)")
                wav.write_bytes(z.read(members[i]))
            entry = {"id": f"vox-{i}", "lang": "en", "audio": str(wav.relative_to(HERE)),
                     "ref": str((out / f"{i}.rttm").relative_to(HERE)), "duration_s": round(sf.info(wav).duration, 2),
                     "speakers": refs[i][0], "kind": "diarization"}
            manifest = [m for m in manifest if m["id"] != entry["id"]] + [entry]
        manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(f"{len(chosen)} files, {total / 60:.1f} min")


if __name__ == "__main__":
    main()
