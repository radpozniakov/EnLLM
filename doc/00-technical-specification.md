# EnLLM Technical Specification

**Status:** Baseline (implemented, personal use)  
**Product:** EnLLM  
**Bundle identifier:** `com.radpozniakov.enllm`  
**Target:** macOS 26, Apple Silicon  
**Audience:** Personal use by Rodion  

Related documents:

- [Functional requirements](01-functional-requirements.md)
- [Non-functional requirements](02-non-functional-requirements.md)
- [MVP acceptance test plan](03-acceptance-test-plan.md)
- [ADR-0001: Application architecture](adr/0001-application-architecture.md)
- [ADR-0002: Selected-text capture and safe replacement](adr/0002-selected-text-capture-and-safe-replacement.md)
- [ADR-0003: LLM provider routing and configuration](adr/0003-llm-provider-routing-and-configuration.md)

## Why Develop This App

Writing and translating text currently requires either switching context to a separate LLM interface or running two independent menu-bar utilities with duplicated permissions, settings, provider clients, hotkey handling, and clipboard logic.

EnLLM will combine the proven workflows of the two reference MVPs in `refs/Corrector` and `refs/llm-translator`:

1. correct selected text in place with one shortcut; and
2. translate selected text into Ukrainian without leaving the current application.

The new app is intended to:

- reduce interruption during daily writing;
- provide both actions through one consistent menu-bar application;
- retain the useful behavior of the reference MVPs while fixing known safety, clipboard, concurrency, credential-storage, and hotkey issues;
- establish a small, testable architecture that can evolve without coupling AppKit integration, feature workflows, and LLM providers; and
- remain fast and unobtrusive for personal use.

## What This Application Is and What It Is Not

### What EnLLM Is

EnLLM is a menu-bar-only macOS utility with no Dock icon and two commands:

- **Correct Selection** — minimally corrects grammar, spelling, punctuation, and obvious wording problems in selected text. It may correct text in any language. It preserves meaning, tone, language, line breaks, plain-text structure, Markdown, code blocks, commands, paths, API names, and identifiers. On success, it replaces the original selection in place.
- **Translate Selection to Ukrainian** — auto-detects the source language and translates selected text into Ukrainian. It shows the result in a nonactivating floating panel near the pointer. The panel contains selectable text and a **Copy** action; copying closes the panel. If the input is already Ukrainian, it is returned unchanged.

Both commands:

- are available from the menu bar;
- have separate configurable global shortcuts;
- accept at most 10,000 characters;
- obtain selected text through the macOS Accessibility API first and a safe simulated-Copy fallback second;
- use a shared, provider-neutral LLM layer;
- support user-supplied Anthropic and OpenAI credentials stored in macOS Keychain;
- use one global primary provider and an optional one-attempt fallback provider;
- use fixed per-action model selectors for each provider, chosen independently for correction and translation, plus separate editable instruction prompts for correction and translation;
- use built-in model and prompt defaults when settings are reset or persisted configuration cannot be loaded safely; and
- retain selected text only in memory for the duration of the active operation.

Default configuration:

| Setting | Default |
|---|---|
| Correct shortcut | `⌃⇧T` |
| Translate shortcut | `⌥T` |
| Anthropic correction model | `claude-haiku-4-5` |
| Anthropic translation model | `claude-haiku-4-5` |
| OpenAI correction model | `gpt-5.4-mini` |
| OpenAI translation model | `gpt-5.4-mini` |
| Translation target | Ukrainian (fixed) |
| Request timeout | 15 seconds |
| Maximum input | 10,000 characters |
| Fallback | Enabled when both credentials are configured; user may disable it |

The application does not open Settings or onboarding automatically at launch. Required permissions or missing configuration are explained when the relevant action is first used. After the first Correct operation reaches a terminal state and finishes clipboard restoration, EnLLM requests notification permission; the permission prompt must never interrupt selection capture or target verification. Correction failures use macOS notifications when already authorized and fall back to the floating error panel otherwise.

### What EnLLM Is Not

EnLLM is not:

- a chat client or general-purpose LLM assistant;
- a full writing editor, grammar-learning product, or translation workspace;
- a background service that monitors typing or the clipboard;
- an autonomous or context-aware action selector;
- an offline/local-model application;
- a rich-text editor or a guarantee of font, color, link, or attributed-text preservation;
- a cross-platform application;
- a public, App Store, or multi-user product; or
- a system of record for correction or translation history.

## Use Cases

### UC-01: Correct Selected Text in Place

**Actor:** User  
**Preconditions:** Accessibility access is granted; at least one usable provider route is configured; editable text of 10,000 characters or fewer is selected.

