#!/usr/bin/env bash
# Builds the Claude plugin into dist/windows-server-search (+ a .zip).
# Usage: scripts/build.sh [--no-validate]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="windows-server-search"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
OUT="$ROOT/dist/$NAME"
VALIDATE=1
[[ "${1:-}" == "--no-validate" ]] && VALIDATE=0

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || { echo "Invalid VERSION '$VERSION'" >&2; exit 1; }

echo "Building $NAME $VERSION -> $OUT"
rm -rf "$OUT" "$ROOT/dist/$NAME-"*.zip
mkdir -p "$OUT/server"

# Plugin skeleton (manifest, MCP config, skills)
cp -R "$ROOT/plugin/." "$OUT/"
sed "s/__VERSION__/$VERSION/g" "$ROOT/plugin/.claude-plugin/plugin.json" > "$OUT/.claude-plugin/plugin.json"

# MCP server
cp "$ROOT/server/server.ps1" "$ROOT/server/WindowsServerSearch.psm1" "$OUT/server/"
printf '%s\n' "$VERSION" > "$OUT/server/VERSION"
cp "$ROOT/LICENSE" "$OUT/LICENSE"

# Windows PowerShell 5.1 reads BOM-less scripts as ANSI; the scripts must stay pure ASCII.
if LC_ALL=C grep -n '[^[:print:][:space:]]' "$OUT/server/"*.ps* >/dev/null; then
  echo "Non-ASCII characters found in server scripts:" >&2
  LC_ALL=C grep -n '[^[:print:][:space:]]' "$OUT/server/"*.ps* >&2
  exit 1
fi

if grep -rq "__VERSION__" "$OUT"; then echo "Unreplaced __VERSION__ placeholder" >&2; exit 1; fi

if [[ $VALIDATE == 1 ]]; then
  if command -v claude >/dev/null 2>&1; then
    claude plugin validate "$OUT"
  else
    echo "warning: 'claude' CLI not found - skipping 'claude plugin validate'" >&2
  fi
fi

(cd "$ROOT/dist" && rm -f "$NAME-$VERSION.zip" && zip -qr "$NAME-$VERSION.zip" "$NAME")
echo "Built dist/$NAME (version $VERSION) and dist/$NAME-$VERSION.zip"
