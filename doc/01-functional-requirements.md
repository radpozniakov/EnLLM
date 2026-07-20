# EnLLM Functional Requirements

**Status:** Baseline (implemented, personal use)  
**Scope:** MVP defined in [00-technical-specification.md](00-technical-specification.md)

The terms **must**, **must not**, **should**, and **may** are normative.

## 1. Application Shell

### FR-001 — Menu-bar application

EnLLM must run as an `LSUIElement` menu-bar application without a Dock icon or normal main window.

### FR-002 — Menu commands

The menu must expose:

- Correct Selection;
- Translate Selection to Ukrainian;
- Settings…; and
- Quit.

The menu-bar item must expose an activity state while an action is in progress.

### FR-003 — No launch-time onboarding

EnLLM must not automatically open Settings or onboarding on launch. Missing setup must be handled when a command is invoked or when the user opens Settings.

## 2. Commands and Hotkeys

### FR-004 — Independent global hotkeys

Correct and Translate must have separate global hotkeys.

Defaults:

- Correct: `⌃⇧T`;
- Translate: `⌥T`.

### FR-005 — Hotkey configuration

The user must be able to configure each hotkey in Settings. A valid hotkey must contain at least one modifier and a supported non-modifier key. The two EnLLM actions must not use the same hotkey.

### FR-006 — Atomic hotkey application

On each autosave commit, EnLLM must validate and register both draft hotkeys before replacing the active configuration. If either registration fails, it must preserve or restore both previously active hotkeys and display an inline error.

## 3. Permissions

### FR-007 — Accessibility permission

Before selection capture, EnLLM must verify Accessibility trust. If access is absent, it must not capture or send text and must explain why access is required with an action that opens the relevant System Settings page.

### FR-008 — Notification permission

The first Correct action must run without waiting for notification authorization. After that operation reaches a terminal state and any internal clipboard restoration is complete, EnLLM must request notification permission if status is undetermined. This sequencing must not disturb selection capture or target verification. Denial must not block correction; errors must use the floating error panel when notifications are unavailable.

## 4. Selection Capture and Clipboard Safety

### FR-009 — AX-first capture

EnLLM must first attempt to read selected text from the focused Accessibility element.

### FR-010 — Safe clipboard fallback

When AX selected text is unavailable, EnLLM may simulate `⌘C`. Before doing so it must capture all pasteboard items and all readable data types. It must accept copied text only if the pasteboard change count advances and a new, nonempty plain-text value is present.

### FR-011 — No stale clipboard input

If simulated Copy does not produce a qualifying pasteboard change before the capture timeout, EnLLM must return a no-selection error. It must not read, send, or paste the previous clipboard string as selected text.

### FR-012 — Internal clipboard restoration

After internal capture or replacement, EnLLM must restore the pre-operation pasteboard snapshot after the target application has consumed any simulated paste. Restoration must run after success, error, or cancellation whenever the operation modified the pasteboard.

A user-requested **Copy** from the result panel is not an internal clipboard mutation and must remain on the clipboard.

### FR-013 — Input validation

Before any provider request, EnLLM must reject:

- no selection;
- empty or whitespace-only text;
- text longer than 10,000 Swift characters; and
- content from secure/password fields when detectable.

The app must not silently truncate input.

## 5. Correction

### FR-014 — Correction instruction

The built-in correction instruction must request minimal grammar, spelling, punctuation, and obvious wording correction while preserving meaning, tone, language, plain-text formatting, Markdown, code, commands, paths, API names, product names, and identifiers. It must request output text only.

Correction must not be restricted to English.

### FR-015 — Correct selected text

Correct must send selected text as user content separate from the active correction instruction. It must accept only a nonempty response whose provider-specific status confirms normal terminal completion. It must reject token-limit, truncated, incomplete, cancelled, or otherwise nonterminal responses.

### FR-016 — Target context capture

