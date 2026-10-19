# 0010 — Ask reads the whole episode; ChatGPT plan usage is optional

- Status: Accepted for implementation; live ChatGPT account consent/inference needs interactive verification
- Date: 2026-10-19

## Problem

Ask previously selected at most twelve lexical/semantic matches, passed no conversation history, and called
the provisional local 4B model once. A four-hour episode could be reduced to a few minutes of evidence.
Broad questions, paraphrases, comparisons across the episode and follow-ups could therefore produce an
incorrect “not found”. An invalid model response could also become an empty answer.

## Decision

Local inference remains the default. Ask uses `EpisodeAnswers` for both local and optional cloud generation:

1. Split the complete transcript into successive contexts. Read **every** context for the current question,
   including contexts with no keyword matches. Include a bounded recent conversation, with citation pointers,
   to resolve follow-ups. Conversation is not source evidence.
2. Validate each extracted claim's quote against both the supplied source and the original transcript. Match
   exact normalized contiguous words (case, accents and punctuation are ignored). This supersedes 0008's 0.85
   fuzzy threshold: it could accept a quote with a changed month or budget inside an otherwise matching sentence. Build
   the original transcript's token/minute index once per question, instead of repeatedly normalizing hours of
   words for every citation. Preserve the original word timings; publisher cue timings remain coarse.
3. Combine relevant findings with bounded hierarchical synthesis. Carry original quotations and timestamps
   through every reduction. A synthesis returning `[]` cannot discard verified evidence. Stop if a model
   fails to condense, rather than loop indefinitely or silently truncate the evidence list.
4. Report absent evidence only after every context has been processed. Invalid output after retry, provider
   errors, usage limits and interrupted generation are separate errors. This refines 0008's citation retry
   behavior: an entirely invalid response is an error, rather than an empty “not found” result.
5. Show reading/synthesis progress and offer Stop. Save the result to the original episode if the user changes
   views; switching episodes cancels the outstanding question. `wavepod-ask` runs this same pipeline without
   requiring the separate meaning-search model or index.

This guarantees source coverage, not universal answer correctness. Quote validation proves the quoted text
exists at the cited position; it does not prove the model's interpretation follows from the quote. Local
generation is still limited by the installed model's reasoning ability. Full scans may take minutes on long
episodes, and repeated questions currently reread the transcript. Evidence caching/retrieval acceleration
can follow once it preserves coverage for broad questions and explicit absence claims.

## Optional ChatGPT plan

Settings → Ask offers **On this Mac** (default) and **My ChatGPT plan**. The latter uses the supported
[Sign in with ChatGPT flow for open-source/local clients](https://developers.openai.com/siwc/token-sharing-open-source).
Eligible users authorize wavepod's own client registration and ChatGPT plan usage in their browser.

- The registration uses a stable per-install host ID, fresh PKCE/state/nonce, a listener bound to
  `127.0.0.1`, and the exact `/auth/callback` URI. Use the issued client ID for token exchange and subsequent
  sign-ins. Validate the ID token's RS256 signature against the pinned issuer's JWKS, issuer, audience,
  expiration, nonce and subject before saving the account. Inference requires the actual granted plan scopes.
- Keep registrations distinct even when their emails match. Access/refresh/ID tokens live in a device-only,
  unlocked Keychain item, never UserDefaults, source control, URLs, network logs or chat messages. Refreshes
  are coalesced and serialized with a process lock. Disconnect clears local credentials and attempts remote
  revocation; failures explicitly direct the user to disconnect in ChatGPT Settings.
- Discover models from the authenticated account's `/v1/models` catalog; preserve visible server ordering.
  No model identifier is hardcoded. A listed model is not proof of inference entitlement: errors are surfaced.
- Use the public Responses API with `store: false`, `stream: true`, self-contained inputs and no unsupported
  sampling/output-limit fields. Accept only a completed response, including when a failure follows text
  deltas. All calls use the shared allow-listed `HTTPClient`, with no credential/body redirects. The network
  log records hosts, purposes and response codes, never request bodies or authorization headers.
- Choosing ChatGPT explicitly sends the question, recent conversation and transcript text to OpenAI; **audio
  is not sent**. Local mode does not use ChatGPT inference. Cloud errors do not silently select another
  provider. Show the first-use plan notice, active account, model, provider and Manage usage link.

This connects the user's account through official OAuth, rather than automating ChatGPT Desktop, scraping
its UI, or reusing the desktop app's/Codex's credentials. A desktop app is not required. Claude is not added in
this change: the owner selected their existing ChatGPT plan and local inference as the standard mode.

References: [registration](https://developers.openai.com/siwc/token-sharing-open-source/sign-in),
[sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions),
[models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference),
[preview limits](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations).

## Validation

Offline tests use a dense, synthetic four-hour transcript to verify all 480 sections reach generation,
independent of keyword matches; early/late evidence, synthesis, follow-up context, invalid citations,
cancellation and explicit absence are tested separately. OAuth tests use freshly signed RSA fixtures,
a real loopback callback and mocked HTTPS exchange/JWKS endpoints, without touching a real account.
Transport tests cover rotating refresh tokens, concurrent callers, streamed completion/errors, model
catalog filtering, credential redirects and log redaction. A separate opt-in local-model test checks changes
in dates/budgets between the beginning and last minute of a multi-context transcript.

On 2026-10-19, the selected suite passed 42 tests (38 pipeline/connection tests and 4 app-model tests),
including both opt-in local-model tests. The early/late evidence test took 83 seconds on the development
Mac; this is a correctness smoke test, not a four-hour performance benchmark. Three snapshot tests
(eight light/dark images) passed after visual review.

Live ChatGPT sign-in, account eligibility and inference cannot be established from offline fixtures. They
must be verified with the owner's browser consent after installation; account usage is not exercised by
ordinary tests. The provider is optional and is not enabled on fresh installations.
