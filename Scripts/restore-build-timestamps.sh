#!/bin/bash
# A restored .build is only useful if its objects look newer than the sources.
# `git checkout` stamps every file with "now", so without this step SwiftPM
# rebuilds the whole graph on every run and the cache buys nothing.
#
# Put each tracked file back on its last commit time, then force a rebuild for
# the files that differ from the commit the cache was built from. Everything
# else keeps its cached object.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d .build ]; then
  echo "no build cache to warm"
  exit 0
fi

git ls-files -z | while IFS= read -r -d '' file; do
  stamp="$(git log -1 --format=%ct -- "$file" || true)"
  if [ -n "$stamp" ]; then
    touch -t "$(date -r "$stamp" +%Y%m%d%H%M.%S)" "$file"
  fi
done

cached=""
if [ -f .build/.cache-commit ]; then
  cached="$(cat .build/.cache-commit)"
fi

if [ -n "$cached" ] && git cat-file -e "$cached^{commit}" 2>/dev/null; then
  changed="$(git diff --name-only "$cached" HEAD || true)"
  if [ -n "$changed" ]; then
    printf '%s\n' "$changed" | tr '\n' '\0' | xargs -0 touch
    echo "rebuilding $(printf '%s\n' "$changed" | wc -l | tr -d ' ') file(s) changed since the cache"
  else
    echo "cache matches HEAD, incremental build"
  fi
else
  # No marker, or its commit is gone from history: the objects cannot be
  # trusted. Drop the build products but keep the checkouts, so the rebuild
  # never waits on the network.
  rm -rf .build/debug .build/release
  echo "no usable cache marker, rebuilding from the checkouts"
fi

mkdir -p .build
echo "${GITHUB_SHA:-$(git rev-parse HEAD)}" > .build/.cache-commit
