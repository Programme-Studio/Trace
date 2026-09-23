#!/bin/bash
# Cuts a release: bumps the version, builds, notarises, signs the update,
# regenerates the appcast and publishes both to GitHub Releases.
#
#   ./release.sh 1.1          marketing version; build number auto-increments
#   ./release.sh 1.1 --dry    everything except the GitHub upload
#
# Sparkle refuses an update whose EdDSA signature doesn't verify against the
# SUPublicEDKey in the shipped app, so the private key must be present in the
# login Keychain (put there once by Sparkle's generate_keys). It is never in
# this repo.

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
DRY=0
[ "${2:-}" = "--dry" ] && DRY=1

if [ -z "$VERSION" ]; then
  echo "usage: ./release.sh <version> [--dry]" >&2
  exit 1
fi

APP="Trace.app"
PLIST="Trace/Info.plist"
TEAM_ID="9BEEYHZT28"
NOTARY_PROFILE="Trace"
LEGACY_NOTARY_PROFILE="DropboxOpener"
REPO="Programme-Studio/Trace"
# Where the appcast tells Sparkle to fetch builds from. GitHub rewrites
# /releases/latest/download/<name> to the newest release's asset, so the feed
# URL in Info.plist never has to change.
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/v$VERSION/"

TOOLS="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)"
if [ -z "$TOOLS" ]; then
  echo "Sparkle's tools aren't in DerivedData yet. Run:" >&2
  echo "  xcodebuild -project Trace.xcodeproj -scheme Trace -resolvePackageDependencies" >&2
  exit 1
fi

# ---------------------------------------------------------------- version bump
OLD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
OLD_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
BUILD=$(( OLD_BUILD + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
echo "==> Version $VERSION (build $BUILD)"

# A rehearsal must not leave the version bumped, or repeated dry runs march the
# build number forward and the real release starts from the wrong place.
restore_version() {
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $OLD_VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $OLD_BUILD" "$PLIST"
}
[ "$DRY" = "1" ] && trap 'restore_version; echo "  (version restored to $OLD_VERSION build $OLD_BUILD)"' EXIT

# ------------------------------------------------------------ build + notarise
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
   && xcrun notarytool history --keychain-profile "$LEGACY_NOTARY_PROFILE" >/dev/null 2>&1; then
  NOTARY_PROFILE="$LEGACY_NOTARY_PROFILE"
fi

echo "==> Building Release (Developer ID)…"
xcodebuild -project Trace.xcodeproj -scheme Trace \
  -configuration Release -derivedDataPath "$BUILD_DIR/dd" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR/out" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  -quiet

# Sparkle ships its helpers — Updater.app, Autoupdate and two XPC services —
# pre-signed by the Sparkle project, and they live *inside* the framework's
# version directory where Xcode's embed phase doesn't reach. Notarisation
# rejects the lot ("not signed with a valid Developer ID certificate", "no
# secure timestamp"). Re-sign them with this Developer ID, innermost first;
# never with --deep, which Apple explicitly warns against.
SPARKLE="$BUILD_DIR/out/$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  echo "==> Re-signing Sparkle's nested helpers…"
  for TARGET in \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/Updater.app" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE/Versions/B/Sparkle" \
    "$SPARKLE"
  do
    [ -e "$TARGET" ] || continue
    codesign --force --timestamp --options=runtime \
      --preserve-metadata=entitlements,identifier \
      --sign "Developer ID Application" "$TARGET"
  done

  # The app's own seal covers the framework, so it has to be re-sealed after.
  codesign --force --timestamp --options=runtime \
    --preserve-metadata=entitlements,identifier \
    --sign "Developer ID Application" "$BUILD_DIR/out/$APP"
fi

codesign --verify --deep --strict "$BUILD_DIR/out/$APP" \
  || { echo "Signature verification failed before notarising." >&2; exit 1; }

echo "==> Notarising…"
ditto -c -k --keepParent "$BUILD_DIR/out/$APP" "$BUILD_DIR/upload.zip"
xcrun notarytool submit "$BUILD_DIR/upload.zip" \
  --keychain-profile "$NOTARY_PROFILE" --wait | tee "$BUILD_DIR/notary.log"
grep -q "status: Accepted" "$BUILD_DIR/notary.log" || { echo "Notarisation failed." >&2; exit 1; }

xcrun stapler staple "$BUILD_DIR/out/$APP"
spctl -a -t exec -vv "$BUILD_DIR/out/$APP" 2>&1 | grep -q "accepted" \
  || { echo "Gatekeeper rejected the build." >&2; exit 1; }

# --------------------------------------------------------- package + sign + feed
# The zip has to be made *after* stapling, so the ticket travels with the app —
# a Sparkle-installed copy is never re-downloaded through Gatekeeper's online
# check, so an unstapled build would be quarantined on a machine that's offline.
RELEASES="$BUILD_DIR/releases"
mkdir -p "$RELEASES"
ZIP="$RELEASES/Trace-$VERSION.zip"
ditto -c -k --keepParent "$BUILD_DIR/out/$APP" "$ZIP"

# Does it actually run? Everything above this line can pass on a build that
# crashes on launch: v1.1 shipped signed, notarised, stapled and universal, and
# died instantly on `Library not loaded: @rpath/Sparkle.framework` because the
# binary had no rpath into Contents/Frameworks. Signature checks cannot catch
# that. Launch it.
echo "==> Smoke test: launching the built app…"
"$BUILD_DIR/out/$APP/Contents/MacOS/Trace" >"$BUILD_DIR/launch.log" 2>&1 &
SMOKE_PID=$!
sleep 6
if kill -0 "$SMOKE_PID" 2>/dev/null; then
  kill "$SMOKE_PID" 2>/dev/null || true
  wait "$SMOKE_PID" 2>/dev/null || true
  echo "    still running after 6s — good"
  # The build and the launch both registered this temp copy with
  # LaunchServices as an https handler, and the temp dir is deleted on exit —
  # which would leave exactly the dead duplicate registration that makes link
  # clicks go missing. install.sh clears it; this has to as well.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$BUILD_DIR/out/$APP" 2>/dev/null || true
else
  echo "Smoke test FAILED: the app exited on launch." >&2
  sed 's/^/    /' "$BUILD_DIR/launch.log" >&2
  exit 1
fi

# Every dylib it references must resolve inside the bundle.
if otool -L "$BUILD_DIR/out/$APP/Contents/MacOS/Trace" | grep -q "@rpath/Sparkle"; then
  otool -l "$BUILD_DIR/out/$APP/Contents/MacOS/Trace" \
    | grep -A2 LC_RPATH | grep -q "@executable_path/../Frameworks" \
    || { echo "Sparkle is linked but there is no rpath into Contents/Frameworks." >&2; exit 1; }
fi

ARCHS_BUILT=$(lipo -archs "$BUILD_DIR/out/$APP/Contents/MacOS/Trace")
echo "==> Architectures: $ARCHS_BUILT"
case "$ARCHS_BUILT" in
  *arm64*x86_64*|*x86_64*arm64*) ;;
  *) echo "Not a universal binary — Intel Macs could not run this." >&2; exit 1 ;;