1. The user selects text in an application.
2. The user presses `⌃⇧T` or chooses **Correct Selection** from the menu.
3. EnLLM shows menu-bar activity within 200 ms.
4. EnLLM captures the selected text and a stable description of its source target.
5. EnLLM sends the text separately from the configured correction instruction prompt to the selected provider route.
6. Before replacement, EnLLM deterministically verifies the original target. AX-selected-text capture requires exact PID, focused-element, range, and text equality. Clipboard-fallback capture requires exact PID and focused-window equality, equality for element/range metadata that was available at capture, and an exact final re-copy text match followed by a second metadata check. This compatibility path supports custom editors that omit AX text-selection metadata.
7. EnLLM replaces the selection only with a nonempty response whose provider status confirms normal completion rather than truncation/token exhaustion.
8. EnLLM restores the pre-operation clipboard contents and clears the activity state.
9. Success is silent.

**Alternative — target changed or cannot be verified safely:** EnLLM does not paste. It shows the corrected result in the floating panel so the user can copy it manually.

**Failure:** EnLLM never pastes empty, partial, stale, cancelled, or failed output. It restores the clipboard and shows a concise notification, or the floating error panel if notifications are unavailable.

### UC-02: Translate Selected Text into Ukrainian

**Actor:** User  
**Preconditions:** Accessibility access is granted; at least one usable provider route is configured; text of 10,000 characters or fewer is selected.

1. The user selects text in an application.
2. The user presses `⌥T` or chooses **Translate Selection to Ukrainian** from the menu.
3. A nonactivating loading panel appears near the pointer within 200 ms without taking focus from the source application.
4. EnLLM sends the selected text separately from the configured translation instruction prompt.
5. The panel displays selectable translated text that satisfies the acceptance fixture’s declared plain-text structure, line-break, Markdown, code, and technical-token invariants.
6. The user clicks **Copy**; EnLLM writes the result to the clipboard and closes the panel.
7. The user may instead dismiss the panel by clicking outside it. Dismissing a loading panel cancels that operation, and a late response cannot reopen it.

**Failure:** The panel displays a concise, actionable error and never replaces source text. Truncated, token-limited, incomplete, or empty provider output is treated as failure.

### UC-03: Use Provider Fallback

1. EnLLM attempts the globally selected primary provider first.
2. If fallback is enabled and the primary provider is missing a credential or fails because of authentication, authorization, rate limiting, timeout, network failure, provider/server failure, or empty or incomplete provider output, EnLLM attempts the other configured provider once.
3. Local failures such as no selection, oversized input, invalid local settings, missing Accessibility access, clipboard failure, or a cancelled operation do not trigger fallback.
4. No provider is retried within the same action.
5. If both providers fail, the user receives one concise error naming both failed providers.

The Settings UI must disclose that fallback can send the same selected text to a second provider.

### UC-04: Cancel an Older Operation

1. An action is already waiting for an LLM response.
2. The user invokes either action again.
3. EnLLM cancels the older task and starts the newest requested action.
4. A late response from the cancelled task cannot update the panel, issue a success state, or paste text.
5. Clipboard and UI state owned by the cancelled operation are restored or discarded safely before the new operation performs conflicting side effects.

### UC-05: Configure EnLLM

1. The user opens **Settings** from the menu bar.
2. The user can configure:
   - primary provider;
   - Anthropic and OpenAI API keys;
   - provider fallback toggle;
   - a fixed model selection for each provider and action (correction and translation);
   - separate correction and translation instruction prompts;
   - correction and translation shortcuts.
3. The user can reset the model selections and prompts to built-in defaults.
4. The user can test each provider connection with a small request that contains no selected user text.
5. After launch bootstrap finishes, edits save automatically a short moment after the user stops editing; Settings controls remain unavailable during bootstrap or an active commit, and a subtle Saving…/Saved status is shown.
6. For each autosave, EnLLM snapshots the complete settings and credential-intent draft, validates it (invalid drafts are never saved), stores credentials in Keychain, stores non-secret versioned preferences locally, prepares both hotkeys, and then publishes the new runtime configuration as one activation step. Closing Settings flushes a pending valid commit; on Quit, autosave awaits the commit or rollback and can cancel termination on a save or recovery failure until an explicit safe-discard confirmation.
7. If any step fails, the known previous runtime configuration remains active. EnLLM attempts to restore previous persisted values; if recovery is incomplete, it reloads non-secret settings and credential presence, disables only routes whose credential truth is uncertain, and shows a recovery error instead of reporting success.

