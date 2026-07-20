# EnLLM Development Plan

**Status:** Active

**Planning style:** Small vertical slices
**Source:** [Technical specification](00-technical-specification.md), [functional requirements](01-functional-requirements.md), [non-functional requirements](02-non-functional-requirements.md), and [acceptance test plan](03-acceptance-test-plan.md)

## 1. Delivery principles

1. Every slice must produce a demonstrable user-visible capability or retire a concrete macOS integration risk.
2. Safety rules are implemented with the capability that needs them, not deferred to a final hardening rewrite.
3. Platform integration is exercised with deterministic local behavior before live-provider latency is introduced.
4. Production and Release composition must fail closed until a real capability exists. A deterministic development harness is permitted only when it is gated by `#if DEBUG` plus an explicit launch argument, is absent from Release binaries, and cannot become the default Debug route.
5. Each slice ends with automated tests and an explicit exit decision; focused manual evidence is recorded when phase or release acceptance is claimed, rather than as paperwork after every change.
6. Scope remains inside the MVP non-goals in the technical specification.

Code is organized by the architectural boundaries in ADR-0001, not by phase. A slice may touch the app, core, and platform targets while preserving their dependency direction.

## 2. Fixed project decisions

| Decision | Value |
|---|---|
| Xcode | 26.3 (build 17C529) |
| Swift | 6.2.4; Swift 6 language mode |
| Deployment target | macOS 26 |
| Architecture | arm64 |
| Project/product/scheme | `EnLLM` |
| App target/module | `EnLLMApp` |
| Package targets | `EnLLMCore`, `EnLLMPlatform` |
| Bundle identifier | `com.radpozniakov.enllm` |
| Signing | Apple Development, Team `66ZYDU2788` |
| Stable local bundle path | `.local-app/EnLLM.app` via `scripts/build-local.sh` |
| Dependencies | System frameworks by default; no third-party package is currently approved |

Phase 5 resolved settings serialization as strict schema-v2 JSON in Application Support with complete-default recovery and a one-time read-only migration from a valid schema-v1 file. Panel auto-dismiss and notification actions remain deferred product choices.

## 3. Phase plan

### Phase 0 — Signed working shell

**Status:** Complete — 2026-07-18

**Outcome:** A locally signed menu-bar app establishes the architecture and build/test workflow without pretending that product actions work.

**Scope**

- Xcode app target with `LSUIElement` and no Dock icon.
- Correct, Translate, Settings, and Quit menu commands.
- Root Swift package with `EnLLMCore` and `EnLLMPlatform`.
- Explicit composition and a main-actor coordinator.
- Fail-closed action handler.
- Package and app unit-test targets.
- Shared scheme, Debug/Release commands, stable local build script, and signing verification.

**Validation**

```sh
swift test
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM test
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM -configuration Debug build
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM -configuration Release build
./scripts/build-local.sh Debug
```

**Exit criteria**

- All commands pass.
- The built app is arm64, signed by the selected identity, has the exact bundle identifier, and contains `LSUIElement = true`.
- Launch creates a status item and no normal window or onboarding.
- Invoking an incomplete action has no selection, clipboard, or network side effects.

**Completion record — 2026-07-18**

- SwiftPM tests, Xcode app tests, and Debug/Release builds passed.
- The stable local Debug and Release bundles passed signature verification.
- Bundle identifier, `LSUIElement`, arm64 architecture, stable path, and signing Team ID were verified.
- Manual validation confirmed menu-bar-only launch, no automatic onboarding or permissions, working Settings lifecycle, fail-closed Correct/Translate commands, unchanged selection and clipboard, no provider network activity, and clean Quit behavior.

**Primary requirements:** FR-001–FR-003; NFR-001, NFR-009, NFR-011.

---

### Phase 1 — Selection-to-panel walking skeleton

**Outcome:** The user invokes Translate and safely sees deterministic local output derived from the real selection in a nonactivating panel.

**Scope**

