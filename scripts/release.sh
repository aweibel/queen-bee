#!/bin/sh
# Builds a release of the version in project.yml: signs it with a Developer ID, has Apple notarize it, packs it
# in a disk image and writes the update feed. With "publish" it then puts it on GitHub and updates the feed.
#
#   ./scripts/release.sh check      only the checks below and what publish would do next; builds and changes nothing
#   ./scripts/release.sh            build, sign, notarize and write the feed; everything lands in dist/<version>/
#   ./scripts/release.sh publish    the same, then release it on GitHub, tag it and push appcast.xml
#
# Publishing goes in an order where a step that fails leaves nothing pointing at a missing download: a draft
# release with the disk image, the tag, the release made public, and only then appcast.xml, which is what
# every installed copy reads. Run "publish" again after a failure and it carries on from the step that failed,
# reusing the disk image in dist/ once GitHub has a copy of it.
#
# Before anything is built it checks that the version is the same in project.yml, MCP.swift and the plugin's
# manifest, that CURRENT_PROJECT_VERSION is above every build in appcast.xml (Sparkle compares those, so a
# release that misses the bump is offered to nobody) and, to publish, that the tree is clean and on main or
# release/<version> (QB_RELEASE_BRANCH names another).
#
# The shipped releases so far were made with QB_SKIP_NOTARIZE=1, which leaves out notarization, for when there
# is no active Apple Developer membership. People then have to approve the app in System Settings the first
# time they open it.
#
# Needs: a "Developer ID Application" certificate for the team in scripts/install.sh in the keychain, a
# notarytool profile (xcrun notarytool store-credentials queenbee-notary), the Sparkle update key in the
# keychain (generate_keys --account queen-bee), and gh signed in.
set -eu
cd "$(dirname "$0")/.."

MODE="${1:-build}"
case "$MODE" in
  check|build|publish) ;;
  *) echo "usage: $0 [check|publish]" >&2; exit 2 ;;
esac

REPO="${QB_REPO:-bamboozledkitty/queen-bee}"
NOTARY_PROFILE="${QB_NOTARY_PROFILE:-queenbee-notary}"
SPARKLE_ACCOUNT="${QB_SPARKLE_ACCOUNT:-queen-bee}"

VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)
TAG="v$VERSION"
APP=build/Build/Products/Release/QueenBee.app
OUT="dist/$VERSION"
DMG="$OUT/QueenBee-$VERSION.dmg"
SPARKLE=build/SourcePackages/artifacts/sparkle/Sparkle/bin
# What the terminal installer holds a release to, from the installer itself, so the two can't disagree.
REQUIREMENT=$(sh scripts/install.sh --print-requirements | sed -n 1p)
DMG_REQUIREMENT=$(sh scripts/install.sh --print-requirements | sed -n 2p)
TEAM=$(sed -n 's/^TEAM="\(.*\)"$/\1/p' scripts/install.sh)

fail() { echo "release: $1" >&2; exit 1; }
ok() { echo "  ok  $1"; }

echo "== Checking $VERSION (build $BUILD)"
[ -n "$VERSION" ] || fail "project.yml has no MARKETING_VERSION."
case "$BUILD" in
  ''|*[!0-9]*) fail "CURRENT_PROJECT_VERSION in project.yml has to be a whole number, not \"$BUILD\"." ;;
esac
[ -n "$REQUIREMENT" ] && [ -n "$DMG_REQUIREMENT" ] && [ -n "$TEAM" ] \
  || fail "couldn't read the signing requirements from scripts/install.sh."

MCP_VERSION=$(sed -n 's/.*public static let version = "\(.*\)".*/\1/p' Core/Sources/QueenBeeCore/MCP.swift)
PLUGIN_VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' Plugin/qb-link/.claude-plugin/plugin.json)
[ "$MCP_VERSION" = "$VERSION" ] && [ "$PLUGIN_VERSION" = "$VERSION" ] || fail "the version isn't the same everywhere: \
project.yml says $VERSION, Core/Sources/QueenBeeCore/MCP.swift says ${MCP_VERSION:-nothing}, \
Plugin/qb-link/.claude-plugin/plugin.json says ${PLUGIN_VERSION:-nothing}."
ok "project.yml, MCP.swift and plugin.json all say $VERSION"
grep -q "^## \[$VERSION\]" CHANGELOG.md || fail "CHANGELOG.md has no section for $VERSION."
ok "CHANGELOG.md has a section for $VERSION"

