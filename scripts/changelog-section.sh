#!/bin/bash
#
# Prints one version's section from CHANGELOG.md, for use as GitHub release
# notes. Keeping the release body and the changelog from the same source means
# they cannot drift apart.
#
#   ./scripts/changelog-section.sh 0.2.0
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>   e.g. $0 0.2.0" >&2; exit 1; }

CHANGELOG="CHANGELOG.md"
[ -f "$CHANGELOG" ] || { echo "error: $CHANGELOG not found" >&2; exit 1; }

# Everything between this version's heading and the next version heading,
# with the link-reference block at the bottom of the file excluded.
SECTION=$(awk -v version="$VERSION" '
  $0 ~ "^## \\[" version "\\]" { capturing = 1; next }
  capturing && /^## \[/        { exit }
  capturing && /^\[[^]]+\]:/   { next }
  capturing                     { print }
' "$CHANGELOG")

# Trim leading and trailing blank lines.
SECTION=$(printf '%s\n' "$SECTION" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')

if [ -z "$SECTION" ]; then
  echo "error: no section for version $VERSION in $CHANGELOG" >&2
  echo "available:" >&2
  grep -oE '^## \[[^]]+\]' "$CHANGELOG" | sed 's/^## /  /' >&2
  exit 1
fi

printf '%s\n' "$SECTION"
