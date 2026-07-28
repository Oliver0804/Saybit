# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`saybit-desktop/` is the **Tauri 2.0 cross-platform** (Windows / macOS / Linux) rewrite of Saybit — a voice-to-LLM-refined-text tool. It is a **separate app** from the native macOS SwiftUI version in `../speakertpyer/` (bundle `com.bashcat.speakertpyer`); this one is bundle `com.oliver.saybit-desktop`. They share the product concept, not code. Frontend is React 19 + Vite 7 + Tailwind; backend is Rust.

## Dev & Build

```bash
# Dev (HMR). Port 1420 is hardcoded in vite.config.ts + tauri.conf.json.
# If 1420 is taken, override without editing those files:
npx tauri dev --config '{"build":{"beforeDevCommand":"npm run dev -- --port 1421 --strictPort","devUrl":"http://localhost:1421"}}'

npx tauri dev          # normal case (port 1420 free)
npm run tauri build    # produce .app / .dmg / .msi
npx tsc --noEmit       # frontend typecheck — run before declaring frontend work done
cd src-tauri && cargo check   # Rust typecheck (whisper.cpp first build is minutes)
```

`tauri dev`'s file watcher auto-recompiles Rust on `src-tauri/**` changes and restarts the app; Vite HMR handles `src/**`. Editing `tauri.conf.json`, `Cargo.toml` features, or `capabilities/*.json` forces a full Rust rebuild. New Tauri `invoke` commands only take effect after that rebuild — verify with `strings src-tauri/target/debug/saybit-desktop | grep <command>`.

## Two-webview architecture

`tauri.conf.json` declares two windows: **`main`** (Settings, 900×650) and **`overlay`** (the floating capsule, 420×90, transparent, always-on-top, `visible:false`). `App.tsx` branches on `getCurrentWindow().label` to render `SettingsView` vs `OverlayView`. Both webviews run their own `useVoicePipeline` instance — this is the source of most cross-window bugs:

- **Only `overlay` may respond to the global hotkey / drive recording** (guarded by `isOverlay` in the hook), else both webviews grab the mic.
- **Settings changes must propagate across webviews** via the `settings-updated` Tauri event (`emit` in `updateSettings`, `listen` in the hook). localStorage alone doesn't reach the other webview's in-memory state.
- **Overlay show/hide is state-driven**: the hook calls `show_window`/`hide_window('overlay')` on state transitions (idle → hidden).

## Pipeline (`src/hooks/useVoicePipeline.ts`)

The whole state machine + audio + STT + LLM orchestration lives in this one hook. Flow:

```
hotkey → startRecording (MediaRecorder WebM/Opus, getUserMedia with AEC/NS/AGC)
  → silence auto-stop (RMS < threshold)
  → processAudio: STT → classifyIntent → refineTextStream (streaming) → history
  → previewing (if enabled) → injectResult: clipboard write + simulate_paste
  → optional Smart Send countdown → simulate_enter
```

State: `idle | listening | recording | processing | previewing | done | confirming | error`.

**STT has four engines** (`settings.sttEngine`):
- `streaming`: WebSocket 串流辨識 via `src-tauri/src/streaming_stt.rs` — recognizes while you speak, so the transcript is ready the instant recording stops. Two providers: **阿里雲百鍊** (Fun-ASR-Realtime / Qwen-ASR, JSON `run-task`/`finish-task` directives + binary audio frames) and **訊飛 RTASR** (query-string signature, `{"end":true}` terminator). Partial results stream back to the capsule via the `stt-partial` event. **The WebSocket lives in Rust, not the webview** — Alibaba authenticates with an `Authorization: bearer` header on the handshake, which the browser WebSocket API cannot set. If the connection fails at record start, it silently falls back to the batch cloud-Whisper path rather than failing the recording.
- `apple`: `SFSpeechRecognizer` via `src-tauri/src/apple_speech.rs` — **macOS only**, gated in the UI by the `apple_speech_supported` command. No model download, no key, lower latency than whisper; weaker punctuation, which the LLM refine step compensates for. `appleSpeechOnDeviceOnly` maps to `requiresOnDeviceRecognition` — when the locale has no local model this errors instead of silently falling back to Apple's servers. Needs `NSSpeechRecognitionUsageDescription` in `Info.plist`.
- `cloud`: `services/llm.ts` → OpenAI (`whisper-1`) or Groq (`whisper-large-v3`), switchable base URL. **STT and LLM keys are different providers** — Whisper needs an OpenAI/Groq key; OpenRouter/DeepSeek keys only work for the LLM refine step. 401 = wrong key type, 429 = OpenAI quota (suggest Groq or local).
- `local`: whisper.cpp via `src-tauri/src/local_stt.rs`. Model (`ggml-large-v3-turbo-q5_0`, ~574 MB) downloads on demand via `download_stt_model` (progress on the `stt-model-progress` event); `WhisperContext` is cached in a `static Mutex` so it loads once.

