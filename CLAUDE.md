# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

**SpeakerTyper** is a macOS menu bar app (LSUIElement) that converts speech to LLM-refined text and injects it into any focused application.

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
| Entry | `App/` | SpeakerTyperApp (@main, MenuBarExtra), AppDelegate (permissions, hotkey) |
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
- Settings UI uses `GlassCard` + `GlassSectionHeader` components
- No external SPM packages — all system frameworks
- API key stored in Keychain via `KeychainHelper`
- Logs written to `~/Library/Application Support/SpeakerTyper/logs/` (JSONL, 7-day retention)

## Known Gotchas

- `NSWindow.isReleasedWhenClosed` must be set to `false` for programmatically created settings windows, otherwise the strong reference becomes a dangling pointer after close
- `scaleEffect` must be applied **before** `clipShape`/`background` in SwiftUI, otherwise only content scales but the capsule shape stays unchanged
- The overlay NSPanel size (840x160) must accommodate the maximum capsule scale (2x)
