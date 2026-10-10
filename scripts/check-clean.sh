#!/bin/sh
# Fails if a tracked file holds something that must stay on one machine: signing files,
# an Apple team id, a private key, or a home folder path. Run it before every push.
set -e
cd "$(dirname "$0")/.."
bad=0
if git ls-files | grep -E '\.(mobileprovision|p12|cer|xcarchive)$|(^|/)Local\.xcconfig$'; then
  echo "^ signing files must not be committed"; bad=1
fi
if git grep -nE 'DEVELOPMENT_TEAM *[:=] *"?[A-Z0-9]{10}' -- . ':!scripts/check-clean.sh'; then
  echo "^ an Apple team id must not be committed"; bad=1
fi
if git grep -nE 'BEGIN [A-Z ]*PRIVATE KEY' -- . ':!scripts/check-clean.sh'; then
  echo "^ a private key must not be committed"; bad=1
fi
if git grep -nE '/Users/[A-Za-z][A-Za-z0-9_-]+/' -- . ':!scripts/check-clean.sh'; then
  echo "^ a home folder path must not be committed"; bad=1
fi
[ "$bad" = 0 ] && echo "clean"
exit "$bad"