- Default Translate global hotkey and menu invocation.
- Accessibility trust check and actionable missing-permission state.
- AX-first selected-text capture.
- Serialized simulated-Copy fallback with complete eager pasteboard snapshot, change-count enforcement, timeout, and restoration.
- Empty, whitespace, secure-field, and 10,000-character validation.
- Reusable nonactivating loading/result/error panel near the pointer.
- Selectable output, Copy, outside-click dismissal, and loading cancellation.
- A deterministic local transformer for manual development checks; it must be gated by `#if DEBUG` and an explicit launch argument, remain off by default, and be absent from Release binaries. It performs no external request.
- Quit coordination lands with the clipboard owner: termination must cancel active work and wait for owned restoration before allowing the process to exit.

**Automated validation**

- Capture decision policy and input boundaries, including missing-Accessibility-permission and secure-field short-circuiting without clipboard fallback.
- Failed hotkey registration removes the installed handler without unregistering a nonexistent hotkey, and a later registration can succeed.
- No stale clipboard acceptance without a change-count transition.
- Snapshot restoration for representative eager item/type fixtures.
- Panel dismissal cancels and suppresses late state.
- Coordinator latest-invocation generation behavior.
- Quit during capture/restoration waits for the clipboard owner to reach a terminal restoration result.
- Release-build inspection proves the deterministic development harness is not present or activatable.

**Manual validation**

- One native app, one browser, and one Electron app.
- Panel remains on the pointer display and does not take source focus.
- Existing text, rich text, image, file URL, and multi-item clipboard cases are preserved where eagerly readable.

**Exit criteria**

- Selected text reaches the panel without network access or source modification.
- No-selection and stale-clipboard scenarios fail before output generation.
- Dismissal prevents a late update or reopen.
- Quit cannot bypass clipboard restoration once Phase 1 introduces clipboard mutation.
- The default Debug route and every Release route remain fail closed unless backed by implemented production adapters.

**Primary requirements:** FR-004, FR-007, FR-009–FR-013, FR-021–FR-024, FR-025–FR-027; NFR-002–NFR-008, NFR-012.

**Implementation note — pending manual acceptance:** The deterministic Phase 1 route remains available only in Debug with the exact `--enable-phase1-local-transformer` launch argument; when selected, Correct remains fail closed. At the Phase 1 implementation point, Debug without that argument and every Release build remained fail closed. Since Phase 3 introduced the production Anthropic adapter, normal Debug and Release composition use that production route while the explicit argument continues to select the network-free Phase 1 harness. The native/browser/Electron, pointer-display/focus, clipboard-fixture, dismissal, hotkey, permission, and quit-during-restoration checks were originally required before phase completion. *(2026-07-19 rescope: for personal use these are now the optional BL-012 smoke check, not a completion gate; the automated gate is the bar.)*

---

### Phase 2 — Safe correction walking skeleton

**Outcome:** Correct uses deterministic local output to replace the original selection only after strict target verification.

**Scope**

- Default Correct global hotkey and menu invocation.
- Capture operation ID, frontmost PID, focused AX window identity, focused AX element identity and selected range when available, source text, and capture method.
- Preserve exact PID, focused-element, range, and text verification for AX-selected-text capture.
- Add capability-based clipboard verification for AX-incomplete editors: stable PID/window, equality for element/range metadata captured when available, exact serialized re-copy text, and a second metadata check immediately before replacement.
- Paste replacement, asynchronous consumption delay, and complete restoration.
- Safety-panel fallback when verification is unavailable or fails.
- Menu-bar activity and silent successful replacement.

**Automated validation**

- Every strict-AX and clipboard-compatibility target-verification mismatch and unavailable mandatory-value case.
- Clipboard compatibility succeeds without element/range metadata only when PID, focused window, final re-copy text, and the second metadata check all match.
- Empty-output rejection.
- Cancellation checks around irreversible effects.
- Restoration ownership when one invocation supersedes another.

**Manual validation**

- Focus changes, application changes, window changes, and selection changes during artificial delay.
- Representative automatic-replacement feasibility checks in one native app and one browser or Electron app.
- Supplemental automatic Correct checks in Sublime Text and Zed, including unchanged selection, app/window/selection changes, clipboard restoration, multiple cursors, identical text elsewhere in one window, and paste-consumption timing.

**Exit criteria**

