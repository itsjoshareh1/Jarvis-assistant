import AppKit
import Carbon
import ServiceManagement

@MainActor
final class Controller: NSObject, NSMenuDelegate {
    private let state = AppState.shared
    private let brain = Brain()
    private let speaker = Speaker()
    private let listener = Listener()
    private var hud: HUD!
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private var work: Task<Void, Never>?
    private var frontApp: String?
    private var timers: [Timer] = []

    func boot() {
        hud = HUD(onSubmit: { [weak self] in self?.handle($0) },
                  onClose: { [weak self] in self?.dismiss() })

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Jarvis")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // ⌥Space: talk. ⌥⇧Space: type.
        hotKeys.append(HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), id: 1) { [weak self] in
            self?.talkPressed()
        })
        hotKeys.append(HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), id: 2) { [weak self] in
            self?.typePressed()
        })

        listener.onLevel = { [weak self] in self?.state.level = $0 }
        listener.onPartial = { [weak self] in self?.state.transcript = $0 }
        listener.onWake = { [weak self] in self?.wakeHeard() }
        listener.onCommand = { [weak self] in self?.commandHeard($0) }
        listener.onFailure = { [weak self] msg in
            guard let self else { return }
            self.state.status = .idle
            self.state.reply = "I can't hear you right now: \(msg)"
            self.updateIcon()
            self.hud.hide(after: 8)
        }
        speaker.onFinish = { [weak self] in self?.finishedSpeaking() }
        brain.tools.onTimer = { [weak self] secs, label in self?.startTimer(secs, label) }

        Listener.requestPermissions { [weak self] ok in
            guard let self else { return }
            if !ok { self.showPermissionHelp() }
            self.resumeWakeListening()
        }
        if APIKey.current == nil { promptForAPIKey() }
    }

    // MARK: - Flow

    func talkPressed() {
        switch state.status {
        case .speaking:
            speaker.stop()
            startListening()
        case .listening:
            listener.finishNow()
        case .thinking:
            cancelWork()
            startListening()
        case .idle:
            startListening()
        }
    }

    func typePressed() {
        if state.status == .speaking { speaker.stop() }
        listener.stop()
        rememberFrontApp()
        state.status = .idle
        state.showInput = true
        hud.show(focusInput: true)
    }

    private func startListening() {
        rememberFrontApp()
        listener.stop()
        state.transcript = ""
        state.reply = ""
        state.activity = ""
        state.status = .listening
        hud.show()
        NSSound(named: "Tink")?.play()
        listener.start(.command)
        updateIcon()
    }

    private func wakeHeard() {
        rememberFrontApp()
        speaker.stop()
        state.transcript = ""
        state.reply = ""
        state.activity = ""
        state.status = .listening
        NSSound(named: "Tink")?.play()
        hud.show()
        updateIcon()
    }

    private func commandHeard(_ text: String) {
        state.level = 0
        guard !text.isEmpty else {
            state.status = .idle
            hud.hide(after: 0.4)
            updateIcon()
            resumeWakeListening()
            return
        }
        NSSound(named: "Pop")?.play()
        handle(text)
    }

    func handle(_ text: String) {
        cancelWork()
        listener.stop()
        state.transcript = text
        state.reply = ""
        state.activity = ""
        state.status = .thinking
        hud.show(focusInput: state.showInput)
        updateIcon()

        let app = frontApp
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.brain.ask(text, frontApp: app) { [weak self] act in
                    self?.state.activity = act
                }
                guard !Task.isCancelled else { return }
                self.deliver(reply)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.deliver(error.localizedDescription)
            }
        }
    }

    private func deliver(_ reply: String) {
        state.activity = ""
        state.reply = reply.trimmed
        if Settings.speakReplies && !state.reply.isEmpty {
            state.status = .speaking
            updateIcon()
            speaker.speak(state.reply)
        } else {
            finishedSpeaking()
        }
    }

    private func finishedSpeaking() {
        guard state.status == .speaking || state.status == .thinking else { return }
        state.status = .idle
        updateIcon()
        // Like Siri: if Jarvis asked a question, reopen the mic for the answer.
        if state.reply.hasSuffix("?") && !state.showInput {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.state.status == .idle else { return }
                self.startListening()
            }
            return
        }
        if !state.showInput { hud.hide(after: 8) }
        resumeWakeListening()
    }

    private func dismiss() {
        cancelWork()
        speaker.stop()
        listener.stop()
        state.status = .idle
        state.showInput = false
        hud.hide()
        updateIcon()
        resumeWakeListening()
    }

    private func cancelWork() {
        if let work {
            work.cancel()
            brain.reset()
        }
        work = nil
    }

    private func resumeWakeListening() {
        guard Settings.wakeWord, state.status == .idle, listener.mode == nil else { return }
        listener.start(.wake)
    }

    private func rememberFrontApp() {
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            frontApp = app.localizedName
        }
    }

    private func updateIcon() {
        let name = state.status == .idle ? "waveform.circle" : "waveform.circle.fill"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Jarvis")
    }

    private func startTimer(_ secs: TimeInterval, _ label: String) {
        let t = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for i in 0..<3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) { NSSound(named: "Glass")?.play() }
                }
                let msg = label.isEmpty ? "Your timer is done." : "Your \(label) timer is done."
                self.state.transcript = ""
                self.deliver(msg)
                self.hud.show()
            }
        }
        timers.append(t)
    }

    // MARK: - URL scheme (jarvis://listen, jarvis://ask?q=...)

    func open(_ url: URL) {
        guard url.scheme == "jarvis" else { return }
        switch url.host {
        case "listen": talkPressed()
        case "type": typePressed()
        case "ask":
            if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value, !q.isEmpty {
                rememberFrontApp()
                hud.show()
                handle(q)
            }
        default: break
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Talk to Jarvis   ⌥Space", #selector(menuTalk)))
        menu.addItem(item("Type to Jarvis   ⌥⇧Space", #selector(menuType)))
        menu.addItem(item("New Conversation", #selector(menuReset)))
        menu.addItem(.separator())

        menu.addItem(toggle("Listen for “Hey Jarvis”", Settings.wakeWord, #selector(toggleWake)))
        menu.addItem(toggle("Speak Replies", Settings.speakReplies, #selector(toggleSpeak)))
        menu.addItem(toggle("Ask Before Shell Commands", Settings.confirmShell, #selector(toggleConfirm)))
        menu.addItem(toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for m in Brain.models {
            let i = toggle(m.name, Settings.model == m.id, #selector(pickModel(_:)))
            i.representedObject = m.id
            modelMenu.addItem(i)
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        let current = Speaker.voice()?.identifier
        for v in Speaker.englishVoices.prefix(30) {
            let q = v.quality == .premium ? " (Premium)" : v.quality == .enhanced ? " (Enhanced)" : ""
            let i = toggle("\(v.name) – \(v.language)\(q)", v.identifier == current, #selector(pickVoice(_:)))
            i.representedObject = v.identifier
            voiceMenu.addItem(i)
        }
        voiceMenu.addItem(.separator())
        voiceMenu.addItem(item("Download Better Voices…", #selector(openVoiceSettings)))
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)

        menu.addItem(.separator())
        menu.addItem(item("Set API Key…", #selector(promptForAPIKey)))
        menu.addItem(item("Open Memory File", #selector(openMemory)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Jarvis", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    @objc private func menuTalk() { talkPressed() }
    @objc private func menuType() { typePressed() }
    @objc private func menuReset() { brain.reset() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleWake() {
        Settings.wakeWord.toggle()
        if Settings.wakeWord { resumeWakeListening() } else if listener.mode == .wake { listener.stop() }
    }
    @objc private func toggleSpeak() { Settings.speakReplies.toggle() }
    @objc private func toggleConfirm() { Settings.confirmShell.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Couldn't change login item", error.localizedDescription)
        }
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            Settings.model = id
            brain.reset() // thinking blocks are tied to the model that produced them
        }
    }

    @objc private func pickVoice(_ sender: NSMenuItem) {
        Settings.voiceIdentifier = sender.representedObject as? String
        speaker.stop()
        speaker.speak("Voice updated.")
    }

    @objc private func openVoiceSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!)
    }

    @objc private func openMemory() {
        if !FileManager.default.fileExists(atPath: Paths.memory.path) {
            try? "# Things Jarvis remembers about you\n".write(to: Paths.memory, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(Paths.memory)
    }

    @objc func promptForAPIKey() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Anthropic API Key"
        a.informativeText = "Jarvis uses Claude through the Anthropic API. Paste a key from console.anthropic.com. It's stored in your Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        if a.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmed
            if !key.isEmpty { Keychain.set(key, for: "anthropic-api-key") }
        }
    }

    private func showPermissionHelp() {
        alert("Microphone or Speech Recognition is off",
              "Jarvis needs both to hear you. Turn them on in System Settings › Privacy & Security, then relaunch Jarvis. You can still type with ⌥⇧Space.")
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
