# Aki Notch UI

**Turn your MacBook notch into a programmable AI companion.**

![Aki Notch UI](screenshot.png)

## Features

- 🌐 **Local HTTP API** on port 47037 — script notifications from any language or tool
- 🤖 **AI Characters** with personality, memory, and mood-based pixel-art faces
- 💬 **Interactive chat** with proposed answers or free-text input
- 👥 **Multi-character conversations** — let your characters talk to each other
- ⌨️ **Compose mode** (⌘⇧K) — quick input from anywhere, no window switching
- 🎮 **Mini-games** — Tic-Tac-Toe, Snake, Hangman, right from the notch
- 📜 **Conversation history** — pick up where you left off
- 👻 **Never steals focus** — overlays stay out of your way
- 🔒 **Privacy first** — everything runs locally, no telemetry, no data collection
- 🧠 **Bring your own model** — works with Anthropic, OpenAI, Ollama, LM Studio, or any OpenAI-compatible endpoint

## Build from Source

```sh
git clone https://github.com/vldv/aki-notch.git
cd aki-notch
xcodebuild -project aki-notch-ui.xcodeproj -scheme aki-notch-ui -configuration Release build
```

> **Note:** [Sparkle](https://sparkle-project.org) (auto-update framework) is the only dependency and is resolved automatically via Swift Package Manager on first build.

## Quick Start

With the app running, send a notification from your terminal:

```sh
curl -X POST http://127.0.0.1:47037/overlay \
  -H "Content-Type: application/json" \
  -d '{"name":"Aki","message":"Hello world!"}'
```

A pixel-art card slides down from your notch. That's it.

## API

| Endpoint | Method | Description |
|---|---|---|
| `/health` | GET | Check if the app is running |
| `/overlay` | POST | Show a notification card from the notch |
| `/chat` | POST | Send a message and get an AI response |
| `/listen` | GET | SSE stream for real-time events |
| `/collapse` | POST | Collapse the current overlay |
| `/clear` | POST | Clear all active overlays |

Full API documentation is available in the app's built-in API Docs tab.

## CLI

The `aki-cli` companion tool gives you quick access from the terminal.

```sh
./install-cli.sh
```

This installs `aki` to `/usr/local/bin`. Then:

```sh
aki say "Build succeeded ✅"
aki chat "Summarize my last commit"
```

## Requirements

- **macOS 14.0+**
- MacBook with notch (recommended — works on any Mac)

## Pre-built App

Don't want to build from source? Download the pre-built, signed DMG from **[aki-notch.app](https://aki-notch.app)** — $5 one-time, includes auto-updates and a free trial.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).

Third-party attributions (including PressStart2P font under SIL OFL) are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## Contributing

Issues and PRs welcome. Please open an issue first for large changes.