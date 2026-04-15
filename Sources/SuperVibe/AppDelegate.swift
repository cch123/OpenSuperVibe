import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        requestPermissions()

        // Check VibeVoice availability in background
        appState.checkVibeVoiceAvailability()

        // Warm up the local model without blocking menu bar startup.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? self?.appState.vibeVoice.warmup()
        }
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "SuperVibe"
            )
            button.image?.isTemplate = true
        }

        rebuildMenu()

        appState.onRecordingChanged = { [weak self] isRecording in
            DispatchQueue.main.async {
                self?.statusItem.button?.image = NSImage(
                    systemSymbolName: isRecording ? "waveform.circle.fill" : "waveform",
                    accessibilityDescription: "SuperVibe"
                )
                self?.rebuildMenu()
            }
        }

        appState.onConfigChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.rebuildMenu()
            }
        }

        appState.onAlert = { title, message in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = message
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Record toggle
        if appState.isRecording {
            let stop = NSMenuItem(title: "Stop Recording", action: #selector(toggleRecord), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)

            let cancel = NSMenuItem(title: "Cancel (ESC)", action: #selector(cancelRecord), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        } else {
            menu.addItem(shortcutMenuItem("Transcribe", shortcut: "Right \u{2325}", action: #selector(toggleRecord)))
            let translateItem = shortcutMenuItem("Translate", shortcut: "Right \u{2325} /", action: #selector(toggleTranslateRecord))
            if appState.translationLanguage == nil {
                translateItem.isEnabled = false
            }
            menu.addItem(translateItem)
        }

        menu.addItem(.separator())

        let modelMenu = NSMenu()
        for model in VibeVoiceSTT.availableModels {
            let item = NSMenuItem(title: model.name, action: #selector(selectVibeModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.id
            item.state = model.id == appState.vibeVoice.currentModel.id ? .on : .off
            item.isEnabled = appState.vibeVoiceAvailable
            modelMenu.addItem(item)
        }
        let modelTitle = appState.vibeVoiceAvailable ? "VibeVoice Model" : "VibeVoice Model (not installed)"
        let modelItem = NSMenuItem(title: modelTitle, action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        modelItem.isEnabled = appState.vibeVoiceAvailable
        menu.addItem(modelItem)

        menu.addItem(.separator())

        // Polish toggle
        let polishItem = NSMenuItem(title: "Polish", action: #selector(togglePolish), keyEquivalent: "")
        polishItem.target = self
        polishItem.state = appState.polishEnabled ? .on : .off
        menu.addItem(polishItem)

        // Translation submenu
        let transMenu = NSMenu()
        let languages: [(String, String?)] = [
            ("Off", nil),
            ("English", "en"),
            ("Chinese (Simplified)", "zh"),
            ("Chinese (Traditional)", "zh-TW"),
            ("Japanese", "ja"),
            ("Korean", "ko"),
            ("French", "fr"),
            ("Spanish", "es"),
            ("German", "de"),
        ]
        for (label, code) in languages {
            let item = NSMenuItem(title: label, action: #selector(setTranslation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = appState.translationLanguage == code ? .on : .off
            transMenu.addItem(item)
        }
        let transItem = NSMenuItem(title: "Translation", action: nil, keyEquivalent: "")
        if let lang = appState.translationLanguage {
            transItem.title = "Translation (\(lang.uppercased()))"
        }
        transItem.submenu = transMenu
        menu.addItem(transItem)

        // LLM settings
        menu.addItem(.separator())

        let providerMenu = NSMenu()
        let claudeProviderItem = NSMenuItem(title: "Claude (Anthropic)", action: #selector(selectClaudeProvider), keyEquivalent: "")
        claudeProviderItem.target = self
        claudeProviderItem.state = appState.llmProvider == .claude ? .on : .off
        providerMenu.addItem(claudeProviderItem)

        let geminiProviderItem = NSMenuItem(title: "Gemini (Google)", action: #selector(selectGeminiProvider), keyEquivalent: "")
        geminiProviderItem.target = self
        geminiProviderItem.state = appState.llmProvider == .gemini ? .on : .off
        providerMenu.addItem(geminiProviderItem)

        let providerLabel = appState.llmProvider == .claude ? "Claude" : "Gemini"
        let providerItem = NSMenuItem(title: "LLM Provider (\(providerLabel))", action: nil, keyEquivalent: "")
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)

        let llmModelMenu = NSMenu()
        for model in appState.llmService.currentModels {
            let item = NSMenuItem(title: model.name, action: #selector(selectLLMModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.id
            item.state = model.id == appState.llmService.currentModel.id ? .on : .off
            llmModelMenu.addItem(item)
        }
        let llmModelItem = NSMenuItem(title: "LLM Model (\(appState.llmService.currentModel.name))", action: nil, keyEquivalent: "")
        llmModelItem.submenu = llmModelMenu
        menu.addItem(llmModelItem)

        let keyTitle = appState.llmService.isAvailable
            ? "LLM API Key (set)"
            : "Set LLM API Key..."
        let keyItem = NSMenuItem(title: keyTitle, action: #selector(setLLMApiKey), keyEquivalent: "")
        keyItem.target = self
        menu.addItem(keyItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SuperVibe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    // MARK: - Permissions

    private func requestPermissions() {
        if AXIsProcessTrusted() {
            log("[SuperVibe] Accessibility OK")
        } else {
            log("[SuperVibe] WARNING: Accessibility not granted")
            log("[SuperVibe] Grant in: System Settings -> Privacy & Security -> Accessibility")
        }
        appState.setupHotkeys()
    }

    // MARK: - Actions

    private func shortcutMenuItem(_ title: String, shortcut: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self

        let pStyle = NSMutableParagraphStyle()
        pStyle.tabStops = [NSTextTab(textAlignment: .right, location: 180)]

        let str = NSMutableAttributedString(string: "\(title)\t\(shortcut)", attributes: [
            .font: NSFont.menuFont(ofSize: 14),
            .paragraphStyle: pStyle,
        ])
        str.addAttribute(
            .foregroundColor, value: NSColor.secondaryLabelColor,
            range: NSRange(location: title.count + 1, length: shortcut.count)
        )
        item.attributedTitle = str
        return item
    }

    @objc private func toggleRecord() {
        appState.toggleRecording()
    }

    @objc private func toggleTranslateRecord() {
        appState.toggleTranslateRecording()
    }

    @objc private func cancelRecord() {
        appState.cancelSession()
        rebuildMenu()
    }

    @objc private func setTranslation(_ sender: NSMenuItem) {
        appState.translationLanguage = sender.representedObject as? String
        log("[SuperVibe] Translation: \(appState.translationLanguage ?? "off")")
        rebuildMenu()
    }

    @objc private func togglePolish() {
        appState.polishEnabled.toggle()
        log("[SuperVibe] Polish: \(appState.polishEnabled ? "ON" : "OFF")")
        rebuildMenu()
    }

    @objc private func selectVibeModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String,
              let model = VibeVoiceSTT.availableModels.first(where: { $0.id == modelId })
        else { return }
        appState.selectVibeModel(model)
    }

    @objc private func selectClaudeProvider() {
        appState.llmProvider = .claude
        log("[SuperVibe] LLM provider: Claude")
        rebuildMenu()
    }

    @objc private func selectGeminiProvider() {
        appState.llmProvider = .gemini
        log("[SuperVibe] LLM provider: Gemini")
        rebuildMenu()
    }

    @objc private func selectLLMModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String else { return }

        if appState.llmProvider == .claude {
            guard let model = LLMService.claudeModels.first(where: { $0.id == modelId }) else { return }
            appState.llmService.selectedModel = model
        } else {
            guard let model = LLMService.geminiModels.first(where: { $0.id == modelId }) else { return }
            appState.llmService.selectedGeminiModel = model
        }
        appState.saveConfig()
        log("[SuperVibe] LLM model: \(appState.llmService.currentModel.name)")
        rebuildMenu()
    }

    @objc private func setLLMApiKey() {
        let alert = NSAlert()

        if appState.llmProvider == .claude {
            alert.messageText = "Claude API Key"
            alert.informativeText = "Enter your Anthropic API key."
        } else {
            alert.messageText = "Gemini API Key"
            alert.informativeText = "Enter your Google Gemini API key."
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 350, height: 60))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 350, height: 60))
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 4)

        if appState.llmProvider == .claude {
            textView.string = appState.llmApiKey ?? ""
        } else {
            textView.string = appState.geminiApiKey ?? ""
        }

        scrollView.documentView = textView
        alert.accessoryView = scrollView

        if alert.runModal() == .alertFirstButtonReturn {
            let key = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if appState.llmProvider == .claude {
                appState.llmApiKey = key.isEmpty ? nil : key
            } else {
                appState.geminiApiKey = key.isEmpty ? nil : key
            }
            rebuildMenu()
        }
    }

    @objc private func quit() {
        appState.vibeVoice.shutdown()
        NSApplication.shared.terminate(nil)
    }
}
