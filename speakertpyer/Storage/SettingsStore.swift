//
//  SettingsStore.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Combine
import Foundation

class SettingsStore: ObservableObject {
    // MARK: - API

    @Published var selectedProviderID: String {
        didSet { UserDefaults.standard.set(selectedProviderID, forKey: "selectedProviderID") }
    }

    @Published var customProviders: [LLMProvider] {
        didSet {
            if let data = try? JSONEncoder().encode(customProviders) {
                UserDefaults.standard.set(data, forKey: "customProviders")
            }
        }
    }

    var allProviders: [LLMProvider] {
        LLMProvider.builtInProviders + customProviders
    }

    var selectedProvider: LLMProvider {
        allProviders.first(where: { $0.id == selectedProviderID }) ?? .openRouter
    }

    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }

    // MARK: - Prompt

    @Published var promptStyle: PromptStyle {
        didSet { UserDefaults.standard.set(promptStyle.rawValue, forKey: "promptStyle") }
    }

    // MARK: - Language

    @Published var languagePreference: String {
        didSet { UserDefaults.standard.set(languagePreference, forKey: "languagePreference") }
    }

    // MARK: - Tone

    @Published var toneStyle: ToneStyle {
        didSet { UserDefaults.standard.set(toneStyle.rawValue, forKey: "toneStyle") }
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

    @Published var enableSoundFeedback: Bool {
        didSet { UserDefaults.standard.set(enableSoundFeedback, forKey: "enableSoundFeedback") }
    }

    @Published var enableWhisperMode: Bool {
        didSet { UserDefaults.standard.set(enableWhisperMode, forKey: "enableWhisperMode") }
    }

    // MARK: - Silence Detection

    @Published var silenceTimeout: Double {
        didSet { UserDefaults.standard.set(silenceTimeout, forKey: "silenceTimeout") }
    }

    @Published var enableAutoStop: Bool {
        didSet { UserDefaults.standard.set(enableAutoStop, forKey: "enableAutoStop") }
    }

    // MARK: - STT Engine

    @Published var sttEngine: STTEngine {
        didSet { UserDefaults.standard.set(sttEngine.rawValue, forKey: "sttEngine") }
    }

    @Published var whisperModel: String {
        didSet { UserDefaults.standard.set(whisperModel, forKey: "whisperModel") }
    }

    // MARK: - Preview Before Inject

    @Published var enablePreviewBeforeInject: Bool {
        didSet { UserDefaults.standard.set(enablePreviewBeforeInject, forKey: "enablePreviewBeforeInject") }
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
        self.selectedModel = defaults.string(forKey: "selectedModel") ?? "openai/gpt-4.1-mini"
        self.promptStyle = PromptStyle(rawValue: defaults.string(forKey: "promptStyle") ?? "") ?? .typeless
        self.languagePreference = defaults.string(forKey: "languagePreference") ?? "zh-TW"
        self.toneStyle = ToneStyle(rawValue: defaults.string(forKey: "toneStyle") ?? "") ?? .auto
        self.hotkeyKeyCode = defaults.object(forKey: "hotkeyKeyCode") as? Int ?? 49 // Space
        self.hotkeyModifiers = defaults.object(forKey: "hotkeyModifiers") as? Int ?? 0x80000 // Option
        self.hotkeyTriggerMode = HotkeyTriggerMode(rawValue: defaults.string(forKey: "hotkeyTriggerMode") ?? "") ?? .toggle
        self.selectedInputDeviceUID = defaults.string(forKey: "selectedInputDeviceUID") ?? ""
        self.selectedMode = ProcessingMode(rawValue: defaults.string(forKey: "selectedMode") ?? "") ?? .dictation
        self.enableContextAwareness = defaults.object(forKey: "enableContextAwareness") as? Bool ?? true
        self.enableOnDeviceSTT = defaults.object(forKey: "enableOnDeviceSTT") as? Bool ?? true
        self.enableSoundFeedback = defaults.object(forKey: "enableSoundFeedback") as? Bool ?? true
        self.enableWhisperMode = defaults.object(forKey: "enableWhisperMode") as? Bool ?? false
        self.silenceTimeout = defaults.object(forKey: "silenceTimeout") as? Double ?? 2.0
        self.enableAutoStop = defaults.object(forKey: "enableAutoStop") as? Bool ?? true
        self.sttEngine = STTEngine(rawValue: defaults.string(forKey: "sttEngine") ?? "") ?? .appleSpeech
        self.whisperModel = defaults.string(forKey: "whisperModel") ?? "whisper-1"
        self.enablePreviewBeforeInject = defaults.object(forKey: "enablePreviewBeforeInject") as? Bool ?? false
        self.enableSmartSend = defaults.object(forKey: "enableSmartSend") as? Bool ?? false
        self.smartSendDelay = defaults.object(forKey: "smartSendDelay") as? Double ?? 3.0
        self.capsuleScale = defaults.object(forKey: "capsuleScale") as? Double ?? 1.0
        self.micSensitivity = defaults.object(forKey: "micSensitivity") as? Double ?? 2.0
        self.overlayPositionX = defaults.object(forKey: "overlayPositionX") as? Double ?? 0
        self.overlayPositionY = defaults.object(forKey: "overlayPositionY") as? Double ?? 0
        self.hasCustomOverlayPosition = defaults.bool(forKey: "hasCustomOverlayPosition")
        self.historyRetentionDays = defaults.object(forKey: "historyRetentionDays") as? Int ?? 30
        self.enableHistoryAutoCleanup = defaults.object(forKey: "enableHistoryAutoCleanup") as? Bool ?? false
    }
}
