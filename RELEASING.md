# Releasing Purr

The documented, repeatable process for cutting a Purr release. Written down because Purr
ships a Developer ID signed binary that runs with Accessibility and Input Monitoring
permissions - the release channel is the most security-sensitive part of the project, and it
should not live only in one person's head.

Current release cadence is ad hoc. There is one release line and users update in place
through the in-app updater.

## Prerequisites

One-time setup on the build machine:

| Requirement | Notes |
| --- | --- |
| Apple Silicon Mac, macOS 14+ | Purr is arm64-only |
| Full Xcode (not Command Line Tools) | The `@Generable` / `@Guide` FoundationModels macros need Xcode's compiler plugin |
| Apple Developer Program membership | Required for Developer ID signing and notarization |
| Developer ID Application certificate | Verify: `security find-identity -p codesigning -v` |
| `notarytool` keychain profile named `purr-app` | Create once, see below |

Create the notary profile:

```bash
xcrun notarytool store-credentials "purr-app" \
  --apple-id "<your-apple-id>" \
  --team-id "5JCFRMC367" \
  --password "<app-specific-password>"
```

Both `DEV_ID` and `NOTARY_PROFILE` can be overridden on the command line if they differ:

```bash
make dmg DEV_ID="Developer ID Application: ... (TEAMID)" NOTARY_PROFILE=other-profile
```

If Xcode is not at the default path:

```bash
make dmg DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer
```

### Credential handling

- The App Store Connect API private key (`AuthKey_*.p8`) is gitignored and **must never be
  committed**. Check `.gitignore` before adding any new credential file.
- The app-specific password lives in the login keychain via `notarytool store-credentials`.
  It is not stored in the repository.
- The Developer ID private key lives in the login keychain and should never be exported to
  the repository or to CI without a hardware-backed or secret-managed store.

## Release steps

### 1. Pick the version

Bump both keys in `Resources/Info.plist`:

- `CFBundleShortVersionString` - the user-visible version, e.g. `0.0.2`
- `CFBundleVersion` - the build number, monotonically increasing

The updater compares `CFBundleShortVersionString` against the GitHub release tag, so the
tag and this value must agree.

### 2. Pre-flight checks

```bash
git status --porcelain          # must be empty
git rev-parse --abbrev-ref HEAD # release from main
swift build -c release --arch arm64
```

Run the app once and exercise the three hotkeys (dictation, meeting, voice edit) on a real
machine. There is no automated test suite, so this manual pass is the only gate.

### 3. Build, sign, notarize, package

```bash
make clean
make dmg
```

`make dmg` performs the whole chain. In order:

1. `swift build -c release --arch arm64`
2. Assembles `dist/Purr.app` - binary, `Info.plist`, `PkgInfo`, icon, menu bar glyph
3. Copies in `llama.framework` and adds the `@executable_path/../Frameworks` rpath
4. Signs the embedded framework **first**, then the outer bundle - inside-out, no `--deep`,
   with `--options runtime` (Hardened Runtime) and `--timestamp`
5. Zips the app, submits to Apple's notary service, waits, staples the ticket
6. Builds the DMG from a staged folder with the pre-baked `.DS_Store` and Applications symlink
7. Converts to ULFO, signs the DMG, notarizes it, staples it
8. Computes `Purr.dmg.sha256` **last**, on the stapled image

Step 8 must come last. Stapling rewrites the DMG, so hashing before it would publish a
checksum that does not match what users download. The Makefile enforces this ordering.

Output: `dist/Purr.dmg` and `dist/Purr.dmg.sha256`.

### 4. Verify before publishing

Do not skip this. These are the same checks a user is told to run in [SECURITY.md](SECURITY.md).

```bash
cd dist
shasum -a 256 -c Purr.dmg.sha256
spctl -a -t open --context context:primary-signature -vv Purr.dmg
```

Then install from the DMG to a clean location and verify the app itself:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/Purr.app
spctl -a -t exec -vv /Applications/Purr.app     # expect: accepted, source=Notarized Developer ID
xcrun stapler validate /Applications/Purr.app
```

Confirm on a Mac that has never run Purr that a plain double-click opens it with no
right-click-to-Open workaround and no Gatekeeper warning.

### 5. Tag and publish

```bash
git tag -a v0.0.2 -m "v0.0.2"
git push origin v0.0.2
```

Create the GitHub release against that tag and attach **both** files:

- `Purr.dmg`
- `Purr.dmg.sha256`

The sidecar is not optional. The updater refuses to install a release that lacks it and
will surface an error to users instead of falling back.

The updater picks the **first asset whose name ends in `.dmg`** (case-insensitive), then
looks for a sidecar named exactly `<that-asset-name>.sha256`. So the DMG filename itself is
flexible, but the sidecar must match it exactly. Do not attach a second `.dmg` to a release
unless you are certain which one sorts first.

### 6. Post-release

- Verify the in-app updater sees the new version: **About Purr > Check for Updates** on a
  machine running the previous release, and let it complete a real in-place upgrade.
- Confirm Accessibility and Input Monitoring survive the update. Because releases are signed
  with a stable Developer ID, TCC should carry the grants across versions. Verify this on a
  real machine rather than assuming it - if the bundle ID or signing identity ever changes,
  users must re-grant, and that has to be called out in the release notes.
- Update the landing page ([purr-site](https://github.com/iamarunbrahma/purr-site)) if the
  release changes anything user-facing.

## Rolling back

There is no downgrade path in the updater. If a release is bad:

1. Delete the GitHub release immediately, or mark it as a pre-release, so the updater's
   `releases/latest` lookup stops returning it.
2. Publish a fixed release with a **higher** version number. Never re-tag or re-upload
   assets under an existing version - anyone who already pulled the old artifact would have
   a checksum mismatch, and re-used tags break the trust story.
3. If the bad release had a security impact, publish a GitHub Security Advisory.

## Known gaps

Known weaknesses in the process above, listed so nobody has to rediscover them.

- **No CI.** There is no `.github/` directory. Every release is built by hand on the
  maintainer's laptop, which is a single point of compromise for an application holding
  Input Monitoring permissions. There is no build provenance and no artifact attestation.
- **Not reproducible.** `Package.resolved` is gitignored and Swift dependencies float on
  `from:` ranges (`WhisperKit from 0.9.0`, `FluidAudio from 0.8.0`). Two builds from the same
  commit on different days can link different dependency versions. Committing
  `Package.resolved` and pinning exact versions is the fix.
- **Sidecar shares an origin with the artifact.** See the corresponding note in
  [SECURITY.md](SECURITY.md).
- **No automated tests.** Step 2's manual pass is the only functional gate before signing.
- **No dependency scanning.** Dependabot and CodeQL are not enabled.
