#!/usr/bin/env bash
# Builds the plugin and publishes it to the marketplace repository.
#   1. builds dist/windows-server-search
#   2. tags this repo v<VERSION> and creates a GitHub release with the plugin zip
#   3. for every marketplace repository: copies the plugin into
#      <marketplace>/plugins/windows-server-search, updates .claude-plugin/marketplace.json,
#      commits and pushes
#
# Usage: scripts/release.sh [--marketplace-dir DIR] [--dry-run] [--skip-github-release]
#        --marketplace-dir publishes to a local checkout instead of cloning MARKETPLACE_REPOS.
# Env:   MARKETPLACE_REPOS (space separated; default
#          "VictorW96/agentic-marketplace PMI-ING/agentic-marketplace")
#        MARKETPLACE_TOKEN (optional; token used to push the marketplaces, e.g. in CI)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="windows-server-search"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TAG="v$VERSION"
MARKETPLACE_REPOS="${MARKETPLACE_REPOS:-${MARKETPLACE_REPO:-VictorW96/agentic-marketplace PMI-ING/agentic-marketplace}}"
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
      --title "$NAME $TAG" --notes "Claude plugin $NAME $VERSION. Install via the marketplace https://github.com/${MARKETPLACE_REPOS%% *}"
  fi
fi

# --- Marketplaces -----------------------------------------------------------------
CLEANUP=""
trap '[[ -n "$CLEANUP" ]] && rm -rf "$CLEANUP"' EXIT

# publish_to_marketplace <checkout dir> <label>
publish_to_marketplace() {
  local mp_dir="$1" label="$2"
  mkdir -p "$mp_dir/plugins" "$mp_dir/.claude-plugin"
  rm -rf "$mp_dir/plugins/$NAME"
  cp -R "$ROOT/dist/$NAME" "$mp_dir/plugins/$NAME"

  python3 "$ROOT/scripts/update_marketplace.py" "$mp_dir/.claude-plugin/marketplace.json" \
    "$mp_dir/plugins/$NAME/.claude-plugin/plugin.json" "./plugins/$NAME"

  if command -v claude >/dev/null 2>&1; then claude plugin validate "$mp_dir"; fi

  (
    cd "$mp_dir"
    git add -A
    if git diff --cached --quiet; then
      echo "$label already up to date."
      exit 0
    fi
    if [[ -z "$(git config user.email || true)" ]]; then
      git config user.email "github-actions[bot]@users.noreply.github.com"
      git config user.name "github-actions[bot]"
    fi
    run git commit -q -m "Release $NAME $VERSION" -m "Built from $SOURCE_REPO@$(git -C "$ROOT" rev-parse --short HEAD)"
    BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"
    run git push -q origin "HEAD:$BRANCH"
    echo "Published $NAME $VERSION to $label"
  )
}

if [[ -n "$MP_DIR" ]]; then
  publish_to_marketplace "$MP_DIR" "$MP_DIR"
  exit 0
fi

CLEANUP="$(mktemp -d)"
for repo in $MARKETPLACE_REPOS; do
  dir="$CLEANUP/${repo//\//_}"
  if [[ -n "${MARKETPLACE_TOKEN:-}" ]]; then
    git clone -q "https://x-access-token:${MARKETPLACE_TOKEN}@github.com/$repo.git" "$dir"
  else
    gh repo clone "$repo" "$dir" -- -q
  fi
  publish_to_marketplace "$dir" "$repo"
done
