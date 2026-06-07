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
if [[ "$RELEASE_TYPE" != "patch" && "$RELEASE_TYPE" != "minor" && "$RELEASE_TYPE" != "major" ]]; then
  echo "Usage: $0 [patch|minor|major]"
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
  patch) NEW_VERSION="$MAJ.$MIN.$((PAT + 1))" ;;
  minor) NEW_VERSION="$MAJ.$((MIN + 1)).0" ;;
  major) NEW_VERSION="$((MAJ + 1)).0.0" ;;
esac

echo ""
case "$RELEASE_TYPE" in
  patch) info "$CURRENT_VERSION → ${BOLD}$NEW_VERSION${NC} (patch — bugfix)" ;;
  minor) info "$CURRENT_VERSION → ${BOLD}$NEW_VERSION${NC} (minor — feature)" ;;
  major) info "$CURRENT_VERSION → ${BOLD}$NEW_VERSION${NC} (major — breaking)" ;;
esac
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
info "Bumping package.json to $NEW_VERSION…"

cd "$PLUGIN_DIR"
npm version "$RELEASE_TYPE" --no-git-tag-version --no-commit-hooks 2>&1

# Verify the file was actually written
WRITTEN_VERSION=$(node -p "require('./package.json').version")
if [[ "$WRITTEN_VERSION" != "$NEW_VERSION" ]]; then
  die "npm version wrote '$WRITTEN_VERSION' but expected '$NEW_VERSION'"
fi
pass "package.json: $WRITTEN_VERSION"

# ─── Commit ──────────────────────────────────────────────────────────────────

info "Committing…"

cd "$ROOT_DIR"
git add obsidian-plugin/package.json obsidian-plugin/package-lock.json
git commit -m "chore: bump to v$NEW_VERSION"

# ─── Tag ────────────────────────────────────────────────────────────────────

info "Tagging v$NEW_VERSION…"
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
echo "  The CI workflow will now build the plugin and"
echo "  create a GitHub Release with the artifacts."
echo ""
echo "    https://github.com/heartlabs/prompt-yourself/actions"
echo ""
