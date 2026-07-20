# EnLLM Remaining Implementation Backlog

**Status:** Active
**Baseline commit:** `f27f2e7`
**Updated:** 2026-07-19

This backlog tracks the remaining work for EnLLM. On 2026-07-19 the backlog was **rescoped for personal use**: EnLLM is a single-user tool for its author, it already behaves as intended, and its safety/privacy/reliability rules are enforced in code and covered by a green automated gate (110 SwiftPM + 89 Xcode app tests, Debug/Release builds — `VAL-2026-07-19-03` at `8fbdd20`). The formal release-acceptance apparatus — a fixed six-application compatibility matrix, ten-sample performance records, dedicated evidence-recording tooling, and a formal MVP-complete gate — was disproportionate for that context and has been descoped. See [Descoped on 2026-07-19](#descoped-on-2026-07-19). The remaining active work is a single lightweight personal smoke check and custom artwork.

The [technical specification](00-technical-specification.md), [requirements](01-functional-requirements.md), [non-functional requirements](02-non-functional-requirements.md), and [acceptance plan](03-acceptance-test-plan.md) were updated in the same pass so they no longer promise the descoped scope.

## Completed and removed

The Phase 6 implementation items **BL-001 through BL-008**, the Phase 5 Settings-contract items **BL-018, BL-019, BL-020, and BL-021**, the Phase 6 gate/documentation item **BL-009**, and the quality-corpus item **BL-010** are complete and have been removed from this backlog. For traceability:

| Item | Title | Commit |
|---|---|---|
| BL-001 | Sanitize every Settings and Test Connection error | `87f2444` |
| BL-002 | Complete actionable error-panel actions and wording | `aa1fb7b` |
| BL-005 | Make result-panel event-monitor cleanup testable | `aa1fb7b` |
| BL-006 | Verify and harden production provider cancellation | `aa1fb7b` |
| BL-007 | Complete the supersession boundary test matrix | `c9ae598` |
| BL-008 | Close the quit and teardown state machine | `0253a5a` |
| BL-003 | Add a typed privacy-safe diagnostic recorder | `16291b4` |
| BL-004 | Instrument operation and provider-attempt lifecycles | `bea4210` |
| BL-019 | Add action-specific model selectors and schema-v2 migration | `1324fba` |
| BL-018 | Hide unavailable API-key actions | `ebdf76a` |
| BL-021 | Complete and validate keyboard shortcut recording UX | `efbaf0f` |
| BL-020 | Replace Save & Apply with debounced transactional autosave | `9c10588` |
| BL-010 | Add the versioned C-01–C-05/T-01–T-05 quality corpus | `8fbdd20` |
| BL-009 | Complete the Phase 6 gate and documentation | `55ee7f2` |

The BL-019/BL-020 authoritative-documentation updates (specification, ADR-0003, requirements, non-functional requirements, acceptance plan, development plan/status, and runbook) landed in `2edf4df`, with post-review hardening in `c7f57a9`. The BL-010 corpus and its automated integrity test landed in `8fbdd20` (post-review cleanup in `f27f2e7`). The BL-009 Phase 6 automated-gate closure is recorded as `VAL-2026-07-19-03`.

<a id="descoped-on-2026-07-19"></a>
## Descoped on 2026-07-19

After a scope-validation pass, the following items were judged to be release-acceptance ceremony that does not add value for a personal-use tool that already works and is already covered by a green automated gate. The underlying safety/privacy/reliability behavior is **not** being removed — only the formal manual re-proving and the fixed multi-app compatibility promise. The linked spec/NFR/acceptance/plan documents were updated to match.

| Item | Former title | Decision | Rationale |
|---|---|---|---|
| BL-011 | Add lightweight acceptance-record templates and helpers | **REMOVE** | Tooling that only exists to format the manual evidence the other validation items produced. With that validation descoped, it has no purpose. |
| BL-013 | Validate live providers, fallback, Settings, notifications | **SIMPLIFY → folded into [BL-012](#bl-012)** | The routing/fallback/settings/notification policies are proven by named automated tests and are exercised every time the author uses the app. Only a deliberate "fallback-off really does not transmit to the secondary provider" spot-check is worth an explicit look. |
| BL-014 | Execute the six-application matrix and app-specific adaptations | **REMOVE** | The fixed six-app compatibility promise (Chrome/Safari/Notes/TextEdit/Slack/VS Code, plus Sublime/Zed supplements) is a product commitment that only matters for distribution. For personal use, "works in the apps I use" replaces it. AX-first capture with clipboard fallback and fail-closed safety already covers unknown apps. |
| BL-015 | Complete performance, privacy, signing, permission-stability evidence | **SIMPLIFY → folded into [BL-012](#bl-012)** | Runtime latency targets are already non-blocking; privacy is guaranteed by code and tests. Only "signed bundle builds, launches, and keeps Accessibility trust across a rebuild" is worth confirming, and that folds into the smoke check. |
| BL-016 | Execute and record the final MVP gate | **REMOVE** | A formal MVP-complete gate exists solely to make a formal MVP-complete claim. No such claim is needed for personal use; the green automated gate is the bar. |

## Priority and scope labels

| Label | Meaning |
|---|---|
| `P1` | Required to complete the currently documented personal-use scope |
| `P2` | Optional readiness spot-check; non-blocking |
| `scope:required` | Keep unless the corresponding requirement is changed |
| `type:implementation` | Changes production or test-support code |
| `type:validation` | Produces personal-readiness evidence and may reveal implementation work |

## Dependency order

1. Independent: [BL-017](#bl-017) (custom artwork).
2. Optional readiness: [BL-012](#bl-012) (personal smoke check), run at the author's discretion before relying on a new build.

---

<a id="bl-012"></a>
## BL-012 — Personal pre-use smoke check

**Labels:** `P2`, `type:validation`, `optional`
**Supersedes:** the former BL-012 (clipboard/correction debt), BL-013 (live providers/fallback/Settings/notifications), and BL-015 (performance/privacy/signing) validation items
**Depends on:** None
**Blocks:** None

### Intent

A single, discretionary ~20-minute check of the few things that would actually bite in real use, run by the author against a fresh build when they want extra confidence. It is **not** a release gate and does not block anything. Everything below is already enforced in code and covered by the automated gate; this only confirms real-world behavior. No formal record is required — jot results in [`06-validation-log.md`](06-validation-log.md) only if useful. Obey the standing privacy rules: never record credentials, selected/generated text, clipboard contents, or request/response bodies.

### Checklist

- [ ] Correct and Translate work in the apps the author actually uses (whatever those are on the day).
- [ ] Clipboard is restored intact for the content types the author actually keeps on the clipboard (at minimum plain text; rich text / image / file URL / multi-item only if relevant to the author's usage).
- [ ] With fallback disabled, a forced primary failure does **not** transmit to the secondary provider. (The one privacy-relevant check worth doing deliberately.)
- [ ] The signed local bundle builds, launches menu-bar-only, and Accessibility trust survives a normal rebuild via `./scripts/build-local.sh Debug`.
- [ ] Quick privacy glance: API keys live only in Keychain; `settings-v2.json` and any diagnostics contain no selected/generated text or secrets. (Already asserted by automated tests; this is a spot confirmation.)

### Not in scope

The former fixed six-application matrix, the ten-request-per-provider performance sample, VoiceOver/keyboard formal acceptance, and the corpus-against-live-providers judgement are descoped for personal use (see [Descoped on 2026-07-19](#descoped-on-2026-07-19)). Run any of them ad hoc if a real problem appears; none are required.

---

<a id="bl-017"></a>
## BL-017 — Add custom app and menu-bar artwork

**Labels:** `P1`, `scope:required`, `type:implementation`, `phase:shell`, `ui`
**Depends on:** Menu-bar idle and active assets supplied by the product owner
**Blocks:** None

### Problem

The app currently uses SF Symbols for its menu-bar idle and active states and has no custom app-icon asset catalog. The product now requires custom branding.

### Confirmed inputs

- Use `/Users/pozniakov.rodion/Desktop/icon.png` as the source app icon. It is a 1024×1024 PNG with transparency.
- Do not derive the menu-bar artwork from that file. Separate idle and active menu-bar icons will be supplied before implementation.
- The two menu-bar states retain their current meaning: idle and action-in-progress.

### Scope

- Add a macOS app-icon asset set generated from the supplied source without committing a dependency on the external Desktop path.
- Add separate idle and active menu-bar assets after they are supplied.
- Render menu-bar artwork as template images so it remains legible across macOS menu-bar appearances unless the final supplied artwork explicitly requires multicolor rendering.
- Replace the current `text.bubble` and `ellipsis.circle` SF Symbols without changing action-state behavior.
- Verify bundle/build configuration includes all artwork in Debug and Release.

### Acceptance criteria

- [ ] The built app displays the custom app icon at standard macOS sizes without clipping or unintended background artifacts.
- [ ] The menu bar displays the supplied idle icon when no action is active.
- [ ] The menu bar displays the supplied active icon while either action is in progress and returns to idle afterward.
- [ ] Both menu-bar states remain clear in light and dark appearances and on Retina displays.
- [ ] Debug and Release builds contain no runtime reference to the external source path.

### Scope decision

`KEEP`. Implementation is blocked only on the two menu-bar assets. The supplied app-icon source is ready for implementation.

---

## Explicitly out of backlog

The following remain deferred: panel auto-dismiss, notification actions, streaming, history, analytics, additional providers, local models, localization, login items, updates, Intel support, App Store work, and public notarized distribution. As of 2026-07-19 this also includes the formal MVP-acceptance gate, the fixed six-application compatibility matrix, and the ten-sample performance records — descoped for personal use (see [Descoped on 2026-07-19](#descoped-on-2026-07-19)).

## Scope-validation checklist

Decisions recorded in the 2026-07-19 scope-validation pass:

| Item | Decision |
|---|---|
| BL-011 | `REMOVE` |
| BL-012 (personal smoke check) | `SIMPLIFY` — the outcome (real-world confidence) is retained as an optional, non-blocking check |
| BL-013 | `SIMPLIFY` — folded into BL-012 |
| BL-014 | `REMOVE` — the six-application compatibility promise is removed from the spec/NFR-004 |
| BL-015 | `SIMPLIFY` — folded into BL-012 |
| BL-016 | `REMOVE` — no formal MVP-complete claim is needed |
| BL-017 | `KEEP` |

Each `REMOVE`/`SIMPLIFY` above that touched compatibility, privacy, performance, or acceptance was accompanied by the corresponding update to the technical specification, non-functional requirements, acceptance plan, development plan, and project status in the same pass.
