# EnLLM Validation Log

This is the append-only record for manual, live-provider, signing, privacy, and compatibility evidence. The scenarios and pass criteria are defined in [`03-acceptance-test-plan.md`](03-acceptance-test-plan.md); do not redefine them here.

Never record API keys, selected/generated user content, clipboard contents, request/response bodies, or other secrets. Fixture IDs and non-content observations are sufficient.

## Recording rules

- Record the tested commit and whether the worktree was clean.
- Identify Debug/Release and whether a deterministic harness or production provider route was used.
- Record exact OS, hardware, app/version, provider/model where relevant, tester, and timestamp.
- Mark results `PASS`, `FAIL`, `BLOCKED`, or `PARTIAL`; do not turn defensive safety-panel behavior into a compatibility pass when automatic replacement is required.
- Link follow-up commits or issues rather than rewriting old records.

## Record template

```md
### VAL-YYYY-MM-DD-NN — Short title

- Result: PASS | FAIL | BLOCKED | PARTIAL
- Acceptance reference: section/scenario from `03-acceptance-test-plan.md`
- Commit/worktree: SHA; clean or dirty
- Build: Debug or Release; signed app path; harness/production route
- Environment: macOS build; hardware; Xcode
- Application: name and version, if applicable
- Provider/model/routing: no live credential values
- Tester/time: name; ISO-8601 timestamp and timezone
- Setup: fixture ID and non-sensitive preconditions
- Observed: concise behavior and timing
- Safety/privacy notes: focus, target, clipboard restoration, transmissions, logs
- Follow-up: issue, commit, or remaining checks
```

## Recorded evidence

### VAL-2026-07-18-01 — Phase 0 signed shell

- **Result:** PASS for Phase 0
- **Acceptance reference:** automated gate and signing/permission workflow applicable to the shell
- **Commit/worktree:** `7cbb359`; completion record does not state worktree cleanliness
- **Build:** Debug and Release; stable locally signed bundle
- **Environment:** macOS 26 arm64 target; Apple Development Team `66ZYDU2788`
- **Observed:** SwiftPM tests, Xcode app tests, and Debug/Release builds passed. Stable bundles passed signature verification. Bundle identifier, `LSUIElement`, arm64 architecture, stable path, and signing Team ID were verified. Manual validation confirmed menu-bar-only launch, no automatic onboarding or permission prompt, working Settings lifecycle, fail-closed incomplete actions, unchanged selection/clipboard, no provider activity, and clean Quit behavior.
- **Follow-up:** This evidence predates implemented product actions and does not satisfy later phase or final acceptance checks.

### VAL-2026-07-18-02 — Phase 2 automatic replacement feasibility

- **Result:** PARTIAL
- **Acceptance reference:** compatibility matrix supplemental AX-incomplete editor checks
- **Commit/worktree:** dirty Phase 2 worktree based on `932f2b8`
- **Build:** signed local Debug app with `--enable-phase2-local-transformer`
- **Environment:** macOS 26.5.1 (25F80), arm64 Mac16,7
- **Applications:** Sublime Text Build 4200; Zed 1.11.3
- **Tester:** Rodion Pozniakov
- **Observed:** automatic replacement of one unchanged selection succeeded in both editors.
- **Safety/privacy notes:** deterministic harness; no provider network request.
- **Follow-up:** Application/window/selection changes, multiple cursors, identical-text ambiguity, clipboard fixtures, and paste timing remain unverified. Repeat against a clean named commit for acceptance.

### VAL-2026-07-19-01 — Clean automated baseline

- **Result:** PASS
- **Acceptance reference:** Section 1 automated gate and signed local Debug bundle
- **Commit/worktree:** `0b3b65b`; clean
- **Build:** SwiftPM tests, Xcode app tests, Debug, Release, and `./scripts/build-local.sh Debug`
- **Environment:** macOS 26.5.1 (25F80), MacBook Pro Mac16,7, Apple M4 Pro, Xcode 26.3 (17C529)
- **Tester/time:** Rodion Pozniakov with coding-agent execution; 2026-07-19T13:11:00+03:00
- **Observed:** 77 SwiftPM tests and 25 Xcode app tests passed; Debug and Release builds succeeded; `.local-app/EnLLM.app` passed signature verification.
- **Safety/privacy notes:** automated/build execution only; no live provider credentials or selected user content recorded.
- **Follow-up:** Repeat the complete gate after Phase 6 changes and at final acceptance.

