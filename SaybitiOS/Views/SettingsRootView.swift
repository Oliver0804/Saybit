//
//  SettingsRootView.swift
//  SaybitiOS
//
//  設定分成：錄音與辨識 / AI 潤飾 / Saybit 鍵盤 / 輸出與回饋 / 歷史紀錄 / 權限 / 關於。
//  每組用 Section header 分類、說明一律放 footer。
//

import AVFoundation
import Speech
import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var mobileSettings: MobileSettings

    var body: some View {
        NavigationStack {
            Form {
                recordingSection
                aiSection
                keyboardSection
                outputSection
                historySection
                PermissionsSection()
                aboutSection
            }
            .navigationTitle("設定")
        }
    }

    // MARK: - 錄音與辨識

    private var recordingSection: some View {
        Section {
            NavigationLink {
                SpeechSettingsView()
            } label: {
                LabeledContent("語音辨識引擎") {
                    Text(settingsStore.sttEngine.displayName)
                        .lineLimit(1)
                }
            }
            Toggle("說完自動停止", isOn: $settingsStore.enableAutoStop)
            if settingsStore.enableAutoStop {
                Stepper(value: $settingsStore.silenceTimeout, in: 1...6, step: 0.5) {
                    LabeledContent("靜音多久後停止", value: String(format: "%.1f 秒", settingsStore.silenceTimeout))
                }
            }
            Toggle("嘈雜環境模式", isOn: $settingsStore.enableWhisperMode)
        } header: {
            Text("錄音與辨識")
        } footer: {
            Text("「說完自動停止」偵測到靜音就結束錄音。嘈雜環境模式會提醒 AI 忽略辨識到的背景人聲與雜訊，只保留你說的內容。")
        }
    }

    // MARK: - AI 潤飾

    private var aiSection: some View {
        Section {
            NavigationLink {
                ProviderSettingsView()
            } label: {
                LabeledContent("服務商與模型") {
                    Text("\(settingsStore.selectedProvider.name) · \(settingsStore.selectedModel)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Picker("處理風格", selection: $settingsStore.promptStyle) {
                ForEach(PromptStyle.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("語氣", selection: $settingsStore.toneStyle) {
                ForEach(ToneStyle.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("輸出語言", selection: $settingsStore.languagePreference) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
        } header: {
            Text("AI 潤飾")
        } footer: {
            Text("Saybit 用你自己的 API Key 呼叫 AI 去除贅字、補標點。處理風格與語氣決定潤飾後的樣子，輸出語言可以和你說的語言不同（等於順便翻譯）。")
        }
    }

    // MARK: - 鍵盤

    private var keyboardSection: some View {
        Section {
            NavigationLink("安裝與使用說明") { KeyboardSetupView() }
            Picker("待命時間", selection: $mobileSettings.keyboardSessionMinutes) {
                ForEach(MobileSettings.sessionMinuteOptions, id: \.self) { Text("\($0) 分鐘").tag($0) }
            }
        } header: {
            Text("Saybit 鍵盤")
        } footer: {
            Text("待命期間 Saybit 會在背景保持麥克風（狀態列會出現麥克風圖示），鍵盤按下麥克風就能直接錄音，不必跳回 App；時間到會自動釋放。")
        }
    }

    // MARK: - 輸出與回饋

    private var outputSection: some View {
        Section {
            Toggle("完成後自動複製", isOn: $mobileSettings.autoCopyResult)
            Toggle("觸覺回饋", isOn: $mobileSettings.hapticFeedback)
            Toggle("提示音", isOn: $settingsStore.enableSoundFeedback)
        } header: {
            Text("輸出與回饋")
        } footer: {
            Text("在 Saybit 裡錄音完成後，結果會自動複製到剪貼簿；從鍵盤發起的錄音則直接輸入到你原本的 App。")
        }
    }

    // MARK: - 歷史

    private var historySection: some View {
        Section {
            Toggle("自動清除舊紀錄", isOn: $settingsStore.enableHistoryAutoCleanup)
            if settingsStore.enableHistoryAutoCleanup {
                Picker("保留期間", selection: $settingsStore.historyRetentionDays) {
                    ForEach([7, 30, 90, 365], id: \.self) { Text("\($0) 天").tag($0) }
                }
            }
        } header: {
            Text("歷史紀錄")
        } footer: {
            Text("紀錄只存在這台裝置上，不會上傳。要手動清空請到「歷史」頁右上角的「全部刪除」。")
        }
    }

    // MARK: - 關於

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: Self.versionString)
            NavigationLink("診斷記錄") { MobileLogsView() }
            Link("GitHub 專案", destination: URL(string: "https://github.com/Oliver0804/saybit")!)
            Button("重新查看新手引導") { mobileSettings.hasCompletedOnboarding = false }
        } header: {
            Text("關於")
        } footer: {
            Text("診斷記錄只保存在本機，回報問題時可以分享給開發者。")
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "-"
        let b = info?["CFBundleVersion"] as? String ?? "-"
        return "\(v) (\(b))"
    }
}

// MARK: - 權限

/// 麥克風 / 語音辨識授權狀態。回到前景時重新讀取，使用者在系統設定改完切回來就會更新。
struct PermissionsSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var micStatus = AVAudioApplication.shared.recordPermission
    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()

    var body: some View {
        Section {
            permissionRow(
                "麥克風",
                granted: micStatus == .granted,
                denied: micStatus == .denied
            ) {
                let granted = await AudioSessionManager.requestMicrophonePermission()
                micStatus = granted ? .granted : .denied
            }
            permissionRow(
                "語音辨識",
                granted: speechStatus == .authorized,
                denied: speechStatus == .denied || speechStatus == .restricted
            ) {
                let ok = await withCheckedContinuation { cont in
                    SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
                }
                speechStatus = ok ? .authorized : .denied
            }
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("打開 Saybit 的系統設定", destination: url)
            }
        } header: {
            Text("權限")
        } footer: {
            Text("沒有麥克風權限就無法錄音。語音辨識權限只有使用 Apple 語音辨識時需要，離線的 SenseVoice 不需要。")
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            micStatus = AVAudioApplication.shared.recordPermission
            speechStatus = SFSpeechRecognizer.authorizationStatus()
        }
    }

    @ViewBuilder
    private func permissionRow(
        _ title: String,
        granted: Bool,
        denied: Bool,
        request: @escaping () async -> Void
    ) -> some View {
        LabeledContent(title) {
            if granted {
                Label("已允許", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if denied {
                Label("已拒絕", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Button("允許") { Task { await request() } }
                    .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Provider

struct ProviderSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var status: Status = .none
    @State private var isTesting = false
    @State private var isLoadingModels = false

    enum Status: Equatable {
        case none, saved, ok, failed(String)
    }

    var body: some View {
        let provider = settingsStore.selectedProvider
        Form {
            Section {
                Picker("服務商", selection: $settingsStore.selectedProviderID) {
                    ForEach(settingsStore.allProviders) { Text($0.name).tag($0.id) }
                }
                if provider.id == "lmstudio" || provider.id == "ollama" {
                    TextField("伺服器網址", text: $settingsStore.lmStudioBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("服務商")
            } footer: {
                if provider.id == "lmstudio" || provider.id == "ollama" {
                    Text("在 iPhone 上請填 Mac 的區網網址，例如 http://192.168.1.10:1234，並確保兩台裝置在同一個 Wi-Fi。")
                } else {
                    Text("OpenRouter 一組 Key 就能用多家模型，也可以改成任何 OpenAI 相容服務。")
                }
            }

            Section {
                SecureField(provider.keyPlaceholder.isEmpty ? "API Key" : provider.keyPlaceholder, text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!provider.requiresAPIKey)
                Button("儲存 API Key") {
                    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        KeychainHelper.deleteAPIKey(for: provider.id)
                    } else {
                        try? KeychainHelper.saveAPIKey(trimmed, for: provider.id)
                    }
                    status = .saved
                }
                .disabled(!provider.requiresAPIKey)
                if provider.requiresAPIKey, let url = provider.keyPortalURL {
                    Link(destination: url) {
                        Label("取得 \(provider.name) API Key", systemImage: "key")
                    }
                }
            } header: {
                Text("API Key")
            } footer: {
                if provider.requiresAPIKey {
                    let credit = provider.needsPrepaidCredit ? "\(provider.name) 要先儲值才能呼叫（US$5 就能用很久），沒儲值時測試會顯示「餘額不足」。" : ""
                    Text("Key 存在 iOS 鑰匙圈，只在這台裝置上使用，不會傳給 Saybit。清空後按儲存可以刪除。\(credit.isEmpty ? "" : "\n" + credit)")
                } else {
                    Text("此服務商不需要 API Key。")
                }
            }

            Section {
                TextField("模型名稱", text: $settingsStore.selectedModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !models.isEmpty {
                    Picker("從清單選擇", selection: $settingsStore.selectedModel) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                }
                Button {
                    Task { await loadModels(provider) }
                } label: {
                    LabeledContent("載入可用模型") {
                        if isLoadingModels { ProgressView() }
                    }
                }
                .disabled(isLoadingModels)
            } header: {
                Text("模型")
            } footer: {
                if provider.modelHint.isEmpty {
                    Text("可以直接輸入模型名稱，或按「載入可用模型」從服務商抓取清單。")
                } else {
                    Text("建議：\(provider.modelHint)")
                }
            }

            Section {
                Button {
                    Task { await test(provider) }
                } label: {
                    LabeledContent("測試連線") {
                        if isTesting { ProgressView() }
                    }
                }
                .disabled(isTesting)
                statusRow
            } footer: {
                Text("測試會送出一句極短的提示，費用幾乎可以忽略。")
            }
        }
        .navigationTitle("AI 服務")
        .onAppear { apiKey = KeychainHelper.loadAPIKey(for: provider.id) ?? "" }
        .onChange(of: apiKey) { _, _ in
            if status == .saved { status = .none }
        }
        .onChange(of: settingsStore.selectedProviderID) { _, newID in
            apiKey = KeychainHelper.loadAPIKey(for: newID) ?? ""
            models = []
            status = .none
            if let model = LLMProvider.defaultModel(for: newID) {
                settingsStore.selectedModel = model
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch status {
        case .none:
            EmptyView()
        case .saved:
            Label("已儲存", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .ok:
            Label("連線成功", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .failed(let msg):
            // 錯誤訊息常常很長（含 HTTP 狀態與服務商回應），這裡讓它完整換行顯示
            Label {
                Text(msg)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill")
            }
            .foregroundStyle(.red)
        }
    }

    private func loadModels(_ provider: LLMProvider) async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            models = try await LLMProvider.fetchOpenAIModels(provider: provider).sorted()
            status = models.isEmpty ? .failed("服務商沒有回傳任何模型") : .none
        } catch {
            status = .failed(TextRefiner.friendlyErrorMessage(error))
        }
    }

    private func test(_ provider: LLMProvider) async {
        isTesting = true
        defer { isTesting = false }
        do {
            try await OpenRouterClient().testConnection(model: settingsStore.selectedModel, provider: provider)
            status = .ok
        } catch {
            status = .failed(TextRefiner.friendlyErrorMessage(error))
        }
    }
}

// MARK: - Speech

struct SpeechSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var whisperKey = ""
    @State private var whisperSaved = false

    var body: some View {
        Form {
            Section {
                Picker("辨識引擎", selection: $settingsStore.sttEngine) {
                    ForEach(STTEngine.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if settingsStore.sttEngine == .appleSpeech {
                    Toggle("僅在裝置上辨識", isOn: $settingsStore.enableOnDeviceSTT)
                }
            } header: {
                Text("辨識引擎")
            } footer: {
                switch settingsStore.sttEngine {
                case .appleSpeech:
                    Text("Apple 語音辨識有即時字幕；「僅在裝置上辨識」較隱私且沒有時間限制，但需先在系統下載語言模型。")
                case .whisperAPI:
                    Text("Whisper API 辨識較準，但要等說完才會上傳辨識，需要 OpenAI API Key 並產生費用。")
                case .sherpaSenseVoice:
                    Text("SenseVoice 完全在 iPhone 上辨識：速度快、中英夾雜表現好、不需網路也不受 Apple 時間限制，背景待命也穩定。每句講完才定稿，字幕會比 Apple 稍晚跳出。")
                }
            }

            if settingsStore.sttEngine == .sherpaSenseVoice {
                SherpaModelSection()
            }

            if settingsStore.sttEngine == .whisperAPI {
                Section {
                    SecureField("OpenAI API Key（sk-…）", text: $whisperKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: whisperKey) { _, _ in whisperSaved = false }
                    Button(whisperSaved ? "已儲存" : "儲存 API Key") {
                        try? KeychainHelper.saveAPIKey(whisperKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "whisper_api")
                        whisperSaved = true
                    }
                    .disabled(whisperSaved)
                    TextField("辨識模型", text: $settingsStore.whisperModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("自動偵測語言", isOn: $settingsStore.enableAutoLanguageDetection)
                } header: {
                    Text("Whisper API")
                } footer: {
                    Text("Key 存在 iOS 鑰匙圈。模型通常填 whisper-1；關閉自動偵測語言時，會用「設定 › AI 潤飾」的輸出語言去辨識。")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("麥克風靈敏度", value: String(format: "%.1f×", settingsStore.micSensitivity))
                    Slider(value: $settingsStore.micSensitivity, in: 0.5...5, step: 0.5) {
                        Text("麥克風靈敏度")
                    }
                    .labelsHidden()
                }
                Toggle("人聲降噪", isOn: $settingsStore.enableVoiceBandpass)
                    .onChange(of: settingsStore.enableVoiceBandpass) { _, on in
                        SharedAudioEngine.shared.setVoiceBandpassEnabled(on)
                    }
                Toggle("回音消除", isOn: $settingsStore.enableEchoCancellation)
                    .onChange(of: settingsStore.enableEchoCancellation) { _, on in
                        SharedAudioEngine.shared.setEchoCancellationEnabled(on)
                    }
            } header: {
                Text("收音")
            } footer: {
                Text("靈敏度只影響音量顯示與靜音判斷。人聲降噪會濾掉 80Hz–8kHz 以外的聲音；回音消除適合邊播放聲音邊錄音，開啟後系統可能降低其他 App 的音量。")
            }
        }
        .navigationTitle("語音辨識")
        .onAppear {
            whisperKey = KeychainHelper.loadAPIKey(for: "whisper_api") ?? ""
            whisperSaved = !whisperKey.isEmpty
        }
    }
}

// MARK: - Sherpa Model

struct SherpaModelSection: View {
    @State private var models = SherpaModelManager.shared
    @State private var confirmDelete = false

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: SherpaModelManager.totalSize, countStyle: .file)
    }

    var body: some View {
        Section {
            switch models.state {
            case .installed:
                LabeledContent("離線模型") {
                    Label("已安裝", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                }
                Button("刪除模型（釋放 \(sizeText)）", role: .destructive) { confirmDelete = true }
            case .notInstalled:
                Button {
                    models.download()
                } label: {
                    LabeledContent("下載離線模型", value: sizeText)
                }
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("下載中", value: progress.formatted(.percent.precision(.fractionLength(0))))
                    ProgressView(value: progress)
                }
                Button("取消下載", role: .cancel) { models.cancelDownload() }
            case .failed(let message):
                Label {
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                Button("重新下載") { models.download() }
            }
        } header: {
            Text("SenseVoice 模型")
        } footer: {
            Text("SenseVoice int8 + Silero VAD，支援中文、英文、日文、韓文、粵語。建議用 Wi-Fi 下載；下載期間請保持 Saybit 在前景。")
        }
        .confirmationDialog("刪除離線模型？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除模型", role: .destructive) { models.delete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會釋放 \(sizeText) 空間。之後要再用 SenseVoice 必須重新下載。")
        }
    }
}

// MARK: - Logs

struct MobileLogsView: View {
    private let logger = AppLogger.shared
    @State private var confirmShare = false
    @State private var shareText: String?

    var body: some View {
        let entries = Array(logger.entries.reversed())
        List(entries) { entry in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.level.rawValue)
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(entry.level == .error ? .red : .secondary)
                    Text(entry.category).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
                Text(entry.message)
                    .font(.caption.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    "還沒有記錄",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("錄音與 AI 處理的過程會記錄在這裡，方便回報問題。")
                )
            }
        }
        .navigationTitle("診斷記錄")
        .toolbar {
            if !entries.isEmpty {
                Button {
                    confirmShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享診斷記錄")
            }
        }
        .alert("分享診斷記錄？", isPresented: $confirmShare) {
            Button("分享") {
                shareText = entries.map(\.formatted).joined(separator: "\n")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("記錄內含最近 7 天口述內容的片段（轉錄與 AI 結果的開頭文字）。請只分享給你信任的對象。")
        }
        .sheet(isPresented: Binding(
            get: { shareText != nil },
            set: { if !$0 { shareText = nil } }
        )) {
            if let shareText {
                ActivityShareSheet(items: [shareText])
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

/// UIActivityViewController 包裝：確認後才能分享（ShareLink 無法程式觸發）
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