# The commit a release is built from. Once its appcast.xml commit is made, that is the commit before it.
SOURCE=$(git rev-parse HEAD)
FEED_COMMITTED=no
if grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" appcast.xml; then
  [ "$(git log -1 --format=%s)" = "Release $TAG" ] && [ "$(git diff --name-only HEAD^ HEAD)" = "appcast.xml" ] \
    || fail "appcast.xml already lists $VERSION, and the last commit isn't the release's own \"Release $TAG\". \
Raise MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml."
  SOURCE=$(git rev-parse HEAD^)
  FEED_COMMITTED=yes
else
  NEWEST=$(sed -n 's/.*<sparkle:version>\([0-9]*\)<\/sparkle:version>.*/\1/p' appcast.xml | sort -n | tail -1)
  [ "$BUILD" -gt "${NEWEST:-0}" ] || fail "CURRENT_PROJECT_VERSION is $BUILD, but appcast.xml already has build \
${NEWEST:-0}. Sparkle only offers a higher build, so raise CURRENT_PROJECT_VERSION in project.yml."
  ok "build $BUILD is above the newest build in appcast.xml (${NEWEST:-none})"
fi

# A tag may only ever name the commit this release is built from.
LOCAL_TAG=$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)
[ -z "$LOCAL_TAG" ] || [ "$LOCAL_TAG" = "$SOURCE" ] || fail "$TAG already exists, on another commit. \
Raise MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml."

if [ "$MODE" = "build" ]; then
  [ -z "$LOCAL_TAG" ] && [ "$FEED_COMMITTED" = no ] \
    || fail "$TAG is already being released. Run '$0 publish' to finish it, or raise the version."
else
  BRANCH=$(git symbolic-ref -q --short HEAD || true)
  if [ -n "${QB_RELEASE_BRANCH:-}" ]; then
    [ "$BRANCH" = "$QB_RELEASE_BRANCH" ] || fail "this is ${BRANCH:-a detached HEAD}, not $QB_RELEASE_BRANCH."
  else
    [ "$BRANCH" = main ] || [ "$BRANCH" = "release/$VERSION" ] \
      || fail "release from main or release/$VERSION, not ${BRANCH:-a detached HEAD}. QB_RELEASE_BRANCH names another."
  fi
  [ -z "$(git status --porcelain)" ] || fail "the tree has changes that aren't committed. A release is built from a commit."
  ok "on $BRANCH, with nothing uncommitted"
  command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || fail "gh isn't installed or isn't signed in."

  # Where an earlier run got to. Each of these is looked up, never assumed, so a run can pick up from any of them.
  RELEASE_ERR=$(mktemp)
  if RELEASE=$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq 'if .isDraft then "draft" else "public" end' 2>"$RELEASE_ERR"); then
    :
  elif grep -q "not found" "$RELEASE_ERR"; then
    RELEASE=none
  else
    cat "$RELEASE_ERR" >&2; rm -f "$RELEASE_ERR"; fail "couldn't ask GitHub about $TAG."
  fi
  rm -f "$RELEASE_ERR"
  REMOTE_TAG=$(git ls-remote --tags origin "refs/tags/$TAG^{}" | cut -f1)
  [ -n "$REMOTE_TAG" ] || REMOTE_TAG=$(git ls-remote --tags origin "refs/tags/$TAG" | cut -f1)
  [ -z "$REMOTE_TAG" ] || [ "$REMOTE_TAG" = "$SOURCE" ] || fail "$TAG on GitHub names another commit. \
Raise MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml."
  REMOTE_HEAD=$(git ls-remote origin "refs/heads/$BRANCH" | cut -f1)
  if [ -n "$REMOTE_HEAD" ] && ! git cat-file -e "$REMOTE_HEAD^{commit}" 2>/dev/null; then
    git fetch -q origin "$BRANCH"
  fi
  FEED_PUSHED=no
  if [ "$FEED_COMMITTED" = yes ] && [ -n "$REMOTE_HEAD" ] && git merge-base --is-ancestor HEAD "$REMOTE_HEAD"; then
    FEED_PUSHED=yes
  elif [ -n "$REMOTE_HEAD" ] && ! git merge-base --is-ancestor "$REMOTE_HEAD" HEAD; then
    # Found now rather than at the last step, when the release would already be public.
    fail "$BRANCH on GitHub has commits this one doesn't. Pull them first (git pull --rebase)."
  fi
  echo "  GitHub release: $RELEASE, tag on GitHub: ${REMOTE_TAG:+yes}${REMOTE_TAG:-no}, appcast.xml committed: $FEED_COMMITTED, pushed: $FEED_PUSHED"

  if [ "$RELEASE" = public ] && [ "$FEED_PUSHED" = yes ]; then
    echo "$TAG is released and the feed is pushed. Nothing is left to do."
    [ "$MODE" = check ] && fail "raise MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml for the next release."
    exit 0
  fi
  [ "$FEED_COMMITTED" = no ] || [ "$RELEASE" != none ] || fail "appcast.xml lists $TAG, but GitHub has no release for it. \
Undo the \"Release $TAG\" commit (git reset --hard HEAD^, if it isn't pushed) and publish again."
  # The release is public and its feed committed: all that is left is pushing.
  if [ "$RELEASE" = public ] && [ "$FEED_COMMITTED" = yes ]; then
    if [ "$MODE" = check ]; then echo "Publish would push the tag and the \"Release $TAG\" commit."; exit 0; fi
    echo "== Pushing the feed for $TAG"
    [ -n "$LOCAL_TAG" ] || git tag "$TAG" "$SOURCE"
    [ -n "$REMOTE_TAG" ] || git push -q origin "refs/tags/$TAG"
    git push -q origin HEAD
    echo "Pushed appcast.xml for $TAG to $BRANCH."
    exit 0
  fi