At selection time, Correct must capture the frontmost application PID, focused AX window identity when available, focused AX element identity when available, selected range when available, selected text, capture method, and operation ID. An Accessibility-selected-text capture is eligible for automatic replacement only with stable element identity and selected range. A clipboard-fallback capture may use the compatibility verification path in FR-017 when the target omits element or range metadata, but it still requires stable focused-window identity.

### FR-017 — Safe target verification

Immediately before automatic replacement, Correct must use the verification path for the capture method:

- **Accessibility capture:** the frontmost PID, focused AX element, selected range, and AX selected text must all be available and exactly equal to the captured values.
- **Clipboard-fallback capture:** the frontmost PID and focused AX window must be available and exactly equal to the captured values. If focused-element identity or selected range was available at capture, that value must still be available and equal. Metadata absent at capture may not be invented or treated as equal. EnLLM must then re-copy through the serialized safe clipboard service, recheck the target metadata, and require the newly copied text to exactly equal the captured source text before immediately posting Paste.

Any unavailable mandatory value or mismatch must use FR-019. The clipboard compatibility path intentionally supports custom editors that expose a stable AX window and standard Copy/Paste but omit AX text-selection metadata; it cannot distinguish identical selected text moved elsewhere within the same AX-incomplete window.

### FR-018 — Correction replacement

When target verification succeeds, Correct must replace the selected text with the corrected plain text, wait until the target has consumed the paste operation, and restore the internal pasteboard snapshot.

### FR-019 — Unsafe replacement fallback

When a valid correction exists but the original target changed or cannot be verified, EnLLM must show the correction in the same nonactivating result panel used for translation. It must not paste automatically.

### FR-020 — Correction feedback

Normal correction progress must be represented by menu-bar activity only. Successful replacement must otherwise be silent.

Correction errors must use a concise macOS notification when authorized, or the floating error panel otherwise.

## 6. Translation

### FR-021 — Ukrainian translation

Translate must auto-detect the source language and translate selected text into Ukrainian. If the input is already Ukrainian, the instruction must request it unchanged. Translation must preserve line breaks and the fixture-declared plain-text/Markdown/code invariants and return text only. It must reject token-limit, truncated, incomplete, cancelled, empty, or otherwise nonterminal provider responses.

### FR-022 — Translation never replaces source

Translate must never paste into or modify the source application automatically.

### FR-023 — Loading and result panel

Translate must immediately show a nonactivating floating panel near the pointer. The panel must remain fully inside the pointer’s current display and represent loading, success, and error states.

### FR-024 — Panel content and actions

Successful output must be selectable and vertically scrollable when needed. The panel must expose **Copy**, which writes the result to the general pasteboard and closes the panel.

The panel must not take keyboard focus when shown. Clicking outside must dismiss it. Dismissing while loading must cancel the active operation, and a late response must not reopen or update the panel. Keyboard-only Escape dismissal is best effort for the nonactivating MVP panel.

## 7. Operation Lifecycle

### FR-025 — Latest invocation wins

EnLLM must allow only one active action workflow. Invoking either command while another request is active must cancel the previous operation and start the newest one.

### FR-026 — Stale-response suppression

Every operation must have an identity or generation token. After cancellation or supersession, its response must not update UI, send notifications, modify source text, or overwrite clipboard state owned by a newer operation.

### FR-027 — Side-effect serialization

Selection capture, simulated paste, and clipboard restoration must be serialized so two operations cannot interleave pasteboard or target-application side effects.

### FR-027A — Quit safety

Quit must cancel the active provider task, suppress late output/UI, and delay termination until any clipboard mutation owned by the operation has been restored or has reported a terminal restoration failure.

## 8. LLM Providers and Routing

### FR-028 — Supported providers

The MVP must support Anthropic Messages API and OpenAI Responses API behind one provider-client protocol.

### FR-029 — Global routing settings

Correction and translation must share one global primary provider and one fallback-enabled setting. Provider routing must not be configured separately per feature.

### FR-030 — Primary attempt

The router must attempt the selected primary provider first when its credential is available.

### FR-031 — Fallback attempt

