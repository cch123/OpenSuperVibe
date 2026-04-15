import Cocoa
import SwiftUI

final class AppState: @unchecked Sendable {

    // MARK: - State

    var stage: SessionStage = .idle
    var isRecording = false
    var statusText = "Ready"
    var asrText = ""
    var gptText = ""
    var polishEnabled: Bool = {
        if let val = AppState.loadConfigValue("polish_enabled") as? Bool {
            return val
        }
        return true  // default ON
    }() {
        didSet { saveConfig() }
    }
    var translationLanguage: String? = AppState.loadConfigValue("translation_language") as? String {
        didSet { saveConfig() }
    }
    private var sessionTranslate = false

    let vibeVoice = VibeVoiceSTT()
    let llmService = LLMService()
    private(set) var vibeVoiceAvailable = false

    var llmApiKey: String? {
        get { llmService.apiKey }
        set {
            llmService.apiKey = newValue
            saveConfig()
        }
    }

    var geminiApiKey: String? {
        get { llmService.geminiApiKey }
        set {
            llmService.geminiApiKey = newValue
            saveConfig()
        }
    }

    var llmProvider: LLMProvider {
        get { llmService.provider }
        set {
            llmService.provider = newValue
            saveConfig()
            onConfigChanged?()
        }
    }

    /// Called when isRecording changes (for menu bar icon update).
    var onRecordingChanged: ((Bool) -> Void)?
    /// Called when configuration changes (for menu rebuild).
    var onConfigChanged: (() -> Void)?
    /// Called when a user action fails and needs a visible alert.
    var onAlert: ((String, String) -> Void)?

    // MARK: - Private

    private let audioRecorder = AudioRecorder()
    private let hotkeyManager = HotkeyManager()
    private var overlayPanel: OverlayPanel?
    private let overlayVM = OverlayViewModel()
    private var processingTask: Task<Void, Never>?
    private var asrAccum = ""
    private var gptAccum = ""

    // MARK: - Init

    init() {
        loadConfig()
    }

    // MARK: - Hotkeys

    func setupHotkeys() {
        hotkeyManager.onToggleRecord = { [weak self] in
            DispatchQueue.main.async { self?.toggleRecording() }
        }
        hotkeyManager.onToggleTranslate = { [weak self] in
            DispatchQueue.main.async { self?.toggleTranslateRecording() }
        }
        hotkeyManager.onCancel = { [weak self] in
            DispatchQueue.main.async { self?.cancelSession() }
        }
        hotkeyManager.start()
    }

    // MARK: - Model Management

    func selectVibeModel(_ model: VibeVoiceSTT.Model) {
        vibeVoice.selectModel(model)
        saveConfig()
        log("[AppState] VibeVoice model: \(model.name)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? self?.vibeVoice.warmup()
        }

        onConfigChanged?()
    }

