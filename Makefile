# Build a runnable Purr.app bundle from the SwiftPM executable.
#
# Why this Makefile exists: macOS gates the microphone, accessibility, and
# input-monitoring permissions on a real .app bundle with a code signature
# and an Info.plist. `swift run` ships a bare Mach-O without those, so TCC
# silently denies everything. This Makefile assembles a minimal .app and
# code-signs it so the OS will route TCC prompts to it.

APP_NAME      := Purr
BUNDLE_ID     := com.arunbrahma.purr
CONFIG        := release
BUILD_DIR     := .build
APP_DIR       := dist/$(APP_NAME).app
DMG           := dist/$(APP_NAME).dmg
DMG_RW        := dist/$(APP_NAME)-rw.dmg
DMG_STAGE     := dist/dmg-stage
DMG_MNT       := dist/dmg-mnt
DMG_BG        := Resources/dmg-launch-window.png
# Pre-baked Finder window settings (window bounds, icon positions, background
# picture pointer). Copied verbatim into every DMG so layout no longer depends
# on osascript + Finder, which fails intermittently on macOS Sequoia/Tahoe
# (TCC Automation prompts, AppleEvent timeouts, hdiutil-vs-Finder races - see
# create-dmg/create-dmg issues #72, #154, #185).
DMG_DS_STORE  := Resources/dmg-DS_Store
CONTENTS      := $(APP_DIR)/Contents
MACOS_DIR     := $(CONTENTS)/MacOS
RES_DIR       := $(CONTENTS)/Resources
FRAMEWORKS_DIR:= $(CONTENTS)/Frameworks
ENTITLEMENTS  := Resources/$(APP_NAME).entitlements
INFO_PLIST    := Resources/Info.plist
# Developer ID code-signing identity and notarization keychain profile. The
# identity must exist in the login keychain (verify with
# `security find-identity -p codesigning -v`); the profile is created once with
# `xcrun notarytool store-credentials`. Override either on the command line.
DEV_ID         ?= Developer ID Application: Arun Brahma (5JCFRMC367)
NOTARY_PROFILE ?= purr-app
# llama.cpp is shipped as an XCFramework binary target. SwiftPM stages
# the macOS-arm64 slice next to the built executable; we copy that into
# the bundle's Frameworks/ and add the rpath the executable needs to
# find it at runtime (the linker's default @loader_path works when the
# binary sits beside the framework, but the .app layout splits them).
LLAMA_FRAMEWORK_SRC := $(BUILD_DIR)/arm64-apple-macosx/$(CONFIG)/llama.framework

# The @Generable / @Guide macros (FoundationModels) need Xcode's compiler
# plugin (libFoundationModelsMacros), which the standalone Command Line
# Tools toolchain does not ship - `swift build` under CLT fails with
# "plugin for module 'FoundationModelsMacros' not found". Pin the build to
# Xcode's toolchain. Override on the command line if Xcode lives elsewhere:
# `make dmg DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer`.
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

.PHONY: app run dmg notarize-app clean

app:
	swift build -c $(CONFIG) --arch arm64
	@mkdir -p $(MACOS_DIR) $(RES_DIR) $(FRAMEWORKS_DIR)
	@cp $(BUILD_DIR)/arm64-apple-macosx/$(CONFIG)/$(APP_NAME) $(MACOS_DIR)/$(APP_NAME)
	@cp $(INFO_PLIST) $(CONTENTS)/Info.plist
	@# Legacy package-type marker that every standard .app carries; some macOS
	@# subsystems still read it. Cheap to include, and a hand-assembled SwiftPM
	@# bundle omits it by default.
	@printf 'APPL????' > $(CONTENTS)/PkgInfo
	@cp Resources/AppIcon.icns $(RES_DIR)/AppIcon.icns
	@cp Resources/purr_menubar_glyph.pdf $(RES_DIR)/purr_menubar_glyph.pdf
	@# Embed llama.cpp dynamic framework. -R preserves the Headers ->
	@# Versions/Current/Headers symlinks; dereferencing them (cp -RHL)
	@# flattens the framework into a layout codesign rejects as
	@# ambiguous. -p keeps perms/timestamps so the signature stays
	@# reproducible across builds.
	@rm -rf $(FRAMEWORKS_DIR)/llama.framework
	@cp -Rp $(LLAMA_FRAMEWORK_SRC) $(FRAMEWORKS_DIR)/llama.framework
	@# Add @executable_path/../Frameworks to the binary's rpath. Quiet if
	@# already present (re-runs of `make app` would otherwise fail).
	@install_name_tool -add_rpath @executable_path/../Frameworks $(MACOS_DIR)/$(APP_NAME) 2>/dev/null || true
	@# Sign the embedded framework first so the nested code is already valid
	@# when we sign the outer bundle (no --deep: Apple recommends signing
	@# inside-out for distribution). --options runtime turns on the Hardened
	@# Runtime that notarization requires; --timestamp adds a secure timestamp.
	@codesign --force --options runtime --timestamp --sign "$(DEV_ID)" $(FRAMEWORKS_DIR)/llama.framework
	@codesign --force --options runtime --timestamp --sign "$(DEV_ID)" --entitlements $(ENTITLEMENTS) $(APP_DIR)
	@# Bump the bundle's mtime. macOS keys its icon/LaunchServices cache on the
	@# bundle modification date; copying a new AppIcon.icns into an existing
	@# .app leaves the bundle dir mtime stale, so Finder keeps serving the old
	@# cached icon. Touching the bundle invalidates that cache on next read.
	@touch $(APP_DIR)
	@echo "Built $(APP_DIR) - open it once from Finder so macOS registers the bundle, then permissions can be granted in System Settings."

