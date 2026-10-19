#!/bin/sh
# Generates the Xcode project and builds the iPad and iPhone app for the Simulator into ./build.
# No Apple account is needed: for the Simulator, Xcode signs the app itself, to run on this Mac only.
# SwiftTerm ships a build plugin, which xcodebuild only runs with validation skipped.
set -e
cd "$(dirname "$0")/.."
xcodegen generate --quiet
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
# "Any Simulator" and not a named one, so it does not matter which devices this Mac happens to have.
xcodebuild -project QueenBee.xcodeproj -scheme QueenBeeMobile -configuration "${1:-Debug}" \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build \
  -skipPackagePluginValidation -skipMacroValidation build > "$LOG" 2>&1 || true
grep -E "error:|warning: var|BUILD (SUCCEEDED|FAILED)|^\*\*" "$LOG" || true
# The filter above hides most of the log, so the script itself has to say whether the build worked.
if grep -q "BUILD SUCCEEDED" "$LOG"; then
  echo "Built build/Build/Products/${1:-Debug}-iphonesimulator/QueenBeeMobile.app"
else
  echo "The build failed. Run the xcodebuild line in this script by hand to see the whole log."
  exit 1
fi
