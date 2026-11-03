//
//  SettingsStore.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Combine
import Foundation
#if os(macOS)
import ServiceManagement
#endif

class SettingsStore: ObservableObject {
    static var shared: SettingsStore?

    var appLanguage: AppLanguage {
        AppLanguage(rawValue: languagePreference) ?? .zhTW
    }

    // MARK: - API

    @Published var selectedProviderID: String {
        didSet { UserDefaults.standard.set(selectedProviderID, forKey: "selectedProviderID") }
    }

    private var saveCustomProvidersTask: Task<Void, Never>?

    @Published var customProviders: [LLMProvider] {
        didSet {
            saveCustomProvidersTask?.cancel()
            let snapshot = customProviders
            saveCustomProvidersTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if let data = try? JSONEncoder().encode(snapshot) {
                    UserDefaults.standard.set(data, forKey: "customProviders")
                }
            }
        }
    }

    var allProviders: [LLMProvider] {
        LLMProvider.builtInProviders + customProviders
    }

    var selectedProvider: LLMProvider {
        let provider = allProviders.first(where: { $0.id == selectedProviderID }) ?? .openRouter
        // LM Studio: 使用用戶自訂的 base URL，容忍各種輸入格式
        if provider.id == "lmstudio", !lmStudioBaseURL.isEmpty {
            return LLMProvider(
                id: provider.id,
                name: provider.name,
                baseURL: Self.normalizeLMStudioURL(lmStudioBaseURL),
                extraHeaders: provider.extraHeaders,
                keyPlaceholder: provider.keyPlaceholder,
                modelHint: provider.modelHint,
                isBuiltIn: provider.isBuiltIn,
                requiresAPIKey: false
            )
        }
        return provider
    }

    /// 把使用者隨意輸入的 LM Studio URL 統一轉成 `<origin>/v1/chat/completions`。
    /// 容忍：尾巴 `/`、已含 `/v1`、已含 `/v1/chat/completions` 的情況。
    static func normalizeLMStudioURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }

        if s.hasSuffix("/chat/completions") { return s }
        if s.hasSuffix("/v1") { return s + "/chat/completions" }
        return s + "/v1/chat/completions"
    }

    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }

    // MARK: - Advanced LLM Parameters

    @Published var useCustomLLMParams: Bool {
        didSet { UserDefaults.standard.set(useCustomLLMParams, forKey: "useCustomLLMParams") }
    }

    @Published var llmMaxTokens: Int {
        didSet { UserDefaults.standard.set(llmMaxTokens, forKey: "llmMaxTokens") }
    }

    @Published var llmFrequencyPenalty: Double {
        didSet { UserDefaults.standard.set(llmFrequencyPenalty, forKey: "llmFrequencyPenalty") }
    }

    @Published var llmPresencePenalty: Double {
        didSet { UserDefaults.standard.set(llmPresencePenalty, forKey: "llmPresencePenalty") }
    }

    @Published var llmTopP: Double {
        didSet { UserDefaults.standard.set(llmTopP, forKey: "llmTopP") }
    }

    // MARK: - Prompt

    @Published var promptStyle: PromptStyle {
        didSet { UserDefaults.standard.set(promptStyle.rawValue, forKey: "promptStyle") }
    }

    // MARK: - Language

    @Published var languagePreference: String {
        didSet { UserDefaults.standard.set(languagePreference, forKey: "languagePreference") }
    }

    // MARK: - Auto Language Detection

    @Published var enableAutoLanguageDetection: Bool {
        didSet { UserDefaults.standard.set(enableAutoLanguageDetection, forKey: "enableAutoLanguageDetection") }
    }

    // MARK: - Tone

    @Published var toneStyle: ToneStyle {
        didSet { UserDefaults.standard.set(toneStyle.rawValue, forKey: "toneStyle") }
    }

    // MARK: - Updates

    @Published var enableAutoUpdateCheck: Bool {
        didSet { UserDefaults.standard.set(enableAutoUpdateCheck, forKey: "enableAutoUpdateCheck") }
    }

    /// 上一次自動檢查時間（用於做每日節流）。
    @Published var lastUpdateCheckAt: Date {
        didSet { UserDefaults.standard.set(lastUpdateCheckAt, forKey: "lastUpdateCheckAt") }
    }

    /// 從 GitHub 抓回的「最新可用版本」tag；用於 menu bar 顯示紅點。
    @Published var availableUpdateTag: String {
        didSet { UserDefaults.standard.set(availableUpdateTag, forKey: "availableUpdateTag") }
    }

    /// 對應 release 的 html_url。
    @Published var availableUpdateURL: String {
        didSet { UserDefaults.standard.set(availableUpdateURL, forKey: "availableUpdateURL") }
    }

    // MARK: - HotKey

    @Published var hotkeyKeyCode: Int {
        didSet { UserDefaults.standard.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") }
    }

    @Published var hotkeyModifiers: Int {
        didSet { UserDefaults.standard.set(hotkeyModifiers, forKey: "hotkeyModifiers") }
    }

    @Published var hotkeyTriggerMode: HotkeyTriggerMode {
        didSet { UserDefaults.standard.set(hotkeyTriggerMode.rawValue, forKey: "hotkeyTriggerMode") }
    }

    // MARK: - Audio Input

    @Published var selectedInputDeviceUID: String {
        didSet { UserDefaults.standard.set(selectedInputDeviceUID, forKey: "selectedInputDeviceUID") }
    }

    // MARK: - Processing Mode

    @Published var selectedMode: ProcessingMode {
        didSet { UserDefaults.standard.set(selectedMode.rawValue, forKey: "selectedMode") }
    }

    // MARK: - Feature Toggles

    @Published var enableContextAwareness: Bool {
        didSet { UserDefaults.standard.set(enableContextAwareness, forKey: "enableContextAwareness") }
    }

    @Published var enableOnDeviceSTT: Bool {
        didSet { UserDefaults.standard.set(enableOnDeviceSTT, forKey: "enableOnDeviceSTT") }
    }

    @Published var enableContinuousSTT: Bool {
        didSet { UserDefaults.standard.set(enableContinuousSTT, forKey: "enableContinuousSTT") }
    }

    @Published var enableSoundFeedback: Bool {
        didSet { UserDefaults.standard.set(enableSoundFeedback, forKey: "enableSoundFeedback") }
    }

    @Published var enableWhisperMode: Bool {
        didSet { UserDefaults.standard.set(enableWhisperMode, forKey: "enableWhisperMode") }
    }

    /// 人聲帶通降噪（80Hz – 8kHz biquad band-pass，去除低頻嗡嗡聲與高頻 hiss）
    @Published var enableVoiceBandpass: Bool {
        didSet { UserDefaults.standard.set(enableVoiceBandpass, forKey: "enableVoiceBandpass") }
    }

    /// 回音消除（Apple Voice Processing IO / AEC，消除喇叭播放洩漏進麥克風的聲音）
    @Published var enableEchoCancellation: Bool {
        didSet { UserDefaults.standard.set(enableEchoCancellation, forKey: "enableEchoCancellation") }
    }

    /// 輸入後觀察使用者的手動更正，自動加進個人字典（macOS）
    @Published var enableAutoLearnDictionary: Bool {
        didSet { UserDefaults.standard.set(enableAutoLearnDictionary, forKey: "enableAutoLearnDictionary") }
    }

    /// 錄音時 OCR 前景視窗文字給 AI 參考（macOS，需螢幕錄製權限）
    @Published var enableScreenContext: Bool {
        didSet { UserDefaults.standard.set(enableScreenContext, forKey: "enableScreenContext") }
    }

    /// 錄音時降低系統音量（macOS）
    @Published var enableDuckingWhileRecording: Bool {
        didSet { UserDefaults.standard.set(enableDuckingWhileRecording, forKey: "enableDuckingWhileRecording") }
    }

    // MARK: - Silence Detection

    @Published var silenceTimeout: Double {
        didSet { UserDefaults.standard.set(silenceTimeout, forKey: "silenceTimeout") }
    }

    @Published var enableAutoStop: Bool {
        didSet { UserDefaults.standard.set(enableAutoStop, forKey: "enableAutoStop") }
    }

    // MARK: - LM Studio

    @Published var lmStudioBaseURL: String {
        didSet { UserDefaults.standard.set(lmStudioBaseURL, forKey: "lmStudioBaseURL") }
    }

    // MARK: - STT Engine

    @Published var sttEngine: STTEngine {
        didSet { UserDefaults.standard.set(sttEngine.rawValue, forKey: "sttEngine") }
    }

    @Published var whisperModel: String {
        didSet { UserDefaults.standard.set(whisperModel, forKey: "whisperModel") }
    }

    // MARK: - Injection Mode

    @Published var injectionMode: InjectionMode {
        didSet { UserDefaults.standard.set(injectionMode.rawValue, forKey: "injectionMode") }
    }

    // MARK: - Preview Before Inject

    @Published var enablePreviewBeforeInject: Bool {
        didSet { UserDefaults.standard.set(enablePreviewBeforeInject, forKey: "enablePreviewBeforeInject") }
    }

    // MARK: - Preview Timeout

    @Published var previewTimeout: Double {
        didSet { UserDefaults.standard.set(previewTimeout, forKey: "previewTimeout") }
    }

    // MARK: - Smart Send

    @Published var enableSmartSend: Bool {
        didSet { UserDefaults.standard.set(enableSmartSend, forKey: "enableSmartSend") }
    }

    @Published var smartSendDelay: Double {
        didSet { UserDefaults.standard.set(smartSendDelay, forKey: "smartSendDelay") }
    }

    // MARK: - Capsule Scale

    @Published var capsuleScale: Double {
        didSet { UserDefaults.standard.set(capsuleScale, forKey: "capsuleScale") }
    }

    // MARK: - Microphone Sensitivity

    @Published var micSensitivity: Double {
        didSet { UserDefaults.standard.set(micSensitivity, forKey: "micSensitivity") }
    }

    // MARK: - History Auto Cleanup

    @Published var historyRetentionDays: Int {
        didSet { UserDefaults.standard.set(historyRetentionDays, forKey: "historyRetentionDays") }
    }

    @Published var enableHistoryAutoCleanup: Bool {
        didSet { UserDefaults.standard.set(enableHistoryAutoCleanup, forKey: "enableHistoryAutoCleanup") }
    }

    // MARK: - Launch at Login

    @Published var launchAtLogin: Bool {
        didSet {
            #if os(macOS)
            if launchAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
            #endif
        }
    }

    // MARK: - Context Rules

    private var saveContextRulesTask: Task<Void, Never>?

    @Published var contextRules: [ContextRule] {
        didSet {
            saveContextRulesTask?.cancel()
            let snapshot = contextRules
            saveContextRulesTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if let data = try? JSONEncoder().encode(snapshot) {
                    UserDefaults.standard.set(data, forKey: "contextRules")
                }
            }
        }
    }

    // MARK: - Voice Modes

    @Published var voiceModes: [VoiceMode] {
        didSet {
            // 編輯指令時每個按鍵都會觸發；debounce 0.4 秒再整包編碼寫入
            voiceModesSaveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flushVoiceModes() }
            voiceModesSaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private var voiceModesSaveWork: DispatchWorkItem?

    /// 立即寫入尚未落盤的 voiceModes（debounce 期間要結束時可呼叫）
    func flushVoiceModes() {
        voiceModesSaveWork?.cancel()
        voiceModesSaveWork = nil
        if let data = try? JSONEncoder().encode(voiceModes) {
            UserDefaults.standard.set(data, forKey: "voiceModes")
        }
    }

    func voiceMode(named name: String) -> VoiceMode? {
        voiceModes.first { $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
    }

    /// Find matching rule for a given app context identifier
    func contextRule(for appIdentifier: String) -> ContextRule? {
        contextRules.first { $0.appIdentifier == appIdentifier && $0.isEnabled }
    }

    // MARK: - Overlay Position

    @Published var overlayPositionX: Double {
        didSet { UserDefaults.standard.set(overlayPositionX, forKey: "overlayPositionX") }
    }

    @Published var overlayPositionY: Double {
        didSet { UserDefaults.standard.set(overlayPositionY, forKey: "overlayPositionY") }
    }

    @Published var hasCustomOverlayPosition: Bool {
        didSet { UserDefaults.standard.set(hasCustomOverlayPosition, forKey: "hasCustomOverlayPosition") }
    }

    // MARK: - URL Scheme / 捷徑控制

    /// 允許其他 App 透過 saybit:// URL 或「捷徑」控制錄音（saybit://settings 不受影響）
    @Published var enableURLSchemeControl: Bool = UserDefaults.standard.object(forKey: "enableURLSchemeControl") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enableURLSchemeControl, forKey: "enableURLSchemeControl") }
    }

    /// 不用詢問即可透過 saybit:// 控制錄音的來源 App（bundle ID）
    static let defaultURLSchemeAllowedSenders = [
        "com.apple.shortcuts",
        "com.raycast.macos",
        "com.runningwithcrayons.Alfred",
        "com.elgato.StreamDeck",
    ]

    @Published var urlSchemeAllowedSenders: [String] = UserDefaults.standard.stringArray(forKey: "urlSchemeAllowedSenders") ?? SettingsStore.defaultURLSchemeAllowedSenders {
        didSet { UserDefaults.standard.set(urlSchemeAllowedSenders, forKey: "urlSchemeAllowedSenders") }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        self.selectedProviderID = defaults.string(forKey: "selectedProviderID") ?? "openrouter"
        if let data = defaults.data(forKey: "customProviders"),
           let decoded = try? JSONDecoder().decode([LLMProvider].self, from: data)
        {
            self.customProviders = decoded
        } else {
            self.customProviders = []
        }
        self.selectedModel = defaults.string(forKey: "selectedModel") ?? "openai/gpt-4.1-nano"
        self.useCustomLLMParams = defaults.object(forKey: "useCustomLLMParams") as? Bool ?? false
        self.llmMaxTokens = defaults.object(forKey: "llmMaxTokens") as? Int ?? 4096
        self.llmFrequencyPenalty = defaults.object(forKey: "llmFrequencyPenalty") as? Double ?? 0.0
        self.llmPresencePenalty = defaults.object(forKey: "llmPresencePenalty") as? Double ?? 0.0
        self.llmTopP = defaults.object(forKey: "llmTopP") as? Double ?? 1.0
        self.promptStyle = PromptStyle(rawValue: defaults.string(forKey: "promptStyle") ?? "") ?? .typeless
        self.languagePreference = defaults.string(forKey: "languagePreference") ?? "zh-TW"
        self.enableAutoLanguageDetection = defaults.object(forKey: "enableAutoLanguageDetection") as? Bool ?? false
        self.toneStyle = ToneStyle(rawValue: defaults.string(forKey: "toneStyle") ?? "") ?? .auto
        self.enableAutoUpdateCheck = defaults.object(forKey: "enableAutoUpdateCheck") as? Bool ?? true
        self.lastUpdateCheckAt = (defaults.object(forKey: "lastUpdateCheckAt") as? Date) ?? .distantPast
        self.availableUpdateTag = defaults.string(forKey: "availableUpdateTag") ?? ""
        self.availableUpdateURL = defaults.string(forKey: "availableUpdateURL") ?? ""
        self.hotkeyKeyCode = defaults.object(forKey: "hotkeyKeyCode") as? Int ?? 49 // Space
        self.hotkeyModifiers = defaults.object(forKey: "hotkeyModifiers") as? Int ?? 0x80000 // Option
        self.hotkeyTriggerMode = HotkeyTriggerMode(rawValue: defaults.string(forKey: "hotkeyTriggerMode") ?? "") ?? .toggle
        self.selectedInputDeviceUID = defaults.string(forKey: "selectedInputDeviceUID") ?? ""
        self.selectedMode = ProcessingMode(rawValue: defaults.string(forKey: "selectedMode") ?? "") ?? .dictation
        self.enableContextAwareness = defaults.object(forKey: "enableContextAwareness") as? Bool ?? true
        self.enableOnDeviceSTT = defaults.object(forKey: "enableOnDeviceSTT") as? Bool ?? true
        self.enableContinuousSTT = defaults.object(forKey: "enableContinuousSTT") as? Bool ?? false
        self.enableSoundFeedback = defaults.object(forKey: "enableSoundFeedback") as? Bool ?? true
        self.enableWhisperMode = defaults.object(forKey: "enableWhisperMode") as? Bool ?? false
        self.enableVoiceBandpass = defaults.object(forKey: "enableVoiceBandpass") as? Bool ?? true
        self.enableScreenContext = defaults.bool(forKey: "enableScreenContext")
        self.enableAutoLearnDictionary = defaults.object(forKey: "enableAutoLearnDictionary") as? Bool ?? false
        self.enableDuckingWhileRecording = defaults.object(forKey: "enableDuckingWhileRecording") as? Bool ?? true
        self.enableEchoCancellation = defaults.object(forKey: "enableEchoCancellation") as? Bool ?? false
        self.silenceTimeout = defaults.object(forKey: "silenceTimeout") as? Double ?? 2.0
        self.enableAutoStop = defaults.object(forKey: "enableAutoStop") as? Bool ?? true
        self.lmStudioBaseURL = defaults.string(forKey: "lmStudioBaseURL") ?? "http://localhost:1234"
        self.sttEngine = STTEngine(rawValue: defaults.string(forKey: "sttEngine") ?? "") ?? .appleSpeech
        self.whisperModel = defaults.string(forKey: "whisperModel") ?? "whisper-1"
        self.injectionMode = InjectionMode(rawValue: defaults.string(forKey: "injectionMode") ?? "") ?? .paste
        self.enablePreviewBeforeInject = defaults.object(forKey: "enablePreviewBeforeInject") as? Bool ?? false
        self.previewTimeout = defaults.object(forKey: "previewTimeout") as? Double ?? 3.0
        self.enableSmartSend = defaults.object(forKey: "enableSmartSend") as? Bool ?? false
        self.smartSendDelay = defaults.object(forKey: "smartSendDelay") as? Double ?? 3.0
        self.capsuleScale = defaults.object(forKey: "capsuleScale") as? Double ?? 1.0
        self.micSensitivity = defaults.object(forKey: "micSensitivity") as? Double ?? 2.0
        #if os(macOS)
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        #else
        self.launchAtLogin = false
        #endif
        self.overlayPositionX = defaults.object(forKey: "overlayPositionX") as? Double ?? 0
        self.overlayPositionY = defaults.object(forKey: "overlayPositionY") as? Double ?? 0
        self.hasCustomOverlayPosition = defaults.bool(forKey: "hasCustomOverlayPosition")
        self.historyRetentionDays = defaults.object(forKey: "historyRetentionDays") as? Int ?? 30
        self.enableHistoryAutoCleanup = defaults.object(forKey: "enableHistoryAutoCleanup") as? Bool ?? false
        if let data = defaults.data(forKey: "contextRules"),
           let decoded = try? JSONDecoder().decode([ContextRule].self, from: data) {
            self.contextRules = decoded
        } else {
            self.contextRules = ContextRule.defaultRules
        }
        if let data = defaults.data(forKey: "voiceModes"),
           let decoded = try? JSONDecoder().decode([VoiceMode].self, from: data) {
            self.voiceModes = decoded
        } else {
            self.voiceModes = VoiceMode.presets
        }
    }
}
