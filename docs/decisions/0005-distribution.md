# 0005 — Distribution: Developer ID, notarization, Sparkle; free

- Status: Accepted (owner decision: direct download, free)
- Date: 2026-10-18

## Decision

- Wavepod is **free** and distributed **directly**: a signed, notarized `.dmg` on GitHub Releases.
- Signing: Developer ID Application certificate, hardened runtime, notarized with `notarytool`, stapled.
- Updates: **Sparkle 2** with an EdDSA-signed appcast. The appcast is served from GitHub Pages. The Sparkle private
  key is kept in the CI secret store and on one offline backup, never in the repo.
- No Mac App Store build in v1.

## Mac App Store: confirmed out for v1

| Feature | Why it conflicts with the MAS |
|---|---|
| YouTube via yt-dlp, installed on first use and updated often | App Review Guideline 2.5.2: apps may not download or run code that changes their features. yt-dlp must update faster than app review allows. |
| Sparkle updates | MAS apps must update only through the store. |
| Model downloads to a shared cache, helper processes | Possible in the sandbox but awkward; not the blocker. |
| Login item for subscriptions (`SMAppService`) | Allowed in the MAS; not a blocker. |

A sandboxed MAS edition without YouTube is possible later. It would be a second build to maintain, so it waits
until there is demand.

## App sandbox

The direct build is **not sandboxed** in v1: it runs a downloaded executable (yt-dlp) and keeps models in a shared
cache. It uses the hardened runtime with no exceptions except `com.apple.security.cs.disable-library-validation`
**only if** a dependency needs it (to be confirmed when the app first builds; the goal is none).

## yt-dlp handling

- Not bundled. On first YouTube use, Wavepod downloads the pinned `yt-dlp_macos` release from GitHub, checks the
  SHA-256 against the value pinned in the app (and published in the release's `SHA2-256SUMS`), stores it in
  Application Support, and runs it as a child process.
- A newer yt-dlp is accepted only through a Wavepod update that pins its checksum. (Trade-off: a YouTube breakage
  can need a Wavepod release; Sparkle makes that fast.)

## Owner action needed

Notarization requires an **Apple Developer Program** membership (paid yearly) for the Developer ID certificate,
even for a free app. Until it exists, CI builds ad-hoc-signed artefacts for testing only.
