#!/usr/bin/env bash
# Installs npm dependencies for each Lambda so `terraform apply` zips a complete
# package. The Node.js 20 Lambda runtime already bundles AWS SDK v3, so this is
# only strictly required if you want pinned SDK versions or add non-SDK deps.
# Safe to run repeatedly.
set -euo pipefail
cd "$(dirname "$0")/lambdas"
for d in */ ; do
  if [ -f "$d/package.json" ]; then
    echo "==> npm install in $d"
    ( cd "$d" && npm install --omit=dev --no-audit --no-fund )
  fi
done
echo "All Lambda dependencies installed."