### VAL-2026-07-19-02 — Phase 1/2 deterministic representative-app checks

- **Result:** PARTIAL
- **Acceptance reference:** Sections 3–5 compatibility, safety, and clipboard scenarios
- **Commit/worktree:** `0b3b65b`; clean at launch
- **Build:** signed local Debug `.local-app/EnLLM.app`; `--enable-phase2-local-transformer`
- **Environment:** macOS 26.5.1 (25F80), MacBook Pro Mac16,7, Apple M4 Pro; TextEdit 1.20, Safari 26.5, Chrome 150.0.7871.128, VS Code 1.129.1, Sublime Text Build 4200, Zed 1.11.3
- **Provider/model/routing:** deterministic Phase 2 harness; no provider network route
- **Tester/time:** Rodion Pozniakov; 2026-07-19T13:38:29+03:00
- **Observed:** unchanged automatic Correct passed in TextEdit, Safari, Chrome, VS Code, Sublime Text, and Zed. Local Translate panel behavior passed in TextEdit, Safari, Sublime Text, and Zed. TextEdit application, window, and selection changes produced the safety panel without replacement; Safari field-focus change and VS Code selection change also failed closed. No-selection with a prepared clipboard sentinel, whitespace-only input, 10,001-character input, and a dummy secure field were rejected. Translation Copy and outside-click dismissal behaved as specified. A prepared plain-text clipboard sentinel was restored after VS Code correction.
- **Safety/privacy notes:** no live provider request; source text remained unchanged on safety-panel paths; secure-field dummy text was not displayed as output.
- **Follow-up / accepted technical debt:** rich/image/file-URL/multi-item clipboard fixtures, quit during restoration, loading-panel dismissal with a late response, permission workflow, multiple displays, real hotkey failure/retry, complete Sublime Text/Zed application/window/selection checks, multiple cursors, identical-text ambiguity, and paste-consumption timing remain unverified. These are accepted for progression to Phase 6 implementation, but remain release-acceptance debt and must not be represented as Phase 1/2 completion.

### VAL-2026-07-19-03 — Clean Phase 6 automated gate (BL-009)

- **Result:** PASS
- **Acceptance reference:** Section 1 automated gate; Section 4 safety scenarios in automated form; Phase 6 exit criteria
- **Commit/worktree:** `8fbdd20`; clean (only untracked, non-source agent notes present)
- **Build:** `swift test`; `xcodebuild -project EnLLM.xcodeproj -scheme EnLLM test`; Debug build; Release build
- **Environment:** macOS 26.5.1 (25F80), MacBook Pro Mac16,7, Apple M4 Pro; Xcode 26.3 (17C529); Swift 6.2.4
- **Tester/time:** Rodion Pozniakov with coding-agent execution; 2026-07-19T21:00:00+03:00
- **Observed:** 110 SwiftPM tests passed (including the new BL-010 corpus-integrity suite); 89 Xcode app tests passed (`xcresulttool` result Passed, 0 failures); Debug and Release builds succeeded.
- **Safety/privacy notes:** automated/build execution only; no live provider credentials or selected user content. Content-free diagnostics and secret-free settings persistence are asserted by named automated tests (see the coverage map below).
- **Follow-up:** Live-provider, notification-permission-dialog, real-hotkey-conflict, VoiceOver, and on-disk `settings-v1.json`→`settings-v2.json` migration confirmations were originally tracked as release-acceptance debt. *(Updated 2026-07-19: the formal gate was descoped for personal use; these are now the optional BL-012 smoke check — see the optional live-check reference below. Repeat the automated gate after significant changes.)*

### VAL-2026-07-20-01 — Automated gate re-run at HEAD

