# EnLLM Developer Runbook

Practical setup, build, launch, and diagnosis notes. Product rules live in the [technical specification](00-technical-specification.md); do not weaken selection, replacement, clipboard, cancellation, credential, or privacy behavior to work around a local problem.

## Required environment

- Apple Silicon Mac running macOS 26
- Xcode 26.3 and Swift 6.2.4
- Apple Development signing identity for Team `66ZYDU2788`
- Scheme/product `EnLLM`; bundle identifier `com.radpozniakov.enllm`

Confirm the selected toolchain:

```sh
xcodebuild -version
swift --version
xcode-select -p
security find-identity -v -p codesigning
```

## Build and test

```sh
swift test
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM test
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM -configuration Debug build
xcodebuild -project EnLLM.xcodeproj -scheme EnLLM -configuration Release build
```

Use `swift test --filter <TestName>` while iterating on Core/Platform tests. For app tests, use Xcode or `xcodebuild ... test -only-testing:EnLLMAppTests/<TestClass>`.

Build the stable signed bundle used for Accessibility permission continuity:

```sh
./scripts/build-local.sh Debug
open .local-app/EnLLM.app
```

The script stages under `.xcode-build/`, verifies the signature, and replaces `.local-app/EnLLM.app`. Prefer this path for manual testing instead of launching changing DerivedData bundle paths.

## Debug harnesses

Both harnesses are Debug-only, explicit, deterministic, and network-free:

```sh
open .local-app/EnLLM.app --args --enable-phase1-local-transformer
open .local-app/EnLLM.app --args --enable-phase2-local-transformer
```

Phase 1 enables local translation only. Phase 2 enables local translation and a two-second deterministic `teh`/`Teh` correction. If both arguments are supplied, Phase 2 wins. Debug without either argument and all Release builds use the production provider route.

Quit an existing instance before changing launch arguments. Do not add a harness route outside `#if DEBUG` or make one the default Debug composition.

## Local state

Non-secret settings are strict schema-v2 JSON at:

```text
~/Library/Application Support/com.radpozniakov.enllm/settings-v2.json
```

`settings-v1.json` is only read for a one-time migration to v2 and is never overwritten.

Credentials are generic-password Keychain items:

| Provider | Service | Account |
|---|---|---|
| Anthropic | `com.radpozniakov.enllm` | `anthropic-api-key` |
| OpenAI | `com.radpozniakov.enllm` | `openai-api-key` |

Inspect non-secret settings only when needed. Never print, export, or commit Keychain values. Prefer deleting credentials through Settings; use Keychain Access for manual recovery.

## Accessibility and signing

Grant Accessibility access to the stable `.local-app/EnLLM.app` through System Settings. If TCC state is genuinely stale, reset it and grant access again:

```sh
tccutil reset Accessibility com.radpozniakov.enllm
```

This intentionally removes the existing grant; do not use it during permission-stability acceptance.

Useful bundle checks:

```sh
codesign --verify --deep --strict --verbose=2 .local-app/EnLLM.app
codesign -dv --verbose=4 .local-app/EnLLM.app
plutil -p .local-app/EnLLM.app/Contents/Info.plist
file .local-app/EnLLM.app/Contents/MacOS/EnLLM
```

Expected results include bundle ID `com.radpozniakov.enllm`, `LSUIElement = true`, the configured development team, and arm64.

## Common problems

- **No selected text:** confirm Accessibility permission. AX-incomplete apps may use simulated Copy; stale clipboard contents must never be accepted without a pasteboard change.
- **Correction appears in the panel:** target verification failed or lacked mandatory evidence. This is intentional fail-closed behavior; diagnose the PID/window/element/range/text evidence instead of bypassing verification.
- **Hotkey does not register:** check for an OS/application shortcut conflict. A failed autosave commit must preserve the old hotkeys and runtime configuration.
- **Settings recover to defaults:** inspect the `settings-v2.json` structure and schema version. Invalid/unreadable files or disallowed model selections intentionally recover the complete built-in configuration; keys are unaffected because they are in Keychain.
- **Provider request fails:** use provider-specific Test Connection (which tests both selected models), confirm the selected models and credential presence, then check routing/fallback settings. Do not log request bodies, response bodies, selected text, or credentials.
- **Accessibility resets after rebuild:** confirm the stable bundle path, bundle identifier, and signing identity before resetting TCC.
- **Clipboard-sensitive test hangs or Quit delays:** allow the clipboard actor to finish restoration. Never force termination in production code to hide restoration failures.

## Manual validation discipline

Run the applicable scenarios from [`03-acceptance-test-plan.md`](03-acceptance-test-plan.md) and append evidence to [`06-validation-log.md`](06-validation-log.md). Record fixture IDs rather than user content. Generated/local directories `.build/`, `.xcode-build/`, `.local-app/`, and `.swiftpm/` must not be committed.
