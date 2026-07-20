# EnLLM Project Status

**Updated:** 2026-07-20

**HEAD:** `d5a6306` — production code is unchanged since the recorded gate commit `8fbdd20`; every commit after it touches only docs, the README, and one corpus-test dedup (`f27f2e7`).

**Target:** macOS 26, arm64, Xcode 26.3, Swift 6.2.4

This is the short current-state dashboard. Requirements remain authoritative in the technical specification and requirement documents; phase details remain in the [development plan](04-development-plan.md).

## Summary

Phase 0 is complete, Phase 5 is delivered (code-complete and automated-gate-verified; final acceptance pending manual evidence), and Phase 6 is complete against its automated exit criteria (BL-009). The implementations for Phases 1–6 are present, including safe selection/replacement, Anthropic and OpenAI routing, bounded fallback, action-specific fixed model selection, schema-v2 settings with one-time v1→v2 migration, debounced transactional autosave, confirmed-explicit credential deletion, Keychain credentials, configurable hotkeys, privacy-safe action errors, correction notifications, notification-authorization sequencing, latest-invocation-wins supersession, quit/restoration teardown, and content-free diagnostics. On 2026-07-19 the project was **rescoped for personal use**: the formal release-acceptance apparatus (fixed six-application compatibility matrix, ten-sample performance records, and a formal MVP-complete gate) was descoped as disproportionate for a single-user tool that already works. The readiness bar is now the green automated gate plus an optional personal smoke check. The versioned C-01–C-05 / T-01–T-05 quality corpus exists (BL-010) under `Tests/QualityCorpus/`. Remaining work is tracked in the [implementation backlog](08-implementation-backlog.md): custom artwork (BL-017) and the optional smoke check (BL-012).

## Implemented

- Signed menu-bar-only app and modular App/Core/Platform architecture.
- AX-first selected-text capture with serialized clipboard fallback and restoration.
- Correction target re-verification with safety-panel fallback.
- Nonactivating translation/loading/error panel and latest-invocation-wins cancellation.
- Anthropic Messages and OpenAI Responses clients with terminal-status validation and 15-second timeout.
- One bounded alternate-provider fallback for approved provider failures.
- Keychain-only credentials and strict schema-v2 non-secret settings JSON (with one-time v1→v2 migration).
- Debounced transactional autosave across credentials, settings, Carbon hotkeys, and runtime publication.
- Explicit network-free Phase 1 and Phase 2 Debug harnesses.

## Current work

1. **BL-017 — custom app and menu-bar artwork.** The only remaining implementation item; blocked on the two supplied menu-bar (idle/active) assets. The app-icon source is ready.
2. **BL-012 — optional personal smoke check.** A discretionary, non-blocking ~20-minute confirmation against a fresh build (apps the author uses, clipboard restore, fallback-off does not leak, signed build launches and keeps Accessibility trust, privacy glance). Not a gate.

The former Phase 1–7 manual/live validation stack (fixed compatibility matrix, live-provider/fallback/Settings/notification runs, performance samples, formal MVP gate) was descoped on 2026-07-19 for personal use; the underlying behavior stays enforced in code and covered by the automated gate. Issue-style detail is in [`08-implementation-backlog.md`](08-implementation-backlog.md).

Representative native, browser, and Electron checks passed at a partial-evidence level (see the validation log). As of the 2026-07-19 rescope, the remaining manual scenarios (Sublime Text/Zed ambiguity, multi-cursor, rich/multi-item clipboard, paste-timing, quit-restoration, and related checks) are no longer acceptance blockers — they are optional items in the BL-012 smoke check. A safety-panel result remains correct defensive behavior; automatic in-place replacement is still the intended behavior where a target verifies.

## Existing evidence

- Phase 0 automated/build/signing/manual completion is recorded in the development plan.
- Automatic replacement was observed in Sublime Text Build 4200 and Zed 1.11.3 using the Phase 2 Debug harness; this is positive feasibility evidence, not full acceptance.
- New manual and live results belong in [`06-validation-log.md`](06-validation-log.md).

## Next recommended actions

- Implement BL-017 once the two menu-bar assets are supplied.
- Run the optional BL-012 smoke check at the author's discretion before relying on a new build.
- Keep the green automated gate as the readiness bar; repeat it after significant changes.
- Update this page whenever the verified commit changes or the remaining work changes.

## Verification state

The complete baseline gate passed on 2026-07-19 at commit `8fbdd20` (recorded as VAL-2026-07-19-03) and was **re-run clean at HEAD `d5a6306` on 2026-07-20** (recorded as VAL-2026-07-20-01): 110 SwiftPM tests pass (including the BL-010 corpus-integrity suite), the Xcode `EnLLM` scheme test succeeds (89 app tests, unchanged since `8fbdd20`), and Debug and Release builds succeed. This is the personal-readiness bar; repeat it after significant changes:

```sh
swift test
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM test
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM -configuration Debug build
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM -configuration Release build
```