- **Result:** PASS
- **Acceptance reference:** Section 1 automated gate; confirms VAL-2026-07-19-03 still holds after the post-gate doc/README/corpus-test-dedup commits
- **Commit/worktree:** `d5a6306`; only untracked, non-source agent notes present (`CLAUDE.md`)
- **Build:** `swift test`; `xcodebuild -project EnLLM.xcodeproj -scheme EnLLM test`; Debug build; Release build
- **Environment:** macOS 26 arm64; Xcode 26.3; Swift 6.2.4
- **Tester/time:** Rodion Pozniakov with coding-agent execution; 2026-07-20
- **Observed:** 110 SwiftPM tests passed; the Xcode `EnLLM` scheme test reported `** TEST SUCCEEDED **` (89 app tests, source unchanged since `8fbdd20`); Debug and Release builds reported `** BUILD SUCCEEDED **`. Production Swift is byte-identical to `8fbdd20`; the only code change since that gate is the `f27f2e7` corpus-integrity-test dedup, which is part of the passing SwiftPM suite.
- **Safety/privacy notes:** automated/build execution only; no live provider credentials or selected user content recorded.
- **Follow-up:** none required; repeat the gate after significant changes.

## Automated safety-scenario coverage map (acceptance plan Section 4)

This map documents which Section 4 safety scenarios and Phase 6 exit criteria are satisfied in **automated** form and which additionally require **focused manual** confirmation. It is derived from the passing suite at `8fbdd20` (see VAL-2026-07-19-03) and is supporting context, not a substitute for the manual evidence tracked below.

| Scenario (Section 4) | Automated coverage (test name) | Manual still required |
|---|---|---|
| No selection; clipboard has text | `emptyAccessibilityResultDoesNotFallBack` | Real-app message wording (partly VAL-2026-07-19-02) |
| Empty/whitespace selection rejected | `inputValidationPreservesFormattingAndEnforcesSwiftCharacterBoundary` | — |
| 10,001-character selection rejected | `inputValidationPreservesFormattingAndEnforcesSwiftCharacterBoundary` | — |
| Focus/app/window change → safety panel | `accessibilityTargetVerificationRequiresExactElementRangeAndText`, `clipboardCompatibilityWindowMismatchDoesNotRecopyOrPaste`, `targetMismatchDoesNotRecopyOrPaste` | Real focus changes across matrix apps (BL-012) |
| Selection/range change → safety panel | `accessibilityTargetVerificationRequiresExactElementRangeAndText`, `targetMismatchDoesNotRecopyOrPaste` | — |
| AX-incomplete re-copy differs → safety panel | `fallbackRecopyTextMismatchRestoresClipboardAndDoesNotPaste`, `fallbackRechecksMetadataAfterRecopyBeforePasting` | Sublime/Zed live checks (BL-012) |
| New hotkey action supersedes active work | `supersessionCancelsActiveProviderAttemptWithoutFallback`, `staleCompletionCannotOverwriteTheNewestOperation`, `lateTransportCompletionForSupersededOperationHasNoUIEffect`, `sameActionSupersessionPublishesOnlyNewestTranslation` | — |
| Dismiss translation panel while loading | `dismissingLoadingPanelSuppressesLateResult`, `translationPanelDismissalCancelsActiveRequestWithoutFallback` | Late-response dismissal in real app (BL-012) |
| Quit while operation owns clipboard | `terminationLatchesAndRejectsNewWorkWhileAwaitingClipboard`, `cancellationAfterPasteWaitsForRestorationBeforeReleasingClipboardOwner`, `quitCancelsActiveRequestWithoutFallbackOrLateEffects`, `terminationReportsRestorationFailureFaithfullyAndIsIdempotent` | Real quit during a live operation (BL-012) |
| Provider token-limit/incomplete → no success | `anthropicRejectsEveryNonEndTurnOrMissingStopReason`, `openAIRequiresExactCompletedStatusAndRejectsMissingOrFutureStatuses`, `routerFallsBackForIncompleteAndEmptyProviderResponsesOnlyOnce`, `translationRejectsEmptyOutput` | Live provider truncation (BL-013) |
| Secure/password field rejected | `secureFieldDoesNotFallBack` | Real secure field (partly VAL-2026-07-19-02) |
| Hotkey conflict on autosave keeps runtime | `customSecondRegistrationConflictPreservesBothActiveShortcuts`, `secondHotkeyFailureRollsBackFirstRegistrationAndAllowsRetry`, `directShortcutSwapRemovesBothBlockingOldRegistrationsBeforeActivation` | Real OS conflict rollback (BL-013) |
| Durable autosave rollback → recovery, no false success | `incompleteDurableRollbackReloadsActualStateAndReportsRecovery`, `failedPersistenceRollsBackCredentialsAndNeverPublishesDraft`, `everyForwardCommitBoundaryKeepsThePreviousRuntimeOnFailure`, `credentialRollbackFailureNeverActivatesDraftKeyAndReloadsDurablePresence` | Real corrupt-file recovery (BL-013) |
| Valid edit → Saving…/Saved, persists to v2 | `debouncedValidEditAutosavesExactlyOnce`, `rapidEditsCoalesceIntoASingleCommit`, `recordedShortcutAutosavesThroughTheTransaction` | Visual Saving…/Saved status (BL-013) |
| Invalid draft not autosaved; last good kept | `invalidDraftIsNotAutosavedAndKeepsLastGoodRuntime`, `staleSuccessIsSuppressedWhenANewerInvalidEditArrives` | — |
| Close Settings flushes pending valid edit | `settingsCloseFlushesPendingValidEdit` | — |
| Quit with invalid/unresolved-recovery edit blocked | `quitIsBlockedByAnUncommittableInvalidEditUntilSafeDiscard`, `incompleteRecoveryBlocksQuitAndRemainsVisible` | — |
| Launch with only v1 → one-time migration | `migratesValidV1IntoV2PreservingUnrelatedSettingsAndNormalizingModels`, `validV2TakesPrecedenceAndV1IsNotMigrated`, `migrationWriteFailureLeavesV1IntactAndRecoversDefaults`, `invalidV1IsNotMigratedAndRecoversDefaults` | Real on-disk migration (BL-013) |

