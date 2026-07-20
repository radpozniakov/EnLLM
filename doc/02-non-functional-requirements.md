# EnLLM Non-Functional Requirements

**Status:** Baseline (implemented, personal use)  
**Scope:** MVP defined in [00-technical-specification.md](00-technical-specification.md)

## NFR-001 — Platform

- EnLLM must target macOS 26 on Apple Silicon.
- The app must use bundle identifier `com.radpozniakov.enllm`.
- Intel and earlier macOS versions are not supported.
- The app must run as a menu-bar accessory application without a Dock icon.

## NFR-002 — Performance

- Runtime behavior must show menu-bar activity or the translation loading panel within 200 ms of a hotkey/menu invocation.
- Runtime behavior must enforce a 15-second timeout for every provider request.
- Selection capture and settings interaction must not block the main thread with sleeps or synchronous network/file operations.
- The formal ten-request-per-provider diagnostic sampling record was **descoped for personal use on 2026-07-19**. The binding runtime requirements above (200 ms feedback, 15-second timeout, no main-thread blocking) still hold; latency may be spot-checked informally at the author's discretion but no formal sample is required.

## NFR-003 — Reliability and Data Safety

- No failure or cancellation may paste empty, token-limited, truncated, incomplete, stale, or unverified output.
- Simulated Copy must be accepted only after a pasteboard change; unchanged pasteboard content must never be treated as the current selection.
- Internal clipboard use must snapshot and restore all available pasteboard items and types.
- Automatic correction replacement must require verification of the original target context immediately before paste.
- Operation side effects must be serialized and cancellation-safe.
- A response from a superseded operation must have no user-visible or clipboard side effects.
- Settings must be atomic from the running app’s perspective: a failed autosave commit must not partially activate a draft. Durable cross-store rollback is best effort; incomplete recovery must be explicit and must reload the actual stored state.

## NFR-004 — Compatibility

EnLLM targets standard macOS editable text controls through AX-first selection capture with a safe clipboard-fallback path, and must fail closed (safety panel, no paste) wherever a target cannot be verified. It must work in the applications its author actually uses; browsers, native editors, and Electron apps are the expected environments, and custom editors that omit AX metadata (e.g. Sublime Text, Zed) are supported through the clipboard-fallback path. Terminal applications, secure fields, and nonstandard/noneditable controls may fail safely and are not required to support full workflows.

The fixed six-application (Chrome, Safari, Notes, TextEdit, Slack, VS Code) 12-run compatibility matrix and the supplemental Sublime Text/Zed acceptance runs were **descoped for personal use on 2026-07-19**: no fixed set of applications is a promised acceptance requirement. If a real app misbehaves, capture the AX/clipboard evidence and fix it as isolated, fail-closed, tested code.

## NFR-005 — Privacy

- EnLLM must collect no analytics or telemetry.
- EnLLM must store no correction or translation history.
- Selected text and model output must remain in memory only for the active operation, except when the user explicitly copies output or it is inserted into the source application.
- Selected text must be sent only to the primary provider and, when enabled and needed, one configured fallback provider.
- Settings must disclose fallback data routing.
- OpenAI response storage must be disabled where supported.

## NFR-006 — Security

- API credentials must be stored only in macOS Keychain.
- Credentials and selected text must never appear in preferences, files, logs, error notifications, crash annotations, or Test Connection payloads.
- Provider requests must use TLS endpoints and Foundation `URLSession`.
- Raw provider error bodies must be sanitized before display.
- Secure/password fields must be rejected when detectable.
- The app must not monitor keystrokes or clipboard changes outside an explicit user-invoked operation.

## NFR-007 — Usability

- Normal correction success must be silent and require one shortcut.
- Translation must require one shortcut plus an optional Copy click.
- The floating panel must appear on the display containing the pointer and remain fully visible.
- The panel must not steal focus from the source application.
- Errors must be concise and actionable, with direct links to Settings/System Settings where appropriate.
- Settings must save automatically via a debounced transactional autosave (no explicit Save/Apply button) and must preserve the active configuration when draft validation fails.
- Reset-to-default controls must exist for configurable prompts and model selections.

## NFR-008 — Accessibility

- Settings must use native, labeled SwiftUI/AppKit controls and support VoiceOver and keyboard navigation.
- Status must not be communicated by color alone.
- The nonactivating result panel must expose selectable text and an accessible Copy button for pointer interaction; full keyboard interaction is not guaranteed until the panel is activated and is not an MVP requirement.
- EnLLM must explain why macOS Accessibility permission is needed before directing the user to System Settings.

## NFR-009 — Maintainability

- AppKit/SwiftUI presentation, feature orchestration, selected-text/clipboard integration, provider routing, provider HTTP clients, and persistence must have explicit boundaries.
- Core use cases and routing policy must depend on protocols rather than concrete provider, Keychain, pasteboard, or UI implementations.
- Anthropic- and OpenAI-specific DTOs and error parsing must remain inside their adapters.
- Correction and translation must reuse shared selection, routing, configuration, and panel infrastructure without combining their distinct output policies.
- The project must avoid unnecessary third-party dependencies; system frameworks are preferred.

## NFR-010 — Testability

Automated tests must cover at least:

- Anthropic request construction, response/error parsing, and rejection of token-limit/truncated completion states;
- OpenAI request construction, `store: false`, scanning all output text blocks, and rejection of incomplete/cancelled response states;
- primary/fallback routing and non-fallbackable failures;
- cancellation and stale-response suppression;
- input validation and 10,000-character boundary;
- configuration validation/default recovery;
- Keychain service through an injectable boundary;
- hotkey registration rollback, including installed-handler cleanup after registration failure;
- AX-first selection decision logic, including missing-permission and secure-field short-circuiting without clipboard fallback;
- pasteboard change-count enforcement;
- all-item/all-type pasteboard snapshot restoration;
- target-context verification; and
- correction versus translation output policy;
- loading-panel dismissal cancellation and late-response suppression; and
- complete recovery defaults for every non-secret setting.

System integration that cannot be reliably automated must have a documented manual test procedure. A versioned quality corpus must declare expected correction/translation invariants for multilingual, already-correct, multiline, Markdown, and technical-text fixtures.

## NFR-011 — Build and Distribution

- EnLLM must use an Xcode app project for lifecycle, resources, signing, and packaging.
- Reusable domain and platform code must live in local Swift Package targets.
- Debug and Release builds must be supported from Xcode and a documented command-line invocation.
- Local builds must use a stable Apple Development signing identity, bundle identifier, and app bundle path so normal rebuilds preserve Accessibility trust.
- Public notarization, App Store compliance, update delivery, and migration from the reference apps are not required.

## NFR-012 — Resource Use

- EnLLM must remain idle when no user-invoked action is running.
- It must not use a persistent event tap for reading arbitrary keystrokes when standard global-hotkey registration is sufficient.
- Active network tasks and temporary event monitors must be cancelled/removed when superseded, when a loading panel is dismissed, or when the app quits.
- Quit must wait for any owned clipboard restoration before process termination.
- The app must retain only one active operation and one reusable floating panel controller.

## NFR-013 — Observability Without Content

- Debug diagnostics may record event names, provider identity, stable error categories, durations, and operation IDs.
- Diagnostics must not record selected text, generated text, request/response bodies, clipboard contents, API keys, or secure-field data.
- Release builds should keep diagnostics minimal and local.