esac

echo "==> Signing the update and generating the appcast…"
"$TOOLS/generate_appcast" --download-url-prefix "$DOWNLOAD_PREFIX" "$RELEASES"

APPCAST="$RELEASES/appcast.xml"
[ -f "$APPCAST" ] || { echo "generate_appcast produced no appcast." >&2; exit 1; }
grep -q 'sparkle:edSignature' "$APPCAST" || { echo "Appcast is unsigned." >&2; exit 1; }

if [ "$DRY" = "1" ]; then
  echo
  echo "Dry run. Built, notarised and signed but nothing was published."
  echo "  app     : $BUILD_DIR/out/$APP"
  echo "  zip     : $ZIP"
  echo "  appcast : $APPCAST"
  cp "$APPCAST" "./appcast-preview.xml"
  echo "  (copied the appcast to ./appcast-preview.xml)"
  trap 'restore_version; echo "  (version restored to $OLD_VERSION build $OLD_BUILD)"' EXIT
  echo "  build dir kept at $BUILD_DIR"
  exit 0
fi

# ------------------------------------------------------------------- publish
echo "==> Publishing v$VERSION to ${REPO}…"
git add -A
git commit -m "Release $VERSION (build $BUILD)" || true
git tag -f "v$VERSION"
git push origin HEAD --tags

gh release create "v$VERSION" "$ZIP" "$APPCAST" \
  --repo "$REPO" \
  --title "Trace $VERSION" \
  --notes "Trace $VERSION (build $BUILD)" \
  || gh release upload "v$VERSION" "$ZIP" "$APPCAST" --repo "$REPO" --clobber

echo
echo "Released v$VERSION."
echo "Existing installs will offer it within a day, or immediately via"
echo "Check for Updates."
