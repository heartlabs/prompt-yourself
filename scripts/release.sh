#!/usr/bin/env bash
# Release script for the Prompt Yourself Obsidian plugin.
#
# Usage:  scripts/release.sh [patch|minor|major]
#
# Pre-checks everything before touching files. Uses npm version only for the
# file write (--no-git-tag-version) and does the git commit + tag ourselves
# so we control exactly what happens and can detect failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$ROOT_DIR/obsidian-plugin"

# ─── Terminal colours ────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

pass() { printf "  ${GREEN}✅${NC} %s\n" "$1"; }
fail() { printf "  ${RED}❌${NC} %s\n" "$1"; }
warn() { printf "  ${YELLOW}⚠️${NC} %s\n" "$1"; }
info() { printf "  ${BOLD}▶${NC} %s\n" "$1"; }

die() {
  printf "\n${RED}${BOLD}Release aborted.${NC}\n" >&2
  exit 1
}

# ─── Parse arguments ─────────────────────────────────────────────────────────

RELEASE_TYPE="${1:-}"
BETA=false

for arg in "$@"; do
  case "$arg" in
    --beta) BETA=true ;;
    patch|minor|major) RELEASE_TYPE="$arg" ;;
  esac
done

if [[ "$RELEASE_TYPE" != "patch" && "$RELEASE_TYPE" != "minor" && "$RELEASE_TYPE" != "major" ]]; then
  echo "Usage: $0 [--beta] patch|minor|major"
  echo ""
  echo "  --beta    Create a pre-release version (e.g. 1.0.7-beta.1)"
  exit 1
fi

echo ""
echo "${BOLD}Prompt Yourself — Release Prep${NC}"
echo ""

# ─── Pre-flight checks ──────────────────────────────────────────────────────
# Every check sets ALL_CLEAR=false so they all run before the final bail.

ALL_CLEAR=true

# 1. Working tree clean?
DIRTY=$(cd "$ROOT_DIR" && git status --porcelain 2>/dev/null || echo "no-git")
if [[ "$DIRTY" == "no-git" ]]; then
  fail "Not a git repository (is .git missing?)"
  ALL_CLEAR=false
elif [[ -n "$DIRTY" ]]; then
  fail "Working tree has uncommitted changes:"
  echo ""
  while IFS= read -r line; do
    warn "  $line"
  done <<< "$DIRTY"
  echo ""
  info "Commit, stash, or discard them before releasing."
  ALL_CLEAR=false
else
  pass "Working tree is clean"
fi

# 2. Git author identity configured?
GIT_USER=$(cd "$ROOT_DIR" && git config user.name 2>/dev/null || echo "")
GIT_EMAIL=$(cd "$ROOT_DIR" && git config user.email 2>/dev/null || echo "")
if [[ -z "$GIT_USER" || -z "$GIT_EMAIL" ]]; then
  fail "Git author identity not set."
  echo ""
  [[ -z "$GIT_USER" ]] && warn '  Run:  git config user.name "Your Name"'
  [[ -z "$GIT_EMAIL" ]] && warn '  Run:  git config user.email "you@example.com"'
  ALL_CLEAR=false
else
  pass "Git author: $GIT_USER <$GIT_EMAIL>"
fi

# 3. On main branch?
CURRENT_BRANCH=$(cd "$ROOT_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  warn "On branch '$CURRENT_BRANCH', not 'main'."
  info "Continuing anyway — make sure you know what you're doing."
else
  pass "On branch 'main'"
fi

# 4. Remote reachable?
if ! git ls-remote --exit-code origin >/dev/null 2>&1; then
  fail "Remote 'origin' is not reachable."
  info "Check your network or run: git remote -v"
  ALL_CLEAR=false
else
  pass "Remote 'origin' is reachable"
fi

# 5. Local commits ahead of remote?
AHEAD=$(cd "$ROOT_DIR" && git rev-list --count origin/main..HEAD 2>/dev/null || echo "0")
if [[ "$AHEAD" -gt 0 ]]; then
  warn "$AHEAD local commit(s) ahead of origin/main (will be pushed with the release)"
else
  pass "In sync with origin/main"
fi

# ─── Bail on failures ───────────────────────────────────────────────────────

if [[ "$ALL_CLEAR" != "true" ]]; then
  die
fi

# ─── Show current & next version (non-destructive) ─────────────────────────

CURRENT_VERSION=$(node -p "require('$PLUGIN_DIR/package.json').version")

# Parse current version and compute the next one — pure arithmetic, no file writes
IFS='.' read -r MAJ MIN PAT <<< "$CURRENT_VERSION"
case "$RELEASE_TYPE" in
  patch) BASE_VERSION="$MAJ.$MIN.$((PAT + 1))" ;;
  minor) BASE_VERSION="$MAJ.$((MIN + 1)).0" ;;
  major) BASE_VERSION="$((MAJ + 1)).0.0" ;;