    func checkVibeVoiceAvailability() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let available = self?.vibeVoice.isAvailable() ?? false
            DispatchQueue.main.async {
                self?.vibeVoiceAvailable = available
                self?.onConfigChanged?()
            }
        }
    }

    // MARK: - Toggle

    func toggleRecording() {
        log("[AppState] toggleRecording -- isRecording=\(isRecording)")
        if isRecording { stopRecording() } else { startRecording(translate: false) }
    }

    func toggleTranslateRecording() {
        log("[AppState] toggleTranslateRecording -- isRecording=\(isRecording)")
        if isRecording {
            stopRecording()
        } else if translationLanguage != nil {
            if !llmService.isAvailable {
                log("[AppState] No LLM API key set, using raw transcription")
            }
            startRecording(translate: true)
        } else {
            log("[AppState] No translation language set")
            onAlert?("Translation Not Configured", "Please select a target language in the Translation menu before using the translate shortcut.")
        }
    }

    // MARK: - Start

    func startRecording(translate: Bool) {
        guard stage == .idle else {
            log("[AppState] startRecording skipped, stage=\(stage)")
            return
        }

        sessionTranslate = translate
        asrText = ""; gptText = ""
        asrAccum = ""; gptAccum = ""
        stage = .recording
        isRecording = true
        statusText = "Recording..."
        onRecordingChanged?(true)
        log("[AppState] Recording started -- mode=\(translate ? "translate(\(translationLanguage ?? "?"))" : "transcribe")")

        overlayVM.asrText = ""
        overlayVM.gptText = ""
        overlayVM.isTranslation = sessionTranslate
        overlayVM.stage = .recording
        showOverlay()

        // Audio level for waveform (both modes)
        audioRecorder.onAudioLevel = { [weak self] level in
            self?.overlayVM.pushLevel(level)
        }

        // Audio stays local; VibeVoice consumes the saved WAV after recording stops.
        audioRecorder.onAudioChunk = nil

        do {
            try audioRecorder.start()
        } catch {
            stage = .error; isRecording = false
            statusText = "Mic error: \(error.localizedDescription)"
            onRecordingChanged?(false)
            setOverlayStage(.error)
            log("[AppState] Mic error: \(error)")
            return
        }

        // Local processing happens on stop, after the WAV has been written.
    }

    // MARK: - Cancel (ESC)

    func cancelSession() {
        guard stage != .idle else { return }
        log("[AppState] Session cancelled (ESC)")
        stage = .idle
        statusText = "Ready"
        if isRecording {
            isRecording = false
            onRecordingChanged?(false)
            overlayVM.resetLevels()
            audioRecorder.stop()
        }
        // Cancel any running local processing.
        processingTask?.cancel()
        processingTask = nil
        hideOverlay()
    }

    // MARK: - Stop

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        onRecordingChanged?(false)
        overlayVM.resetLevels()

        if stage == .recording {
            stage = .recognizing
            statusText = "Transcribing..."
            setOverlayStage(.recognizing)
        }

        log("[AppState] Recording stopped, starting local transcription")
        processingTask = Task { [weak self] in
            await self?.runLocalTranscription()
        }
    }

    // MARK: - Local Processing (VibeVoice)

    private func runLocalTranscription() async {
        do {
            let wavURL = try audioRecorder.stopAndSaveWAV()
            defer { try? FileManager.default.removeItem(at: wavURL) }

            log("[VibeVoice] Transcribing \(wavURL.path)...")
            let startTime = Date()
            let text = try vibeVoice.transcribe(wavPath: wavURL.path)
            let asrElapsed = Date().timeIntervalSince(startTime)
            log("[VibeVoice] ASR \(String(format: "%.1f", asrElapsed))s -- \(text.prefix(80))")

            guard !Task.isCancelled, stage != .idle else { return }

            if text.isEmpty {
                log("[VibeVoice] No speech detected")
                await MainActor.run {
                    scheduleReset(delay: 1.0)
                }
                return
            }

            await MainActor.run {
                asrText = text
                asrAccum = text
                setOverlayStage(.recognizing, asr: text)
            }

            // Determine if LLM post-processing is needed
            let needsTranslation = sessionTranslate && translationLanguage != nil
            let needsPolish = !sessionTranslate && polishEnabled
            let needsLLM = (needsTranslation || needsPolish) && llmService.isAvailable

            if needsLLM {
                await MainActor.run {
                    stage = .translating
                    if needsPolish {
                        statusText = "Polishing..."
                        overlayVM.isPolish = true
                    } else {
                        statusText = "Translating..."
                    }
                    setOverlayStage(.translating, asr: text)
                }

                guard !Task.isCancelled, stage != .idle else { return }

                let llmStart = Date()
                let result: String
                if needsTranslation, let lang = translationLanguage {
                    result = try await llmService.translate(text, to: lang, polish: polishEnabled)
                } else {
                    result = try await llmService.polish(text)
                }
                let llmElapsed = Date().timeIntervalSince(llmStart)
                log("[LLM] \(String(format: "%.1f", llmElapsed))s -- \(result.prefix(80))")

                guard !Task.isCancelled, stage != .idle else { return }

                await MainActor.run {
                    gptText = result
                    gptAccum = result
                    setOverlayStage(.translating, asr: text, gpt: result)
                }
            } else if needsTranslation && !llmService.isAvailable {
                log("[VibeVoice] Translation requested but no LLM API key set, using raw transcription")
            } else if needsPolish && !llmService.isAvailable {
                log("[VibeVoice] Polish enabled but no LLM API key set, using raw transcription")
            }

            guard !Task.isCancelled, stage != .idle else { return }

            await MainActor.run {
                finishSession()
            }
        } catch {
            guard !Task.isCancelled, stage != .idle else { return }
            await MainActor.run {
                log("[VibeVoice] Error: \(error)")
                stage = .error
                statusText = "Error: \(error.localizedDescription)"
                setOverlayStage(.error)
                scheduleReset(delay: 3.0)
            }
        }
    }

    // MARK: - Finish

    /// Strip trailing period for short single-sentence results.
    private func trimTrailingPunctuation(_ text: String) -> String {
        var s = text
        let midPunct: [Character] = [".", "\u{3002}", "!", "\u{FF01}", "?", "\u{FF1F}"]
        let body = s.dropLast()
        let hasMidPunct = body.contains(where: { midPunct.contains($0) })
        if !hasMidPunct, let last = s.last, last == "." || last == "\u{3002}" {
            s.removeLast()
        }
        return s
    }

    private func finishSession() {
        guard stage != .idle else { return }
        stage = .done

        // If GPT returned a refusal, discard it and use raw ASR text
        if !gptText.isEmpty && LLMService.looksLikeRefusal(gptText) {
            log("[AppState] GPT refusal detected, falling back to ASR text")
            gptText = ""
        }

        let raw = gptText.isEmpty ? asrText : gptText
        let finalText = trimTrailingPunctuation(raw)
        statusText = "Done"
        setOverlayStage(.done, asr: asrText, gpt: gptText)
        log("[AppState] Finish -- text=\"\(finalText.prefix(80))\"")

        guard !finalText.isEmpty else {
            scheduleReset(delay: 1.0)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            PasteService.paste(finalText)
        }
        scheduleReset(delay: 1.5)
    }

    private func scheduleReset(delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.hideOverlay()
            self?.stage = .idle
            self?.statusText = "Ready"
        }
    }

    // MARK: - Overlay

    private func setOverlayStage(
        _ stage: SessionStage,
        asr: String = "",
        gpt: String = ""
    ) {
        overlayVM.stage = stage
        overlayVM.asrText = asr
        overlayVM.gptText = gpt
        overlayVM.isTranslation = sessionTranslate
        // isPolish is set separately where needed (not reset here to avoid clearing it mid-session)
    }

    private func showOverlay() {
        if overlayPanel == nil {
            overlayVM.onCancel = { [weak self] in self?.cancelSession() }
            overlayVM.onConfirm = { [weak self] in self?.stopRecording() }
            overlayPanel = OverlayPanel()
            overlayPanel?.contentView = NSHostingView(
                rootView: OverlayRootView(vm: overlayVM)
            )
        }
        overlayPanel?.positionCenter()
        overlayPanel?.orderFront(nil)
    }

    private func hideOverlay() {
        overlayVM.resetLevels()
        overlayPanel?.contentView = nil   // tear down SwiftUI view tree (kills all animations & timers)
        overlayPanel?.orderOut(nil)
        overlayPanel = nil                // next showOverlay() will recreate
        overlayVM.stage = .idle
        overlayVM.asrText = ""
        overlayVM.gptText = ""
        overlayVM.isPolish = false
    }

    // MARK: - Persistence

    private static let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".SuperVibe")
    private static let configFile = configDir.appendingPathComponent("config.json")

    static func loadConfigValue(_ key: String) -> Any? {
        guard let data = try? Data(contentsOf: configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json[key]
    }

    private func loadConfig() {
        guard let data = try? Data(contentsOf: Self.configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let lang = json["translation_language"] as? String {
            translationLanguage = lang
        }
        if let modelId = json["vibevoice_model"] as? String,
           let model = VibeVoiceSTT.availableModels.first(where: { $0.id == modelId }) {
            vibeVoice.selectModel(model)
        }
        if let key = json["llm_api_key"] as? String, !key.isEmpty {
            llmService.apiKey = key
        }
        if let key = json["gemini_api_key"] as? String, !key.isEmpty {
            llmService.geminiApiKey = key
        }
        if let raw = json["llm_provider"] as? String, let p = LLMProvider(rawValue: raw) {
            llmService.provider = p
        }
        if let polish = json["polish_enabled"] as? Bool {
            polishEnabled = polish
        }
        if let modelId = json["llm_model"] as? String,
           let model = LLMService.claudeModels.first(where: { $0.id == modelId }) {
            llmService.selectedModel = model
        }
        if let modelId = json["gemini_model"] as? String,
           let model = LLMService.geminiModels.first(where: { $0.id == modelId }) {
            llmService.selectedGeminiModel = model
        }
    }

    func saveConfig() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.configDir, withIntermediateDirectories: true)

        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: Self.configFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = existing
        }

        if let lang = translationLanguage {
            config["translation_language"] = lang
        } else {
            config.removeValue(forKey: "translation_language")
        }

        config.removeValue(forKey: "engine")
        config["vibevoice_model"] = vibeVoice.currentModel.id

        if let key = llmService.apiKey, !key.isEmpty {
            config["llm_api_key"] = key
        } else {
            config.removeValue(forKey: "llm_api_key")
        }

        if let key = llmService.geminiApiKey, !key.isEmpty {
            config["gemini_api_key"] = key
        } else {
            config.removeValue(forKey: "gemini_api_key")
        }

        config["llm_provider"] = llmService.provider.rawValue
        config["polish_enabled"] = polishEnabled
        config["llm_model"] = llmService.selectedModel.id
        config["gemini_model"] = llmService.selectedGeminiModel.id

        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.configFile)
        }
    }
}
