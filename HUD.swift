import AppKit
import SwiftUI

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class HUD {
    private let panel: HUDPanel
    private var hideWork: DispatchWorkItem?
    private static let size = NSSize(width: 480, height: 420)

    init(onSubmit: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        panel = HUDPanel(contentRect: NSRect(origin: .zero, size: HUD.size),
                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                         backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: HUDView(onSubmit: onSubmit, onClose: onClose))
        host.frame = NSRect(origin: .zero, size: HUD.size)
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible }

    func show(focusInput: Bool = false) {
        hideWork?.cancel()
        if !panel.isVisible, let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - HUD.size.width / 2, y: f.maxY - HUD.size.height - 8))
        }
        if focusInput {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            AppState.shared.showInput = false
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

struct HUDView: View {
    @ObservedObject var state = AppState.shared
    var onSubmit: (String) -> Void
    var onClose: () -> Void
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Orb(status: state.status, level: state.level)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 15, weight: .semibold))
                        if !state.activity.isEmpty {
                            Text(state.activity).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if !state.transcript.isEmpty {
                    Text("“\(state.transcript)”")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if !state.reply.isEmpty {
                    ScrollView {
                        Text(state.reply)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if state.showInput {
                    TextField("Ask Jarvis…", text: $typed)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
                        .focused($focused)
                        .onSubmit {
                            let t = typed.trimmed
                            typed = ""
                            if !t.isEmpty { onSubmit(t) }
                        }
                        .onAppear { focused = true }
                }
            }
            .padding(18)
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .onExitCommand(perform: onClose)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .frame(width: 480, height: 420, alignment: .top)
    }

    private var title: String {
        switch state.status {
        case .idle: return state.showInput ? "How can I help?" : "Jarvis"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Jarvis"
        }
    }
}

struct Orb: View {
    var status: JarvisStatus
    var level: Float

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let pulse: CGFloat = {
                switch status {
                case .listening: return CGFloat(min(1, level * 14))
                case .thinking: return 0.25 + 0.2 * CGFloat(sin(t * 4))
                case .speaking: return 0.2 + 0.25 * CGFloat(abs(sin(t * 7)))
                case .idle: return 0.05
                }
            }()
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.9), .cyan, .blue.opacity(0.1)],
                                         center: .center, startRadius: 1, endRadius: 20))
                    .scaleEffect(0.7 + pulse * 0.45)
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees((t * (status == .thinking ? 360 : 60)).truncatingRemainder(dividingBy: 360)))
                    .opacity(status == .idle ? 0.3 : 0.9)
            }
            .frame(width: 42, height: 42)
        }
    }
}