- No changed target or target missing mandatory verification evidence receives an automatic paste.
- A valid result remains recoverable through the safety panel.
- Representative platform feasibility is demonstrated in one native app and one browser or Electron app, and the supplemental automatic Correct checks pass in Sublime Text and Zed, or an explicit blocking adaptation is recorded before provider work continues. The official six-application matrix was descoped for personal use on 2026-07-19 (see the implementation backlog); real-world coverage is now the optional BL-012 smoke check.

**Primary requirements:** FR-014–FR-020, FR-025–FR-027A; NFR-003, NFR-004, NFR-012.

**Implementation note — pending manual acceptance:** The deterministic Phase 2 route remains available only in Debug with the exact `--enable-phase2-local-transformer` launch argument; the existing Phase 1 argument remains translation-only. The route captures PID, focused AX window, available focused-element/range metadata, source text, method, and operation ID. AX capture retains strict verification. Clipboard fallback supports custom editors through stable PID/window verification, equality for any captured optional metadata, an exact serialized re-copy, and a second metadata check before Paste. At the Phase 2 implementation point, Debug without an explicit development argument and every Release build remained fail closed. Since Phase 3, normal Debug and Release composition use the production Anthropic route, while the explicit Phase 1/2 arguments continue to select their deterministic network-free harnesses. Focus/application/window/selection changes, automatic-replacement feasibility in one native app and one browser or Electron app, and supplemental Sublime Text/Zed Correct checks were originally required before phase completion. *(2026-07-19 rescope: for personal use these are now the optional BL-012 smoke check, not a completion gate.)*

**Partial manual evidence — 2026-07-18:** Rodion Pozniakov confirmed automatic single-selection replacement with the signed local Debug harness in Sublime Text Build 4200 and Zed 1.11.3 on arm64 Mac16,7, macOS 26.5.1 (25F80). The build came from the dirty Phase 2 worktree based on commit `932f2b8`; this establishes positive feasibility only. Window/application/selection-change, multiple-cursor, identical-text ambiguity, clipboard-fixture, and paste-timing checks remain pending.

**Progression decision — 2026-07-19:** Clean commit `0b3b65b` passed representative deterministic-harness checks in TextEdit, Safari, Chrome, VS Code, Sublime Text, and Zed. Normal automatic Correct passed in all six, normal Translate passed in the tested native/browser/editor subset, and sampled application/window/selection changes failed closed to the safety panel. The remaining complete Sublime Text/Zed safety matrix, multiple-cursor and identical-text ambiguity records, rich/multi-item clipboard fixtures, and paste-consumption timing are accepted as explicit technical debt for progression to Phase 6 implementation. As of 2026-07-19 these are no longer acceptance blockers: the fixed matrix and formal gate were descoped for personal use, and any of these checks can be run ad hoc as part of the optional BL-012 smoke check if a real problem appears.

---

### Phase 3 — Anthropic end-to-end

**Outcome:** A user can store an Anthropic credential and complete both real actions using the built-in Anthropic model and prompts.

**Scope**

- Provider-neutral completion request with separate instruction and user text.
- URLSession transport and 15-second timeout.
- Anthropic Messages request/response DTOs and stable error mapping.
- Strict terminal completion validation, including `max_tokens` rejection and empty-output rejection.
- Built-in correction and Ukrainian translation prompts.
- Keychain-backed Anthropic credential and minimal draft Settings entry.
- Anthropic Test Connection containing no selected text.

**Automated validation**

- Request construction, headers, separate content, response parsing, status rejection, timeout, sanitization, and cancellation through injected transport.
- Keychain boundary tests without real credentials.

**Exit criteria**

- Both actions work end-to-end with Anthropic.
- No incomplete, truncated, cancelled, or empty output is treated as success.
- No key or selected/generated text appears in files or diagnostics.

**Primary requirements:** FR-015, FR-021, FR-028, FR-035, FR-037–FR-039, FR-042, FR-044–FR-046; NFR-005, NFR-006, NFR-010.

**Implementation note — pending manual acceptance:** Normal Debug and Release composition now use the production Anthropic Messages route; the explicit Phase 1/2 Debug harness arguments remain deterministic and network-free. The implementation stores the Anthropic key under the EnLLM Keychain namespace, sends compiled instruction and selected user text separately, uses the compiled `claude-haiku-4-5` model with a 15-second timeout, and accepts only nonempty `end_turn` responses. Settings provides draft-key save/delete and content-free Test Connection without pulling later non-secret settings persistence forward. Phase 3's production route is implemented and covered by the automated gate. *(2026-07-19 rescope: live-credential confirmation of model availability, both actions, cancellation, and privacy behavior is now the optional BL-012 smoke check rather than a phase-completion blocker.)*