When fallback is enabled and the alternate provider has a credential, the router must attempt it at most once if the primary credential is missing or the primary attempt fails because of authentication, authorization, rate limiting, timeout, network, provider/server failure, or empty or incomplete provider output.

### FR-032 — No fallback for local failures

Fallback must not occur for local validation, permission, clipboard, configuration, target-verification, or cancellation failures.

### FR-033 — No same-provider retry

The MVP must not retry a provider during the same action.

### FR-034 — Combined failure

If both providers fail, EnLLM must display one concise failure that names both providers without exposing credentials, request content, or unstable raw response bodies.

### FR-035 — Request timeout and storage

Each provider request must time out after 15 seconds. OpenAI requests must set `store: false` or the current equivalent where supported.

Both clients must parse provider completion metadata. Anthropic must reject token-exhausted/truncated responses such as `stop_reason == "max_tokens"`. OpenAI must require a completed response status and reject incomplete/cancelled statuses. Equivalent future provider statuses must map to the same stable complete-versus-incomplete contract.

## 9. Settings and Persistence

### FR-036 — Settings fields

Settings must expose:

- global primary provider;
- fallback toggle and privacy disclosure;
- secure Anthropic and OpenAI API-key fields;
- fixed model selectors for each provider and action (Anthropic correction/translation and OpenAI correction/translation), limited to the built-in catalog with no free-form entry;
- correction instruction editor;
- translation instruction editor;
- correction hotkey recorder;
- translation hotkey recorder;
- Accessibility permission status and link;
- per-provider Test Connection;
- Reset to Default for the model selections and prompts; and
- a subtle autosave status (Saving…/Saved/error) that is keyboard- and VoiceOver-accessible.

### FR-037 — Built-in defaults

Built-in model defaults must be:

- OpenAI correction: `gpt-5.4-mini` (allowed: `gpt-5.4-mini`, `gpt-5.6-luna`);
- OpenAI translation: `gpt-5.4-mini` (allowed: `gpt-5.4-mini`, `gpt-5.6-luna`);
- Anthropic correction: `claude-haiku-4-5` (allowed: `claude-haiku-4-5`);
- Anthropic translation: `claude-haiku-4-5` (allowed: `claude-haiku-4-5`, `claude-sonnet-5`).

Built-in correction and translation instructions must be compiled with the app. The complete initial/recovery configuration is:

- primary provider: Anthropic;
- fallback: enabled, but effective only when an alternate credential exists;
- Correct hotkey: `⌃⇧T`;
- Translate hotkey: `⌥T`;
- OpenAI correction and translation models: `gpt-5.4-mini`;
- Anthropic correction and translation models: `claude-haiku-4-5`; and
- built-in correction and translation instructions.

Disallowed/reset model selections or prompt values and unreadable/corrupt non-secret configuration must resolve to this complete safe state. API keys must never receive defaults.

### FR-038 — Instruction-only prompt editing

Prompt editors must configure instruction/system content only. EnLLM must send selected text separately as user content; prompt settings must not require or accept a `{{text}}` placeholder contract.

### FR-039 — Credential storage

API keys must be stored in macOS Keychain under the EnLLM service namespace. A confirmed explicit deletion must remove that provider’s Keychain item through the same autosave transaction; an edited empty or whitespace-only field must not implicitly delete a stored key.

### FR-040 — Non-secret configuration

Non-secret settings must use a versioned local schema and atomic persistence. The file/domain must not contain API keys or selected text.

### FR-041 — Fallback default

Fallback must be effective when both provider credentials are configured unless the user explicitly disables it. The UI must show when fallback is enabled but unavailable because the alternate credential is absent.

### FR-042 — Test Connection

Each provider must have a Test Connection action using that provider’s draft key and its distinct selected models, testing each in sequence (a single request when correction and translation select the same model). It must flush and await any pending valid autosave and use an immutable captured snapshot, be rejected inline while the draft is invalid, contain no selected user text, and return an actionable success/failure state that identifies which selected model failed.

