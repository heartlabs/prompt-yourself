# Heartlabs Echo — iOS App

A voice-based companion app for iPhone. Record speech, get thoughtful
responses from an LLM. No typing, no goals, no pressure — just tap and speak.

## What it does

1. Shows a **chat interface** with a microphone button at the bottom
2. **Tap the mic** → recording starts (button pulses red)
3. Speak into the phone — your words appear live on screen
4. **Tap again** → recording stops, transcript is sent to an LLM (DeepSeek by default)
5. The **LLM responds** as a chat bubble — a patient listener that mirrors your thoughts
6. Tap the mic to continue the conversation; the full history is sent each time

You can edit the system prompt in `HeartlabsEcho/system-prompt.md` to change
how the LLM behaves.

### Switching LLM providers

The app uses an OpenAI-compatible API. To switch providers, edit
`HeartlabsEcho/llm-config.plist` (gitignored — copy from `.template`):

| Provider | `LLMBaseURL` | `LLMModel` |
|---|---|---|
| DeepSeek | `https://api.deepseek.com` | `deepseek-chat` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |
| Groq | `https://api.groq.com/openai/v1` | `llama-3.3-70b-versatile` |
| Any OpenAI-compatible | your endpoint | your model |

## Prerequisites

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
3. Navigate to `ios-app/HeartlabsEcho.xcodeproj` and open it

## Building & running on your iPhone

### 1. Set up your Apple ID in Xcode
- Xcode → Settings → Accounts → add your Apple ID

### 2. Configure signing
- In the project navigator, select the **"Heartlabs Echo"** target
- Go to **Signing & Capabilities**
- Select your **Team** from the dropdown
- Xcode will generate a provisioning profile automatically
- The bundle identifier is `eu.heartlabs.echo`

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
├── HeartlabsEcho.xcodeproj/     ← Xcode project (open this)
├── HeartlabsEcho/
│   ├── HeartlabsEchoApp.swift   ← @main entry point
│   ├── ContentView.swift         ← Main UI (chat bubbles + mic button)
│   ├── ChatMessage.swift         ← Message model & conversation history
│   ├── ChatViewModel.swift       ← Orchestrates STT → LLM → UI flow
│   ├── LLMService.swift          ← OpenAI-compatible API client
│   ├── SpeechRecognizer.swift    ← SFSpeechRecognizer wrapper
│   ├── system-prompt.md          ← Editable system prompt for the LLM
│   ├── llm-config.plist          ← LLM API config (gitignored)
│   ├── llm-config.plist.template ← Template — copy to llm-config.plist
│   ├── Info.plist                ← Permissions & bundle config
│   └── Assets.xcassets/          ← Accent color & app icon
├── Package.swift                 ← SPM manifest (for reference)
├── Scripts/
│   └── copy-to-host.sh           ← Helper to copy to macOS
├── PLAN.md                       ← Integration plan & decisions
└── README.md                     ← This file
```

## Phase 1 ✅ (Speech-to-text)

- [x] SwiftUI app with microphone button
- [x] Speech-to-text via `SFSpeechRecognizer`
- [x] Toggle recording on/off
- [x] Display transcribed text
- [x] Proper permission prompts
- [x] Xcode project ready to open & build

## Phase 2 ✅ (LLM integration)

- [x] DeepSeek / OpenAI-compatible API client (`LLMService.swift`)
- [x] Chat UI with message bubbles (`ContentView.swift`)
- [x] Conversation history sent with each request
- [x] Editable system prompt (`system-prompt.md`)
- [x] Configurable provider via `Config.xcconfig`
- [x] Typing indicator while waiting for response
- [x] Error handling with user-friendly messages

