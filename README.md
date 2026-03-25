# Responder

Responder is a native macOS SwiftUI app that drafts iMessage replies using **local Ollama** or **OpenRouter** (optional), keeps memory and logs on-device, and offers opt-in autonomy controls with simulation and policy gates.

## Install

Download release assets from [GitHub Releases](https://github.com/itsasheruwu/responder-v1/releases) or run:

```bash
curl -fsSL https://raw.githubusercontent.com/itsasheruwu/responder-v1/main/install.sh | bash
```

The script downloads **`Responder.app.zip` from the latest published GitHub Release** (not necessarily the newest commit on `main`) and copies `Responder.app` into `/Applications`.

Install a **specific** version:

```bash
curl -fsSL https://raw.githubusercontent.com/itsasheruwu/responder-v1/main/install.sh | bash -s v1.0.2
```

After installing, run Responder once from `/Applications` so macOS privacy dialogs and Full Disk Access apply to that copy.

## What Is Implemented

- Native macOS 15+ SwiftUI app with:
  - conversation list
  - message history view
  - model picker
  - editable draft inspector
  - context usage meter
  - memory inspector/editor
  - per-contact autonomy settings
  - local activity log
- **LLM providers:** local **Ollama** (default) or **OpenRouter** with an API key in Settings
- Local persistence with SQLite via GRDB for:
  - selected model
  - user profile memory
  - contact memory
  - rolling summaries
  - drafts
  - autonomy configuration
  - activity logs
  - simulation runs
  - monitor cursors
- Actor-backed services for:
  - Ollama and OpenRouter integration
  - Messages history access
  - Messages send automation
  - prompt assembly
  - summary compaction
  - memory management
  - policy evaluation
  - autonomy monitoring

## Build And Test

Generate the project:

```bash
xcodegen generate
```

Build:

```bash
xcodebuild -project Responder.xcodeproj -scheme Responder -destination 'platform=macOS' build
```

Run unit tests:

```bash
xcodebuild -project Responder.xcodeproj -scheme Responder -destination 'platform=macOS' -only-testing:ResponderTests test
```

Run the UI smoke test:

```bash
xcodebuild -project Responder.xcodeproj -scheme Responder -destination 'platform=macOS' -only-testing:ResponderUITests/ResponderUITests/testAppLaunches test
```

Build local release artifacts (version comes from `VERSION` or `scripts/release.sh`; current default is **1.0.2**):

```bash
./scripts/release.sh
```

That script generates, for the configured version:

- `release/<version>/Responder.app.zip`
- `release/<version>/Responder-<version>.pkg`
- `release/<version>/install.sh`

## Local Runtime Requirements

- macOS 15 or later
- **Drafts:** either **Ollama** on `http://127.0.0.1:11434`, or **OpenRouter** with a valid API key and network access (configure in Settings)
- A local Messages history database at `~/Library/Messages/chat.db` (same macOS user that runs the app), or use **Choose Messages Folder** in the permission gate / Settings if Full Disk Access alone is not enough
- **Automation** permission if you want sending or real autonomy through the Messages app

## macOS And iMessage Limitations

### 1. Message history is not exposed through a stable public Messages SDK

There is no clean first-party API that provides full local iMessage conversation history for this use case.

Current workaround:

- Read `~/Library/Messages/chat.db` in read-only mode
- Treat Apple’s schema as an external dependency
- Isolate all SQL in a dedicated adapter layer
- Fall back safely when messages contain unsupported rich content

Practical implication:

- Future macOS releases can change the Messages schema
- Text messages work best in this MVP
- Attachments, stickers, reactions, and other rich content are intentionally downgraded to placeholders such as `[Attachment omitted]`

### 2. Sending messages requires automation, not a dedicated send API

There is no dedicated public iMessage send framework for a standalone app like this. The working local-only path is Apple Events automation against the Messages app.

Current workaround:

- Use AppleScript / Apple Events to issue `send` to the selected chat
- Include `NSAppleEventsUsageDescription`
- Require explicit user approval for Messages automation

Practical implication:

- Sending can fail if Messages is not available, if Automation permission is denied, or if Apple changes the scripting behavior
- Draft suggestion mode remains the default and safest mode

### 3. Mac App Store distribution is not a fit for this feature set

The requested architecture depends on direct access to the user’s Messages database and on app-to-app automation. That is not a good fit for an App Sandbox-constrained Mac App Store build.

Best workaround:

- Distribute outside the Mac App Store
- Use local-only or Developer ID distribution
- Keep App Sandbox disabled for this build target
- Ask the user to grant only the permissions needed for local history access and optional sending

### 4. Full Disk Access and the Messages folder

Depending on macOS privacy settings, reading `~/Library/Messages/chat.db` may require **Full Disk Access** to the app you actually launch.

Important details:

- Privacy entries are **per macOS user**. If you use several accounts on one Mac, enable Full Disk Access (and Automation, if needed) while logged into **that** user.
- They are also **per app path and signature**. The binary in `/Applications/Responder.app` is different from a Debug build opened from Xcode or DerivedData—add the one you use to **System Settings → Privacy & Security → Full Disk Access**.
- If access is still blocked after enabling FDA, use **Choose Messages Folder** in the app to grant read access to the folder that contains `chat.db`.

Best workaround:

- Grant Full Disk Access to Responder if conversation loading fails, then **restart the app**
- Optionally pick the `Library/Messages` folder (or the folder that contains `chat.db`) when prompted
- Keep the app’s own database in `~/Library/Application Support/Responder/responder.sqlite`
- Never write to Apple’s Messages database

## Safety Model

- Draft suggestion mode is the default
- Global autonomy is off by default
- Real auto-send is per contact and opt-in
- Simulation runs can be executed before real send is enabled
- Policy gates include:
  - confidence threshold
  - quiet hours
  - rate limits
  - emergency stop
  - hard blocks for money, legal, medical, safety, conflict, scheduling, ambiguous questions, unsupported-content threads, and group auto-send

## Notes

- This MVP is intentionally text-first.
- When Ollama is selected, failures degrade the app into view-only/manual mode rather than switching to cloud without your configuration.
- OpenRouter sends prompt and context data to the configured cloud endpoint—use it only when that tradeoff is acceptable.
- All logs, memories, drafts, and summaries remain local to the machine.
