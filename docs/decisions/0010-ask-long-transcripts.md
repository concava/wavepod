# 0010 — Ask reads the whole episode; cloud plan usage is optional

- Status: Accepted for implementation; live cloud account consent/inference needs interactive verification
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

## Speed on a plan (2026-10-23)

A 4.5-hour episode (250k characters) is seven 40k-character parts on a plan. Wavepod read them one after another,
and the summary took about 15 minutes on `gpt-6.1-sol` at medium effort. Now a plan reads up to four parts at the
same time (`AnswerModel.planParallelRequests`), for summaries, for Ask and for the Ask synthesis groups. The local
model still reads one part at a time, because it has one session. Results keep the order of the parts.

A summary part that returns some invalid quotes keeps its valid claims and is not asked again. Before, one
invalid quote out of twenty caused a second request for the whole part. A part with no valid claim is still asked
again, and then fails as before. Ask keeps the full retry, because an answer must not lose evidence.

## Optional ChatGPT plan

Settings → Ask offers **On this Mac** (default) and **My ChatGPT plan**. The latter uses the supported
[Sign in with ChatGPT flow for open-source/local clients](https://developers.openai.com/siwc/token-sharing-open-source).
Eligible users authorize Wavepod's own client registration and ChatGPT plan usage in their browser.

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
its UI, or reusing the desktop app's/Codex's credentials. A desktop app is not required.

References: [registration](https://developers.openai.com/siwc/token-sharing-open-source/sign-in),
[sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions),
[models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference),
[preview limits](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations).

## Optional Claude plan

Settings → Ask also offers **My Claude plan**, using Anthropic's official Claude Code programmatic interface
(`claude -p`). As of 2026-10-19, Anthropic explicitly supports subscription limits for this interface and
third-party apps: [plan usage](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan),
[programmatic use](https://code.claude.com/docs/en/headless), [CLI reference](https://code.claude.com/docs/en/cli-reference).
This requires a current, user-installed Claude Code executable. Settings detects common install locations,
offers executable selection and the installation guide, browser sign-in, connection checks, model aliases
(Sonnet/Opus/Haiku), disconnect and usage management. Model access still depends on the account.

Claude Code owns OAuth, refresh and credential storage in a **wavepod-specific `CLAUDE_CONFIG_DIR`**; its
sign-in/logout does not modify the user's ordinary Claude Code profile. Wavepod never opens desktop credential
files or copies tokens. The subprocess environment excludes inherited API keys, bearer tokens, federation,
alternate endpoints and provider flags; `forceLoginMethod: claudeai` and an `auth status` check reject API-key,
Console and third-party accounts before passing transcript text. Selecting this option does not silently
switch to paid API-key billing.

The same full-coverage, citation-validated pipeline supplies questions/history/transcript text to Claude.
Audio and existing Claude Desktop conversations are not supplied. Prompts travel over stdin, not process
arguments. Safe/restricted mode, empty tool and MCP sets, disabled hooks/skills/browser integration, and no
session persistence keep the call focused on the supplied text. Managed administrator policies still apply.
`--bare` is deliberately not used because it skips subscription authentication. A dedicated empty working
directory avoids loading a project. Stop cancels the process; time and output are bounded. Nonzero exits,
partial/error results, expiry and quota problems fail explicitly rather than becoming “not found”.

Unlike the direct ChatGPT adapter, Claude Code owns its network stack. This is an explicit exception to the
app HTTP transport policy, alongside the existing media extractor. Settings discloses it; the network log
records an **external invocation**, without pretending to have observed destinations or HTTP codes. The
app's HTTP allow-list cannot govern Claude Code. Local remains the default and does not start this process.

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

Claude validation uses a fake CLI executor for subscription enforcement, isolated configuration, provider
environment exclusion, safe arguments/stdin, structured failures and redacted external logging, plus real
local process fixtures for large input, cancellation and timeout. A live Claude sign-in/inference check still
requires an installed Claude Code executable and the owner's browser consent; ordinary tests do neither.
