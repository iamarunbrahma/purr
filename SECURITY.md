# Security Policy

## Supported Versions

Only the latest release gets security fixes. Click **Check for Updates** in the menu bar to make sure you're on it before reporting.

|    Version     | Supported |
| :------------: | :-------: |
| Latest release |    Yes    |
| Older releases |     No    |

## Reporting a Vulnerability

Please don't open a public issue for a security problem. Report it privately through [GitHub](https://github.com/iamarunbrahma/purr/security/advisories/new), or email contact@arunbrahma.com with `[purr-security]` in the subject.

Include your Purr version (menu bar > About Purr), your macOS version, the steps to reproduce it, and what happened.

## What to Expect

I'll reply within 3 working days and tell you whether I could reproduce the problem and how I plan to fix it. If I confirm and fix it, the advisory credits you, unless you'd rather stay anonymous.

There's no bug bounty. Reports that are only scanner output, with no steps that show a real problem, will be closed.

Purr is maintained by one person, so please give me a reasonable chance to ship a fix before you share details publicly.

## Scope

**In scope:** the Purr app and this repository, including the updater, model downloads, permission handling and how meeting notes are stored.

**Out of scope:** bugs in dependencies like WhisperKit, FluidAudio, llama.cpp and Sparkle (please report those upstream), and macOS itself. Purr needing Microphone and Accessibility access is by design, not a vulnerability.
