# 0007 — Golden set (proposal for owner approval)

- Status: **Proposed — awaiting owner approval** (owner chose "I propose, you approve")
- Date: 2026-10-18

## Rules

- ~10 episodes covering: English, Spanish, Catalan; one code-switching episode; 1–4 speakers; crosstalk; a music
  intro; one episode over 2 h.
- Prefer shows that publish human transcripts. Where none exist, we hand-correct a **20-minute scored window**;
  the full episode still runs for RTF, memory and stability.
- **Audio and reference transcripts are copyrighted.** They are never committed. The repo holds only
  `eval/golden/manifest.json`: episode URL, GUID, enclosure SHA-256, scored windows, speaker names. Audio and
  references live in a private cache on the self-hosted CI runner (`~/Library/Caches/wavepod-golden`).
- Before an episode enters the set, we check that its published transcript matches the audio (some shows edit
  audio after the transcript is written). Mismatched parts are excluded from the scored window.

## Proposed episodes (shows; exact episodes chosen after you approve)

| # | Show | Lang | Speakers | Covers | Reference |
|---|---|---|---|---|---|
| 1 | This American Life | EN | 4+ | Music intro, field tape, many voices | Published transcript (human) |
| 2 | Planet Money (NPR) | EN | 2–3 | Music beds, fast banter | Published transcript (human) |
| 3 | Lex Fridman Podcast — an episode over 2 h | EN | 2 | **> 2 h**, long-form memory | Published transcript (check quality; hand-correct window) |
| 4 | All-In | EN | 4 | **Heavy crosstalk** | Hand-corrected 20 min |
| 5 | A solo-host show (e.g. Dan Carlin's Hardcore History, a short-format episode) | EN | 1 | **1 speaker** | Hand-corrected 20 min |
| 6 | Radio Ambulante (NPR) | ES | 3+ | Spanish, Latin American accents, music | Published transcript (human) |
| 7 | A Spain-based conversational show (e.g. Cadena SER "Nadie Sabe Nada") | ES | 2 | Peninsular Spanish, laughter, crosstalk | Hand-corrected 20 min |
| 8 | RAC1 "La Competència" | CA | 3–4 | Catalan, comedy, crosstalk | Hand-corrected 20 min |
| 9 | Catalunya Ràdio / 3Cat narrative show (e.g. "Crims") | CA | 2+ | Catalan narration, music, clips | Hand-corrected 20 min |
| 10 | Latino USA (NPR) | EN↔ES | 2+ | **Code-switching** | Published transcript (human) |

Gap: there is no Catalan↔Spanish code-switching episode with a human transcript in this list. If you know a show
where hosts switch between Catalan and Spanish, it would be a better #10 (or an 11th episode).

Phase 2 also uses separate, small **fixture** feeds (not scored) to test the `podcast:transcript`,
`podcast:chapters` and `podcast:person` tags.

## What I need from you

1. Approve or swap any row.
2. Hand-correction is about 2–3 hours per 20-minute window. Six windows above need it. Decide who does the
   Catalan and Spanish corrections (native speakers preferred).
3. Speaker names for each episode come from the show notes; you confirm them once.
