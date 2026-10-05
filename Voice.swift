import AVFoundation
import Speech

// MARK: - Speech output

@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var onFinish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { synth.isSpeaking }

    func speak(_ text: String) {
        let u = AVSpeechUtterance(string: Speaker.clean(text))
        u.voice = Speaker.voice()
        u.rate = 0.52
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    static func voice() -> AVSpeechSynthesisVoice? {
        if let id = Settings.voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        // Default to the best-quality British voice installed, for the butler feel.
        let gb = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" }
        return gb.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
        var r = 0
        switch v.quality {
        case .premium: r += 30
        case .enhanced: r += 20
        default: r += 10
        }
        if v.name.contains("Daniel") { r += 5 }
        if v.voiceTraits.contains(.isNoveltyVoice) { r -= 100 }
        return r
    }

    static var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { (rank($0), $0.name) > (rank($1), $1.name) }
    }

    /// Strip markdown and URLs so the voice doesn't read punctuation aloud.
    static func clean(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
        return t
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }
}

// MARK: - Speech input

/// Live, on-device transcription using SpeechAnalyzer (macOS 26+).
/// Unlike SFSpeechRecognizer, this works even when Siri and Dictation are turned off.
@MainActor
final class Listener {
    enum Mode { case command, wake }

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var silenceTimer: Timer?
    private var generation = 0
    private var heardWake = false
    private var finalized = ""
    private var volatile = ""
    private var latest = ""
    private(set) var mode: Mode?

    var onPartial: ((String) -> Void)?
    var onWake: (() -> Void)?
    var onCommand: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?

    private static let locale = Locale(identifier: "en-US")
    private static let wakeWords = ["jarvis", "jervis", "jarvus", "javis"]

    static func requestPermissions(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { mic in
            DispatchQueue.main.async { done(mic) }
        }
    }

    func start(_ mode: Mode) {
        stop()
        self.mode = mode
        heardWake = false
        finalized = ""
        volatile = ""
        latest = ""
        let gen = generation
        Log.write("start \(mode)")
        Task { await self.begin(mode, gen: gen) }
    }

    private func begin(_ mode: Mode, gen: Int) async {
        do {
            let transcriber = SpeechTranscriber(locale: Listener.locale, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults, .fastResults],
                                                attributeOptions: [])
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Log.write("downloading speech model")
                try await install.downloadAndInstall()
            }
            guard gen == generation else { return }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw NSError(domain: "Jarvis", code: 1, userInfo: [NSLocalizedDescriptionKey: "No compatible audio format"])
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            guard gen == generation else { return }
            self.analyzer = analyzer
            self.input = continuation

            resultsTask = Task { [weak self] in
                do {
                    for try await r in transcriber.results {
                        let text = String(r.text.characters)
                        self?.handle(gen: gen, text: text, isFinal: r.isFinal)
                    }
                } catch {
                    Log.write("results error: \(error)")
                }
            }

            try startEngine(feeding: continuation, as: format)
            try await analyzer.start(inputSequence: stream)
            guard gen == generation else { return }
            if mode == .command { armSilence(6.0) } // time allowed to start talking
        } catch {
            Log.write("listener failed: \(error)")
            guard gen == generation else { return }
            fail(error.localizedDescription, mode: mode)
        }
    }

    private func startEngine(feeding continuation: AsyncStream<AnalyzerInput>.Continuation,
                             as outFormat: AVAudioFormat) throws {
        let node = engine.inputNode
        let inFormat = node.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "Jarvis", code: 2, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            if let ch = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = n > 0 ? sqrt(sum / Float(n)) : 0
                Task { @MainActor in self?.onLevel?(rms) }
            }
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil && out.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: out))
            }
        }
        engine.prepare()
        try engine.start()
    }

    /// End the current utterance now and deliver whatever was heard.
    func finishNow() { finish() }

    func stop() {
        generation += 1
        silenceTimer?.invalidate()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        input?.finish()
        input = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        mode = nil
    }

    private func handle(gen: Int, text: String, isFinal: Bool) {
        guard gen == generation, let mode else { return }
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
        let heard = finalized + volatile

        switch mode {
        case .command:
            latest = heard
            onPartial?(heard)
            armSilence(1.4)
        case .wake:
            if let after = Listener.textAfterWakeWord(heard) {
                if !heardWake {
                    heardWake = true
                    onWake?()
                }
                latest = after
                onPartial?(after)
                armSilence(after.isEmpty ? 4.0 : 1.4)
            } else if isFinal && finalized.count > 300 {
                finalized = "" // forget old chatter while waiting for the wake word
            }
        }
    }

    private func fail(_ message: String, mode: Mode) {
        stop()
        if mode == .wake {
            // Back off instead of spinning; try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.mode == nil, Settings.wakeWord else { return }
                self.start(.wake)
            }
        } else {
            onFailure?(message)
        }
    }

    private func armSilence(_ seconds: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    private func finish() {
        guard mode != nil else { return }
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        onCommand?(text)
    }

    private static func textAfterWakeWord(_ text: String) -> String? {
        var best: Range<String.Index>?
        for w in wakeWords {
            if let r = text.range(of: w, options: [.caseInsensitive, .backwards]),
               best == nil || r.upperBound > best!.upperBound {
                best = r
            }
        }
        guard let r = best else { return nil }
        let after = text[r.upperBound...]
        return after.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