---

### Phase 4 — OpenAI and bounded fallback

**Outcome:** The user can select either provider and optionally allow one attempt through the alternate provider.

**Scope**

- OpenAI Responses client with `store: false`.
- Scan supported output blocks and require completed status.
- Global primary-provider preference.
- One-attempt fallback for the approved provider failure taxonomy, including missing primary credential.
- No fallback for local, target, clipboard, configuration, or cancellation failures.
- Combined provider failure naming both providers without raw bodies.
- Fallback privacy disclosure and effective/unavailable state.

**Automated validation**

- Both provider parsers and complete/incomplete status matrices.
- Routing call order, maximum attempt count, disabled fallback, missing credentials, and non-fallbackable failures.

**Exit criteria**

- Provider routing behavior matches UC-03 and never retries the same provider.
- Disabling fallback prevents secondary-provider transmission.

**Primary requirements:** FR-028–FR-035, FR-041, FR-046; NFR-005, NFR-006, NFR-010.

**Implementation note — pending manual acceptance:** Normal Debug and Release composition now use a shared two-provider route for both actions while the explicit Phase 1/2 Debug harness arguments still bypass provider networking and remain deterministic. Anthropic and OpenAI credentials live in separate Keychain accounts under the EnLLM namespace. The production route uses built-in models only for this phase, keeps instruction text separate from selected user text, sets OpenAI `store: false`, accepts only Anthropic `end_turn` and OpenAI `completed` responses, rejects incomplete output as non-success, and permits at most one alternate-provider attempt only for the approved provider-failure taxonomy, including a missing primary credential and empty or incomplete provider output. Settings exposes runtime-only primary/fallback controls, per-provider content-free Test Connection, a fallback privacy disclosure, and an unavailable-state message when the alternate saved credential is absent. Phase 4 still defers non-secret persistence, model selection and prompt editing, hotkey editing, and atomic autosave to Phase 5. Before Phase 4 can be marked complete, record focused live/manual evidence for both actions with each provider primary, one allowed fallback in each direction, fallback-disabled no-secondary transmission, fixed-content Test Connection, Settings disclosure/state messaging, and the explicit Debug harnesses remaining network-free.

---

### Phase 5 — Complete settings and hotkeys

**Status:** Delivered — 2026-07-19 (code-complete and automated-gate-verified; final acceptance pending manual evidence)

**Outcome:** The user can safely configure every MVP setting; each valid edit autosaves as one whole-snapshot runtime activation.

**Scope**

- Final versioned non-secret schema and atomic file/domain repository.
- Primary provider, both keys, four fixed per-action model selectors, fallback, prompts, two hotkey recorders, permission status, Test Connection, and defaults.
- Prompt/model-selection reset and complete corrupt/unreadable recovery defaults.
- Carbon hotkey validation, conflict handling, registration, and rollback.
- Runtime-atomic debounced autosave transaction across credentials, settings, hotkeys, and runtime publication.
- Explicit recovery state when durable rollback is incomplete.

**Automated validation**

- Draft validation and every complete default.
- Empty-key deletion.
- Hotkey conflict and two-registration rollback.
- Persistence failure at each commit point and reload of actual stored state.

**Exit criteria**

- A failed apply never partially activates the draft.
- Recovery never reports false success.
- Both independently configured global hotkeys invoke the expected action.

**Primary requirements:** FR-005, FR-006, FR-036–FR-043; NFR-007, NFR-008, NFR-010.

