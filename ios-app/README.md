# Prompt Yourself — iOS App (Phase 1)

A minimal iOS app that records speech and transcribes it using Apple's
`SFSpeechRecognizer`. This is the first step toward building a full
prompt-yourself coaching expert for iPhone.

## What it does

1. Shows a microphone button and a status label
2. Tap the mic → recording starts (button pulses red)
3. Speak into the phone
4. Tap again → recording stops, transcribed text appears on screen
5. Tap again to repeat

## Prerequisites

- macOS with **Xcode 15.3+** (tested with Xcode 15.3+ / iOS 17+)
- An **Apple Developer account** (free or paid) — needed to sign and run on a
  physical device
- A personal iPhone running **iOS 17+**
- Optionally: a USB cable to connect the iPhone to your Mac

## Getting the project onto your Mac

The project is created inside a Linux container. You have a few options:

### Option A: The workspace is mounted on the host
If your container mounts `/workspace` from the host filesystem, the
`ios-app/` folder is already on your Mac — open it directly.

### Option B: Copy via scp/rsync
```bash
# From your Mac, inside the project folder:
scp -r <container-user>@<container-ip>:/workspace/ios-app /path/on/your/mac/
```

### Option C: Copy via Docker cp
```bash
docker cp <container-name>:/workspace/ios-app ./ios-app
```

## Opening in Xcode

1. Open **Xcode** on your Mac
2. Go to **File → Open…** (or `⌘O`)
3. Navigate to `ios-app/PromptYourself.xcodeproj` and open it

## Building & running on your iPhone

### 1. Set up your Apple ID in Xcode
- Xcode → Settings → Accounts → add your Apple ID

### 2. Configure signing
- In the project navigator, select the **"Prompt Yourself"** target
- Go to **Signing & Capabilities**
- Select your **Team** from the dropdown
- Xcode will generate a provisioning profile automatically
- The bundle identifier is `com.yourname.promptyourself` — you may want to
  change it to something unique (e.g. `com.<yourname>.promptyourself`)

### 3. Connect your iPhone
- Use a USB cable, or ensure both Mac and iPhone are on the same WiFi network
- Trust the computer on your iPhone if prompted
- Select your iPhone as the **run destination** (next to the play button in Xcode's toolbar)

### 4. Build & run
- Press **Play** (`⌘R`)
- Xcode builds the app, signs it, and installs it on your iPhone
- On first launch, iOS will ask for **microphone** and **speech recognition**
  permissions — grant both

> **Note:** If you get a "code signing" error, your free developer account may
> have reached its limit (3 apps per 7 days). Delete an old test app or use a
> paid account.

## Project Structure

```
ios-app/
├── PromptYourself.xcodeproj/     ← Xcode project (open this)
├── PromptYourself/
│   ├── PromptYourselfApp.swift   ← @main entry point
│   ├── ContentView.swift         ← Main UI (mic button + transcript)
│   ├── SpeechRecognizer.swift    ← SFSpeechRecognizer wrapper
│   ├── Info.plist                ← Permissions & bundle config
│   └── Assets.xcassets/          ← Accent color & app icon
├── Package.swift                 ← SPM manifest (for reference)
├── Scripts/
│   └── copy-to-host.sh           ← Helper to copy to macOS
└── README.md                     ← This file
```

## Phase 1 Status ✅

- [x] SwiftUI app with microphone button
- [x] Speech-to-text via `SFSpeechRecognizer`
- [x] Toggle recording on/off
- [x] Display transcribed text
- [x] Proper permission prompts
- [x] Xcode project ready to open & build

## Next Steps (Phase 2+)

- Connect to the `core` WASM engine for coaching logic
- Replace the standalone UI with conversation view
- Add persistent journal storage via Core Data / iCloud
- Handle background audio / long recordings