Both STT paths bias toward Traditional Chinese (Taiwan) via an initial prompt, augmented with the user's personal dictionary terms.

## Audio capture (`services/audioChain.ts`)

**Not MediaRecorder.** Capture is raw Float32 PCM through a Web Audio graph:
`getUserMedia → [highpass 80Hz → lowpass 8kHz] → analyser + AudioWorklet`. Three reasons this replaced the old WebM/Opus recorder:
1. The pre-roll ring buffer needs audio from *before* the hotkey press; WebM chunks can't be prepended (only the first chunk carries the header).
2. Local whisper.cpp wants 16 kHz mono f32 anyway — the old path recorded WebM then decoded it back to PCM.
3. The band-pass filter has to act on what gets sent to STT, which means it belongs in the graph.

The `AudioContext` is constructed at **16 kHz directly** (`new AudioContext({sampleRate: 16000})`) so the browser's own resampler does the downconversion — this removes manual resampling from both the batch and streaming paths, and avoids block-boundary seams that a hand-rolled incremental resampler would introduce. Environments that reject an explicit sample rate fall back to the default, and `resampleTo16k` still covers them.

`setLiveTap()` registers a per-chunk callback used by streaming STT to push audio out during recording; failures inside the tap are swallowed so a dropped WebSocket never takes the recording down with it.

The worklet is loaded from a Blob URL (no extra bundled file) with a `ScriptProcessorNode` fallback. `resampleTo16k` + `pcmToWavBlob` produce the upload for the cloud path. Biquad Q is `0.7071067` — the same Butterworth value as the native `VoiceBandpassFilter`.

## Rust backend (`src-tauri/src/`)

| Module | Commands |
|--------|----------|
| `lib.rs` | `simulate_enter`, `apply_vibrancy`, `show_window`, `hide_window`, `set_hotkey`, `show_overlay_menu`, `frontend_log`, `read_log`, `clear_log` |
| `platform.rs` | `foreground_app`, `get_selected_text` |
| `injection.rs` | `inject_text` (paste / keypress / replace_selection) |
| `secure_store.rs` | `secret_get`, `secret_set`, `secret_delete` |
| `eventkit.rs` | `action_intents_supported`, `create_calendar_event`, `create_reminder` (macOS only) |
| `apple_speech.rs` | `apple_speech_supported`, `apple_speech_authorized`, `apple_speech_authorize`, `transcribe_apple` (macOS only) |
| `streaming_stt.rs` | `streaming_stt_start`, `streaming_stt_push`, `streaming_stt_finish`, `streaming_stt_cancel`, `streaming_stt_test` |
| `local_stt.rs` | `local_stt_status`, `download_stt_model`, `transcribe_local` |

`main.rs` is a one-line shim into `lib.rs::run()`.

Hotkey events: the global-shortcut handler emits **`hotkey-pressed` and `hotkey-released`**. All three trigger modes (toggle / hold / doubleTap) are decided in the frontend from that pair — the Rust side has no mode knowledge.

## Non-obvious gotchas (all hit and fixed in practice)