**Delivery note — 2026-07-19:** Phase 5 is delivered and automated-gate-verified. It uses strict schema-v2 JSON at `Application Support/com.radpozniakov.enllm/settings-v2.json` (with one-time migration from a valid `settings-v1.json`, which is never overwritten), complete-default recovery, masked Keychain-backed credential fields, four fixed per-action model selectors and editable instructions, confirmed-explicit credential deletion, draft two-model Test Connection, focused local shortcut recording, configurable staged Carbon registration, and one Settings-owned debounced autosave publication transaction. API keys and selected/generated content are excluded from the JSON document. Automated package/app gates cover defaults, strict schema recovery, v1→v2 migration, atomic file rollback, draft two-model Test Connection, debounced autosave (coalescing, serialize/coalesce, invalid-not-saved, stale suppression, recovery-blocking), close/quit flush and safe-discard, credential delete/undo visibility, shortcut-recording validation, runtime publication, credential rollback, and Carbon staging. The BL-018/BL-019/BL-020/BL-021 implementation and documentation landed in commits `1324fba`, `ebdf76a`, `efbaf0f`, `9c10588`, `2edf4df`, and `c7f57a9`. *(2026-07-19 rescope: for personal use, Phase 5 needs no further formal acceptance beyond the automated gate.)* The manual items that were formerly required — two custom shortcuts after relaunch, a real OS shortcut conflict preserving both old shortcuts/runtime state, corrupt-file recovery and a real v1→v2 migration, rollback-recovery messaging, live availability of the selectable models to the configured accounts, and keyboard/VoiceOver operation — are now optional items in the BL-012 smoke check.

---

### Phase 6 — Lifecycle, error, and privacy closure

**Status:** Complete against automated exit criteria — 2026-07-19 (live/visual manual confirmations are now the optional BL-012 personal smoke check, not release-acceptance debt, following the 2026-07-19 rescope)

**Outcome:** Cancellation, notification, quit, permission, and diagnostic behavior satisfy the complete lifecycle contract.

**Scope**

- First-Correct notification authorization sequencing after clipboard restoration.
- Notification/error-panel selection and final actionable wording.
- Latest-invocation-wins across both actions and all side effects.
- Revalidate and harden the quit/restoration coordination introduced in Phase 1 while adding live provider and notification teardown; suppress all late UI/output.
- Removal of temporary event monitors and cancellation of active network tasks.
- Privacy-safe diagnostics containing only operation IDs, categories, provider identities, and durations.

**Automated validation**

- Supersession at each async boundary.
- Notification sequencing.
- Quit/restoration state machine.
- Error sanitization and content-free diagnostic payloads.

**Exit criteria**

- Every safety scenario in the acceptance plan passes in automated or focused manual form.
- No selected/generated text, credential, request body, response body, or clipboard content is persisted or logged.

**Primary requirements:** FR-008, FR-020, FR-024–FR-027A, FR-044–FR-046; NFR-003, NFR-005, NFR-006, NFR-012, NFR-013.

**Completion record — 2026-07-19 (BL-009):** The clean automated gate passed at commit `8fbdd20`: 110 SwiftPM tests, 89 Xcode app tests (`xcresulttool` result Passed, 0 failures), and Debug and Release builds — recorded in [`06-validation-log.md`](06-validation-log.md) as VAL-2026-07-19-03. Both Phase 6 exit criteria are satisfied in automated form:

- *Every safety scenario in the acceptance plan passes in automated or focused manual form.* Every acceptance-plan Section 4 scenario has named automated coverage; see the "Automated safety-scenario coverage map" in the validation log. The Phase 6 automated-validation list (supersession at each async boundary, notification sequencing, quit/restoration state machine, error sanitization, and content-free diagnostic payloads) is fully covered by passing tests.
- *No selected/generated text, credential, request body, response body, or clipboard content is persisted or logged.* Asserted by `diagnosticEventSummaryContainsOnlyClosedContentFreeFacts`, `routerDiagnosticsCarryOperationIDAndNeverContainContent`, `coordinatorActionDiagnosticsCarryOperationIDAndNeverContainContent`, and `settingsRepositoryRoundTripsStrictV2WithoutSecrets`.

This completion is for Phase 6's own automated exit criteria only. It does **not** mark Phase 1–5 complete, and it does not claim the live/visual confirmations that require a real Mac: live-provider truncation, real notification permission dialogs, a real OS hotkey conflict, on-disk `settings-v1.json`→`settings-v2.json` migration, corrupt-file recovery, VoiceOver, and quit during a real live operation. Following the 2026-07-19 rescope, those confirmations are the optional BL-012 personal smoke check (see the optional live-check reference in the validation log), not release-acceptance debt; no formal record and no MVP-complete claim is required for personal use.