esac

if [[ "$BETA" == true ]]; then
  # Auto-increment beta number from existing tags
  BETA_NUM=1
  EXISTING_TAGS=$(cd "$ROOT_DIR" && git tag -l "v${BASE_VERSION}-beta.*" 2>/dev/null || true)
  if [[ -n "$EXISTING_TAGS" ]]; then
    LAST_BETA=$(echo "$EXISTING_TAGS" | sed 's/.*-beta\.//' | sort -n | tail -1)
    BETA_NUM=$((LAST_BETA + 1))
  fi
  NEW_VERSION="${BASE_VERSION}-beta.${BETA_NUM}"
  LABEL="beta $BETA_NUM — preview"
else
  NEW_VERSION="$BASE_VERSION"
  case "$RELEASE_TYPE" in
    patch) LABEL="patch — bugfix" ;;
    minor) LABEL="minor — feature" ;;
    major) LABEL="major — breaking" ;;
  esac
fi

echo ""
info "$CURRENT_VERSION → ${BOLD}$NEW_VERSION${NC} ($LABEL)"
echo ""

read -rp "  Create this release? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo ""
  info "Cancelled."
  exit 0
fi

# ─── Do the release ─────────────────────────────────────────────────────────
# We use npm version just to write the file (no git ops from npm).
# Then we handle commit + tag ourselves for full control.

echo ""
info "Bumping to $NEW_VERSION..."

cd "$PLUGIN_DIR"

# Write version to package.json
if [[ "$BETA" == true ]]; then
  # Beta: bump base version first, then overwrite with beta tag
  npm version "$RELEASE_TYPE" --no-git-tag-version --no-commit-hooks 2>/dev/null
  node -e "
    const p = require('./package.json');
    p.version = '$NEW_VERSION';
    require('fs').writeFileSync('./package.json', JSON.stringify(p, null, 2) + '\n');
  "
else
  npm version "$RELEASE_TYPE" --no-git-tag-version --no-commit-hooks 2>&1
fi

# Verify
WRITTEN_VERSION=$(node -p "require('./package.json').version")
if [[ "$WRITTEN_VERSION" != "$NEW_VERSION" ]]; then
  die "package.json has '$WRITTEN_VERSION' but expected '$NEW_VERSION'"
fi
pass "package.json: $WRITTEN_VERSION"

# Sync version into manifest.json
node -e "
  const m = require('./manifest.json');
  m.version = '$NEW_VERSION';
  require('fs').writeFileSync('./manifest.json', JSON.stringify(m, null, 2) + '\n');
"
pass "manifest.json: $NEW_VERSION"

# Sync version into manifest-beta.json (so BRAT always sees the latest)
if [[ -f "manifest-beta.json" ]]; then
  node -e "
    const m = require('./manifest-beta.json');
    m.version = '$NEW_VERSION';
    require('fs').writeFileSync('./manifest-beta.json', JSON.stringify(m, null, 2) + '\n');
  "
  pass "manifest-beta.json: $NEW_VERSION"
fi

# ─── Commit ──────────────────────────────────────────────────────────────────

info "Committing…"

cd "$ROOT_DIR"
git add obsidian-plugin/
git commit -m "chore: bump to v$NEW_VERSION"

# ─── Tag ────────────────────────────────────────────────────────────────────

info "Tagging v$NEW_VERSION..."
git tag -a "v$NEW_VERSION" -m "chore: bump to v$NEW_VERSION"

# Verify the tag exists
if ! git tag -l | grep -q "^v$NEW_VERSION$"; then
  die "Tag v$NEW_VERSION was not created"
fi
pass "Tag v$NEW_VERSION created"

# ─── Push ────────────────────────────────────────────────────────────────────

info "Pushing commit and tag to origin…"
git push origin main
git push origin "v$NEW_VERSION"

# ─── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "${GREEN}${BOLD}✅ Release v$NEW_VERSION published!${NC}"
echo ""
if [[ "$BETA" == true ]]; then
  echo "  🧪 Beta release — testers with BRAT installed will auto-update."
  echo ""
fi
echo "  CI workflow: https://github.com/heartlabs/prompt-yourself/actions"
echo ""
if [[ "$BETA" == true ]]; then
  echo "  Tell beta testers to:"
  echo "    1. Install the BRAT plugin from Community Plugins"
  echo "    2. Run command: BRAT: Add a beta plugin for testing"
  echo "    3. Enter: https://github.com/heartlabs/prompt-yourself"
  echo ""
fi
