# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Two separate apps in this repo

- **`speakertpyer/`** — the native macOS SwiftUI menu-bar app (bundle `com.bashcat.speakertpyer`). Everything below in this file describes it.
- **`saybit-desktop/`** — a **separate** Tauri 2.0 cross-platform (Windows/macOS/Linux) app (bundle `com.oliver.saybit-desktop`), React + Rust. Same product concept, no shared code. It has its own `saybit-desktop/CLAUDE.md` — read that when working there. Don't confuse the two: launching `/Applications/Saybit.app` runs the native app, not the Tauri build.

## iOS app (same Xcode project)

- Targets `SaybitiOS` (app, bundle `com.bashcat.speakertpyer`, scheme `SaybitiOS`) + `SaybitKeyboard` (keyboard extension, `com.bashcat.speakertpyer.keyboard`). App Group `group.com.bashcat.speakertpyer`.
- `SaybitiOS` compiles `speakertpyer/` too, minus macOS-only files listed in the "Exceptions for speakertpyer folder in SaybitiOS target" set in pbxproj (App/, UI/, Accessibility/, HotKey/, Update/, VoicePipeline, BackgroundSTTEngine, MicLevelTester, Assets). **A new macOS-only file under `speakertpyer/` must be added to that exception list** (or wrapped in `#if os(macOS)`), otherwise the iOS build breaks.
- Shared LLM logic lives in `Core/LLM/TextRefiner.swift` (used by both macOS `VoicePipeline` and iOS `MobileVoicePipeline`) — change intent/refine behavior there, not in a pipeline.
- Keyboard extensions can't use the mic: the keyboard sends commands over `SaybitShared/KeyboardBridge` (App Group defaults + Darwin notifications); the main app records in the background (`UIBackgroundModes=audio`, "鍵盤待命" session with heartbeat) or is woken via `saybit://dictate?source=keyboard`. The keyboard needs "Allow Full Access".
- Offline STT engine `STTEngine.sherpaSenseVoice` (iOS only, case is `#if os(iOS)`): sherpa-onnx SenseVoice int8 + Silero VAD in `SaybitiOS/STT/`. Prebuilt static xcframeworks live in gitignored `Vendor/sherpa-onnx/` — **run `scripts/fetch-sherpa-onnx.sh` once after cloning** or the iOS build fails (bridging header can't find `c-api.h`). This is the one deliberate exception to "no external packages". The ~240MB model is downloaded at runtime by `SherpaModelManager` (Application Support, excluded from backup). All sherpa objects live on `SherpaWorker`'s serial queue — never touch them from another thread.

## Feature notes (macOS)

- **Voice modes** (`Models/VoiceMode.swift`, `settingsStore.voiceModes`): per-mode instructions + own hotkey. Mode hotkeys share the main event tap via `GlobalHotKeyManager.extraBindings` (exact modifier match, checked before the main hotkey). A mode skips Stage 1 intent classification (`RefineRequest.modeInstructions` → `SystemPrompts.forMode`).
- **URL scheme** `saybit://toggle|start|stop|cancel[?mode=Name]`, plus `saybit://settings?tab=<SettingsTab rawValue>` (opens settings on that tab, no refocus; handy for screenshotting each tab) — declared in `Config/Saybit-macOS-Info.plist` (merged with the generated plist). Opening a URL activates Saybit, so `AppDelegate` re-activates the last external app before handling. LaunchServices won't bind the scheme for builds run from DerivedData/tmp; test with `open -a <path>/Saybit.app "saybit://toggle"`.
- **Apple on-device LLM**: provider id `apple-on-device`; `OpenRouterClient` routes it to `AppleOnDeviceLLM` (FoundationModels) instead of HTTP.
- **Dictionary at recognition time**: `DictionaryHints` feeds preferred spellings to Apple Speech `contextualStrings` and does literal term→preferred replacement (ASCII terms whole-word) in `TextRefiner` before the LLM.
- **Auto-learn dictionary** (`DictionaryAutoLearner`): watches the focused AX element ~30s after inject; learns only a single short replacement inside the injected range (no pure inserts/deletes, no punctuation, CJK expanded to ≥2 chars).
- **Screen context** (`ScreenContextCapture`): OCR of the frontmost window via ScreenCaptureKit + Vision, sent as `screen_context`; off by default, needs Screen Recording permission.
- **Ducking** (`SystemAudioDucker`): lowers system output volume while recording; pending restore stored in UserDefaults and applied on next launch.
- **File transcription** tab (`UI/Transcribe/FileTranscriptionView`, `SherpaFileTranscriber`): AVAssetReader → 16k PCM → VAD → SenseVoice, separate recognizer instance.
- Don't run end-to-end dictation tests with Smart Send on while the user is in another app — it will type into and send in whatever app has focus.

## Build & Run

```bash
# Build (via XcodeBuildMCP)
mcp__XcodeBuildMCP__build_macos

# Build & Run
mcp__XcodeBuildMCP__build_run_macos

# Kill running instance before relaunch
pkill -f "speakertpyer"
```

Xcode project uses `PBXFileSystemSynchronizedRootGroup` — new Swift files are auto-discovered, no need to edit pbxproj.

## Architecture

**Saybit** is a macOS menu bar app (LSUIElement) that converts speech to LLM-refined text and injects it into any focused application.

### Pipeline Flow

```
Hotkey → Recording (SpeechRecognizer) → STT transcript
  → LLM processing (OpenRouterClient, streaming)
  → TextInjector (Cmd+V paste into focused app)
  → Optional Smart Send (countdown → auto Enter)
```

### Key Layers

| Layer | Location | Role |
|-------|----------|------|
| Entry | `App/` | SaybitApp (@main, MenuBarExtra), AppDelegate (permissions, hotkey) |
| Pipeline | `Core/Pipeline/VoicePipeline.swift` | State machine orchestrator — the central coordinator |
| STT | `Core/SpeechRecognition/` | SpeechRecognizer (Speech framework), AudioLevelMonitor, AudioSessionManager |
| LLM | `Core/LLM/` | OpenRouterClient (actor, streaming), SystemPrompts, LLMPayload |
| Accessibility | `Core/Accessibility/` | TextExtractor (AX API), TextInjector (CGEvent Cmd+V / Enter) |
| HotKey | `Core/HotKey/` | GlobalHotKeyManager (event tap) |
| Models | `Models/` | TranscriptionSession (@Observable state machine), enums |
| Storage | `Storage/` | SettingsStore (UserDefaults), Persistence (Core Data), KeychainHelper |
| UI | `UI/` | Overlay (floating NSPanel capsule), Settings, MenuBar, History, Onboarding |

### State Machine

`TranscriptionSession.State`: `.idle` → `.recording` → `.processing` → `.done` → `.confirming(remaining:)` → `.idle`

### Settings Pattern

All settings are `@Published` with `didSet` → `UserDefaults`. No Core Data for settings. Core Data is for history (TranscriptionRecord), dictionary (PersonalDictionaryEntry), and snippets (SnippetEntry).

### Overlay Window

`OverlayWindowController` manages a floating NSPanel. Right-click context menu is handled via `NSEvent.addLocalMonitorForEvents` (SwiftUI intercepts rightMouseDown). Settings window is created as direct NSWindow (MenuBarExtra apps can't use `showSettingsWindow:` from NSPanel context menus).

## Conventions

- UI language: Traditional Chinese (繁體中文)
- Settings UI uses `GlassCard` + `GlassSectionHeader`; rows inside a card use `SettingToggle` / `SettingRow` / `SettingSlider` / `SettingDescription` / `SettingIndent` (in `SettingsView.swift`) so switches stay right-aligned and descriptions use `.callout`. Don't hand-roll `Toggle` + `Text(.body)` pairs.
- Settings tab selection lives in `SettingsNavigation.shared`; open settings via `OverlayWindowController.shared.openSettings(tab:)` (menu bar, overlay menu and URL all use it). Each `SettingsTab` has `searchKeywords` so sidebar search can dim/jump across tabs — add keywords there when adding a card.
- No external SPM packages — all system frameworks
- API key stored in Keychain via `KeychainHelper`
- Logs written to `~/Library/Application Support/Saybit/logs/` (JSONL, 7-day retention)

## Known Gotchas

- `NSWindow.isReleasedWhenClosed` must be set to `false` for programmatically created settings windows, otherwise the strong reference becomes a dangling pointer after close
- `scaleEffect` must be applied **before** `clipShape`/`background` in SwiftUI, otherwise only content scales but the capsule shape stays unchanged
- The overlay NSPanel size (840x160) must accommodate the maximum capsule scale (2x)
