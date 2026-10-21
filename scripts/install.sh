#!/bin/sh
# Installs the latest Queen Bee release into /Applications, from a terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/bamboozledkitty/queen-bee/main/scripts/install.sh | sh
#
# Releases are signed with a Developer ID but not yet notarized by Apple, so a copy downloaded in a
# browser has to be approved in System Settings. A copy fetched here isn't marked as a browser download,
# so it opens straight away. In place of Apple's check, this script refuses anything that isn't signed
# by the Queen Bee developer's certificate: the disk image before it is opened, and the app inside it.
#
# QB_INSTALL_DIR puts the app somewhere other than /Applications.
set -eu

REPO="bamboozledkitty/queen-bee"
TEAM="M76T8VT55M"
BUNDLE_ID="dev.queenbee.app"
# What a signature has to prove: a Developer ID certificate that Apple issued to that team. The team name
# a signature prints is not enough. A signature made with any other kind of certificate can carry the same
# name, so the certificate chain itself is checked, up to Apple's root. The disk image is held to that,
# and the app inside it also has to be this app.
DEVELOPER_ID="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
and certificate leaf[subject.OU] = \"$TEAM\""
REQUIREMENT="=$DEVELOPER_ID and identifier \"$BUNDLE_ID\""
DMG_REQUIREMENT="=$DEVELOPER_ID"
# The release script checks what it built against these same two, so they are written only here.
if [ "${1:-}" = "--print-requirements" ]; then
  printf '%s\n%s\n' "$REQUIREMENT" "$DMG_REQUIREMENT"
  exit 0
fi
DEST_DIR="${QB_INSTALL_DIR:-/Applications}"

fail() { echo "install: $1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Queen Bee only runs on macOS."
[ "$(uname -m)" = "arm64" ] || fail "Queen Bee needs a Mac with Apple silicon."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || fail "Queen Bee needs macOS 26 or later."
[ -d "$DEST_DIR" ] && [ -w "$DEST_DIR" ] || fail "can't write to $DEST_DIR."
DEST_DIR=$(cd "$DEST_DIR" && pwd -P)
DEST="$DEST_DIR/QueenBee.app"
# Whatever the folder, the copy being replaced has to be closed. A copy open from somewhere else can stay open.
if ps -axo comm= | grep -qxF "$DEST/Contents/MacOS/QueenBee"; then
  fail "Queen Bee is open. Quit it, then run this again."
fi
# A run that stopped while swapping the app can leave the old copy set aside. It goes back first.
if [ -d "$DEST.old" ]; then
  if [ -d "$DEST" ]; then rm -rf "$DEST.old"; else mv "$DEST.old" "$DEST"; fi
fi

WORK=$(mktemp -d)
MOUNT="$WORK/mount"
cleanup() {
  hdiutil detach -quiet "$MOUNT" >/dev/null 2>&1 || true
  rm -rf "$WORK" "$DEST.new"
}
trap cleanup EXIT

echo "Finding the latest release..."
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | sed -n 's/.*"browser_download_url": *"\(https:[^"]*\.dmg\)".*/\1/p' | head -1)
[ -n "$URL" ] || fail "couldn't find a release to download."

echo "Downloading $(basename "$URL")..."
curl -fL --progress-bar -o "$WORK/QueenBee.dmg" "$URL"

echo "Checking the signature..."
# The disk image is checked before it is opened, so nothing but a Queen Bee release is ever mounted.
codesign --verify -R "$DMG_REQUIREMENT" "$WORK/QueenBee.dmg" 2>/dev/null \
  || fail "the download isn't signed with the Queen Bee developer's Developer ID certificate. Nothing was installed."

mkdir "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$WORK/QueenBee.dmg" >/dev/null 2>&1 \
  || fail "couldn't open the download."
[ -d "$MOUNT/QueenBee.app" ] || fail "the download doesn't contain Queen Bee."

codesign --verify --deep --strict "$MOUNT/QueenBee.app" 2>/dev/null || fail "the app's signature is broken. Nothing was installed."
codesign --verify --deep --strict -R "$REQUIREMENT" "$MOUNT/QueenBee.app" 2>/dev/null \
  || fail "the app isn't signed with the Queen Bee developer's Developer ID certificate. Nothing was installed."

echo "Installing to $DEST..."
rm -rf "$DEST.new"
ditto "$MOUNT/QueenBee.app" "$DEST.new" || fail "couldn't copy the app into $DEST_DIR. Nothing was changed."
codesign --verify --deep --strict -R "$REQUIREMENT" "$DEST.new" 2>/dev/null \
  || fail "the copy in $DEST_DIR doesn't match the signed app. Nothing was changed."
# The installed copy is set aside, not deleted, until the new one is in its place.
if [ -d "$DEST" ]; then
  mv "$DEST" "$DEST.old" || fail "couldn't move the installed copy aside. Nothing was changed."
fi
if ! mv "$DEST.new" "$DEST"; then
  if [ -d "$DEST.old" ]; then mv "$DEST.old" "$DEST"; fi
  fail "couldn't put the new copy in place. The copy you had is back where it was."
fi
rm -rf "$DEST.old"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DEST/Contents/Info.plist")
echo "Queen Bee $VERSION is installed. Open it from $DEST_DIR, or run: open \"$DEST\""
