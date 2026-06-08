#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse flags ───────────────────────────────────────────────────────────────
# --offline  disables all network access inside the container

FLAGS=()
USER_ARGS=()
UPDATE=0

for arg in "$@"; do
    case "$arg" in
        --offline) FLAGS+=("--offline") ;;
        --force-rebuild) FLAGS+=("--force-rebuild") ;;
        --update)  UPDATE=1 ;;
        *)         USER_ARGS+=("$arg") ;;
    esac
done

if [[ "$UPDATE" -eq 1 ]]; then
    PASSTHROUGH_ARGS=("bash" "-c" 'pi update && exec pi "$@"' "pi" ${USER_ARGS[@]+${USER_ARGS[@]}})
else
    PASSTHROUGH_ARGS=("pi" ${USER_ARGS[@]+${USER_ARGS[@]}})
fi

DOCKER_ARGS+=(
    # Pi config
    -v "$HOME/.pi/agent/:/root/.pi/agent/"
    # Expose kanban board to the host (port 3460)
    -p 3460:3460
)

# ── API key ───────────────────────────────────────────────────────────────────
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
   # DOCKER_ARGS+=(-e ANTHROPIC_API_KEY)
    DOCKER_ARGS+=(-e DEEPSEEK_API_KEY)
else
    echo "Warning: ANTHROPIC_API_KEY is not set. Pi may ask you to /login."
    echo "Add 'export ANTHROPIC_API_KEY=sk-ant-...' to your ~/.zshrc to fix this."
fi

echo "${PASSTHROUGH_ARGS[@]}"
./sandbox/run.sh ${FLAGS[@]+"${FLAGS[@]}"} "${DOCKER_ARGS[@]}" -- "${PASSTHROUGH_ARGS[@]}"


