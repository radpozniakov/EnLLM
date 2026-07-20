# ADR-0001: Xcode App with a Small Modular Architecture

- **Status:** Accepted
- **Date:** 2026-07-18

## Context

The two reference MVPs prove the product workflows but use different project structures. Corrector is a Swift Package executable with a packaging script and strong service tests. LLM Translator is an Xcode app with native app lifecycle/resources but concentrates orchestration in `AppDelegate` and has no tests.

EnLLM needs stable local signing, AppKit/SwiftUI integration, shared services for two features, provider-neutral routing, and testable side-effect boundaries. It does not need a large multi-feature framework or public SDK.

## Decision

Use an Xcode macOS application project plus a local Swift package.

### Xcode app target: `EnLLMApp`

Responsibilities:

- `@main` lifecycle and accessory-app policy;
- status item/menu, Settings window, and result panel;
- SwiftUI/AppKit presentation;
- dependency composition;
- app-level permission prompts; and
- mapping use-case state into UI state.

The app target must not construct provider HTTP requests or own clipboard algorithms.

### Local package target: `EnLLMCore`

Foundation-oriented domain and orchestration code:

- action/operation models;
- settings models and validation;
- provider and routing models;
- `CorrectionUseCase` and `TranslationUseCase`;
- `LLMRouter`;
- target-verification policy;
- stable application error types; and
- protocols for selection, replacement, providers, credentials, settings, hotkeys, notifications, and clocks.

`EnLLMCore` must not depend on SwiftUI or concrete AppKit singletons.

### Local package target: `EnLLMPlatform`

Concrete macOS/provider implementations:

- Accessibility and pasteboard selected-text service;
- safe text replacement service;
- global hotkey registrar;
- Keychain credential store;
- versioned settings repository;
- notification service;
- Anthropic and OpenAI clients; and
- URLSession transport.

`EnLLMPlatform` depends on `EnLLMCore` and system frameworks. Provider-specific DTOs remain internal.

### App coordinator

A single `@MainActor` `ActionCoordinator` in the app target owns:

- the current operation task and generation ID;
- latest-invocation-wins cancellation;
- menu-bar activity;
- result panel state; and
- presentation of stable errors.

It delegates business behavior to use cases. Clipboard and paste side effects are serialized by a dedicated actor/service rather than by view code.

### Dependency direction

```text
EnLLMApp  ───────► EnLLMCore
    │                 ▲
    └────► EnLLMPlatform
                      │
                      └── implements EnLLMCore protocols
```

Composition uses explicit initializers. Global singletons are avoided except where a macOS framework requires a shared system object, which must remain wrapped by an injectable service.

## Consequences

### Positive

- Xcode owns app packaging, resources, code signing, and schemes.
- Core routing/cancellation/validation can be tested without Accessibility, Keychain, pasteboard, or live APIs.
- Correction and translation share infrastructure but retain different output policies.
- Provider clients can evolve independently.
- The structure is clearer than placing all coordination in `AppDelegate` and less custom than packaging a SwiftPM executable manually.

### Negative

- The repository has both an Xcode project and local package manifests.
- Some AppKit behavior still requires manual integration testing.
- Dependency composition adds small upfront ceremony.

## Rejected Alternatives

### Pure Swift Package executable

Rejected because app-bundle generation, resources, stable signing, and Xcode permission workflows would require additional custom scripting.

### Pure monolithic Xcode target

Rejected because it would make provider routing, selection safety, and operation cancellation easier to couple to UI and harder to test.

### Many feature packages

Rejected as premature for a two-action personal MVP. Two local package targets plus one app target provide enough separation.
