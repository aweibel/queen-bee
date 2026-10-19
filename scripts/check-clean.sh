#!/bin/sh
# Fails if a tracked file holds something that must stay on one machine: signing files,
# an Apple team id, a private key, or a home folder path. Run it before every commit and every push.
set -e
cd "$(dirname "$0")/.."
bad=0
if git ls-files | grep -E '\.(mobileprovision|p12|cer|xcarchive)$|(^|/)Local\.xcconfig$'; then
  echo "^ signing files must not be committed"; bad=1
fi
if git grep -nE 'DEVELOPMENT_TEAM *[:=] *"?[A-Z0-9]{10}' -- . ':!scripts/check-clean.sh'; then
  echo "^ an Apple team id must not be committed"; bad=1
fi
# The two files the iPad and iPhone app's signing is read from must name no team at all, whatever it looks
# like. A team goes in Mobile/Local.xcconfig, which stays on the machine that made it.
if git grep -nE "^[[:space:]]*\"?DEVELOPMENT_TEAM[^:=]*[:=][[:space:]]*[\"']?[^[:space:]\"']" -- project.yml Mobile/Config.xcconfig; then
  echo "^ DEVELOPMENT_TEAM must be left unset here. Put yours in Mobile/Local.xcconfig"; bad=1
fi
if git grep -nE 'BEGIN [A-Z ]*PRIVATE KEY' -- . ':!scripts/check-clean.sh'; then
  echo "^ a private key must not be committed"; bad=1
fi
if git grep -nE '/Users/[A-Za-z][A-Za-z0-9_-]+/' -- . ':!scripts/check-clean.sh'; then
  echo "^ a home folder path must not be committed"; bad=1
fi
[ "$bad" = 0 ] && echo "clean"
exit "$bad"
