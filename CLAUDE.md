# EnLLM agent notes

## What this repo is

EnLLM is an Apple-Silicon, menu-bar-only macOS 26 app (`LSUIElement`, bundle ID `com.radpozniakov.enllm`) with two actions: safely correct selected text in place, or translate it to Ukrainian in a nonactivating result panel. It is Swift 6.2.4/Xcode 26.3, uses Anthropic Messages and OpenAI Responses, and has no approved third-party dependencies.

## Code map and dependency rules

- `EnLLMApp/` — SwiftUI/AppKit lifecycle, views, `@MainActor` coordinators, and dependency composition. Start at `App/AppComposition.swift`.
- `Sources/EnLLMCore/` — provider-neutral models, protocols, validation, routing, settings, and use cases. Keep it free of SwiftUI and concrete AppKit singletons.
- `Sources/EnLLMPlatform/` — Accessibility, clipboard, hotkey, Keychain, settings-file, URLSession, and provider adapters. It depends on Core; Core must never depend on Platform.
- `Tests/` contains SwiftPM Core/Platform tests; `EnLLMAppTests/` contains Xcode app/coordinator tests.
- `doc/00-technical-specification.md` is the product/safety source of truth; `doc/adr/` records architectural constraints; `doc/04-development-plan.md` tracks phases and manual acceptance.

## Non-negotiable behavior

- Fail closed: never paste empty, partial, cancelled, stale, or failed output. Before correction, re-verify the captured PID/window/element/range/text; if verification is insufficient, show the corrected text in the safety panel instead.
- Preserve the complete clipboard snapshot (all items/types), serialize clipboard side effects, and finish restoration before termination. A newer invocation cancels and supersedes older work; late results must have no UI or clipboard effects.
- Keep selected text only in memory and never log it. API keys belong only in macOS Keychain. Keep instructions and selected user text as separate provider payload fields; OpenAI requests must retain `store: false`.
- Provider fallback is at most one attempt and only for the approved provider-failure taxonomy—not local validation, Accessibility, clipboard, settings, Keychain, or cancellation failures.
- Settings Save/Apply is transactional: credentials, strict schema-v1 non-secret JSON, hotkeys, and the runtime snapshot must not become partially active. Preserve rollback/recovery behavior.
- UI/coordinator and macOS interaction protocols are intentionally `@MainActor`; preserve cancellation checks around asynchronous boundaries.

## Build and test

```sh
swift test                                      # Core + Platform package tests
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM test  # includes app tests
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM -configuration Debug build
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM -configuration Release build
./scripts/build-local.sh Debug                  # signed stable bundle at .local-app/EnLLM.app
```

Use the smallest relevant test command while iterating, then run both `swift test` and the Xcode test suite for cross-layer changes. Selection, focus, Accessibility permissions, clipboard preservation, signing, and multi-app compatibility also require the manual checks described in `doc/03-acceptance-test-plan.md`. Debug-only network-free harnesses require exact launch arguments `--enable-phase1-local-transformer` or `--enable-phase2-local-transformer`; they must remain explicit, `#if DEBUG`-gated, and absent from Release.

Do not edit or commit generated/local state under `.build/`, `.xcode-build/`, `.local-app/`, or `.swiftpm/`.
