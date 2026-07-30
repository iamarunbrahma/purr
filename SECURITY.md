# Security Policy

Purr runs with some of the most sensitive permissions macOS grants. Please report anything
you find.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report privately through either channel:

- [GitHub private vulnerability reporting](https://github.com/iamarunbrahma/purr/security/advisories/new) - preferred
- Email **contact@arunbrahma.com** with `[purr-security]` in the subject

Please include what you need to make the problem reproducible: the Purr version
(menu bar > About Purr), your macOS version and chip, what you did, what happened, and what
you expected. A proof of concept helps but is not required to report something.

### What to expect

Purr is maintained by one person outside a full-time job. Treat these as targets:

| Stage | Target |
| --- | --- |
| Acknowledgement that I received your report | 3 working days |
| Initial assessment and severity call | 10 working days |
| Fix released for a confirmed high-severity issue | 30 days where practical |

If you have not heard back within a week, assume the mail went astray and ping me again.

I will tell you plainly if I decide not to fix something, and why.

## Disclosure

Coordinated disclosure. I will work with you on a timeline and credit you in the release
notes and advisory unless you would rather stay anonymous. If a fix is taking longer than
90 days, you are free to disclose - I will not ask you to sit on a finding indefinitely.

## Safe harbour

If you are acting in good faith to find and report a vulnerability, I will not pursue or
support any action against you. Please stay within the obvious bounds: test against your
own machine and your own data, do not access other people's audio or transcripts, do not
degrade the service for anyone else, and give me a reasonable chance to fix things before
going public.

## Supported versions

Purr is pre-1.0 and ships from a single release line. Only the latest release receives
security fixes.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Anything older | No - please update |

Update from the menu bar: **About Purr > Check for Updates**.

## Threat model

Purr's permission set is unusual. You should know what you are trusting.

### What Purr can do on your Mac

To type into arbitrary applications, Purr holds:

- **Microphone** - records your voice
- **Accessibility** - reads and writes text in other applications' fields
- **Input Monitoring** with a global `CGEventTap` - observes keystrokes system-wide to
  detect its hotkeys
- **System audio capture** (meeting mode, macOS 14.2+) - records everything your Mac plays,
  including other participants on a call

**App Sandbox is intentionally disabled.** `CGEventTap` and paste injection do not work
reliably from a sandboxed process across arbitrary host applications. This is documented in
`Resources/Purr.entitlements`. The tradeoff is deliberate.

Taken together this is, mechanically, the capability set of a keylogger with a microphone.
Purr does not use it that way, and the source is here so you can confirm that. But the
correct assumption is that a compromised Purr build would be an excellent surveillance
tool, which is why the integrity of the release channel matters more than almost anything
else in this project.

### What Purr does not do

- No telemetry, analytics, crash reporting, or usage tracking of any kind
- No account, no login, no server
- No network traffic at all once models are downloaded, other than an explicit update check

The only outbound connections Purr ever makes:

| Purpose | Host |
| --- | --- |
| Update check | `api.github.com` |
| Update download | `github.com`, redirecting to `objects.githubusercontent.com` |
| Gemma 3 4B summary model | `huggingface.co` |
| Parakeet / Whisper / diarizer weights | fetched by FluidAudio and WhisperKit |

The updater refuses any download URL whose host is not exactly `github.com` over HTTPS,
even if the GitHub API response names one.

Your audio is never uploaded. Transcription runs on the Apple Neural Engine, on-device.

### Where your data sits

By default everything Purr writes lives under one directory:

```
~/Library/Application Support/Purr/models/          # downloaded model weights
~/Library/Application Support/Purr/Purr Meetings/   # meeting transcripts
```

You can choose a different meetings folder during setup or in Settings, in which case
transcripts go there instead. If that folder later becomes unwritable, Purr falls back to
the default location rather than losing the transcript.

Meeting transcripts are **plaintext Markdown, not encrypted at rest** - one
`Meeting <timestamp>.md` per recording, plus an optional `.summary.md` sidecar. They may
contain the speech of other people on your calls who never installed Purr. Treat that
folder with the same care as the recordings themselves. Encryption at rest is on the
roadmap.

Preferences live in `defaults` under `com.arunbrahma.purr`.

### Release integrity

Releases are Developer ID signed, built with the Hardened Runtime, notarized by Apple, and
stapled. The `.app`, the embedded `llama.framework`, and the `.dmg` are each signed, and the
DMG is notarized and stapled before its hash is computed.

Verify a download yourself before installing:

```bash
shasum -a 256 -c Purr.dmg.sha256          # integrity against the published sidecar
codesign --verify --deep --strict --verbose=2 /Applications/Purr.app
spctl -a -t exec -vv /Applications/Purr.app   # should report: accepted, Notarized Developer ID

# Confirm it is signed by this project and not merely by *someone* with a Developer ID:
codesign -dv --verbose=4 /Applications/Purr.app 2>&1 | grep TeamIdentifier
# expected: TeamIdentifier=5JCFRMC367
```

The in-app updater refuses to install a release that has no `.sha256` sidecar, checks the
download host, and verifies the codesign seal before swapping the bundle.

### Known limitations

Weaknesses I already know about:

- **The checksum sidecar shares an origin with the artifact.** `Purr.dmg.sha256` is published
  in the same GitHub release as `Purr.dmg`. That defends against corruption and interception
  in transit; it does **not** defend against a compromised GitHub account or token, since an
  attacker able to replace one file could replace both. An independent signature verified
  against an offline key is planned.
- **The install helper does not pin the signing identity.** Before swapping the bundle the
  helper runs `codesign --verify --deep --strict` on the app inside the downloaded DMG. That
  proves the bundle carries an intact, valid signature; it does **not** prove the signature
  is *Purr's*. Any bundle signed by any valid Developer ID would pass. Pinning the check to
  Team ID `5JCFRMC367` with `codesign -R` is the fix, and it is not yet in place.
- **Releases are built by hand on the maintainer's machine.** There is no CI, so there is no
  build provenance or attestation. See [RELEASING.md](RELEASING.md).
- **`Package.resolved` is not committed**, and Swift dependencies use `from:` version ranges,
  so builds are not byte-for-byte reproducible across machines or time.
- **Vendored SpeexDSP has not been audited or fuzzed.** `Sources/CEcho` contains SpeexDSP
  compiled from source with warnings suppressed (`-w`) and a hand-written `config.h`. It
  parses untrusted audio in meeting mode.
- **Model weights are third-party.** Purr verifies the Gemma GGUF against a pinned SHA-256
  and pins the llama.cpp XCFramework by checksum, but weights fetched by WhisperKit and
  FluidAudio are subject to those projects' own integrity handling.

These are the things I would attack first. If you find something worse, please tell me.

## Scope

**In scope:** the Purr application and this repository - the updater, model download and
verification, permission handling, the vendored C in `Sources/CEcho`, transcript storage,
and the signing and release pipeline.

**Out of scope:** vulnerabilities in upstream dependencies (report those to WhisperKit,
FluidAudio, llama.cpp, or SpeexDSP directly, though I would appreciate a heads-up), macOS
itself, and the fact that Purr requires the permissions documented above - that is a design
constraint, not a bug. Reports consisting only of automated scanner output with no
demonstrated impact will be closed.