fi

# A disk image GitHub already has is the one the feed has to describe, so it is never rebuilt. Nor is one
# built from this same commit by an earlier run, unless QB_REBUILD=1.
REUSE=no
if [ "$MODE" != build ] && [ -f "$DMG" ] && [ -f "$OUT/appcast.xml" ] && [ "$(cat "$OUT/built-from" 2>/dev/null)" = "$SOURCE" ]; then
  if [ "$RELEASE" != none ] || [ "$FEED_COMMITTED" = yes ] || [ "${QB_REBUILD:-}" != 1 ]; then REUSE=yes; fi
fi
if [ "$MODE" != build ] && [ "$REUSE" = no ] && { [ "$RELEASE" != none ] || [ "$FEED_COMMITTED" = yes ]; }; then
  fail "GitHub already has a disk image for $TAG, but $OUT doesn't hold the one built from $SOURCE. \
Delete the draft release on GitHub and publish again, or finish it by hand."
fi

if [ "$REUSE" = no ]; then
  command -v xcodegen >/dev/null || fail "xcodegen isn't installed: brew install xcodegen"
  if [ -n "${QB_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$QB_SIGN_IDENTITY"
  else
    # The certificate's own hash, so a second Developer ID in the keychain can't make the choice ambiguous.
    IDENTITY=$(security find-identity -v -p codesigning \
      | sed -n "s/.*) \([0-9A-F]\{40\}\) \"Developer ID Application: .* ($TEAM)\"$/\1/p" | head -1)
    [ -n "$IDENTITY" ] || fail "the keychain has no Developer ID Application certificate for team $TEAM."
  fi
  ok "signing with the Developer ID certificate for team $TEAM"
  security find-generic-password -a "$SPARKLE_ACCOUNT" -s https://sparkle-project.org >/dev/null 2>&1 \
    || fail "the keychain has no Sparkle update key for $SPARKLE_ACCOUNT. Make one with generate_keys --account $SPARKLE_ACCOUNT."
  ok "the Sparkle update key for $SPARKLE_ACCOUNT is in the keychain"
fi

if [ "$MODE" = check ]; then
  if [ "$REUSE" = yes ]; then echo "Publish would use $DMG, built from $SOURCE by an earlier run, and release it."
  else echo "Publish would build $VERSION from $SOURCE, then release it."; fi
  exit 0
fi

if [ "$REUSE" = yes ]; then
  echo "== Using $DMG, built from $SOURCE by an earlier run"
  codesign --verify -R "$DMG_REQUIREMENT" "$DMG" 2>/dev/null \
    || fail "$DMG isn't signed the way scripts/install.sh requires."
else
  echo "== Building $VERSION"
  xcodegen generate --quiet
  # An app left by an earlier build must never be mistaken for this one, so it is removed first
  # and the build has to say it succeeded.
  rm -rf "$APP"
  BUILD_LOG=$(mktemp)
  xcodebuild -project QueenBee.xcodeproj -scheme QueenBee -configuration Release \
    -derivedDataPath build -skipPackagePluginValidation -skipMacroValidation build > "$BUILD_LOG" 2>&1 || true
  grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$BUILD_LOG" || true
  grep -q "BUILD SUCCEEDED" "$BUILD_LOG" || { rm -f "$BUILD_LOG"; fail "the release build failed. Nothing was packaged."; }
  rm -f "$BUILD_LOG"
  [ -d "$APP" ] || fail "the build didn't produce $APP."
  BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
  [ "$BUILT" = "$VERSION" ] || fail "the built app says $BUILT, not $VERSION."
  BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
  [ "$BUILT" = "$BUILD" ] || fail "the built app is build $BUILT, not $BUILD."

  echo "== Signing"
  # Inside out: Sparkle's helpers, the framework, our helper, then the app.
  sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
  FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
  sign "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
  sign "$FRAMEWORK/Versions/B/Autoupdate"
  sign "$FRAMEWORK/Versions/B/Updater.app"
  sign "$FRAMEWORK"
  sign "$APP/Contents/MacOS/qb"
  sign "$APP"
  # The same check the terminal installer makes, so a release it would refuse never goes out.
  codesign --verify --deep --strict -R "$REQUIREMENT" "$APP" \
    || fail "the app isn't signed the way scripts/install.sh requires."

  if [ "${QB_SKIP_NOTARIZE:-}" = "1" ]; then
    echo "== Skipping notarization (QB_SKIP_NOTARIZE=1)"
    notarize() { :; }
    staple() { :; }
    assess() { :; }
  else
    notarize() { xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait; }
    staple() { xcrun stapler staple "$1"; }
    assess() { spctl --assess "$@"; }
  fi

  echo "== Notarizing the app"
  # The app first, so the copy people drag out of the disk image carries its own ticket and opens offline.
  rm -rf "$OUT" && mkdir -p "$OUT"
  ditto -c -k --keepParent "$APP" "$OUT/app.zip"
  notarize "$OUT/app.zip"
  rm "$OUT/app.zip"
  staple "$APP"
  assess --type execute -vv "$APP"

  echo "== Building the disk image"
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "Queen Bee" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  codesign --verify -R "$DMG_REQUIREMENT" "$DMG" || fail "the disk image isn't signed the way scripts/install.sh requires."
  notarize "$DMG"
  staple "$DMG"
  assess --type open --context context:primary-signature -vv "$DMG"

  echo "== Writing the update feed"
  # The notes for this version are its section of the changelog.
  awk -v v="$VERSION" '/^## \[/{on = index($0, "[" v "]") > 0; next} /^\[.*\]: /{on = 0} on' CHANGELOG.md > "$OUT/QueenBee-$VERSION.md"
  cp appcast.xml "$OUT/appcast.xml"
  "$SPARKLE/generate_appcast" --account "$SPARKLE_ACCOUNT" --embed-release-notes \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://github.com/$REPO" -o "$OUT/appcast.xml" "$OUT"
  # Which commit this disk image is, so a later publish knows whether it may use it. A tree with changes isn't one.
  if [ -z "$(git status --porcelain)" ]; then echo "$SOURCE" > "$OUT/built-from"; else echo "uncommitted" > "$OUT/built-from"; fi
  echo "Built $DMG"
fi

[ "$MODE" = publish ] || { echo "The feed is in $OUT/appcast.xml. Run again with 'publish' to release it."; exit 0; }

echo "== Publishing $TAG"
NOTES="$OUT/QueenBee-$VERSION.md"
NAME=$(basename "$DMG")
if [ "$RELEASE" = none ]; then
  echo "Creating a draft release with $NAME"
  gh release create "$TAG" "$DMG" --repo "$REPO" --draft --target "$SOURCE" --title "Queen Bee $VERSION" --notes-file "$NOTES"
  RELEASE=draft
fi
# GitHub's copy has to be the very file the feed was written for: the feed carries its size and signature.
WANT=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
HAVE=$(gh release view "$TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name == \"$NAME\") | .digest" | sed 's/^sha256://')
if [ "$HAVE" != "$WANT" ]; then
  [ "$RELEASE" = draft ] || fail "the public release $TAG has a different $NAME from $DMG. Fix it on GitHub by hand."
  echo "Uploading $NAME to the draft"
  gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
  HAVE=$(gh release view "$TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name == \"$NAME\") | .digest" | sed 's/^sha256://')
  [ "$HAVE" = "$WANT" ] || fail "GitHub's copy of $NAME isn't the one in $OUT, even after uploading it again."
fi

[ -n "$LOCAL_TAG" ] || git tag "$TAG" "$SOURCE"
[ -n "$REMOTE_TAG" ] || git push -q origin "refs/tags/$TAG"

if [ "$RELEASE" = draft ]; then
  echo "Making the release public"
  gh release edit "$TAG" --repo "$REPO" --draft=false --latest
fi

# Last, because this is what every installed copy reads: by now the download it points at is there.
if [ "$FEED_COMMITTED" = no ]; then
  cp "$OUT/appcast.xml" appcast.xml
  git add appcast.xml
  git commit -q -m "Release $TAG" -- appcast.xml
fi
git push -q origin HEAD
if [ "$BRANCH" = main ]; then
  echo "Released $TAG. Installed copies will be offered it."
else
  echo "Released $TAG. Installed copies are offered it once $BRANCH is merged into main, where they read appcast.xml."
fi
