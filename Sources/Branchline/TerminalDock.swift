import AppKit
import Darwin
import Observation
import SwiftTerm
import SwiftUI

@MainActor @Observable
final class TerminalDock {
    let root: URL
    private(set) var visible = false
    private(set) var sessions: [TerminalSession] = []
    private(set) var focusRequest: UInt = 0
    private var selection: UUID?
    @ObservationIgnored private var nextNumber = 1

    init(root: URL) { self.root = root }

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selection }
    }

    var hasRunningSessions: Bool {
        sessions.contains(where: \.running)
    }

    var isRunningScript: Bool { sessions.contains { $0.isScript && $0.running } }

    func runScript(_ name: String) {
        guard !isRunningScript else { return }
        let session = TerminalSession(root: root, number: nextNumber, script: name)
        if let previous = sessions.firstIndex(where: \.isScript) {
            sessions[previous].stop()
            sessions[previous] = session
        } else {
            sessions.append(session)
        }
        selection = session.id
        visible = true
        focusRequest &+= 1
    }

    func toggle() {
        if visible {
            hide()
        } else if sessions.isEmpty {
            addSession()
        } else {
            visible = true
            focusRequest &+= 1
        }
    }

    func hide() {
        visible = false
    }

    func addSession() {
        let session = TerminalSession(root: root, number: nextNumber)
        nextNumber += 1
        sessions.append(session)
        selection = session.id
        visible = true
        focusRequest &+= 1
    }

    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selection = id
        focusRequest &+= 1
    }

    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let closed = sessions.remove(at: index)
        closed.stop()
        if sessions.isEmpty {
            selection = nil
            hide()
        } else if selection == id {
            selection = sessions[min(index, sessions.count - 1)].id
            focusRequest &+= 1
        }
    }

    func stopAll() {
        for session in sessions { session.stop() }
        sessions.removeAll()
        selection = nil
        hide()
    }
}

@MainActor @Observable
final class TerminalSession: Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let title: String
    let isScript: Bool
    private(set) var view: LocalProcessTerminalView?
    private(set) var running = true
    private(set) var status: String?
    private(set) var exitCode: Int32?

    init(root: URL, number: Int, script: String? = nil) {
        let shell = script == nil ? Self.loginShell() : "/bin/zsh"
        let name = URL(fileURLWithPath: shell).lastPathComponent
        title = script.map { "npm: \($0)" } ?? (number == 1 ? name : "\(name) \(number)")
        isScript = script != nil
        let options = TerminalOptions(
            cursorStyle: .steadyBlock,
            scrollback: 1_200,
            enableSixelReported: false,
            maximumOscBytes: 1_048_576
        )
        // Start with a useful PTY size before AppKit applies the dock's actual frame.
        let terminal = ProjectTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 246),
                                           font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                           options: options)
        view = terminal
        terminal.nativeBackgroundColor = NSColor(Palette.base)
        terminal.nativeForegroundColor = NSColor(Palette.text)
        terminal.caretColor = NSColor(Palette.accent)
        terminal.caretViewTracksFocus = true
        terminal.setAccessibilityElement(true)
        terminal.setAccessibilityRole(.textArea)
        terminal.setAccessibilityLabel("Терминал \(title)")
        terminal.processDelegate = self

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Branchline"
        environment["SHELL"] = shell
        environment["PWD"] = root.path
        terminal.startProcess(executable: shell, args: script.map(NPMScripts.arguments) ?? ["-l"],
                              environment: environment.map { "\($0.key)=\($0.value)" },
                              currentDirectory: root.path)
    }

    func stop() {
        guard let view else { return }
        view.processDelegate = nil
        if running { view.terminate() }
        running = false
        view.removeFromSuperview()
        // Releasing SwiftTerm's process also activates its safe SIGKILL escalation
        // if an interactive shell ignores SIGTERM.
        self.view = nil
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        self.exitCode = exitCode
        running = false
        if let exitCode, exitCode != 0 {
            status = "Код выхода \(exitCode)"
        } else {
            status = "Сеанс завершён"
        }
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        running = false
        status = isScript ? "Не удалось запустить npm-скрипт" : "Не удалось запустить оболочку"
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    private static func loginShell() -> String {
        let preferred = ProcessInfo.processInfo.environment["SHELL"]
        let account = getpwuid(getuid()).flatMap { row in
            row.pointee.pw_shell.map { String(cString: $0) }
        }
        return [preferred, account, "/bin/zsh", "/bin/sh"]
            .compactMap { $0 }
            .first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/sh"
    }
}

