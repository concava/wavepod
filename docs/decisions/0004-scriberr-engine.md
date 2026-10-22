# 0004 — Optional engine: the user's own Scriberr server

- Status: Accepted (design); implementation in Phase 3
- Date: 2026-10-18

## Context

Some users already run Scriberr on a home server with a GPU. Wavepod can send audio there instead of transcribing
locally. The audio still never leaves the user's own machines.

## Decision

`ScriberrEngine` conforms to the same `Engine` protocol as `NativeEngine`. The pipeline does not know which one it
calls. Shape of the protocol (Swift, simplified):

```swift
public protocol Engine: Sendable {
    var id: EngineID { get }
    func capabilities() async throws -> EngineCapabilities   // languages, diarization, word timestamps, limits
    func transcribe(_ audio: AudioAsset, options: TranscribeOptions,
                    progress: @Sendable (Progress) -> Void) async throws -> RawTranscript
}
```

`RawTranscript` holds words (text, start, end, confidence, speaker label?) and optional speaker embeddings.
A remote engine that returns no word timings or no embeddings states that in `capabilities()`; the pipeline then
runs local alignment or local diarization on the result to fill the gap.

### API contract used (Scriberr `a353078`, `/api/v1`)

| Step | Call |
|---|---|
| Health and version | `GET /health` |
| Models | `GET /transcription/models` |
| Submit | `POST /transcription/submit` (multipart: `audio`, `title`, `model`, `language`, `diarization`, `min_speakers`, `max_speakers`, `vad_filter`) |
| Poll | `GET /transcription/:id/status` (backoff 1 s → 10 s; Scriberr also offers SSE under `/events`, used when available) |
| Result | `GET /transcription/:id/transcript` |
| Cancel | `POST /transcription/:id/kill` |

Auth: an API key created in Scriberr, sent as `X-API-Key`, stored in the macOS Keychain.

### Network rules

- The host must be loopback, a private address (RFC 1918 / RFC 4193), or a `.local` name. Any other host is
  refused with a clear message. This keeps the privacy promise checkable.
- The configured host is the only extra entry in the network allow-list, and every request appears in the
  Network log.
- `Info.plist`: `NSAllowsLocalNetworking` (plain HTTP on the LAN is common for home servers) and
  `NSLocalNetworkUsageDescription` for the macOS Local Network prompt.

### Compatibility

A contract test suite runs against recorded fixtures of the endpoints above, plus an opt-in live test against a
Scriberr Docker container. On an unknown Scriberr version, Wavepod tries the calls and shows "unsupported version"
if the response shape differs.

## Consequences

- Scriberr's transcript format is converted into ours. Speaker labels from Scriberr are kept, but voice
  identity (Phase 4) needs embeddings, so Wavepod runs its own embedding extractor on the speaker turns locally.
- No Scriberr code is vendored; we only talk to its HTTP API.
