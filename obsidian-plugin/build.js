/**
 * Build script for the Obsidian plugin.
 *
 * 1. Builds the WASM module via wasm-pack
 * 2. Bundles the plugin JS + WASM glue code into a single main.js via esbuild
 *
 * Usage:  node build.js          (production build)
 *         node build.js --watch  (watch mode for development)
 */

const { execSync } = require('child_process');
const esbuild = require('esbuild');
const path = require('path');
const fs = require('fs');

const ROOT = path.resolve(__dirname, '..');
const PLUGIN_SRC = path.join(__dirname, 'src');
const PLUGIN_OUT = __dirname; // builds directly into obsidian-plugin/

// ─── Step 1: Build WASM via wasm-pack ───────────────────────────────────────

function buildWasm() {
  console.log('🔨 Building core-wasm…');

  const wasmDir = path.join(ROOT, 'core-wasm');
  const outDir = path.join(wasmDir, 'pkg');

  // Run wasm-pack
  execSync(
    `wasm-pack build "${wasmDir}" --target web --out-dir "${outDir}" --release`,
    { stdio: 'inherit' }
  );

  // Copy the generated files to the plugin src directory so esbuild can find them
  const wasmGlueSrc = path.join(outDir, 'prompt_yourself_core_wasm.js');
  const wasmBinarySrc = path.join(outDir, 'prompt_yourself_core_wasm_bg.wasm');
  const wasmDtsSrc = path.join(outDir, 'prompt_yourself_core_wasm.d.ts');

  const wasmGlueDst = path.join(PLUGIN_SRC, 'core_wasm.js');
  const wasmBinaryDst = path.join(PLUGIN_SRC, 'core_wasm_bg.wasm');
  const wasmDtsDst = path.join(PLUGIN_SRC, 'core_wasm.d.ts');

  // Copy the glue JS, stripping the unused __wbg_init function (dead code
  // that causes an esbuild warning about import.meta.url in CJS mode).
  // Our plugin only uses initSync() — the bytes-initialization path.
  let glue = fs.readFileSync(wasmGlueSrc, 'utf-8');
  glue = glue.replace(/\n\nasync function __wbg_init[\s\S]*?\n\}/, '');
  glue = glue.replace("export { initSync, __wbg_init as default };", "export { initSync };",);
  fs.writeFileSync(wasmGlueDst, glue);

  fs.copyFileSync(wasmBinarySrc, wasmBinaryDst);
  if (fs.existsSync(wasmDtsSrc)) {
    fs.copyFileSync(wasmDtsSrc, wasmDtsDst);
  }

  console.log('✅ WASM built and copied to plugin src/');
}

// ─── Step 2: Bundle with esbuild ────────────────────────────────────────────

/**
 * esbuild plugin to handle .wasm imports.
 * Embeds the wasm binary as a Uint8Array in the JS bundle so it's self-contained.
 * This avoids URL resolution issues in CJS context where import.meta.url is not set.
 *
 * The plugin intercepts imports of .wasm files and returns the raw bytes as
 * a Uint8Array, which can be passed directly to wasm-pack's initSync() function.
 *
 * Inspired by https://github.com/evanw/esbuild/issues/95
 */
const wasmPlugin = {
  name: 'wasm',
  setup(build) {
    // Intercept .wasm imports
    build.onResolve({ filter: /\.wasm$/ }, (args) => {
      return {
        path: path.resolve(args.resolveDir, args.path),
        namespace: 'wasm-binary',
      };
    });

    // Load the .wasm file and return the bytes as a Uint8Array
    build.onLoad({ filter: /.*/, namespace: 'wasm-binary' }, (args) => {
      const binary = fs.readFileSync(args.path);
      // Output a Uint8Array constructor call with the raw bytes
      const bytes = Array.from(binary);
      return {
        contents: `module.exports = new Uint8Array([${bytes.join(',')}]);`,
        loader: 'js',
      };
    });
  },
};

async function bundle(watch) {
  console.log('📦 Bundling plugin…');

  const buildOptions = {
    entryPoints: [path.join(PLUGIN_SRC, 'main.js')],
    bundle: true,
    outfile: path.join(PLUGIN_OUT, 'main.js'),
    platform: 'browser',
    target: ['es2021'],
    format: 'cjs',
    external: ['obsidian'],
    plugins: [wasmPlugin],
    sourcemap: 'inline',
    minify: !watch,
    logLevel: 'info',
  };

  if (watch) {
    const ctx = await esbuild.context(buildOptions);
    await ctx.watch();
    console.log('👀 Watching for changes…');
  } else {
    await esbuild.build(buildOptions);
    console.log('✅ Plugin bundled to', path.join(PLUGIN_OUT, 'main.js'));
  }

  // Copy styles.css from src/ to the output directory
  const srcCss = path.join(PLUGIN_SRC, 'styles.css');
  const dstCss = path.join(PLUGIN_OUT, 'styles.css');
  fs.copyFileSync(srcCss, dstCss);
  console.log('✅ Copied styles.css');
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const watch = process.argv.includes('--watch');

  buildWasm();
  await bundle(watch);
}

main().catch((err) => {
  console.error('❌ Build failed:', err);
  process.exit(1);
});
