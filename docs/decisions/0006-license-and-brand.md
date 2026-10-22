# 0006 — License and brand

- Status: Accepted (owner decisions: open source, permissive; calm editorial brand)
- Date: 2026-10-18

## License: Apache-2.0

The owner chose "open source, MIT/Apache". We use **Apache-2.0** for the repository (see `LICENSE`):

- It is permissive like MIT, so anyone can use, fork and ship the code.
- It adds an explicit patent grant and patent-retaliation clause, which matters in a field (speech ML) with active
  patents.
- It is compatible with every dependency we plan to use (MIT, Apache-2.0, BSD). It is **not** compatible with
  shipping GPL code, so noScribe stays ideas-only ([0001](0001-references.md)).

### Third-party license audit

`THIRD_PARTY_LICENSES.md` (created with the first app build) lists every shipped component and every model the
app downloads, with license and source URL. CI fails if a new dependency appears in `Package.resolved` without an
entry. Initial list:

| Component | License | Shipped how |
|---|---|---|
| WhisperKit | MIT | Swift package |
| Whisper model weights (OpenAI) | MIT | Downloaded on first use |
| FluidAudio | Apache-2.0 | Swift package |
| Parakeet TDT v3 weights (NVIDIA) | CC-BY-4.0 (attribution in About) | Downloaded, if adopted |
| pyannote community-1 weights | CC-BY-4.0 (attribution in About) | Downloaded (CoreML port) |
| yt-dlp | Unlicense | Downloaded on first YouTube use |
| Sparkle | MIT | Framework |
| GRDB.swift | MIT | Swift package |
| MLX-Swift | MIT | Swift package |
| Local LLM weights | Must be Apache-2.0 or MIT; chosen in Phase 5 | Downloaded |
| Scriberr | MIT | Not shipped; we only call its API |

Each model license is re-checked against the model card at the pinned revision during the audit.

## Brand: "Wavepod", calm editorial

The layout follows SpotScribe's three panes; nothing else does. No SpotScribe name, icon, colors, wording or
screenshots are used.

Direction: a reading app for spoken words. Warm paper and ink, one deep teal accent, serif for the transcript.

| Token | Light | Dark | Use |
|---|---|---|---|
| `paper` | `#F7F4EE` | `#16181A` | Window background |
| `surface` | `#FFFFFF` | `#1E2123` | Panes, cards |
| `ink` | `#1C1B19` | `#ECE8E1` | Body text |
| `inkMuted` | `#6B665E` | `#A39E95` | Secondary text, timestamps |
| `rule` | `#E4DFD6` | `#2E3235` | Dividers |
| `accent` | `#0F5E63` | `#5FB3B3` | Links, active timestamp, primary button |
| `highlight` | `#E6F0EE` | `#203A3B` | Current paragraph while playing |
| `speaker1…6` | muted, distinct hues, AA contrast on `surface` | | Speaker chips |

All text/background pairs meet WCAG AA (4.5:1 for body text). Final values are checked by a contrast test in the
snapshot suite.

- Type: **New York** (system serif) for transcript and summary, **SF Pro** for UI chrome, **SF Mono** for timestamps.
  All via Dynamic Type text styles, so system text-size settings apply.
- Icon: a single sound-wave line that becomes a page edge, teal on paper. Drawn in-house.
- Voice: short, plain, calm. "Transcribing — about 4 minutes left." not "Magic is happening! ✨".
