#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse flags ───────────────────────────────────────────────────────────────
# --offline  disables all network access inside the container

FLAGS=()
PASSTHROUGH_ARGS=(claude)
for arg in "$@"; do
    case "$arg" in
        --offline) FLAGS+=("--offline") ;;
        --force-rebuild) FLAGS+=("--force-rebuild") ;;
        *)         PASSTHROUGH_ARGS+=("$arg") ;;
    esac
done

DOCKER_ARGS+=(
    # Claude config + credentials: shared with the host claude installation.
    # .claude.json lives in $HOME (not inside .claude/), so both must be mounted.
    -v "$HOME/.claude.json:/root/.claude.json"
    -v "$HOME/.claude:/root/.claude"
)

# ── API key ───────────────────────────────────────────────────────────────────
# Claude Code stores its session in the macOS Keychain, which is inaccessible
# from inside the container. Pass ANTHROPIC_API_KEY as an env var instead.
# Add it to your shell rc (e.g. ~/.zshrc): export ANTHROPIC_API_KEY=sk-ant-...
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    DOCKER_ARGS+=(-e ANTHROPIC_API_KEY)
else
    echo "Warning: ANTHROPIC_API_KEY is not set. Claude may ask you to /login."
    echo "Add 'export ANTHROPIC_API_KEY=sk-ant-...' to your ~/.zshrc to fix this."
fi

echo "${PASSTHROUGH_ARGS[@]}"
./sandbox/run.sh ${FLAGS[@]+"${FLAGS[@]}"} "${DOCKER_ARGS[@]}" -- "${PASSTHROUGH_ARGS[@]}"


