<div align="center">

<img src="Resources/purr_app_logo.png" alt="Purr" width="180" height="180">

# Purr

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-orange)](#)
[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-orange?logo=swift)](#)
[![Engine: Parakeet TDT v2](https://img.shields.io/badge/Engine-Parakeet%20TDT%20v2-purple)](#)

### Hold a key. Speak. Your words type into any text field - 100% local, on-device.

</div>

Local voice-to-text dictation for macOS Apple Silicon. A free, MIT-licensed alternative to paid commercial dictation apps, with no telemetry and no cloud round-trips.

## Screenshots

<table>
  <tr>
    <td align="center" width="50%">
      <img src="Resources/screenshots/onboarding.png" alt="Onboarding and permissions"><br>
      <sub>Onboarding &amp; permissions</sub>
    </td>
    <td align="center" width="50%">
      <img src="Resources/screenshots/general-settings.png" alt="General settings"><br>
      <sub>General settings</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <img src="Resources/screenshots/features-settings.png" alt="Features settings"><br>
      <sub>Features settings</sub>
    </td>
    <td align="center">
      <img src="Resources/screenshots/customization-settings.png" alt="Customization settings"><br>
      <sub>Customization settings</sub>
    </td>
  </tr>
</table>

## QuickStart

```bash
git clone https://github.com/iamarunbrahma/purr.git
cd purr
make app
mv dist/Purr.app /Applications/
open /Applications/Purr.app
```

First launch:

1. A short setup picks the speech engine, downloads its model (~450 MB for Parakeet), and asks for Microphone and Accessibility.
2. Click into any text field, hold **Right Option**, speak, release.

## Hot Keys

| Action      | Default | Behavior                                       |
| ----------- | ------- | ---------------------------------------------- |
| Dictation   | hold ⌥  | Hold to talk, release to paste/type.           |
| Meeting     | ⌃⌥ M    | Tap to start/stop. Captures mic + system audio. |
| Voice edit  | ⌃⌥ E    | Select text, hold, speak the edit, release.    |

While a meeting is recording, the dictation hotkey is suspended so a reflexive press won't spray a transcript over your notes. Each hotkey can be switched between a few built-in presets in Settings.

**In-speech voice commands:** "new paragraph", "comma", "period", "question mark", "exclamation mark", "scratch that".

**Voice-edit phrases:** "change X to Y", "replace X with Y", "delete X", "add Y at the end", "prepend Y", "capitalize", "lowercase", "uppercase". Anything else replaces the selection wholesale.

## Features

- **Two transcription engines**: Parakeet TDT v2 (default) is English-only, on-device, and the fastest option on Apple Silicon. Switch to WhisperKit (Whisper Tiny EN through Large V3 Turbo) when you need another language.
- **Smart Typing**: With Parakeet, words appear live in the focused app as you speak instead of only landing on key release. Each phrase stays separately undoable and coexists cleanly with autocorrect and IMEs.
- **Meeting mode**: Captures your mic and your Mac's system audio together, so everyone on a call is transcribed. Echo cancellation and offline speaker diarization (FluidAudio) label each voice, and transcripts save as Markdown to a folder you choose.
- **Meeting summaries**: Each meeting can save a sidecar `.summary.md` with a TL;DR, decisions, action items, and notes. Uses Apple's on-device model on macOS 26+, or Gemma 4 E2B locally on older systems.
- **Voice editing**: Select text, hold the voice-edit hotkey, and speak the change. A parser handles "change X to Y", "delete X", "capitalize", and more; anything else replaces the selection wholesale.
- **In-speech voice commands**: Punctuate, break paragraphs, and undo hands-free by saying "comma", "period", "new paragraph", or "scratch that" as you dictate. Add your own in Settings.
- **Custom dictionary**: Teach Purr the proper nouns and acronyms it keeps mishearing - map "fluid audio" to "FluidAudio" or "ts" to "TypeScript".
- **Filler trimming**: "um", "uh", and "er" are stripped automatically; add your own filler words in Settings.
- **Flexible hotkeys**: Pick each feature's trigger from a few built-in presets - a bare modifier, a modifier combo, or a function key.
- **Native and private**: Pure Swift and SwiftUI (no Electron, no Tauri), with everything running on-device and zero telemetry.

## Compatibility

| Platform                                       | Status                                                       |
| ---------------------------------------------- | ------------------------------------------------------------ |
| macOS 14+ on Apple Silicon (M1, M2, M3, M4)    | Supported                                                    |
| macOS 14+ on Intel                             | Not supported (Apple Silicon only - CoreML / ANE)            |
| macOS 13 or earlier                            | Not supported (uses Sonoma+ APIs)                            |
| Windows                                        | Not planned (CGEventTap, Accessibility, ANE are Apple-only)  |
| Linux                                          | Not planned                                                  |
| iOS / iPadOS                                   | Not planned (designed as a menu bar app)                     |

## FAQs

<details>
<summary><strong>Does my audio leave my Mac?</strong></summary>

No. Recording, transcription, and post-processing all happen on-device (transcription runs on the Apple Neural Engine). Zero telemetry, and zero network calls after the initial model download.

</details>

<details>
<summary><strong>Which mode is lowest-latency?</strong></summary>

Parakeet (the default) with Smart Typing on, so words appear as you speak instead of on key release. Whisper can't match it because it's non-streaming.

</details>

<details>
<summary><strong>What languages can I dictate in?</strong></summary>

English with the default Parakeet engine. For other languages, switch to WhisperKit in Settings > Engine - it transcribes ~100 languages (auto-detected or pinned) and can optionally translate them to English.

</details>

<details>
<summary><strong>Does meeting mode record the other people on my call?</strong></summary>

Yes - it captures your mic and your Mac's system audio together, so remote participants are transcribed too, still entirely on-device. System-audio capture needs macOS 14.2+; older systems record the mic only.

</details>

<details>
<summary><strong>The mic icon isn't visible in my menu bar.</strong></summary>

On notched MacBooks the icon hides behind the notch when the menu bar is crowded. Hold Command and drag to reorder, quit a few menu bar apps, or use [Ice](https://github.com/jordanbaird/Ice) / Bartender to manage overflow.

</details>

<details>
<summary><strong>How big is the model download?</strong></summary>

Parakeet TDT v2 is ~450 MB, fetched automatically on first launch. Whisper models range from ~140 MB (Tiny) to ~616 MB (Large V3 Turbo) if you switch engines.

</details>

<details>
<summary><strong>Does it work without internet?</strong></summary>

Yes, after the first model download. Everything runs on-device.

</details>

<details>
<summary><strong>Can I change the hotkey?</strong></summary>

Yes - pick from a few built-in presets per feature in Settings (e.g. Right Option, F5, or ⌃⌥ Space for dictation). There's no custom recorder yet, so keys outside the presets can't be assigned.

</details>

<details>
<summary><strong>Can I use it in any app?</strong></summary>

Any standard text field. Voice editing works in Accessibility-supported fields (most native macOS apps); other apps fall back to paste injection.

</details>

<details>
<summary><strong>How do I update Purr?</strong></summary>

Open the menu bar > About Purr and it checks GitHub Releases automatically (or click "Check for Updates"). A new version downloads, verifies its checksum, and relaunches in place.

</details>

<details>
<summary><strong>Why was I asked to grant permissions again after an update?</strong></summary>

Either the bundle ID changed (e.g. you swapped in a different fork) or you revoked a permission in System Settings. Re-grant from the menu bar > Permissions Needed…

</details>

<details>
<summary><strong>How do I delete the models or fully uninstall Purr?</strong></summary>

To reclaim disk space without uninstalling, open **Settings > Models** and click **Delete All…**. It removes every downloaded model (Parakeet, Whisper, the diarizer, and Gemma) while keeping your meeting transcripts and preferences; the models re-download automatically the next time a feature needs them.

To uninstall completely, open **Settings > General** and click **Uninstall…**. Purr moves itself, its models and your meetings to the Trash, deletes its preferences and caches, resets its permissions, and quits.

Already dragged Purr to the Trash? Put it back, open it and click **Uninstall…**, or remove what it left yourself:

```bash
rm -rf ~/Library/Application\ Support/Purr     # models + meetings
rm -rf ~/Library/Caches/com.arunbrahma.hello   # caches
defaults delete com.arunbrahma.hello           # preferences
```

Older versions also kept Whisper files in `~/Documents/huggingface`. Delete that folder too if no other app uses it.

</details>

## License

Purr itself is MIT-licensed. Copyright (c) 2026 Arun Brahma. See [LICENSE](LICENSE).

### Third-party licenses

Purr builds on open-source work in two categories, handled differently.

**Model weights** download on first use and are never redistributed by Purr; each carries its own terms:

- **Parakeet TDT v2** (NVIDIA, run via FluidAudio) - CC-BY-4.0. Powers the default English dictation, voice editing, and meeting transcription.
- **Whisper** (OpenAI, via WhisperKit) - MIT. Optional engine for other languages.
- **Gemma 4 E2B Instruct** (Google) - [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0). Used for meeting summaries and Voice Edit.

**Bundled code** is compiled or linked into the app:

- **WhisperKit** (Argmax) - MIT.
- **FluidAudio** (FluidInference) - Apache-2.0. Runs Parakeet transcription and the meeting-mode speaker diarization model.
- **llama.cpp** (ggml-org) - MIT, embedded as an Apple XCFramework; runs the Gemma summaries.
- **SpeexDSP** (Xiph.Org) - BSD-3-Clause, vendored from source for meeting echo cancellation.
