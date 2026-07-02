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

### API Keys

API keys are injected at build time via a gitignored `Secrets.xcconfig` file.

**Setup (every developer):**
```bash
cp Secrets.xcconfig.template Secrets.xcconfig
# Then edit Secrets.xcconfig and fill in your API keys
```

The template looks like:
```
DEEPSEEK_API_KEY =
MISTRAL_API_KEY =
```

**Provider mapping** (hardcoded in `HeartlabsEcho/LLMConfigs.swift`, easy to edit):

| Tier | Provider | Base URL | Model |
|---|---|---|---|
| `cheap` | DeepSeek | `https://api.deepseek.com` | `deepseek-chat` |
| `performant` | Mistral | `https://api.mistral.ai/v1` | `mistral-large-latest` |

To switch providers, edit `HeartlabsEcho/LLMConfigs.swift` — update the `baseURL` / `model` in `.cheap` or `.performant`.

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

### 0. Set up API keys
```bash
cp Secrets.xcconfig.template Secrets.xcconfig
# Then edit Secrets.xcconfig and fill in your API keys
```
The app will still compile without keys (they default to empty), but API
calls will fail with a "No API key" error until you set them.

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
│   ├── LLMConfigs.swift          ← Provider mapping (committed, secret-free)
│   ├── Info.plist                ← Permissions & bundle config + API key refs
│   └── Assets.xcassets/          ← Accent color & app icon
├── Secrets.xcconfig.template     ← Template — copy to Secrets.xcconfig
├── Secrets.xcconfig              ← API keys (gitignored — do not commit)
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
- [x] Configurable provider via `Secrets.xcconfig`
- [x] Typing indicator while waiting for response
- [x] Error handling with user-friendly messages

