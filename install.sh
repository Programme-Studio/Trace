#!/bin/bash
# Builds Unbox, notarises it, and installs it.
#
#   ./install.sh            Developer ID + notarised. Use this.
#   ./install.sh --local    Apple Development signing, no notarisation. Faster
#                           (no ~2 minute wait), but macOS will refuse the
#                           default-browser slot through the supported API and
#                           the app won't appear in System Settings' browser
#                           list. Fine while iterating on code.
#
# Why notarisation matters here, given the app never leaves this Mac: macOS gates
# the default-browser slot on it. NSWorkspace.setDefaultApplication refuses a
# non-notarised app with "the file couldn't be opened", and System Settings won't
# list it. A notarised build takes the slot the supported way and keeps it.
#
# Never install by pressing ⌘R and using the app's "Move to Applications" button.
# ⌘R produces a Debug build: Xcode splits it into a stub executable plus a
# .debug.dylib plus a SwiftUI preview dylib and signs it with get-task-allow.
# LaunchServices records the result as "launch-disabled, no-info.plist" and the
# app half-works, which is harder to diagnose than not working at all.

set -euo pipefail
cd "$(dirname "$0")"

APP="Unbox.app"
DEST="/Applications/$APP"
BUNDLE_ID="uk.co.researchunit.unbox"
TEAM_ID="9BEEYHZT28"
NOTARY_PROFILE="Unbox"
# The stored notarytool credential predates the rename to Unbox. Re-creating it
# needs an app-specific password, so fall back to the old profile name rather
# than dead-ending a notarised build on a cosmetic change.
LEGACY_NOTARY_PROFILE="DropboxOpener"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

LOCAL_ONLY=0
[ "${1:-}" = "--local" ] && LOCAL_ONLY=1

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# Every registered copy of this bundle id. Paths can contain spaces, so no $2.
registrations() {
  "$LSREGISTER" -dump 2>/dev/null | awk -v id="$BUNDLE_ID" '
    /^path:/ {
      p = $0
      sub(/^path:[[:space:]]*/, "", p)
      sub(/ \(0x[0-9a-f]+\)$/, "", p)
      next
    }
    /^identifier:/ {
      v = $0
      sub(/^identifier:[[:space:]]*/, "", v)
      if (v == id && p != "" && p ~ /\.app$/) print p
      p = ""
    }' | sort -u
}

# ---------------------------------------------------------------- signing setup

if [ "$LOCAL_ONLY" = "1" ]; then
  SIGN_ID="Apple Development"
  echo "==> Local build (not notarised)."
else
  if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    cat <<'MSG'
No "Developer ID Application" certificate in your keychain.

Create one — it takes a minute and only has to be done once:

  Xcode → Settings… → Accounts → select "Peter Bruce" (team 9BEEYHZT28)
        → Manage Certificates… → + → Developer ID Application

Then re-run this script. To build without notarising meanwhile:

  ./install.sh --local
MSG
    exit 1
  fi
  SIGN_ID="Developer ID Application"

  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
     && xcrun notarytool history --keychain-profile "$LEGACY_NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> Using the pre-rename notarisation profile \"$LEGACY_NOTARY_PROFILE\"."
    echo "    Re-store it as \"$NOTARY_PROFILE\" when convenient."
    NOTARY_PROFILE="$LEGACY_NOTARY_PROFILE"
  fi

  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat <<MSG
No stored notarisation credentials named "$NOTARY_PROFILE".

Store them once with an app-specific password from appleid.apple.com
(Sign-In and Security → App-Specific Passwords):

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
    --apple-id "peter@researchunit.co.uk" \\
    --team-id "$TEAM_ID"

It will prompt for the app-specific password. Then re-run this script.
MSG
    exit 1
  fi
fi

# ------------------------------------------------------------------------ build

echo "==> Building Release (signing: $SIGN_ID)…"
xcodebuild -project Unbox.xcodeproj -scheme Unbox \
  -configuration Release -derivedDataPath "$BUILD/dd" \
  CONFIGURATION_BUILD_DIR="$BUILD/out" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  build >"$BUILD/log" 2>&1 \
  || { echo "Build failed:"; grep -E "error:" "$BUILD/log" | head -20; exit 1; }

# A correct Release bundle has exactly one file in Contents/MacOS. Anything else
# means a Debug build slipped through — the failure this script exists to stop.
COUNT=$(ls -1 "$BUILD/out/$APP/Contents/MacOS" | wc -l | tr -d ' ')
if [ "$COUNT" != "1" ]; then
  echo "Refusing to install: Contents/MacOS has $COUNT files, expected 1."
  ls -1 "$BUILD/out/$APP/Contents/MacOS"
  exit 1
