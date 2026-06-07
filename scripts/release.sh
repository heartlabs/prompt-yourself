#!/usr/bin/env bash
# Release script for the Prompt Yourself Obsidian plugin.
#
# Usage:  scripts/release.sh [patch|minor|major]
#
# Pre-checks everything before touching files, so you get a clear error
# message instead of a half-baked version bump and no tag.
#
# Examples:
#   scripts/release.sh patch    # 1.0.3 → 1.0.4
#   scripts/release.sh minor    # 1.0.3 → 1.1.0
#   scripts/release.sh major    # 1.0.3 → 2.0.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$ROOT_DIR/obsidian-plugin"

# ─── Terminal colours ────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

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

# ─── Pre-flight checks ───────────────────────────────────────────────────────

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

# ─── Bail if any check failed ────────────────────────────────────────────────

if [[ "$ALL_CLEAR" != "true" ]]; then
  die
fi

# ─── Show current version & confirm ──────────────────────────────────────────

CURRENT_VERSION=$(cd "$PLUGIN_DIR" && node -p "require('./package.json').version")
NEW_VERSION=$(cd "$PLUGIN_DIR" && npm version "$RELEASE_TYPE" --no-git-tag-version 2>/dev/null || echo "$CURRENT_VERSION")
# Undo the dry-run bump
cd "$PLUGIN_DIR" && git checkout -- package.json 2>/dev/null || true

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

# ─── Do the release ──────────────────────────────────────────────────────────

echo ""
info "Bumping version…"

cd "$PLUGIN_DIR"
npm version "$RELEASE_TYPE" -m "chore: bump to %s" --force 2>&1 | tail -1

echo ""
info "Pushing commit and tag to origin…"
cd "$ROOT_DIR"
git push origin main
git push origin --tags

echo ""
echo "${GREEN}${BOLD}✅ Release $NEW_VERSION published!${NC}"
echo ""
echo "  The CI workflow at the link below will build the plugin"
echo "  and create a GitHub Release with the artifacts:"
echo ""
echo "    https://github.com/heartlabs/prompt-yourself/actions"
echo ""