Phase 6 privacy exit criterion (no selected/generated text, credential, request/response body, or clipboard content persisted or logged) is asserted by `diagnosticEventSummaryContainsOnlyClosedContentFreeFacts`, `routerDiagnosticsCarryOperationIDAndNeverContainContent`, `coordinatorActionDiagnosticsCarryOperationIDAndNeverContainContent`, and `settingsRepositoryRoundTripsStrictV2WithoutSecrets`. Notification-authorization sequencing after clipboard quiescence is asserted by `firstCorrectRequestsNotificationAuthorizationOnlyAfterClipboardQuiescence`, `notificationAuthorizationDefersUntilNewerActionIsIdleAndRunsOnce`, and `undeterminedNotificationAuthorizationUsesTheErrorPanelWithoutBlockingCorrection`.

## Optional live-check reference (formerly the BL-013 scaffold)

**Descoped 2026-07-19:** BL-013 was folded into the optional personal smoke check (BL-012); these rows are no longer a required release gate. They remain a useful reference of what the author *could* confirm live, and each row names the automated test that already proves the underlying policy — so live execution only ever confirms real-world behavior, never the policy itself. Running any of these is discretionary. If a row is executed and the author wants a note, copy it into a `VAL-YYYY-MM-DD-NN` record using the template above, obey the privacy rules (no credentials, selected/generated content, or request/response bodies), and never mark a live/manual row `PASS` from an automated agent without human observation.

