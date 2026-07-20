# ADR-0002: AX-First Selection with Safe Clipboard Fallback

- **Status:** Accepted
- **Date:** 2026-07-18

## Context

The reference Translator tries Accessibility-selected text first but restores only a plain-text clipboard value on fallback. The reference Corrector snapshots all pasteboard items but can treat an unchanged, stale clipboard string as the selection. Corrector can also paste into the wrong application or selection after network latency.

EnLLM must work across Chrome, Safari, Notes, TextEdit, Slack, VS Code, Sublime Text, and Zed without adopting the reference Corrector's blind-paste or stale-clipboard behavior. Sublime Text and Zed support standard Copy/Paste but may omit focused-element or selected-range Accessibility metadata.

## Decision

### Capture strategy

1. Capture a `SelectionContext` before network work. It contains:
   - frontmost application PID;
   - focused AX window identity when available;
   - focused AX element identity when available;
   - selected AX range when available;
   - selected source text;
   - capture method (`accessibility` or `clipboardFallback`); and
   - a unique operation ID.

   AX-selected-text correction requires stable element and range values. Clipboard-fallback correction may use the compatibility verification path below when the target provides a stable focused window but omits element or range metadata.
2. Read `kAXSelectedTextAttribute` from the focused element first.
3. If unavailable, capture a complete pasteboard snapshot, simulate `⌘C`, and wait asynchronously for `NSPasteboard.changeCount` to advance.
4. Accept only a new, nonempty plain-text value after a real change-count transition.
5. On timeout/no change, restore the snapshot and report no selection. Never read the old pasteboard string as selected input.
6. Restore every captured pasteboard item/type after fallback capture.

### Correction target verification

Immediately before automatic replacement, use the verification path for the capture method.

For an Accessibility-selected-text capture:

1. the current frontmost PID equals the captured PID;
2. the current focused AX element equals the captured element using Accessibility/Core Foundation equality semantics;
3. the current selected AX range equals the captured range; and
4. the current AX selected text exactly equals the captured source text.

For a clipboard-fallback capture:

1. the current frontmost PID equals the captured PID;
2. the current focused AX window equals the captured window;
3. focused-element identity and selected range are compared when they were available at capture, and any captured value must remain available and equal;
4. EnLLM re-copies through the serialized safe clipboard service and accepts only a real pasteboard change containing text exactly equal to the captured source;
5. EnLLM rechecks PID, window, and every captured optional metadata value after the re-copy and immediately before Paste.

A missing focused window, any unavailable mandatory value, or any mismatch makes the operation ineligible for automatic replacement. EnLLM must not paste and must show the completed correction in the result panel for manual copying. The compatibility path does not pretend missing element/range metadata was verified: identical text moved elsewhere inside the same AX-incomplete window remains indistinguishable and is an explicitly accepted limitation for Sublime Text and Zed compatibility.

The runtime rules above are binding. The former fixed compatibility **matrix** — which required, at final acceptance, one automatic Correct smoke replacement in each of a fixed set of applications — was **descoped for personal use on 2026-07-19** (see [NFR-004](../02-non-functional-requirements.md#nfr-004--compatibility)). Automatic replacement is still the required behavior wherever a target verifies; a safety-panel fallback remains correct behavior. Real-world confirmation is now an optional personal smoke check rather than a gate against a fixed app list.

### Replacement strategy

For the MVP, use a paste-based replacement for compatible editable controls:

1. retain/refresh the complete pasteboard snapshot;
2. put corrected plain text on the pasteboard;
3. simulate `⌘V` only after target verification;
4. wait asynchronously for the target to consume the paste; and
5. restore the complete snapshot.

The replacement layer must reject empty output and must not contain provider-specific errors.

### Concurrency

Selection capture and pasteboard replacement run through a serialized actor/service. Cancellation checks occur before each irreversible side effect. Once a paste event has been posted, restoration for that operation completes before a newer operation can use the pasteboard.

A user clicking **Copy** in a result panel is an intentional clipboard action and is not followed by restoration.

## Consequences

### Positive

- AX-first capture avoids unnecessary clipboard mutation in compatible apps.
- Fallback retains broad compatibility without stale clipboard submission.
- Complete snapshots preserve rich clipboard items even though corrected output is plain text.
- Wrong-target correction becomes copy-only rather than destructive.
- Shared selection infrastructure serves both features.

### Negative

- Clipboard compatibility requires a stable AX focused window even when element/range metadata is absent; targets without that minimum identity use the safety panel.
- In an AX-incomplete window, identical selected text moved to another location cannot be distinguished, and multiple-cursor behavior may be editor-specific.
- Paste consumption cannot be proven perfectly across every third-party app; timing requires manual validation.
- AX element/range comparison needs careful wrappers because Accessibility values are not ideal domain identifiers.
- Full pasteboard snapshotting may fail for promised/lazy data types; restoration is best effort in those exceptional cases and must fail safely.

## Rejected Alternatives

### Clipboard-only capture without requiring change count

Rejected because it can send and paste stale clipboard content when no selection exists.

### AX-only capture

Rejected because some target applications do not expose selected text consistently.

### Blind paste after the provider response

Rejected because users can change focus or selection during network latency.

### Rich-text-preserving replacement

Deferred. The MVP preserves plain-text structure and protects the user’s pre-operation clipboard, but does not reconstruct attributed styles in generated output.
