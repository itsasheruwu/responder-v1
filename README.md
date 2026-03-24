# Responder

Responder is a native macOS SwiftUI app that drafts iMessage replies using a local Ollama model, keeps memory and logs on-device, and offers opt-in autonomy controls with simulation and policy gates.

## Install

Download the latest release assets from GitHub or run:

```bash
curl -fsSL https://raw.githubusercontent.com/itsasheruwu/responder-v1/main/install.sh | bash
```

The installer pulls the latest `Responder.app.zip` release and installs `Responder.app` into `/Applications`.

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
  - Ollama integration
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

Build the local release artifacts:

```bash
./scripts/release.sh
```

That script generates:

- `release/1.0.2/Responder.app.zip`
- `release/1.0.2/Responder-1.0.2.pkg`
- `release/1.0.2/install.sh`

## Local Runtime Requirements

- macOS 15 or later
- Ollama running locally on `http://127.0.0.1:11434`
- A local Messages history database at `~/Library/Messages/chat.db`
- Permission to automate Messages if you want sending or real autonomy

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

### 4. Full Disk Access may be needed for reliable Messages DB reads

Depending on macOS privacy settings, reading `~/Library/Messages/chat.db` may require broader filesystem access.

Best workaround:

- Instruct the user to grant Full Disk Access to Responder if conversation loading fails
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
- Ollama failures degrade the app into view-only/manual mode rather than attempting remote fallback.
- All logs, memories, drafts, and summaries remain local to the machine.