private final class ProjectTerminalView: LocalProcessTerminalView {
    override func accessibilityValue() -> Any? {
        visibleRowsText(0..<terminalDimensions.rows).joined(separator: "\n")
    }
}

struct TerminalDockView: View {
    var dock: TerminalDock

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.leading, 5)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 3) {
                        tabs
                        add
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    HStack(spacing: 3) {
                        ScrollView(.horizontal) {
                            HStack(spacing: 3) { tabs }
                        }
                        .scrollIndicators(.never)
                        add
                    }
                }
                Spacer(minLength: 0)
                if let status = dock.selectedSession?.status {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Button(action: dock.hide) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(WorkbenchIconButton())
                .accessibilityLabel("Скрыть терминал")
                .workbenchHint("Скрыть терминал", shortcut: GitKeymap.terminal)
            }
            .padding(.horizontal, 5)
            .frame(height: 34)
            .background(Palette.panel)

            if let terminal = dock.selectedSession?.view {
                MountedTerminal(terminal: terminal, focusRequest: dock.focusRequest)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 10)
                    .padding(.top, 4)
            }
        }
        .background(Palette.base)
    }

    private var tabs: some View {
        ForEach(dock.sessions) { session in
            let active = dock.selectedSession?.id == session.id
            HStack(spacing: 1) {
                Button {
                    dock.select(session.id)
                } label: {
                    Text(session.title)
                        .foregroundStyle(session.running ? Palette.text : Palette.muted)
                        .font(.system(size: 11, weight: active ? .semibold : .medium))
                        .lineLimit(1)
                        .padding(.leading, 7)
                        .padding(.trailing, 3)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.title)
                .accessibilityValue(session.status ?? "Активен")
                .accessibilityAddTraits(active ? .isSelected : [])

                Button {
                    dock.close(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(WorkbenchIconButton())
                .accessibilityLabel("Закрыть сеанс \(session.title)")
                .workbenchHint("Закрыть сеанс")
            }
            .background(active ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private var add: some View {
        Button(action: dock.addSession) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(WorkbenchIconButton())
        .accessibilityLabel("Новый сеанс терминала")
        .workbenchHint("Новый сеанс терминала")
    }
}

/// The dock owns the terminal views; changing tabs only moves them between a mount and the dock.
private struct MountedTerminal: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    let focusRequest: UInt

    func makeNSView(context: Context) -> TerminalMount {
        TerminalMount(frame: .zero)
    }

    func updateNSView(_ mount: TerminalMount, context: Context) {
        mount.install(terminal, focusRequest: focusRequest)
    }

    static func dismantleNSView(_ mount: TerminalMount, coordinator: ()) {
        mount.unmount()
    }
}

private final class TerminalMount: NSView {
    private weak var terminal: LocalProcessTerminalView?
    private var focusRequest: UInt?
    private var appliedFocus: UInt?

    func install(_ view: LocalProcessTerminalView, focusRequest: UInt) {
        if terminal !== view {
            unmount()
            view.removeFromSuperview()
            // A zero-sized intermediary frame would resize and reflow the PTY while mounting.
            if bounds.width > 0 && bounds.height > 0 { view.frame = bounds }
            view.autoresizingMask = []
            addSubview(view)
            terminal = view
        }
        self.focusRequest = focusRequest
        scheduleFocus()
    }

    func unmount() {
        if let terminal, terminal.superview === self { terminal.removeFromSuperview() }
        terminal = nil
        focusRequest = nil
        appliedFocus = nil
    }

    override func layout() {
        super.layout()
        sizeTerminal()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeTerminal()
    }

    private func sizeTerminal() {
        if bounds.width > 0 && bounds.height > 0, let terminal, terminal.superview === self, terminal.frame != bounds {
            terminal.frame = bounds
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { appliedFocus = nil }
        else { scheduleFocus() }
    }

    private func scheduleFocus() {
        guard window != nil, let focusRequest, focusRequest != appliedFocus else { return }
        appliedFocus = focusRequest
        DispatchQueue.main.async { [weak self] in
            guard let self, appliedFocus == focusRequest, let terminal, terminal.superview === self else { return }
            window?.makeFirstResponder(terminal)
        }
    }
}
