#!/bin/sh
# Prints the Sparkle appcast for the version in Resources/Info.plist: one
# item whose notes are that version's CHANGELOG.md section, with a download
# link to Purr.dmg on its GitHub release (tag v<version>) and the DMG's EdDSA
# signature.
#
# usage: scripts/appcast.sh <dmg> <sign_update> <keychain account>
# Run by `make appcast`.
set -eu

DMG=$1
SIGN_UPDATE=$2
ACCOUNT=$3
REPO=https://github.com/iamarunbrahma/purr

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }
fail() { echo "appcast: $1" >&2; exit 1; }

VERSION=$(plist CFBundleShortVersionString Resources/Info.plist)
BUILD=$(plist CFBundleVersion Resources/Info.plist)
MIN_OS=$(plist LSMinimumSystemVersion Resources/Info.plist)

[ -f "$DMG" ] || fail "$DMG not found. Build it with make dmg first."
# The DMG holds a copy of dist/Purr.app, so a stale one shows up here.
[ "$(plist CFBundleVersion "$(dirname "$DMG")/Purr.app/Contents/Info.plist")" = "$BUILD" ] ||
    fail "$DMG wasn't built from this Info.plist. Run make dmg again."
grep -q "^## $VERSION - Unreleased" CHANGELOG.md && fail "Put the release date on the $VERSION section of CHANGELOG.md."

# The lines between "## <version> ..." and the next "## " heading.
NOTES=$(awk -v v="$VERSION" '/^## / { if (found) exit; found = ($2 == v); next } found && (NF || started) { started = 1; print }' CHANGELOG.md)
[ -n "$NOTES" ] || fail "CHANGELOG.md has no section for $VERSION."

# Prints: sparkle:edSignature="..." length="..."
SIGNATURE=$("$SIGN_UPDATE" --account "$ACCOUNT" "$DMG")
PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Purr</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO/blob/main/CHANGELOG.md</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[
$NOTES
]]></description>
      <enclosure url="$REPO/releases/download/v$VERSION/Purr.dmg" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
EOF