### UC-06: Handle Missing Setup or Permissions

- EnLLM does not show automatic first-launch UI.
- If a command is invoked without Accessibility permission, EnLLM explains why access is required and offers a direct path to the relevant System Settings page.
- If no provider route is usable, EnLLM shows an actionable error and offers to open Settings.
- After the first Correct action finishes and any internal clipboard restoration is complete, EnLLM requests notification permission. The first action does not wait for this permission; denial does not block later corrections, and errors use the floating panel instead.

## Acceptance Criteria

### Core Workflow

1. EnLLM builds and runs as a locally signed, Apple-Silicon, menu-bar-only application on macOS 26 using bundle identifier `com.radpozniakov.enllm`.
2. **Correct Selection** minimally corrects selected text in any language and replaces it only when the original target is verified as unchanged.
3. **Translate Selection to Ukrainian** never modifies source text and displays Ukrainian output in a nonactivating floating panel.
4. Correct and Translate are available through both menu actions and independently configurable global shortcuts. Defaults are `⌃⇧T` and `⌥T`.
5. Empty/whitespace selection and input over 10,000 characters are rejected before any provider request.
6. If simulated Copy does not produce a new pasteboard value, EnLLM reports no selection and never sends or pastes stale clipboard text.
7. If focus, target element, or selection changes during correction, EnLLM does not paste and instead displays the result panel.
8. A newer invocation cancels and supersedes an older request; stale responses have no user-visible or clipboard side effects.
9. Translation output is selectable; **Copy** places it on the clipboard and closes the panel.
10. Successful correction is silent except for temporary menu-bar activity.

### Compatibility and Reliability

11. EnLLM works in standard macOS editable text controls through AX-first capture with a safe clipboard-fallback path, and fails closed (safety panel, no paste) wherever a target cannot be verified. A successful Correct requires automatic in-place replacement; the safety-panel fallback is correct failure behavior but is not a compatibility success. A successful Translate requires a completed panel result and working Copy. *(The former fixed six-application matrix — Chrome, Safari, Notes, TextEdit, Slack, VS Code — and the supplemental Sublime Text/Zed acceptance runs were descoped for personal use on 2026-07-19; no fixed app list is a promised acceptance requirement. See NFR-004.)*
12. Across those runs there is no wrong-target paste, stale clipboard submission, truncated/partial output, empty replacement, or loss of pre-existing clipboard contents caused by internal capture/replacement operations.
13. The safe clipboard fallback preserves all captured pasteboard items and data types, not only plain text.
14. Secure/password fields are rejected or fail safely without exposing content.
15. Rebuilding and locally signing the app with the documented development identity does not require Accessibility permission to be granted again under the normal development workflow.

### Provider and Configuration

16. Anthropic and OpenAI clients conform to one provider-neutral operation contract and support the built-in model defaults.
17. Each client validates the provider’s terminal completion status. Token-limit, truncated, incomplete, cancelled, or empty responses are rejected for both correction and translation and are covered by parsing tests.
18. The primary provider is attempted first. When enabled and configured, fallback occurs at most once only for approved provider failures, including a missing primary credential.
19. Disabling fallback prevents text from being sent to the secondary provider.
20. API keys are stored only in macOS Keychain. They do not appear in preferences, files, logs, crash messages, or UI after the secure field is cleared.
21. Editable correction and translation instructions are stored separately; selected text is sent as separate user content and is never interpolated into the instruction setting.
22. Invalid, unreadable, or disallowed-selection non-secret configuration resolves to a complete default state: Anthropic primary, fallback enabled, default hotkeys, built-in model selections, and built-in prompts. API keys never receive defaults.
23. **Test Connection** reports success or an actionable provider-specific failure without using selected text.
24. Autosave is atomic from the running app’s perspective: failure never partially activates the draft. Persisted rollback is attempted; incomplete recovery is shown explicitly, the UI reloads durable non-secret settings and credential presence, and only uncertain credential routes are disabled.

### Performance and Privacy

25. Runtime performance is bounded by feedback within 200 ms of invocation and a 15-second timeout for every provider request. *(The former formal 10-request-per-provider diagnostic sample was descoped for personal use on 2026-07-19; these runtime bounds still hold and latency may be spot-checked informally. See NFR-002.)*
26. EnLLM stores no correction/translation history, analytics, or selected-text logs.
27. Selected text is sent only to the active provider and, when enabled and required, one configured fallback provider. The behavior is disclosed in Settings.
28. OpenAI requests disable provider-side response storage where the API supports it (for example, `store: false`).

### Verification

