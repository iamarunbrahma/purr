<div align="center">

<img src="Resources/purr_app_logo.png" alt="Purr" width="160" height="160">

# Purr

**Hold a key, speak, and your words appear in any app.**<br>
Dictation, meeting notes and voice editing that run entirely on your Mac.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-orange)](#requirements)

</div>

## Features

- **Dictate** into any text field. Hold a key, talk, let go.
- **Smart Typing** types as you speak instead of waiting for you to let go.
- **Meetings** records your mic and the call, labels who said what, and saves Markdown notes with an optional summary.
- **Voice Edit** rewrites selected text when you say what to change.
- **Languages**: English by default, about 100 for dictation with Whisper, and 28 for meetings.
- **Voice commands** for punctuation, new lines and "scratch that", plus your own.
- **Vocabulary** fixes the names and acronyms it mishears, and drops "um" and "uh".
- **Private**: no account, no cloud, no telemetry.

## Install

Download `Purr.dmg` from the [latest release](https://github.com/iamarunbrahma/purr/releases/latest), open it and drag Purr into Applications.

Or build it from source (needs Xcode):

```bash
git clone https://github.com/iamarunbrahma/purr.git
cd purr
make app
mv dist/Purr.app /Applications/
open /Applications/Purr.app
```

On first launch, a short setup picks the speech engine, downloads its model (about 450 MB for Parakeet) and asks for Microphone and Accessibility access. Then click into any text field, hold **Right Option**, speak and let go.

## Hot Keys

| Mode       | Default      | Behavior                                           |
| ---------- | ------------ | -------------------------------------------------- |
| Dictate    | hold right ⌥ | Hold to talk, release to type.                     |
| Meeting    | ⌃⌥ M         | Tap to start and stop. Records mic + system audio. |
| Voice Edit | ⌃⌥ E         | Select text, hold, say the change, release.        |

Meeting and Voice Edit are off until you turn them on in Settings. Each mode has a few other keys to pick from, and Dictate can also start and stop with a tap.

While dictating, say "comma", "period", "question mark", "new line", "new paragraph" or "scratch that". Add your own commands in **Settings > Vocabulary**.

## Requirements

- An Apple Silicon Mac with macOS 14 or later.
- macOS 14.2 or later to record the other people on a call.
- For summaries and Voice Edit, Apple Intelligence on macOS 26, or Gemma 4 E2B (a 3.35 GB download) on any version.

## FAQ

<details>
<summary><strong>Does anything leave my Mac?</strong></summary>

No. Recording, transcription, summaries and Voice Edit all run on your Mac. Purr only goes online to download models and, when you open About, to check GitHub for a new version. Once the models are downloaded, it works offline.

</details>

<details>
<summary><strong>Which languages does it support?</strong></summary>

Dictation uses Parakeet for English. Switch to Whisper in **Settings > Engine** for about 100 other languages, and optionally translate them into English. Meetings work in English and 27 more languages (pick one in **Settings > Meetings**), and the summary is written in the meeting's language.

</details>

<details>
<summary><strong>Does meeting mode record the other people on my call?</strong></summary>

Yes. It records your mic and your Mac's audio output together, so remote voices are transcribed too. On macOS 14.0 and 14.1, only your mic is recorded.

</details>

<details>
<summary><strong>I can't see the icon in the menu bar.</strong></summary>

On MacBooks with a notch, menu bar icons can hide behind it when the bar is full. Quit a few menu bar apps, hold ⌘ and drag icons to make room, or use [Ice](https://github.com/jordanbaird/Ice).

</details>

<details>
<summary><strong>How do I update Purr?</strong></summary>

Open **About Purr** from the menu bar. It checks GitHub Releases each time it opens, and installs a new version after verifying its SHA-256.

</details>

<details>
<summary><strong>How do I remove the models or uninstall Purr?</strong></summary>

**Settings > Models > Delete All** removes every downloaded model and keeps your meetings and settings. Models download again when a feature needs them.

**Settings > General > Uninstall** moves Purr, its models and your meetings to the Trash, removes its settings, caches and permissions, and quits.

If you already dragged Purr to the Trash, put it back and use Uninstall, or remove the rest yourself:

```bash
rm -rf ~/Library/Application\ Support/Purr     # models and meetings
rm -rf ~/Library/Caches/com.arunbrahma.purr   # caches
defaults delete com.arunbrahma.purr           # settings
```

</details>

## License

Purr is MIT licensed. Copyright (c) 2026 Arun Brahma. See [LICENSE](LICENSE).

Models download on first use, are never bundled, and keep their own licenses:

- **Parakeet TDT v2 and v3** (NVIDIA, via FluidAudio): CC-BY-4.0
- **Whisper** (OpenAI, via WhisperKit): MIT
- **Gemma 4 E2B** (Google): [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0)

Bundled code:

- **WhisperKit** (Argmax): MIT
- **FluidAudio** (FluidInference): Apache-2.0
- **llama.cpp** (ggml-org): MIT
- **SpeexDSP** (Xiph.Org): BSD-3-Clause, for echo cancellation in meetings
