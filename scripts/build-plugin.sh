#!/usr/bin/env bash
# Build script: copies the Obsidian plugin source into a deployable folder
# at the project root: obsidian-plugin/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$ROOT_DIR/src/obsidian-plugin"
OUT_DIR="$ROOT_DIR/obsidian-plugin"

echo "Building Obsidian plugin…"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

cp "$SRC_DIR/manifest.json" "$OUT_DIR/manifest.json"
cp "$SRC_DIR/main.js"       "$OUT_DIR/main.js"
cp "$SRC_DIR/styles.css"    "$OUT_DIR/styles.css"

echo "Done. Plugin ready at: $OUT_DIR"
echo ""
echo "To install in Obsidian, symlink or copy this folder to:"
echo "  <vault>/.obsidian/plugins/prompt-yourself/"
