import AppKit

struct ToolResult {
    var content: Any // String, or an array of content blocks (for images)
    var isError = false
}

/// Local tools Claude can call to act on the Mac.
@MainActor
final class ToolBox {
    var onTimer: ((TimeInterval, String) -> Void)?

    static let definitions: [[String: Any]] = [
        [
            "name": "run_applescript",
            "description": """
            Run AppleScript via osascript and return its result. This is the main way to control the Mac and its apps: \
            Music/Spotify playback, volume (`set volume output volume 40`), dark mode, Calendar, Reminders, Notes, Mail, \
            Messages, Safari/Chrome tabs, Finder, System Events (keystrokes, UI scripting), notifications, and so on.
            """,
            "input_schema": [
                "type": "object",
                "properties": ["script": ["type": "string", "description": "AppleScript source code."]],
                "required": ["script"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "run_shell",
            "description": """
            Run a zsh command (login shell) and return stdout/stderr. Use for files, system info (battery: `pmset -g batt`, \
            disk, network, processes), and command-line tools. Times out after 120 seconds.
            """,
            "input_schema": [
                "type": "object",
                "properties": ["command": ["type": "string"]],
                "required": ["command"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "open",
            "description": "Open an application by name (e.g. \"Safari\"), a URL (https://…, or app schemes like spotify:), or a file/folder path.",
            "input_schema": [
                "type": "object",
                "properties": ["target": ["type": "string"]],
                "required": ["target"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "look_at_screen",
            "description": "Take a screenshot of the main display and return it as an image, to see what the user is looking at.",
            "input_schema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "clipboard",
            "description": "Read the clipboard text (omit text) or replace it (provide text).",
            "input_schema": [
                "type": "object",
                "properties": ["text": ["type": "string"]],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "set_timer",
            "description": "Start a countdown timer. Jarvis will chime and announce it when it finishes.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "seconds": ["type": "number"],
                    "label": ["type": "string", "description": "Short name, e.g. \"pasta\"."],
                ],
                "required": ["seconds"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "remember",
            "description": "Save a lasting fact or preference about the user to long-term memory (persists across conversations).",
            "input_schema": [
                "type": "object",
                "properties": ["fact": ["type": "string"]],
                "required": ["fact"],
                "additionalProperties": false,
            ],
        ],
    ]

    static func describe(_ name: String, _ input: [String: Any]) -> String {
        switch name {
        case "run_applescript": return "Controlling apps…"
        case "run_shell": return "Running: \((input["command"] as? String ?? "").prefix(60))"
        case "open": return "Opening \(input["target"] as? String ?? "")…"
        case "look_at_screen": return "Looking at your screen…"
        case "clipboard": return "Using the clipboard…"
        case "set_timer": return "Setting a timer…"
        case "remember": return "Noting that down…"
        case "web_search": return "Searching the web…"
        default: return "Working…"
        }
    }

    func run(name: String, input: [String: Any]) async -> ToolResult {
        switch name {
        case "run_applescript":
            guard let script = input["script"] as? String else { return ToolResult(content: "Missing script", isError: true) }
            let r = await Shell.run("/usr/bin/osascript", [], input: script, timeout: 60)
            if r.code != 0 { return ToolResult(content: "Error: \(r.err.trimmed)", isError: true) }
            return ToolResult(content: r.out.trimmed.isEmpty ? "OK" : String(r.out.trimmed.prefix(20000)))

        case "run_shell":
            guard let cmd = input["command"] as? String else { return ToolResult(content: "Missing command", isError: true) }
            if Settings.confirmShell && !confirm(cmd) {
                return ToolResult(content: "The user declined to run this command.", isError: true)
            }
            let r = await Shell.run("/bin/zsh", ["-lc", cmd], timeout: 120)
            var out = r.out
            if !r.err.isEmpty { out += "\n[stderr]\n" + r.err }
            out = String(out.trimmed.prefix(20000))
            return ToolResult(content: "exit \(r.code)\n\(out)", isError: r.code != 0)

        case "open":
            guard let target = input["target"] as? String else { return ToolResult(content: "Missing target", isError: true) }
            let expanded = (target as NSString).expandingTildeInPath
            let args: [String]
            if FileManager.default.fileExists(atPath: expanded) {
                args = [expanded]
            } else if target.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil {
                args = [target] // URL or app scheme
            } else {
                args = ["-a", target]
            }
            let r = await Shell.run("/usr/bin/open", args, timeout: 15)
            return r.code == 0 ? ToolResult(content: "Opened \(target)") : ToolResult(content: r.err.trimmed, isError: true)

        case "look_at_screen":
            let path = NSTemporaryDirectory() + "jarvis-screen.jpg"
            let r = await Shell.run("/usr/sbin/screencapture", ["-x", "-m", "-t", "jpg", path], timeout: 15)
            _ = await Shell.run("/usr/bin/sips", ["-Z", "1568", path], timeout: 15)
            guard r.code == 0, let data = FileManager.default.contents(atPath: path) else {
                return ToolResult(content: "Screenshot failed. Screen Recording permission may be needed: \(r.err)", isError: true)
            }
            try? FileManager.default.removeItem(atPath: path)
            return ToolResult(content: [[
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()],
            ]])

        case "clipboard":
            let pb = NSPasteboard.general
            if let text = input["text"] as? String {
                pb.clearContents()
                pb.setString(text, forType: .string)
                return ToolResult(content: "Clipboard updated.")
            }
            return ToolResult(content: pb.string(forType: .string) ?? "(clipboard is empty or not text)")

        case "set_timer":
            let secs = (input["seconds"] as? NSNumber)?.doubleValue ?? 0
            guard secs > 0 else { return ToolResult(content: "seconds must be positive", isError: true) }
            onTimer?(secs, input["label"] as? String ?? "")
            return ToolResult(content: "Timer set for \(Int(secs)) seconds.")

        case "remember":
            guard let fact = input["fact"] as? String else { return ToolResult(content: "Missing fact", isError: true) }
            let line = "- \(fact)\n"
            if let h = try? FileHandle(forWritingTo: Paths.memory) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? line.write(to: Paths.memory, atomically: true, encoding: .utf8)
            }
            return ToolResult(content: "Remembered.")

        default:
            return ToolResult(content: "Unknown tool \(name)", isError: true)
        }
    }

    private func confirm(_ cmd: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Jarvis wants to run a shell command"
        a.informativeText = cmd
        a.addButton(withTitle: "Run")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
