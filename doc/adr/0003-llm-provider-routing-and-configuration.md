# ADR-0003: Shared Provider Router with Keychain Credentials and Editable Instructions

- **Status:** Accepted
- **Date:** 2026-07-18

## Context

Corrector already demonstrates provider-neutral Anthropic/OpenAI routing with bounded fallback. Translator is Anthropic-only and stores its key in plaintext JSON. EnLLM needs both features to share provider configuration while maintaining clear privacy behavior and allowing model/prompt customization.

## Decision

### Provider contract

Define a provider-neutral client contract similar to:

```swift
protocol LLMProviderClient: Sendable {
    var provider: LLMProvider { get }
    func complete(_ request: LLMCompletionRequest) async throws -> String
}

struct LLMCompletionRequest: Sendable {
    let instruction: String
    let userText: String
    let model: String
    let maxOutputTokens: Int
    let timeout: Duration
}
```

Selected text is always passed as `userText`, separate from editable instruction/system content. UI prompt settings do not use a `{{text}}` placeholder.

Anthropic and OpenAI request/response DTOs, headers, endpoints, completion metadata, and error parsing remain inside their adapters. OpenAI sets `store: false` where supported. Empty, token-limit, truncated, incomplete, cancelled, or otherwise nonterminal output is a provider failure. Anthropic rejects `max_tokens` completion; OpenAI requires a completed response status.

### Global routing

Both features share:

- one primary provider preference;
- one fallback-enabled preference; and
- a fixed model selection for each provider and action, chosen from a closed catalog (correction and translation route independently, including the single fallback attempt).

The router:

1. validates local request data;
2. attempts the selected primary provider when its key exists;
3. if fallback is enabled, attempts the alternate configured provider once when the primary key is missing or the primary has a provider-class failure;
4. does not fall back on local validation, permission, clipboard, configuration, target, or cancellation errors; and
5. does not retry the same provider.

Fallback is enabled by default/effective when both credentials are configured, but the user can explicitly disable it. Settings disclose that fallback may send the same selected text to a second provider.

### Built-in defaults

- OpenAI correction model: `gpt-5.4-mini` (choose `gpt-5.4-mini` or `gpt-5.6-luna`);
- OpenAI translation model: `gpt-5.4-mini` (choose `gpt-5.4-mini` or `gpt-5.6-luna`);
- Anthropic correction model: `claude-haiku-4-5` (only choice);
- Anthropic translation model: `claude-haiku-4-5` (choose `claude-haiku-4-5` or `claude-sonnet-5`);
- max output tokens: 4096;
- timeout: 15 seconds;
- separate built-in correction and Ukrainian-translation instructions;
- primary provider: Anthropic;
- fallback enabled, effective only when an alternate credential exists;
- Correct hotkey: `⌃⇧T`; and
- Translate hotkey: `⌥T`.

Model selections use fixed dropdowns limited to the catalog above; there are no free-form model IDs and no custom-ID option. Users may change each provider/action model selection and edit both instructions in Settings, and reset each to defaults. These values form the complete recovery state for disallowed selections or unreadable/corrupt non-secret persisted configuration. API keys never receive defaults. Live account availability of the catalog models is confirmed at manual acceptance, not compile time.

### Persistence

- API keys: macOS Keychain under the bundle/service namespace `com.radpozniakov.enllm`, with separate provider accounts.
- Non-secret settings: a strict schema-v2 JSON document at `~/Library/Application Support/com.radpozniakov.enllm/settings-v2.json` (resolved through `FileManager`) and written by same-directory atomic replacement. `settings-v1.json` is only ever read for a one-time migration and is never overwritten.
- The domain configuration has ten properties: primary provider, fallback flag, four action/provider model selections, two instruction strings, and two physical Carbon hotkey records. `schemaVersion` exists only in the persistence envelope. Hotkey key codes use an explicit supported physical-key whitelist; media keys, modifier-only keys, and undefined Carbon gaps are rejected.
- Missing v2 and v1 files use complete defaults. Malformed, unreadable, unsupported-version, missing/unknown-field, blank-instruction, disallowed-model-selection, invalid-hotkey, or duplicate-hotkey documents recover the entire non-secret state to defaults; fields are never partially merged.
- On load, a valid v2 file wins. Only when v2 is absent is a valid v1 file migrated: each provider's single v1 model is copied into both of that provider's action selections when still allowed, otherwise defaulted, and all other settings are preserved. The migrated v2 file is written atomically before the migrated runtime is published; a failed migration write leaves v1 untouched and falls back to complete defaults, never a partial migration.
- No v0 conversion and no migration from either reference MVP.
- Settings load stored keys into secure fields, where they are displayed as masked values. Editing replaces a key; a confirmed explicit deletion removes the Keychain item through the same autosave transaction, while an edited empty/whitespace field is not an implicit deletion.