| BL-013 sub-scenario | Acceptance ref | Automated backing (policy already proven) | Live/manual status |
|---|---|---|---|
| Correct + Translate, Anthropic primary | §6, §10 | `routerUsesConfiguredPrimaryProviderWithoutCallingAlternateOnSuccess` | PENDING (live) |
| Correct + Translate, OpenAI primary | §6, §10 | `routerUsesOpenAIAsPrimaryWhenConfigured` | PENDING (live) |
| One allowed fallback Anthropic→OpenAI | §6 | `routerFallsBackForIncompleteAndEmptyProviderResponsesOnlyOnce`, `routerRecordsTwoOrderedProviderAttemptsOnFallback` | PENDING (live) |
| One allowed fallback OpenAI→Anthropic | §6 | `routerFallsBackOnceWhenPrimaryCredentialIsMissingAndAlternateCredentialExists` | PENDING (live) |
| Fallback disabled → no secondary transmission | §6 | `routerDoesNotFallbackWhenFallbackIsDisabledEvenForMissingPrimaryCredential` | PENDING (live) |
| Non-fallbackable failure never retries | §6 | `routerDoesNotFallbackForLocalOrCredentialStoreFailuresAndPropagatesCancellation` | PENDING (live) |
| Combined failure names both providers, no bodies | §6 | `routerThrowsSanitizedCombinedFailureAfterTwoDistinctProviderAttempts` | PENDING (live) |
| Fixed-content Test Connection (per selected model) | §6 | `testConnectionTestsBothDistinctDraftModelsWithFixedContent`, `testConnectionIdentifiesWhichSelectedModelFailed`, `testConnectionIssuesOneRequestWhenBothActionsSelectTheSameModel` | PENDING (live) |
| Compiled model availability to the accounts | §6, Phase 7 | `modelCatalogExposesAllowedChoicesDefaultsAndNormalization` | PENDING (live) |
| OpenAI request retains `store: false` | §6 | `openAIRequestUsesRequiredHeadersAndBodyWithoutCombiningInstructionAndInput` | PENDING (live) |
| Two custom shortcuts persist after relaunch | §4, §5 | `recordedShortcutAutosavesThroughTheTransaction`, `hotkeyRegistrarDispatchesBothActionIDs` | PENDING (manual) |
| Real OS shortcut conflict rollback keeps both | §4 | `customSecondRegistrationConflictPreservesBothActiveShortcuts` | PENDING (manual) |
| Corrupt-settings recovery to defaults | §4, §9 | `missingSettingsAreCompleteDefaultsAndCorruptV2Recovers` | PENDING (manual) |
| Incomplete-recovery messaging (no false success) | §4 | `incompleteDurableRollbackReloadsActualStateAndReportsRecovery`, `unreadableCredentialDuringIncompleteRecoveryDisablesOnlyThatRoute` | PENDING (manual) |
| Settings full keyboard operation | §10 | (UI-only; not automatable) | PENDING (manual) |
| Settings VoiceOver operation | §10 | (UI-only; not automatable) | PENDING (manual) |
| Notification permission undetermined path | §4 | `undeterminedNotificationAuthorizationUsesTheErrorPanelWithoutBlockingCorrection` | PENDING (manual, real dialog) |
| Notification permission authorized path | Phase 6 | `authorizedCorrectionFailureDeliversSanitizedNotification`, `firstCorrectRequestsNotificationAuthorizationOnlyAfterClipboardQuiescence` | PENDING (manual, real dialog) |
| Notification permission denied path | Phase 6 | `correctionFailureUsesErrorPanelWhenNotificationsAreUnavailable`, `correctionNotificationDeliveryFailureFallsBackToPanel` | PENDING (manual, real dialog) |
| Notification permission does not interrupt capture | §4, Phase 6 | `notificationAuthorizationDefersUntilNewerActionIsIdleAndRunsOnce` | PENDING (manual) |

## Optional smoke-check groups (formerly pending evidence groups)

**Descoped 2026-07-19:** none of these are acceptance blockers. They are candidate items for the optional BL-012 personal smoke check; run whichever are relevant to how the author actually uses the app, ad hoc, if a real problem appears.

- Clipboard: rich and multi-item preservation, loading dismissal with a late response, permission/hotkey failure, multiple-display placement, and quit restoration.
- AX-incomplete editors: complete Sublime Text/Zed supplemental safety checks, multiple cursors, identical-text ambiguity, rich/multi-item clipboard fixtures, and paste-consumption timing.
- Providers: live actions with each provider, routing/fallback boundaries (especially fallback-off no-secondary transmission), and fixed-content Test Connection.
- Settings: persisted custom shortcuts, conflict rollback, corrupt-file recovery, incomplete-recovery messaging, keyboard use, and VoiceOver.
- Lifecycle/privacy: signing/rebuild Accessibility persistence and a privacy spot-glance.