run: app
	open $(APP_DIR)

# Notarize the .app: zip it, submit to Apple's notary service, wait for the
# ticket, then staple it onto the bundle so the app passes Gatekeeper offline
# even after the updater copies it out of the DMG into /Applications.
notarize-app: app
	@ditto -c -k --keepParent $(APP_DIR) $(APP_DIR).zip
	@xcrun notarytool submit $(APP_DIR).zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	@xcrun stapler staple $(APP_DIR)
	@rm -f $(APP_DIR).zip

# Wraps the signed app bundle in a compressed read-only .dmg, notarizes the
# app and the disk image, and staples both, so Gatekeeper accepts a normal
# double-click (no right-click -> Open needed). Needs DEV_ID + NOTARY_PROFILE.
#
# The DMG is laid out as a "drag to Applications" install window: a custom
# background image with a curved arrow plus an Applications symlink. The
# Finder window settings (icon positions + background picture) live in a
# pre-baked .DS_Store (Resources/dmg-DS_Store) we copy in directly. That
# replaces the old osascript+Finder dance which silently failed on macOS
# Sequoia/Tahoe (TCC Automation, hdiutil-vs-Finder races) and shipped
# DMGs without the custom window ~30% of the time.
dmg: notarize-app
	@rm -rf $(DMG) $(DMG_RW) $(DMG_STAGE)
	@mkdir -p $(DMG_STAGE)/.background
	@cp -R $(APP_DIR) $(DMG_STAGE)/
	@cp $(DMG_BG) $(DMG_STAGE)/.background/background.png
	@cp $(DMG_DS_STORE) $(DMG_STAGE)/.DS_Store
	@# Volume icon: Finder shows .VolumeIcon.icns for the mounted disk (and the
	@# .dmg file itself) once the volume root carries the kHasCustomIcon bit.
	@cp Resources/AppIcon.icns $(DMG_STAGE)/.VolumeIcon.icns
	@ln -s /Applications $(DMG_STAGE)/Applications
	@hdiutil create -volname "$(APP_NAME)" \
	  -srcfolder $(DMG_STAGE) \
	  -ov -format UDRW \
	  -fs HFS+ \
	  $(DMG_RW) >/dev/null
	@# Set kHasCustomIcon on the volume root so .VolumeIcon.icns takes effect.
	@# Done by mounting the read-write image and writing the attribute directly
	@# (SetFile, not osascript/Finder), so it keeps the AppleEvents-free
	@# guarantee that motivated the pre-baked .DS_Store.
	@rm -rf $(DMG_MNT) && mkdir -p $(DMG_MNT)
	@hdiutil attach $(DMG_RW) -nobrowse -noverify -noautoopen -mountpoint $(DMG_MNT) >/dev/null
	@SetFile -a C $(DMG_MNT)
	@hdiutil detach $(DMG_MNT) >/dev/null
	@rmdir $(DMG_MNT)
	@# ULFO (LZFSE) decompresses in-kernel and mounts faster than UDZO
	@# zlib-9, so Finder renders the window icons with less first-open lag.
	@# Requires macOS 10.11+ (we target 14+); the image is also slightly smaller.
	@hdiutil convert $(DMG_RW) -format ULFO -o $(DMG) >/dev/null
	@rm -rf $(DMG_RW) $(DMG_STAGE)
	@# Code-sign the disk image itself (Developer ID + secure timestamp) before
	@# notarizing, so the notary ticket covers the image and `spctl -a -t open`
	@# accepts the DMG directly. Apple doesn't require a signed DMG, but signing
	@# folds the image into the ticket for a clean Gatekeeper assessment. Order
	@# matters: sign -> notarize -> staple.
	@codesign --force --timestamp --sign "$(DEV_ID)" $(DMG)
	@# Notarize the disk image and staple the ticket onto it so the DMG is
	@# recognized offline. Stapling rewrites the DMG, so it MUST happen before
	@# the sha256 below or the published hash won't match the shipped file.
	@xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	@xcrun stapler staple $(DMG)
	@# Sidecar SHA-256 published alongside the DMG. The Updater fetches this
	@# file from the GitHub release and verifies the downloaded DMG against it
	@# BEFORE invoking the install helper. Computed last, on the stapled image,
	@# so it matches what users download. Format is `<hex>  Purr.dmg\n`, matching
	@# `shasum -a 256` output so anyone can `shasum -a 256 -c` it manually.
	@shasum -a 256 "$(DMG)" | awk '{ printf "%s  $(APP_NAME).dmg\n", $$1 }' > $(DMG).sha256
	@echo "Built $(DMG) ($$(du -h $(DMG) | cut -f1)) + $(DMG).sha256"

clean:
	rm -rf $(BUILD_DIR) dist
