#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

# ── Resolve wasm-bindgen version from Cargo.lock ──────────────────────────────
# The sandbox image bakes in the exact wasm-bindgen-cli version from Cargo.lock.
# The image is tagged with that version so a new image is built automatically
# when the version changes. Old images accumulate; prune with: docker image prune
WASM_BINDGEN_VERSION=$(grep -A1 '^name = "wasm-bindgen"$' "$PROJECT_ROOT/Cargo.lock" \
    | grep version | head -1 | cut -d'"' -f2)

IMAGE_TAG="prompt-yourself-sandbox:wbg-${WASM_BINDGEN_VERSION}"

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
    echo "Building sandbox image $IMAGE_TAG (first run or wasm-bindgen version changed)..."
    docker build \
        --build-arg WASM_BINDGEN_VERSION="$WASM_BINDGEN_VERSION" \
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
    # Cargo caches: named volumes so downloaded crates survive container teardown
    -v "prompt-yourself-cargo-registry:/root/.cargo/registry"
    -v "prompt-yourself-cargo-git:/root/.cargo/git"
    # Compiled artifacts: separate named volume to avoid host/container platform
    # mismatch. The host target/ dir is unused when running inside the container.
    -v "prompt-yourself-target:/cargo-target"
    -e CARGO_TARGET_DIR=/cargo-target
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