- **enigo key simulation must run on the main thread on macOS.** Tauri commands run on tokio worker threads; enigo's macOS keycode lookup calls Text Input Source APIs (`TSMGetInputSourceProperty` / HIToolbox) that `dispatch_assert_queue` the main thread and **crash the whole app** (SIGTRAP) otherwise. `simulate_paste`/`simulate_enter` wrap the enigo calls in `app.run_on_main_thread(...)`.
- **The transparent overlay's rendering gets paused when it's not on the active Space** → `requestAnimationFrame` drops to ~0-2fps, which looks like ~1s of input lag on the waveform (canvas repaints once or twice a second). Fix: `visibleOnAllWorkspaces: true` on the overlay window (the Tauri equivalent of the native app's `NSWindow.collectionBehavior = .canJoinAllSpaces`). Confirmed via an in-webview rAF fps probe: `onscreen=false` → paused, `visibleOnAllWorkspaces` → steady 60fps. Corollary: the waveform reads the analyser directly each frame and keeps the rightmost bar = live level, so it never lags behind the audio once the window renders at 60fps.

- **Transparent windows need a compile-time feature.** `tauri` must have the `macos-private-api` feature in `Cargo.toml` **and** `app.macOSPrivateApi: true` in `tauri.conf.json`. Config alone → the transparent window never paints.
- **`apply_vibrancy` (NSVisualEffectView) fills the whole rectangular window**, defeating the capsule's rounded transparency. `App.tsx` must **not** call it for the `overlay` label — only the Settings window gets vibrancy. Overlay also sets `shadow:false` (OS window shadow draws a rectangular halo around the pill).
- **`fetch` in the WKWebView masks CORS-less error responses as `TypeError: Load failed`** — OpenAI's 401/429 bodies carry no CORS header, so the real status is invisible. All external API calls go through `@tauri-apps/plugin-http`'s `fetch` (Rust-side request, no CORS). See `[[tauri-webview-fetch-load-failed]]`.
- **Tauri v2 permissions are explicit.** A `<plugin>:default` set does **not** include write actions. Clipboard write needed `clipboard-manager:allow-write-text` added to `capabilities/default.json`; HTTP needed an `http:default` entry with a URL allowlist. A denied command surfaces as `<command> not allowed. Permissions associated...`.
- **`"clipboard-manager": {}` (empty config) crashes v2 plugin init** with `invalid type: map, expected unit`. Leave plugin config out of `tauri.conf.json` (empty `"plugins": {}`), configure via Builder in `lib.rs` instead.
- **Debugging the webview**: `console.log` isn't visible in headless runs. `logToFile()` in the hook calls the `frontend_log` command, which appends to `~/Library/Application Support/com.oliver.saybit-desktop/frontend.log`. Rust startup writes `startup.log` in the same dir. `tail -f` these to trace a run.
- **Waveform must not go through React state.** The canvas `draw()` reads `audioChain.getAnalyser().getByteTimeDomainData()` directly each RAF frame; `setAudioLevel` is throttled to ~15 Hz for the silence-detection logic only. Feeding `audioLevel` into the canvas useEffect deps caused ~1 s visible lag.
- **`setState` is not visible to the next rAF frame.** The pipeline mirrors state into `stateRef` and every transition goes through `transitionTo()`, which writes the ref *synchronously* before calling `setState`. Without this, `monitorAudioLevel()`'s first frame reads the pre-transition state and returns immediately — waveform and silence detection never start. Same hazard applies to the hotkey handlers.
- **The overlay must never take focus.** `show_window` skips `set_focus()` for the `overlay` label. If Saybit becomes the frontmost app, `foreground_app` reports Saybit itself and the subsequent paste lands in the capsule. This is the Tauri stand-in for the native app's `nonactivatingPanel`.
- **Foreground-app queries go through `run_on_main_thread`.** `NSWorkspace` is AppKit; the same off-main-thread hazard as enigo applies. The result comes back over an `mpsc` channel with a 500 ms timeout.
- **Selection capture simulates Cmd/Ctrl+C, so terminals are excluded.** With no selection, Ctrl+C in a terminal is SIGINT and would kill whatever the user is running. `isSelectionCaptureSafe()` blocks the `terminal` context. The native app has no such problem because it reads selection through the AX API, which has no Tauri equivalent.
- **Never call `secret_get` without the process-level cache.** macOS pops a keychain authorization dialog on *every* `get_password`, and both webviews read two keys each — with StrictMode's double-mount that is 8 prompts per launch. `secure_store.rs` caches values in a `HashMap` for the process lifetime. Separately, "Always Allow" never sticks in `tauri dev` because each rebuild changes the binary's signature and the keychain ACL is bound to it; only a stable-signed release build makes it persist.
- **Whisper hallucinates on silence rather than returning empty.** Fed near-silence it emits YouTube-subtitle residue from its training data (`字幕:CM 李宗盛`, `謝謝。`, `Thanks for watching!`). `services/sttArtifacts.ts` gates on energy before STT (`peak >= 0.06 || rms >= 0.02`, calibrated against measured values: 0.012 silence leak / 0.033 noise / 0.251 real speech) and pattern-matches known artifacts after. Exact-match, not substring — a user genuinely saying 「感謝觀看」 must survive.
- **The OS repeats `hotkey-pressed` while the key is held.** Combined with `startRecording`'s async prologue (during which state is still `idle`), toggle mode would start a *second* recording whose `beginCapture()` discards the first one's audio — the symptom is a recording far shorter than what was spoken. Fixed by tracking held state via `hotkey-released` plus a synchronous `isStartingRef` guard.
- **Capsule content must not swallow drag events.** `data-tauri-drag-region` only applies to the element under the cursor, so the waveform canvas and text labels inside the capsule blocked window dragging. Non-interactive content carries `pointer-events-none`; buttons re-enable with `pointer-events-auto`.
- **Intent classification needs a hard timeout.** Ported from `classifyIntentWithTimeout` (8 s + fallback to dictation) — without it a slow provider stalls the whole pipeline; one measured run took 25 s. The fallback records a `degradedReason` so logs distinguish "model said dictation" from "classification never succeeded".
- **Local/custom providers reject `stream_options` and `response_format`.** LM Studio, Ollama and `custom-*` endpoints 400 on both. `isLocalOrCustom()` in `llm.ts` gates them; without the `response_format` gate, intent classification silently degraded to plain dictation on every local model.

## Persistence

- `services/db.ts` — Dexie (IndexedDB) tables: `history`, `dictionary`, `skills`. History carries real token usage and an estimated `costUsd` (see `services/pricing.ts`); unknown models store `null` rather than 0 so the stats page can say what it couldn't price.
- Settings — one JSON blob in `localStorage` under `saybit_settings_v2`. `loadSettings()` merges over `DEFAULT_SETTINGS`, so new fields never break an old profile; `migrateLegacySettings()` folds in the 0.2.x scattered `saybit_*` keys.
- **API keys — system keychain, never localStorage.** `secret_get`/`secret_set` wrap the `keyring` crate (macOS Keychain / Windows Credential Manager / Linux Secret Service). Accounts are `llm.<providerId>` and `stt.<openai|groq|custom>`. `migratePlaintextKeys()` moves any 0.2.x plaintext keys across once and deletes the originals. Keys are *not* part of the settings broadcast — changing one emits a separate **`secrets-updated`** event so the overlay reloads them.

## Ported from the native app

These are direct ports of `../speakertpyer/` logic — when changing behaviour, check the Swift original first:

| TS | Swift original |
|----|----------------|
| `services/systemPrompts.ts` | `Core/LLM/SystemPrompts.swift` |
| `services/appContext.ts` | `Models/AppContext.swift` |
| `services/contextRules.ts` | `Models/ContextRule.swift` |
| `services/providers.ts` | `Core/LLM/LLMProvider.swift` |
| `services/pricing.ts` | `Core/LLM/ModelPricing.swift` |
| `services/settings.ts` | `Storage/SettingsStore.swift` + `Storage/KeychainHelper.swift` |
| `services/updateChecker.ts` | `Core/Update/UpdateChecker.swift` |
| `services/hotkeyConflicts.ts` | `Core/HotKey/HotKeyConflictChecker.swift` |
| `services/l10n.ts` | `Core/Localization/L10n.swift` |
| `src-tauri/src/injection.rs` | `Core/Accessibility/TextInjector.swift` + `ClipboardBackup.swift` |
| `src-tauri/src/eventkit.rs` | `Core/EventKit/EventKitManager.swift` |
| `services/audioChain.ts` | `SharedAudioEngine` + `VoiceBandpassFilter` + `PreBufferRing` |

Two deliberate divergences from the native app, both forced by platform limits: selection capture uses the clipboard instead of the AX API (hence the terminal exclusion above), and clipboard backup/restore is text-only — the Tauri clipboard plugin can't snapshot every pasteboard type the way `ClipboardBackup.swift` does, so restoring after an image copy loses the image.

## Conventions

UI language follows `settings.appLanguage` via `services/l10n.ts` (zh-TW / zh-CN / en-US / ja-JP); new user-facing strings go in that table rather than being inlined. Tailwind utility classes inline; shared controls live in `components/ui.tsx` (`GlassCard`, `Row`, `Toggle`, `Segmented`, …) — the counterpart to the native `GlassCard` / `GlassSectionHeader`. `bg-slate-900/75` + `backdrop-blur` + `rounded-full` is the capsule look. No design-system library.
