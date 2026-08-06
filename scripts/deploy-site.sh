#!/bin/zsh
set -euo pipefail

# Uploads docs/ to the web host serving napeprofix.gigowat.com.
#
# The site is not built from the repository — it is a plain directory on a
# LiteSpeed shared host, so pushing to GitHub does nothing for it. This script
# is the deploy step; run it whenever docs/ changes.
#
# Needs the `lolipop` host in ~/.ssh/config.

project_dir="${0:A:h:h}"
remote="lolipop:web/napeprofix/"

cd "$project_dir/docs"

# --delete is deliberately not used: only files present here are replaced, so
# anything added on the server by hand survives.
if command -v rsync >/dev/null 2>&1 && ssh -o BatchMode=yes lolipop 'command -v rsync' >/dev/null 2>&1; then
  rsync -az --itemize-changes ./ "$remote"
else
  # The host has no rsync; scp everything instead.
  scp -q .htaccess ./*.html ./*.css "lolipop:web/napeprofix/"
  echo "uploaded via scp"
fi

echo "https://napeprofix.gigowat.com/"
