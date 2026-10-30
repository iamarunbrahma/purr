# Changelog

## 0.0.2 - Unreleased

- Transcribe meetings in 27 more languages with Parakeet v3.
- Optionally save each meeting's audio next to its notes.
- Keep a meeting's audio when its transcription fails.
- Summaries and Voice Edit use Gemma 4 E2B instead of Gemma 3 4B.
- Pick Apple Intelligence or Gemma for Voice Edit.
- Uninstall Purr from Settings > General.
- Redesigned Settings and first-run setup. Input Monitoring is no longer needed.
- Copy, paste and undo work in Purr's own text fields.
- About checks for updates every time it opens.
- Purr asks before quitting in the middle of a recording.
- Fixed Whisper writing English when you speak another language.
- Fixed garbled "You" lines in meetings when the call plays through the speakers.
- Fixed Smart Typing sometimes dropping a sentence.
- Fixed the first dictation after launch waiting about 2 seconds for the mic.
- Fixed the menu bar icon sometimes not showing up.
- Fixed "new line" and "new paragraph" leaving a stray comma, and "colon" leaving a space before the mark.
- Fixed "tab key" typing a space instead of a tab.
- Fixed dictation starting in lowercase after a filler word like "um" or after "new paragraph".
- Fixed made-up "You" lines in meetings when your mic is muted.
- Dictation recovers instead of staying stuck on "Transcribing" when Core ML stalls.
- A Whisper model loads as soon as it downloads, so the first dictation doesn't wait for it.
- A Gemma download that breaks off picks up where it stopped when you retry.
- Whisper's tokenizer is stored with its model instead of in ~/Documents/huggingface.

## 0.0.1 - 2026-06-15

- First release: dictation with Parakeet or Whisper, Smart Typing, meeting notes with summaries, Voice Edit, voice commands and a custom dictionary.
