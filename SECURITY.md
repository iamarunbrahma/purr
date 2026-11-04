# Security Policy

## Supported Versions

Only the latest release gets security fixes. Click **Check for Updates** in the menu bar to make sure you're on it before reporting.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Older releases | No |

## Reporting a Vulnerability

Please don't open a public issue for a security problem. Report it privately through [GitHub](https://github.com/iamarunbrahma/purr/security/advisories/new), or email contact@arunbrahma.com with `[purr-security]` in the subject.

Include your Purr version (menu bar > About Purr), your macOS version, the steps to reproduce it, and what happened.

## What to Expect

- A reply within 3 working days.
- Word on whether I could reproduce it and how I plan to fix it.
- Once the fix ships, an advisory that credits you, unless you'd rather stay anonymous.

Purr is maintained by one person, so please give me a reasonable chance to ship a fix before you share details publicly.

## Scope

**In scope:** the Purr app and this repository, including the updater, model downloads, permission handling and how meeting notes are stored.

**Out of scope:** bugs in dependencies like WhisperKit, FluidAudio, llama.cpp and Sparkle (please report those upstream), and macOS itself. Purr needing Microphone and Accessibility access is by design, not a vulnerability.
