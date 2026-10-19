# 0007 — Golden set

- Status: **Accepted (v1)** — the owner replaced the proposal below with four episodes of their own (2026-10-19)
- Date: 2026-10-18, updated 2026-10-19

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

## Golden set v1 (owner's choice, 2026-10-19; #5 added the same day)

Resolved with `wavepod-resolve` (Spotify links matched to the RSS feed by GUID at confidence 1.0; the YouTube
link read with the pinned yt-dlp `-J`, metadata only).

| # | Link | Show | Episode | Lang | Length | Audio source | Reference |
|---|---|---|---|---|---|---|---|
| 1 | Spotify `2lvUyQfZHFG68ySik7fz0i` | Podcast de Itnig | "Empieza la Era de los Agentes de IA \| tertulia de itnig" (2026-10-08) | ES | 1 h 44 min | RSS enclosure (anchor.fm feed) | Hand-corrected 20 min |
| 2 | Spotify `1xukjoklX32akneFePthbM` | Podcast de Itnig | "El ordenador cuántico ya existe. ¿Para qué sirve realmente?" (2026-10-01) | ES | **2 h 05 min** | RSS enclosure (anchor.fm feed) | Hand-corrected 20 min |
| 3 | YouTube `fNOhEq65FtA` | Búscate la vida (BLV) | "Romuald Fons VUELVE a BLV (con nuevos líos) \| Ep 144" (2026-09-16) | ES | **2 h 04 min** | yt-dlp audio (no RSS match attempted yet) | Hand-corrected 20 min |
| 4 | Apple `id1738229736?i=1000784391917` | ROCA PROJECT | "#104 - LA SOLEDAD DESTRUYE TU CEREBRO \| Ana Asensio en Roca Project" (2026-08-19) | ES | 1 h 22 min | RSS enclosure (anchor.fm feed) | Hand-corrected 20 min |
| 5 | Spotify `38WF1IXMypIn56llEtBajd` | Acquired | "Ferrari" (2026-04-13) | EN | **3 h 58 min** | RSS enclosure (transistor.fm feed) | Published transcript (speaker-labelled, untimed), aligned to the window and checked |

Episodes 1–4 publish no transcript (no `podcast:transcript` in their feeds, no YouTube subtitles), so their scored
windows are hand-corrected: about 8–12 hours in total. Acquired publishes a speaker-labelled transcript
(`podcast:transcript`, `text/plain`) without timings; `podeval draft` aligns it to the window, and it still gets a
listen, because published transcripts drop filler words and false starts. Speaker names come from the show notes
and the owner confirms them once.

What this set covers: peninsular Spanish and English, 2–4 speakers in conversation, crosstalk and laughter, three
episodes over 2 h (one near 4 h, beyond the 3 h memory target of Phase 3), three link types (Spotify, YouTube,
Apple). All five run on the Parakeet path of [0002](0002-asr-engine.md); the durations of the downloaded files are
longer than the feeds say because of inserted ads.

Coverage gaps, measured elsewhere until episodes are added:

- **Catalan** (the WhisperKit + VAD-window path): covered only by FLEURS in `bench/` (read speech, not podcasts).
  A Catalan episode is the most useful addition.
- **Code-switching** and a **solo speaker**: not covered.

The original proposal (10 episodes across EN/ES/CA) is kept below for reference.

### Original proposal (superseded)

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
