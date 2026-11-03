#!/bin/bash
# Rewrites the "Archives" table of a GitHub release's notes from the assets that
# are attached right now, and optionally turns a pre-release into a normal,
# "latest" release.
#
#   refresh-release.sh <tag> [--mark-release]
#
# Needs the gh CLI with GH_TOKEN, run inside the repository (or set GH_REPO).
# For testing, FAKE_RELEASE_DIR=<dir with body.md and assets.txt> skips gh and
# prints the new notes instead of editing the release.
set -euo pipefail

tag=${1:?usage: refresh-release.sh <tag> [--mark-release]}
mark=0
[ "${2:-}" = "--mark-release" ] && mark=1

if [ -n "${FAKE_RELEASE_DIR:-}" ]; then
  body=$(tr -d '\r' < "$FAKE_RELEASE_DIR/body.md")
  assets=$(cat "$FAKE_RELEASE_DIR/assets.txt")
else
  # notes edited in the GitHub web UI come back with CRLF line endings
  body=$(gh release view "$tag" --json body --jq .body | tr -d '\r')
  assets=$(gh release view "$tag" --json assets --jq '.assets[].name')
fi

notes=$(mktemp)
{
  # everything before the archives section stays as it is
  printf '%s\n' "$body" | sed '/^### Archives$/,$d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
  echo
  echo "### Archives"
  echo
  echo "| Archive | FreeBSD | Architecture |"
  echo "|---|---|---|"
  printf '%s\n' "$assets" | grep -E '^freebsd-[0-9]+-(amd64|aarch64)\.tar$' | sort -t- -k2,2n -k3,3 | while read -r f; do
    rest=${f#freebsd-}; rest=${rest%.tar}
    echo "| \`$f\` | ${rest%%-*} | ${rest#*-} |"
  done
} > "$notes"

if [ -n "${FAKE_RELEASE_DIR:-}" ]; then
  cat "$notes"
  exit 0
fi

if [ "$mark" = 1 ]; then
  gh release edit "$tag" --notes-file "$notes" --prerelease=false --latest
else
  gh release edit "$tag" --notes-file "$notes"
fi
