# EnLLM

EnLLM is a menu-bar utility for macOS that works on whatever text you have selected, in any app:

- **Correct** — fixes grammar, spelling, and wording *in place*, without changing your meaning.
- **Translate to Ukrainian** — shows the translation in a small floating panel you can copy from.

It lives in the menu bar (no Dock icon, no window), keeps your text only in memory, and never replaces your selection with empty, partial, or unverified output.

## Requirements

- macOS 26 on Apple Silicon
- An Anthropic and/or OpenAI API key
- Xcode 26.3 (to build — there is no prebuilt download)

## Install

Build it once from source:

```sh
./scripts/build-local.sh Debug
open .local-app/EnLLM.app
```

The app appears in the menu bar.

## First-time setup

1. Click the menu-bar icon → **Settings**.
2. Paste your Anthropic and/or OpenAI API key. Keys are stored only in your macOS Keychain.
3. Grant **Accessibility** permission when prompted — it's required to read and replace the selected text.

## Using it

Select text in any app, then:

- **Correct** — `⌃⇧T` — replaces the selection in place. If it can't be replaced safely, the corrected text appears in a panel instead.
- **Translate to Ukrainian** — `⌥T` — opens a floating panel with the translation; click **Copy** to copy it.

Both shortcuts are configurable in Settings.

## Settings

- Choose the model for each action — Anthropic: `claude-haiku-4-5`, `claude-sonnet-5`; OpenAI: `gpt-5.4-mini`, `gpt-5.6-luna`.
- Pick your primary provider, and optionally allow one automatic fallback to the other.
- Edit the correction/translation instructions and the keyboard shortcuts.
- **Test Connection** checks your keys without sending any of your selected text.
- Changes save automatically — there's no Save button.

## Privacy

- Your selected text is sent only to your chosen provider — and, if you enable fallback, once to the other. Nothing more.
- No history, analytics, or telemetry. Selected text is never written to disk or logs, and API keys live only in the macOS Keychain.

---

*Technical documentation for contributors lives in [`doc/`](doc).*
