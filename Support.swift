import AppKit
import Security

enum JarvisStatus: Equatable {
    case idle, listening, thinking, speaking
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var status: JarvisStatus = .idle
    @Published var transcript = ""
    @Published var reply = ""
    @Published var activity = ""
    @Published var level: Float = 0
    @Published var showInput = false
}

enum Settings {
    private static var d: UserDefaults { .standard }

    static var speakReplies: Bool {
        get { d.object(forKey: "speakReplies") as? Bool ?? true }
        set { d.set(newValue, forKey: "speakReplies") }
    }
    static var wakeWord: Bool {
        get { d.object(forKey: "wakeWord") as? Bool ?? false }
        set { d.set(newValue, forKey: "wakeWord") }
    }
    static var confirmShell: Bool {
        get { d.object(forKey: "confirmShell") as? Bool ?? true }
        set { d.set(newValue, forKey: "confirmShell") }
    }
    static var model: String {
        get { d.string(forKey: "model") ?? "claude-opus-5-5" }
        set { d.set(newValue, forKey: "model") }
    }
    static var voiceIdentifier: String? {
        get { d.string(forKey: "voice") }
        set { d.set(newValue, forKey: "voice") }
    }
}

enum Keychain {
    private static let service = "com.joshareh.jarvis"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum APIKey {
    static var current: String? {
        if let k = Keychain.get("anthropic-api-key"), !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        return nil
    }
}

enum Paths {
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jarvis", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var memory: URL { support.appendingPathComponent("memory.md") }
}

enum Shell {
    /// Runs an executable off the main thread, with a timeout, capturing stdout/stderr.
    static func run(_ exe: String, _ args: [String], input: String? = nil,
                    timeout: TimeInterval = 60) async -> (code: Int32, out: String, err: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let o = Pipe(), e = Pipe(), i = Pipe()
                p.standardOutput = o
                p.standardError = e
                p.standardInput = i
                do { try p.run() } catch {
                    cont.resume(returning: (-1, "", error.localizedDescription))
                    return
                }
                if let input { i.fileHandleForWriting.write(Data(input.utf8)) }
                try? i.fileHandleForWriting.close()

                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { outData = o.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); group.leave() }

                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                p.waitUntilExit()
                killer.cancel()
                // A backgrounded grandchild can hold the pipes open; don't wait on it forever.
                _ = group.wait(timeout: .now() + 2)
                cont.resume(returning: (p.terminationStatus,
                                        String(decoding: outData, as: UTF8.self),
                                        String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}

enum Log {
    static let url = Paths.support.appendingPathComponent("jarvis.log")
    static func write(_ s: String) {
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