fi

# Sparkle ships its helpers — Updater.app, Autoupdate and two XPC services —
# pre-signed by the Sparkle project, inside the framework's version directory
# where Xcode's embed phase doesn't reach. Notarisation rejects the lot ("not
# signed with a valid Developer ID certificate", "no secure timestamp"), which
# is exactly how this script failed the first time Sparkle was in the build:
# release.sh had the fix and this one didn't. Re-sign innermost-first; never
# with --deep, which Apple explicitly warns against.
SPARKLE="$BUILD/out/$APP/Contents/Frameworks/Sparkle.framework"
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
      --sign "$SIGN_ID" "$TARGET"
  done

  # The app's own seal covers the framework, so re-seal after touching it.
  codesign --force --timestamp --options=runtime \
    --preserve-metadata=entitlements,identifier \
    --sign "$SIGN_ID" "$BUILD/out/$APP"
fi

codesign --verify --deep --strict "$BUILD/out/$APP" \
  || { echo "Signature verification failed. Not installing."; exit 1; }

# Signature and notarisation checks both pass on a build that dies instantly on
# launch: v1.1 shipped signed, notarised and stapled, and crashed on
# "Library not loaded: @rpath/Sparkle.framework". Cheap to assert, impossible to
# catch any other way short of running it.
if otool -L "$BUILD/out/$APP/Contents/MacOS/Unbox" | grep -q "@rpath/Sparkle"; then
  otool -l "$BUILD/out/$APP/Contents/MacOS/Unbox" \
    | grep -A2 LC_RPATH | grep -q "@executable_path/../Frameworks" \
    || { echo "Sparkle is linked but there is no rpath into Contents/Frameworks."; exit 1; }
fi

# ------------------------------------------------------------------- notarise

if [ "$LOCAL_ONLY" = "0" ]; then
  echo "==> Notarising (usually under two minutes)…"
  ditto -c -k --keepParent "$BUILD/out/$APP" "$BUILD/upload.zip"

  if ! xcrun notarytool submit "$BUILD/upload.zip" \
        --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$BUILD/notary.log"; then
    echo "Notarisation submission failed — see above."
    exit 1
  fi

  if ! grep -q "status: Accepted" "$BUILD/notary.log"; then
    echo
    echo "Notarisation did not come back Accepted. Full log:"
    SUB=$(awk '/id:/ { print $2; exit }' "$BUILD/notary.log")
    [ -n "$SUB" ] && xcrun notarytool log "$SUB" --keychain-profile "$NOTARY_PROFILE" 2>&1 | head -40
    exit 1
  fi

  echo "==> Stapling the ticket…"
  xcrun stapler staple "$BUILD/out/$APP"

  echo "==> Verifying with Gatekeeper…"
  if ! spctl -a -vv -t exec "$BUILD/out/$APP" 2>&1 | grep -q accepted; then
    echo "Gatekeeper still rejects the build. Not installing."
    spctl -a -vv -t exec "$BUILD/out/$APP" 2>&1 | head
    exit 1
  fi
  echo "    accepted"
fi

# ------------------------------------------------------------------- install

echo "==> Quitting the running copy…"
osascript -e 'tell application "Unbox" to quit' 2>/dev/null || true
sleep 1
pkill -x Unbox 2>/dev/null || true
sleep 1

echo "==> Clearing old LaunchServices registrations…"
registrations | while read -r stale; do
  echo "    unregistering $stale"
  "$LSREGISTER" -u "$stale" 2>/dev/null || true
done
"$LSREGISTER" -u "$BUILD/out/$APP" 2>/dev/null || true

echo "==> Installing to ${DEST}…"
rm -rf "$DEST"
ditto "$BUILD/out/$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
"$LSREGISTER" -f -R -trusted "$DEST"
sleep 1

echo "==> Launching…"
open -a "$DEST"
sleep 2

echo
echo "Installed. Registered copies (should be exactly one):"
registrations | sed 's/^/    /'
echo
if [ "$LOCAL_ONLY" = "1" ]; then
  echo "This is a LOCAL build. macOS will refuse it the default-browser slot"
  echo "through the supported API, and won't list it in System Settings."
  echo "Re-run without --local before relying on it."
else
  echo "Notarised. Set it as your default browser either way:"
  echo "  • \"Make Unbox the default\" in the app's setup window, or"
  echo "  • System Settings → Desktop & Dock → Default web browser"
fi
