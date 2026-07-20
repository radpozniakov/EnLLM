# EnLLM Acceptance / Readiness Test Plan

**Status:** Baseline (implemented, personal use)  
**Source:** [Technical specification](00-technical-specification.md)

**Scope note (2026-07-19):** EnLLM is a personal-use tool. The formal phase/release-acceptance apparatus — a fixed six-application compatibility matrix, ten-sample performance records, and a formal MVP-complete gate — was descoped (see the [implementation backlog](08-implementation-backlog.md#descoped-on-2026-07-19)). The readiness bar is now the **automated gate (Section 1)** plus an **optional personal smoke check** (backlog BL-012). Sections 3–9 are retained as reference checklists for that optional check, not as mandatory gates; run any of them ad hoc if a real problem appears. The automated coverage (Sections 1–2) remains fully required.

## 1. Automated Gate

Before manual testing:

```sh
swift test
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM test
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM -configuration Debug build
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM -configuration Release build
```

The final project may adjust exact scheme/package commands. All tests and builds must pass.

Required automated coverage is defined by FR-047–FR-049 and NFR-010, including:

- provider completion/truncation parsing;
- primary/fallback routing;
- cancellation and stale-response suppression;
- pasteboard change-count and all-type restoration;
- deterministic target verification;
- one-time schema-v1 to schema-v2 migration and debounced autosave commit/rollback; and
- complete configuration recovery defaults.

## 2. Versioned Quality Corpus

The concrete fixture files live under [`Tests/QualityCorpus/`](../Tests/QualityCorpus), documented by [`Tests/QualityCorpus/README.md`](../Tests/QualityCorpus/README.md). Each fixture is a JSON document that declares its expected invariants (see the README for the invariant vocabulary). The corpus is versioned with a `corpusVersion` field. Fixture inputs are synthetic only and must never contain captured personal text, credentials, or PII.

The automated integrity check [`Tests/EnLLMCoreTests/QualityCorpusIntegrityTests.swift`](../Tests/EnLLMCoreTests/QualityCorpusIntegrityTests.swift) validates fixture structure, versioning, result-only declarations, and that every declared protected token literally appears in its input. It does not call any provider; model-quality judgement against the declared invariants is performed during manual acceptance and recorded in [`06-validation-log.md`](06-validation-log.md).

| ID | Action | Content type | Fixture path | Required invariants |
|---|---|---|---|---|
| C-01 | Correct | English prose with known grammar/spelling errors | `Tests/QualityCorpus/correction/C-01.json` | Known errors fixed; meaning/tone retained; no commentary |
| C-02 | Correct | Non-English prose with known errors | `Tests/QualityCorpus/correction/C-02.json` | Errors fixed without translating or changing language |
| C-03 | Correct | Already-correct prose | `Tests/QualityCorpus/correction/C-03.json` | Returned unchanged |
| C-04 | Correct | Multiline Markdown | `Tests/QualityCorpus/correction/C-04.json` | Line breaks, list structure, links, and fences retained |
| C-05 | Correct | Technical prose with code, command, path, API/product names, and identifiers | `Tests/QualityCorpus/correction/C-05.json` | Technical tokens unchanged; surrounding prose minimally corrected |
| T-01 | Translate | English prose | `Tests/QualityCorpus/translation/T-01.json` | Ukrainian translation only; meaning retained |
| T-02 | Translate | Multiline Markdown | `Tests/QualityCorpus/translation/T-02.json` | Ukrainian prose; declared Markdown structure retained |
| T-03 | Translate | Technical prose and code | `Tests/QualityCorpus/translation/T-03.json` | Prose translated; declared technical tokens/code unchanged |
| T-04 | Translate | Multiline conversational text | `Tests/QualityCorpus/translation/T-04.json` | Speaker/line structure retained |
| T-05 | Translate | Already-Ukrainian text | `Tests/QualityCorpus/translation/T-05.json` | Returned unchanged |

Quality acceptance is invariant-based rather than byte-for-byte where natural-language variation is valid.

## 3. Compatibility (optional personal smoke check)

*Reference checklist, not a mandatory matrix. The former fixed six-application (Chrome, Safari, Notes, TextEdit, Slack, VS Code) 12-run matrix and the supplemental Sublime Text/Zed acceptance runs were descoped for personal use on 2026-07-19.* Run Correct and Translate in whichever applications the author actually uses; the success definitions below are the useful bar for that.

### Successful Correct run

All must be true:

1. Menu-bar activity appears within 200 ms.
2. The provider returns a terminal, nonempty, nontruncated result.
3. EnLLM automatically replaces the original selection in place.
4. The output satisfies fixture invariants.
5. No other field/application receives the paste.
6. Internal clipboard use restores the prepared clipboard snapshot.
7. No modal UI appears on success.

A safety-panel result is correct defensive behavior but does not count as a compatibility success.

### Successful Translate run

All must be true:

1. The loading panel appears within 200 ms on the pointer’s display without taking source-app focus.
2. A terminal, nonempty, nontruncated Ukrainian result appears.
3. Source text is unchanged.
4. Output satisfies fixture invariants.
5. **Copy** writes the result to the clipboard and closes the panel.

### AX-incomplete editors (optional)

Custom editors that omit AX selection metadata (e.g. Sublime Text, Zed) use the clipboard-fallback compatibility path. If the author uses one, the useful things to confirm are: an unchanged selection is replaced in place; changing application/window or the selected text produces the safety panel; prepared clipboard contents are restored; and identical-text-elsewhere ambiguity remains an accepted limitation of that path. None of this is a required gate.

## 4. Safety Scenarios

Run at least once in two representative applications, including one browser/Electron app and one native app.

| Scenario | Expected result |
|---|---|
| No selection; clipboard already contains text | “No selected text”; old clipboard text is not sent or pasted |
| Empty/whitespace selection | Rejected before provider request |
| 10,001-character selection | Rejected without truncation or provider request |
| Focus/app/window changes during correction | No automatic paste; correction appears in safety panel |
| Selection/range changes in same field during correction | No automatic paste; correction appears in safety panel |
| AX-incomplete editor re-copy differs from captured text | No automatic paste; correction appears in safety panel |
| New hotkey action while request is active | Old task cancelled; only newest action can update UI/paste |
| Dismiss translation panel while loading | Request cancelled; panel does not reopen on late response |
| Quit while operation owns clipboard snapshot | Request cancelled; clipboard restored before termination |
| Provider returns token-limit/incomplete status | No paste/result success; stable error/fallback behavior |
| Secure/password field | Rejected or fails safely; no content disclosure |
| Hotkey conflict on autosave commit | Previous runtime configuration and hotkeys remain active |
| Simulated durable autosave rollback failure | Recovery error shown; actual stored state reloaded; no false success |
| Change a model selection or valid setting, then pause | Subtle Saving… then Saved status; change persists to `settings-v2.json` with no Save button |
| Edit a setting into an invalid draft | Not autosaved; last good runtime kept; inline validation shown |
| Close Settings with a pending valid edit | Pending commit is flushed and persisted |
| Quit with an uncommittable invalid or unresolved-recovery edit | Termination cancelled until an explicit safe-discard confirmation |
| Launch with only `settings-v1.json` present | One-time migration writes `settings-v2.json`; each provider's v1 model fills both its action selections; v1 file left untouched |

## 5. Clipboard Preservation

Prepare representative clipboard snapshots before internal capture/replacement:

1. plain text;
2. rich text with plain-text representation;
3. an image;
4. file URL(s); and
5. multiple pasteboard items when supported.

After each internal operation, verify all captured items/types remain available and byte-equivalent where their data is eagerly readable. A user-initiated panel **Copy** intentionally replaces the clipboard and is excluded.

## 6. Provider Routing

With test credentials configured:

- primary Anthropic success does not call OpenAI;
- primary OpenAI success does not call Anthropic;
- disabling fallback prevents secondary calls;
- missing primary key uses configured secondary only when fallback is enabled;
- primary authentication/rate-limit/network/timeout/server/empty/incomplete failures attempt the configured secondary once;
- local input/permission/clipboard/configuration/cancellation failures never trigger fallback;
- both-provider failure names both providers without raw bodies or content;
- Test Connection uses no selected text and tests each provider's distinct selected models for correction and translation (a single request when both actions select the same model), reporting which selected model failed; and
- OpenAI sends `store: false` or the current equivalent.

## 7. Performance (optional spot-check)

*The formal ten-request-per-provider sample was descoped for personal use on 2026-07-19.* The binding runtime requirements remain: feedback within 200 ms of invocation and a 15-second timeout for every provider request (enforced in code). If the author wants a latency read, informally time a few requests against each provider with fallback disabled and a stable connection; nothing here is a gate.

## 8. Signing and Permission Stability

1. Build/package at the documented stable app-bundle path with the chosen Apple Development identity and `com.radpozniakov.enllm`.
2. Grant Accessibility permission once.
3. Run both actions successfully.
4. Rebuild and replace the app through the documented normal workflow.
5. Confirm Accessibility remains authorized and both actions still work.
6. Verify the code signature using the documented `codesign` command.

## 9. Privacy Inspection

Inspect Keychain, the versioned preferences store, app logs, notifications, and diagnostic output:

- API keys exist only in Keychain;
- selected/generated text and request/response bodies are absent from persistence and logs;
- no history, analytics, or telemetry is created; and
- fallback disclosure accurately describes routing.

## 10. Readiness Record (personal use)

*The formal MVP-acceptance gate was descoped on 2026-07-19.* Personal readiness requires only:

- **automated gate (Section 1): pass** — the required bar; and
- **quality corpus integrity (Section 2): pass** — required.

Optional, at the author's discretion (backlog BL-012), with no formal record needed: the compatibility, safety, clipboard, routing, performance, signing, and privacy checklists in Sections 3–9. Run any of them ad hoc if a real problem appears.