### Settings transaction

Settings use a draft model and debounced transactional autosave; there is no explicit Save/Apply button. Settings save automatically after a short debounce (600 ms, within an approved 500–800 ms range) once the user stops editing. The complete draft, including credential intents and values, is snapshotted when a commit starts; draft controls are unavailable during bootstrap and commit. Autosave is atomic for runtime activation, not a claim of crash-atomicity across Keychain, filesystem preferences, and Carbon registration. Invalid drafts are never autosaved: the last good active runtime is kept and inline validation is shown. Rapid edits coalesce and commits serialize to the newest complete valid snapshot; obsolete work is cancelled and stale routine success/error status is suppressed, but incomplete-rollback/recovery/uncertain-credential errors are never suppressed and block further autosave until a fresh edit. A subtle Saving…/Saved/error status is shown and is keyboard- and VoiceOver-accessible. On Settings close a pending valid commit is flushed; on Quit, autosave coordinates with clipboard teardown, awaits the commit or rollback, and cancels termination on a save or recovery failure until an explicit safe-discard confirmation permits abandoning an uncommitted edit.

Commit order:

1. validate the full draft and snapshot previous runtime/persisted state;
2. stage/write Keychain credentials and the versioned configuration;
3. prepare both hotkeys by checking every superseded Carbon unregister, staging replacements, and retaining the old definitions needed for truthful rollback; and
4. publish the new in-memory runtime configuration only after every prior step succeeds.

On failure, the previous runtime configuration remains active and persisted values/hotkeys are restored where possible. If durable rollback is incomplete, EnLLM reports a recovery error, reloads durable non-secret settings and credential presence into Settings, preserves each known previous runtime credential, and disables only routes whose credential truth is uncertain; it never reports Save success.

Each provider has Test Connection that flushes and awaits any pending valid autosave, then tests an immutable captured snapshot of the draft credential and that provider's distinct selected models in sequence (a single request when both actions select the same model), each with a small built-in request containing no selected text. It is rejected inline while the draft is invalid and cannot be raced or cancelled by autosave, and it reports which selected model failed with stable, content-free wording. After composition, the Settings coordinator is the sole writer of Keychain credentials, the JSON repository, Carbon registration generations, and the active runtime snapshot.

## Consequences

### Positive

- Correction and translation share routing and credentials without duplicating clients.
- A provider can be replaced or extended without changing feature orchestration.
- Credentials are not persisted in plaintext.
- Separate instruction and user content avoids fragile placeholders.
- Bounded fallback improves availability while remaining visible and controllable.
- Built-in defaults provide a recoverable configuration state.

### Negative

- Automatic fallback can disclose text to a second company; clear Settings disclosure and an off switch are mandatory.
- Durable cross-store crash atomicity is impossible; explicit commit order, runtime-atomic activation, rollback, and recovery UI are required.
- A fixed model catalog removes the free-form model IDs that could fail at runtime, though live account availability of the catalog models is still verified at manual acceptance.
- Test Connection incurs a small provider request and cannot guarantee that every later content request will succeed.

## Rejected Alternatives

### Anthropic-only MVP

Rejected because the user wants both Anthropic and OpenAI and the Corrector reference already validates the abstraction.

### Provider settings per feature

Rejected to keep routing predictable and Settings small. Both actions use one global primary/fallback policy.

### Prompt files with `{{text}}`

Rejected because placeholder validation is fragile and mixes instructions with user text. Instructions remain editable while content is a separate message/input.

### Store credentials in the normal settings file

Rejected because API keys are secrets and must use Keychain.

### Unlimited retry/fallback chains

Rejected due to latency, cost, privacy, and stale-target risk. The MVP permits one alternate-provider attempt only.
