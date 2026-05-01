#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

IMAGE_TAG="prompt-yourself-sandbox:latest"

# ── Parse flags ───────────────────────────────────────────────────────────────
# --offline  disables all network access inside the container
OFFLINE=0
FORCE_REBUILD=false
DOCKER_ARGS=(--rm -it -e TERM)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --offline) OFFLINE=1 ;; 
        --force-rebuild) FORCE_REBUILD=true ;;
        --) shift; break ;;
        *)         DOCKER_ARGS+=("$1") ;;
    esac
    shift
done
PASSTHROUGH_ARGS=("$@")

echo "docker args: ${DOCKER_ARGS[*]}"
echo "passthrough args: ${PASSTHROUGH_ARGS[*]}"

# -- Start docker if it's not running
docker desktop start

# ── Build image if it doesn't exist ───────────────────────────────────────────
if [[ "$FORCE_REBUILD" == true ]] || ! docker image inspect "$IMAGE_TAG" > /dev/null 2>&1; then
    echo "Building sandbox image $IMAGE_TAG..."
    docker build \
        -t "$IMAGE_TAG" \
        "$SCRIPT_DIR"
fi


# ── Assemble docker run arguments ─────────────────────────────────────────────

if [[ "$OFFLINE" -eq 1 ]]; then
    DOCKER_ARGS+=(--network none)
fi

DOCKER_ARGS+=(
    # Repo: mounted so edits made inside the container are visible on the host
    -v "$PROJECT_ROOT:/workspace"
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

# ── Launch ────────────────────────────────────────────────────────────────────
docker run "${DOCKER_ARGS[@]}" "$IMAGE_TAG" "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"
