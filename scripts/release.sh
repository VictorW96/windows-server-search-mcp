#!/usr/bin/env bash
# Builds the plugin and publishes it to the marketplace repository.
#   1. builds dist/windows-server-search
#   2. tags this repo v<VERSION> and creates a GitHub release with the plugin zip
#   3. copies the plugin into <marketplace>/plugins/windows-server-search, updates
#      .claude-plugin/marketplace.json, commits and pushes
#
# Usage: scripts/release.sh [--marketplace-dir DIR] [--dry-run] [--skip-github-release]
# Env:   MARKETPLACE_REPO (default VictorW96/agentic-marketplace)
#        MARKETPLACE_TOKEN (optional; token used to push the marketplace, e.g. in CI)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="windows-server-search"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TAG="v$VERSION"
MARKETPLACE_REPO="${MARKETPLACE_REPO:-VictorW96/agentic-marketplace}"
SOURCE_REPO="${SOURCE_REPO:-VictorW96/windows-server-search-mcp}"
MP_DIR=""
DRY_RUN=0
GH_RELEASE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --marketplace-dir) MP_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --skip-github-release) GH_RELEASE=0; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

run() { if [[ $DRY_RUN == 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }

"$ROOT/scripts/build.sh"

# --- GitHub release of this repo ------------------------------------------------
if [[ $GH_RELEASE == 1 ]]; then
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    echo "Working tree is dirty - commit before releasing." >&2; exit 1
  fi
  if ! git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    run git -C "$ROOT" tag -a "$TAG" -m "Release $TAG"
    run git -C "$ROOT" push origin "$TAG"
  fi
  if gh release view "$TAG" --repo "$SOURCE_REPO" >/dev/null 2>&1; then
    run gh release upload "$TAG" "$ROOT/dist/$NAME-$VERSION.zip" --repo "$SOURCE_REPO" --clobber
  else
    run gh release create "$TAG" "$ROOT/dist/$NAME-$VERSION.zip" --repo "$SOURCE_REPO" \
      --title "$NAME $TAG" --notes "Claude plugin $NAME $VERSION. Install via the marketplace https://github.com/$MARKETPLACE_REPO"
  fi
fi

# --- Marketplace -------------------------------------------------------------------
CLEANUP=""
if [[ -z "$MP_DIR" ]]; then
  MP_DIR="$(mktemp -d)/marketplace"
  CLEANUP="$(dirname "$MP_DIR")"
  if [[ -n "${MARKETPLACE_TOKEN:-}" ]]; then
    git clone -q "https://x-access-token:${MARKETPLACE_TOKEN}@github.com/$MARKETPLACE_REPO.git" "$MP_DIR"
  else
    gh repo clone "$MARKETPLACE_REPO" "$MP_DIR" -- -q
  fi
fi
trap '[[ -n "$CLEANUP" ]] && rm -rf "$CLEANUP"' EXIT

mkdir -p "$MP_DIR/plugins" "$MP_DIR/.claude-plugin"
rm -rf "$MP_DIR/plugins/$NAME"
cp -R "$ROOT/dist/$NAME" "$MP_DIR/plugins/$NAME"

python3 "$ROOT/scripts/update_marketplace.py" "$MP_DIR/.claude-plugin/marketplace.json" \
  "$MP_DIR/plugins/$NAME/.claude-plugin/plugin.json" "./plugins/$NAME"

if command -v claude >/dev/null 2>&1; then claude plugin validate "$MP_DIR"; fi

cd "$MP_DIR"
git add -A
if git diff --cached --quiet; then
  echo "Marketplace already up to date."
  exit 0
fi
if [[ -z "$(git config user.email || true)" ]]; then
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git config user.name "github-actions[bot]"
fi
run git commit -q -m "Release $NAME $VERSION" -m "Built from $SOURCE_REPO@$(git -C "$ROOT" rev-parse --short HEAD)"
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"
run git push -q origin "HEAD:$BRANCH"
echo "Published $NAME $VERSION to $MARKETPLACE_REPO"
