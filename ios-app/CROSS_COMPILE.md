# Cross-Compiling iOS Apps from Linux (Future Option)

This document records our research on building the iOS app from inside the
Linux sandbox container, without needing to open Xcode on the host Mac.

## The Tool: [xtool](https://github.com/xtool-org/xtool)

`xtool` is a cross-platform Xcode replacement (~5K stars, MIT license) that
runs on Linux, Windows, and macOS. It can build, sign, and install iOS apps
using Swift Package Manager — no Xcode GUI required.

## How It Works

```
Container (Linux)                              Host (macOS)
─────────────────────                          ─────────────────────
Swift toolchain (swift.org)                    
xtool CLI                                       
                                                 Xcode.xip (read-only bind mount)
                                                 │
xtool setup ─────────────────────────────────► reads Xcode.xip
  extracts iOS SDK                              
  registers as "arm64-apple-ios" SDK            
                                                 then: swift build --swift-sdk arm64-apple-ios
```

## What Needs to Be Set Up

### 1. Dockerfile additions (`sandbox/Dockerfile`)

```dockerfile
# Swift toolchain for Linux (from swift.org)
RUN wget https://download.swift.org/swift-6.1-release/ubuntu2404/swift-6.1-RELEASE/swift-6.1-RELEASE-ubuntu24.04.tar.gz \
    && tar xzf swift-*.tar.gz -C /opt/ \
    && ln -s /opt/swift-*/usr/bin/swift /usr/local/bin/swift

# xtool CLI
RUN curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" -o /usr/local/bin/xtool \
    && chmod +x /usr/local/bin/xtool
```

### 2. Bind mount for Xcode.xip (`sandbox/run.sh`)

The user adds a volume mount pointing to their downloaded Xcode.xip:

```bash
DOCKER_ARGS+=(
  -v /path/to/Xcode_16.xip:/xcode/Xcode.xip:ro
)
```

### 3. One-time SDK setup (inside container)

```bash
xtool setup
# Provides path /xcode/Xcode.xip when prompted
# Extracts SDK, registers it
# Verify with: swift sdk list  # should show "darwin"
```

## What This Enables

| Capability | Status |
|---|---|
| Compile iOS Swift code from Linux | ✅ `swift build --swift-sdk arm64-apple-ios` |
| Catch Swift syntax/type/API errors | ✅ Full compiler validation |
| Package into unsigned `.app` / `.ipa` | ✅ |
| Code sign and deploy to device | ❌ needs Apple ID credentials |
| Run iOS simulator | ❌ macOS-only runtime |
| Test speech-to-text on device | ❌ needs physical iPhone |

## Caveats

- Xcode.xip is ~2-3 GB. The extracted SDK cache is ~500 MB.
- Requires macOS host with Xcode installed (already true for this project).
- The extracted SDK is version-locked to the Xcode version used.
- `xtool` is under active development; some features (app extensions,
  entitlements) may be incomplete.

## Decision Status

**Not implemented.** The SpeechAnalyzer path (iOS 26+) was attempted first
but couldn't be used because the available Xcode version (16.4) doesn't
include the iOS 26 SDK. Instead we use parallel SFSpeechRecognizers
(en/de/ru) which work with Xcode 15.3+ and iOS 17+.
Revisit cross-compilation if we need automated build verification inside
the sandbox in a future phase.
