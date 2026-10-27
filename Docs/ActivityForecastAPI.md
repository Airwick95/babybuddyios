# What's next: optional own-provider API comparison

This is an additive contribution built on PR #209's local estimator. Keep the local estimate
available as a baseline; the API result is displayed separately as an experimental comparison.
It is not claimed to be more accurate. No real provider account, credential or family data is
required to build or run the supplied tests.

## Setup in the app

Settings > Activity estimates > Own API accepts the user's complete HTTPS endpoint, model
identifier and optional Bearer API key. No provider or model is preselected. The endpoint must
implement the OpenAI-compatible **Chat Completions** request/response shape, JSON-object mode
and one of `max_completion_tokens` / `max_tokens`. The user chooses the token-limit field
their service supports. The request is capped at 1024 tokens. This is not an adapter for every
provider's native API schema; a compatible endpoint/proxy is required.

Plain HTTP, URL credentials, query strings and fragments are rejected. Self-hosted services
need a trusted HTTPS endpoint; no TLS bypass or broad App Transport Security exception is
added. The existing Baby Buddy server installation and API client are untouched.

The configuration is stored as a separate Keychain item with
`WhenUnlockedThisDeviceOnly`, no synchronizable storage and a **new app-only access group**
`$(AppIdentifierPrefix)com.kurtisguy.BabyBuddy.Forecast`. The widget is not granted that group.
Existing server credential groups remain unchanged. A signing profile must permit the new
group. An unsigned simulator cannot be assumed to support this; a Keychain failure is shown
instead of falling back to the server's credential store or insecure persistence.

Saving any configuration resets consent. The user must explicitly allow sharing with that
service and then tap Request API estimate on Home. There are no background requests, automatic
retry loops, model calls from widgets, or automatic requests when changing tabs. Removing the
configuration or wiping server data on sign-out/server change deletes the item and consent.
The debug UI-test reset clears the new item too. The API key is never in defaults or the repo.

## Data sent and accepted

Only bounded, derived numeric features are sent: activity kind, at most ten rounded interval
lengths in minutes, number of represented days, minutes since the anchor, and allowed future
window limits. No names, child IDs, birth dates, exact event dates, notes, tags, pictures, server
URL, Baby Buddy token or custom authorization headers are included. The patterns still carry
health information; the app does not promise anonymity or a provider's retention behavior.

A dedicated ephemeral URLSession has no shared cookies, credential storage or URL cache,
uses normal certificate checks, refuses redirects, times out, and bounds response streaming
to 64 KiB. Error bodies and model prose are not displayed or logged. `store: false` is sent,
which is a request to the selected provider, not a guarantee about its policies. Provider
costs and retention depend on the user's chosen service.

The model returns only `{ "predictions": [{ "kind": "feeding", "start_minutes": 70,
"end_minutes": 90 }] }`, with times relative to the calculation moment. An empty list means
abstention. Client validation rejects extra fields, unknown/duplicate kinds, booleans or
fractional/overflowing times, past or reversed windows, widths under five minutes, truncated
or refused outputs, and predictions extending the local permitted range. Arbitrary generated
advice is never rendered. The model cannot bypass sparse/irregular/freshness checks, invent
unsupported activities or change records. Choosing a narrower range does not establish a
higher confidence or a validated improvement in accuracy.

Results expire within five minutes, earlier at a prediction/freshness cutoff. Record/timer
changes, child switching, consent changes, navigation away and leaving the foreground cancel
the request and discard results. A response received after cancellation/freshness expiry is
not shown. Local estimates remain usable if the API fails or abstains.

## Sources and integration notes

- [Official OpenAI Chat Completions reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)
- [Official OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data)
- [Ollama's OpenAI compatibility documentation](https://docs.ollama.com/api/openai-compatibility)

These sources establish the protocol fields and compatibility options, not verification of a
particular account, model, endpoint or retention agreement. Actual endpoint compatibility is
not live-tested here. In particular, services differ in support for `store`, token-limit
fields and JSON mode. An incompatible service returns an error; the app does not silently
retry under another schema or destination.

The owner should describe the new optional user-selected transfer and provider retention in
the app's privacy information before shipping it. This contribution intentionally leaves
the owner's `PRIVACY.md` wording unchanged. The UI already explains data sharing, costs and
uncertain accuracy before consent. English/German API copy has its own string catalog.

## Verification

`scripts/test-forecast-api.sh` compiles the actual Foundation client/configuration and drives
it through a fake transport. Checks cover request content and units, consent, freshness,
HTTPS validation, Bearer isolation, token cap, protocol compatibility setting, HTTP failures,
valid completion, bounds, malformed model output, abstention and expiry. No live request,
real API key, Keychain write or child data is used. The transport and Keychain sources also
typecheck against the local macOS SDK. This is not an iOS build or a live model accuracy test.

Supplied XCTest and UI tests require full Xcode. The UI tests cover blank configuration and
off-by-default consent without saving a real secret or contacting a provider. A device test
must cover the private Keychain group, actual endpoint and request cancellation behavior.

## Maintainer device checklist

- [ ] Merge/rebase on the local estimator (#209), build app/widgets, and run unit/UI suites.
- [ ] Verify the app's signing profile includes the new private Keychain group and the widget's
  does not. Save, reload, remove and sign out with a synthetic test configuration.
- [ ] Use an owned compatible HTTPS test endpoint and synthetic routines. Inspect the request,
  compare the two displayed estimates, test JSON errors/abstention, and confirm data bounds.
- [ ] Test 401, 429, timeout, oversized output, redirect, cancellation, record/timer changes,
  child switch, backgrounding, changed destination and expired freshness. Check that no stale
  result is shown and that the local estimate still works.
- [ ] Review English/German, VoiceOver, costs/data-sharing copy and the privacy disclosure.