### FR-043 — Runtime-atomic debounced autosave

Settings must save automatically after a short debounce (600 ms, within an approved 500–800 ms range) once the user stops editing; there is no explicit Save/Apply button. Each autosave must validate the entire settings draft before committing it. Validation must include allowed model selections, nonempty effective instructions, and distinct valid hotkeys. Invalid drafts must never be autosaved: the last successfully persisted and active runtime must be kept and inline validation shown. Rapid edits must coalesce and commits must serialize to the newest complete valid snapshot; obsolete work must be cancelled and stale routine status suppressed, but incomplete-rollback/recovery/uncertain-credential errors must never be suppressed and must block further autosave until a fresh edit.

The commit sequence must be:

1. snapshot the previous runtime and persisted settings;
2. stage/write credentials and versioned non-secret configuration;
3. register both new hotkeys while preserving rollback handles for the old hotkeys; and
4. only after all prior steps succeed, publish the new runtime configuration.

A failure must never partially activate the draft in the running app. EnLLM must attempt to restore previous persisted values and hotkeys. If durable rollback cannot complete, it must not report success; it must reload the actual stored state into Settings, keep the previous runtime configuration where possible, disable any route whose stored state is uncertain, and show an explicit recovery error. Cross-store crash atomicity is not guaranteed.

On Settings close, a pending valid commit must be flushed. On Quit, autosave must coordinate with clipboard teardown, await the commit or rollback, and cancel termination on a save or recovery failure until an explicit safe-discard confirmation permits abandoning an uncommitted edit.

## 10. Errors and Privacy

### FR-044 — Actionable errors

User-facing errors must distinguish at least:

- Accessibility permission missing;
- no selected text;
- text too long;
- secure field unsupported;
- provider key missing;
- invalid provider key/authorization;
- rate limiting;
- timeout/network failure;
- provider failure;
- both providers failed;
- clipboard unavailable;
- hotkey conflict; and
- invalid settings.

### FR-045 — No content logging or history

EnLLM must not persist or log selected text, corrections, translations, API keys, provider request bodies, or provider response bodies. It must not maintain history, analytics, or telemetry.

### FR-046 — Error body sanitization

Provider errors must be mapped to stable user-facing categories. Raw provider bodies must not be shown or logged unless explicitly sanitized to exclude request content and secrets.

## 11. Acceptance Fixtures

### FR-047 — Versioned quality corpus

The repository must contain a small versioned acceptance corpus with declared invariants rather than relying only on subjective ad-hoc text. It must include:

- erroneous prose in English and at least one other language;
- already-correct prose that should remain unchanged;
- multiline and Markdown text;
- technical prose containing code, commands, file paths, API/product names, and identifiers;
- English text to translate into Ukrainian; and
- already-Ukrainian input that should remain unchanged.

For every fixture, successful output must contain only the result text, preserve declared structural/technical invariants, and avoid unrequested tone or meaning changes.

### FR-048 — Manual compatibility outcome

**Descoped for personal use on 2026-07-19.** The former fixed six-application compatibility matrix (Chrome, Safari, Notes, TextEdit, Slack, VS Code) and the supplemental Sublime Text/Zed acceptance runs are no longer promised. Correct must still perform automatic in-place replacement when the target verifies, Translate must still produce a completed panel result with a working Copy, and a correction routed to the safety panel remains correct failure behavior — these are runtime requirements enforced in code and tests. Real-world confirmation is now an optional personal smoke check (see the implementation backlog's BL-012), not an acceptance gate against a fixed app list. See [NFR-004](02-non-functional-requirements.md#nfr-004--compatibility).

### FR-049 — Performance sample

**Descoped for personal use on 2026-07-19.** The formal ten-request-per-provider diagnostic sample is no longer required. The binding runtime performance requirements (200 ms feedback, 15-second request timeout) remain in force under [NFR-002](02-non-functional-requirements.md#nfr-002--performance); latency may be spot-checked informally at the author's discretion.