29. Automated tests cover provider request/response and completion-status parsing, fallback routing, cancellation/stale-response suppression, configuration validation/defaulting, hotkey rollback, selection validation, pasteboard snapshot restoration, and correction target verification.
30. A versioned acceptance corpus covers: erroneous prose in more than one language, already-correct text, multiline text, Markdown, technical prose containing code/commands/paths/identifiers, English-to-Ukrainian translation, and already-Ukrainian input. Results must contain no commentary and must preserve the fixture’s declared invariants.
31. The project passes its unit test suite and Debug/Release builds. This automated gate is the readiness bar for personal use.
32. Real-world behavior may be confirmed by an optional, non-blocking personal smoke check on the target Mac (see the implementation backlog's BL-012). *(The former formal phase/release-acceptance apparatus — a documented compatibility matrix, ten-sample performance record, and MVP-complete gate — was descoped for personal use on 2026-07-19.)*
33. Dismissing a loading panel or quitting EnLLM cancels the active task, suppresses late UI/output, and completes any owned clipboard restoration before termination.

## Non-Goals

The following are explicitly outside the MVP:

- translation to languages other than Ukrainian;
- automatic bidirectional translation;
- automatic action/language inference between Correct and Translate;
- preview/diff for every normal correction;
- rich-text/attributed-style preservation;
- correction or translation history;
- accounts, sync, teams, analytics, or telemetry;
- local/offline models;
- streaming responses;
- more than Anthropic and OpenAI;
- provider-specific prompts or separate provider routing per feature;
- retries beyond the single alternate-provider fallback;
- background clipboard or keystroke monitoring;
- app-specific browser/editor extensions;
- terminal compatibility as an MVP acceptance requirement;
- a fixed multi-application compatibility matrix, a formal ten-sample performance record, and a formal MVP-acceptance gate (descoped for personal use on 2026-07-19);
- launch at login;
- auto-update;
- sandboxing, Mac App Store distribution, notarized public distribution, Intel support, or support for macOS versions earlier than 26;
- migration of settings or credentials from either reference MVP; and
- localization of the EnLLM interface.

## Phase 5 configuration-format decision

The first release uses a strict schema-v2 JSON document at `~/Library/Application Support/com.radpozniakov.enllm/settings-v2.json`, resolved through `FileManager`. `settings-v1.json` is only ever read for a one-time migration and is never overwritten: when no v2 file exists, a valid v1 file is migrated by copying each provider's single v1 model into both of that provider's action selections (defaulting any no-longer-allowed value) and preserving all other settings, writing v2 atomically before the migrated runtime is published; a failed migration write leaves v1 untouched and falls back to complete defaults. There is no v0 or reference-application migration. A missing file uses complete defaults; unreadable, malformed, unsupported-version, missing/unknown-field, blank-instruction, disallowed-model-selection, invalid-hotkey, or duplicate-hotkey documents recover the entire non-secret configuration to defaults rather than partially merging fields. Credentials remain separate Keychain items.

Existing credentials are loaded from Keychain into secure Settings fields and displayed as masked values. Editing replaces the credential; a confirmed explicit deletion removes it through the same autosave transaction, while an edited empty/whitespace field is not an implicit deletion.

## Phase 6 notification decision

Correction failures use a macOS notification only when notification authorization is already granted. The notification title is **“Correction failed”** and its body is a sanitized, stable actionable error category. Notifications expose no actions. Accessibility and unavailable-notification cases use the floating error panel, which retains its direct Accessibility Settings action where applicable. Panel auto-dismiss remains deferred.

## Open Questions

These questions do not block the product definition but must be resolved before or during implementation:

1. Which local Apple Development signing identity and Team ID will be used, and what exact build/package command will guarantee a stable bundle path and signature?
2. If a specific application the author uses does not expose a stable focused element and selected range, does it need app-specific Accessibility adaptation, or is the clipboard-fallback path sufficient? Safety-panel fallback remains correct behavior but does not satisfy the automatic-replacement criterion. (No longer gated on a fixed acceptance matrix as of 2026-07-19; handled ad hoc if a real app misbehaves.)
3. Should completed translation/error panels auto-dismiss after a fixed interval, and if so, should the interval differ for errors and successful results?
4. Are the four catalog model selections (OpenAI correction/translation `gpt-5.4-mini` or `gpt-5.6-luna`; Anthropic correction `claude-haiku-4-5`; Anthropic translation `claude-haiku-4-5` or `claude-sonnet-5`) still available to the configured accounts at implementation time? If not, the catalog must be updated without changing the provider abstraction.
