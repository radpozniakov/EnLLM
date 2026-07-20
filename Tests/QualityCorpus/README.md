# EnLLM Versioned Quality Corpus

This directory holds the versioned quality fixtures for repeatable correction and
translation acceptance, as required by
[`doc/03-acceptance-test-plan.md`](../../doc/03-acceptance-test-plan.md) section 2
and backlog item BL-010.

Quality acceptance is **invariant-based**, not byte-for-byte: natural-language
variation is valid, so a fixture declares the properties its result must satisfy
rather than a single expected string.

## Layout

```
Tests/QualityCorpus/
  correction/   C-01.json .. C-05.json   (Correct action)
  translation/  T-01.json .. T-05.json   (Translate action)
```

The automated integrity check lives at
`Tests/EnLLMCoreTests/QualityCorpusIntegrityTests.swift`. It validates fixture
structure and protected-token declarations only; it does not call any provider.

## Synthetic-content rule

Every `input` string is **synthetic** and authored for this corpus. Fixtures must
never contain captured personal text, real correspondence, credentials, API keys,
or any personally identifying information. Recorded manual results must follow the
same rule and belong in `doc/06-validation-log.md`.

## Fixture schema

Each JSON file has these fields:

| Field | Meaning |
|---|---|
| `id` | Fixture ID (`C-0x` / `T-0x`); must match the file name and be unique. |
| `corpusVersion` | Integer corpus schema/content version (currently `1`). |
| `action` | `"correction"` or `"translation"`; must match the directory. |
| `contentType` | Human-readable content category from the acceptance plan. |
| `language` | BCP-47-ish source language tag (`en`, `fr`, `uk`, or `mixed`). |
| `input` | The synthetic source text handed to the action. |
| `invariants` | The declared properties the result must satisfy (see below). |
| `notes` | Free-text authoring notes (synthetic-only reminder, error inventory). |

### Invariant vocabulary

| Invariant | Type | Meaning |
|---|---|---|
| `resultOnly` | bool | Output must be the result text only — no preamble, explanation, or commentary. Always `true`. |
| `meaningPreserved` | bool | The result must retain the source meaning and tone. |
| `returnedUnchanged` | bool | The input is already correct/target-language; the result must equal the input. |
| `preserveLanguage` | bool | Correction only: fix errors without translating or changing the language. |
| `targetLanguage` | string | Translation only: required output language (`uk`). |
| `protectedTokens` | string[] | Tokens (code, commands, paths, product/API names, identifiers) that must appear unchanged in the result. Every entry is a literal substring of `input`. |
| `structural` | string[] | Structural properties that must be retained (Markdown/list/code-fence/link/speaker-line structure). |
| `expectedChanges` | string[] | Human-checkable corrections the result is expected to contain (correction fixtures). |

`resultOnly` is `true` for every fixture because the product contract forbids
model commentary in either action.