---

### Phase 7 — Personal readiness (formal MVP gate descoped 2026-07-19)

**Outcome:** The automated gate is green and, optionally, the author has run a personal smoke check against a fresh build.

**Rescope note (2026-07-19):** For a personal-use tool that already works, the formal MVP-acceptance gate — a documented six-application compatibility matrix, ten-sample performance records, and a full manual acceptance run — was disproportionate and has been descoped. The corpus authoring and automated gate below remain required; the manual/live records become the optional personal smoke check tracked as BL-012 in the [implementation backlog](08-implementation-backlog.md#descoped-on-2026-07-19).

**Required**

- Versioned C-01–C-05 and T-01–T-05 corpus with declared invariants (complete — BL-010).
- Debug/Release and complete automated gate passes.

**Optional (personal smoke check, non-blocking — BL-012)**

- Correct/Translate in the apps the author uses; clipboard restore for the content types they use; fallback-off does not transmit to the secondary; signed bundle builds/launches and keeps Accessibility trust across a rebuild; privacy spot-glance.
- Final model-default availability check when convenient.

**Exit criteria**

- Automated gate passes and corpus integrity passes. That is the personal-readiness bar.
- No fixed compatibility-matrix count or performance-sample record is required.

**Primary requirements:** FR-047; NFR-002, NFR-004, NFR-010, NFR-011. (FR-048/FR-049 descoped 2026-07-19; acceptance plan Sections 1–2 required, 3–9 optional.)

**Implementation note — 2026-07-19 (BL-010):** The versioned C-01–C-05 and T-01–T-05 quality corpus now exists under [`Tests/QualityCorpus/`](../Tests/QualityCorpus) with declared, invariant-based fixtures and an automated integrity check (`Tests/EnLLMCoreTests/QualityCorpusIntegrityTests.swift`); the concrete fixture paths are referenced in [`03-acceptance-test-plan.md`](03-acceptance-test-plan.md) section 2. This satisfies the corpus-authoring portion of Phase 7 scope. Executing the corpus against live providers, the former 12-run compatibility matrix, and the safety/clipboard/routing/performance/signing/privacy records are no longer required Phase 7 work — they were descoped on 2026-07-19 into the optional personal smoke check (BL-012).

## 4. Per-slice definition of done

A slice is complete only when:

- behavior is reachable through the real menu/hotkey entry point where applicable;
- Core remains independent of concrete AppKit, Keychain, pasteboard, and provider adapters;
- no temporary permissive path weakens replacement, completion-status, cancellation, or privacy rules;
- tests cover policy and adapter parsing introduced by the slice;
- manual checks required for the current phase or release acceptance claim are recorded; otherwise pending manual acceptance work is named explicitly;
- Debug and Release builds pass;
- documentation and requirement traceability are updated; and
- deferred work is named rather than hidden behind an unconditional success stub.

## 5. Risk register

| Risk | Retirement point | Stop condition |
|---|---|---|
| AX element/range incompatibility in matrix apps | Phases 1–2 | Do not proceed to live-provider work without a credible automatic-replacement path or explicit scope decision. |
| Clipboard promised/lazy data cannot be restored byte-for-byte | Phases 1–2 | Fail safely and document the limitation; never silently discard known items. |
| Accessibility trust resets after rebuild | Phase 0 and Phase 7 | Adjust stable build path/signature workflow before broad manual testing. |
| Nonactivating panel conflicts with dismissal/accessibility behavior | Phase 1 | Resolve focus and cancellation semantics before adding live requests. |
| Provider defaults become unavailable | Phases 3–4 and Phase 7 | Update compiled defaults without leaking provider details into Core policy. |
| Cross-store settings rollback is incomplete | Phase 5 | Preserve previous runtime, disable uncertain routes, reload stores, and show recovery error. |
| Notification permission disrupts selection/clipboard state | Phase 6 | Move authorization until after terminal restoration; never block the first action. |

## 6. Explicitly deferred non-goals

No phase includes streaming, rich-text reconstruction, history, analytics, additional providers, local models, login items, updates, localization, Intel support, earlier macOS versions, App Store work, notarized public distribution, app-specific extensions, or migration from the reference apps.
