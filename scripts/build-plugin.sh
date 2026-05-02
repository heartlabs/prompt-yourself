#!/usr/bin/env bash
# Build script: compiles WASM and bundles the Obsidian plugin into a single
# main.js at obsidian-plugin/main.js.
#
# Prerequisites:
#   - wasm-pack (install via: cargo install wasm-pack)
#   - Node.js >= 18
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$ROOT_DIR/obsidian-plugin"

echo "Building Obsidian plugin…"

cd "$PLUGIN_DIR"

# Install build dependencies if needed
npm install --silent

# Run the build (wasm-pack + esbuild)
node build.js

echo ""
echo "Done. Plugin ready at: $PLUGIN_DIR"
echo ""
echo "To install in Obsidian, symlink or copy this folder to:"
echo "  <vault>/.obsidian/plugins/prompt-yourself/"
