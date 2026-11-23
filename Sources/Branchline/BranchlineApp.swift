import AppKit
import SwiftUI

@main
struct BranchlineApp: App {
    @State private var desk = WorkspaceTabs()
    @NSApplicationDelegateAdaptor(BranchlineTermination.self) private var termination
    @AppStorage(DiffView.syntaxHighlightingKey) private var highlightsSyntax = true

    var body: some Scene {
        Window("Branchline", id: "workspace") {
            MainWindow(desk: desk)
                .frame(minWidth: 950, minHeight: 650)
                .preferredColorScheme(.dark)
                .onAppear { termination.desk = desk }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть репозитории…", action: desk.chooseRepository)
                    .keyboardShortcut("o")
                if !desk.recent.isEmpty {
                    Menu("Недавние репозитории") {
                        ForEach(desk.recent, id: \.self) { path in
                            let url = URL(fileURLWithPath: path, isDirectory: true)
                            Button(url.lastPathComponent) { desk.open(url) }
                                .help(path)
                        }
                    }
                }
                Button("Открыть демо", action: desk.demo)
                Divider()
                Button("Закрыть вкладку") {
                    if let id = desk.activeID { desk.close(id) }
                }
                .keyboardShortcut("w")
                .disabled(desk.activeID == nil || desk.active?.activity != nil)
            }
            CommandMenu("Git") {
                gitCommand("Commit…", action: .commit, shortcut: GitKeymap.commit)
                gitCommand("Commit and Push…", action: .commitAndPush, shortcut: GitKeymap.commitAndPush)
                gitCommand("Push…", action: .push, shortcut: GitKeymap.push)
                gitCommand("Update Project…", action: .update, shortcut: GitKeymap.update)
                Button("Fetch") { desk.active?.fetch() }.disabled(desk.active == nil || desk.active?.activity != nil)
                Button("Refresh File Status") { desk.active?.refresh(userInitiated: true) }
                    .keyboardShortcut("r")
                    .disabled(desk.active == nil || desk.active?.activity != nil)
                Divider()
                gitCommand("Show Diff", action: .diff, shortcut: GitKeymap.showDiff)
                gitCommand(desk.active?.commitMode == .index ? "Stage" : "Toggle Inclusion in Commit",
                           action: .stage, shortcut: GitKeymap.stage)
                gitCommand("Rollback…", action: .rollback, shortcut: GitKeymap.rollback)
                gitCommand("Amend", action: .amend, shortcut: GitKeymap.amend)
                Divider()
                gitCommand("Commit Tool Window", action: .commitTool, shortcut: GitKeymap.commitToolWindow)
                gitCommand("Git Tool Window", action: .log, shortcut: GitKeymap.log)
                gitCommand("VCS Operations Popup", action: .vcsActions, shortcut: GitKeymap.vcsOperations)
                gitCommand("Find Action…", action: .findAction, shortcut: GitKeymap.findAction)
                Button("Branches…") { desk.active?.send(.branches) }.disabled(desk.active == nil)
                Button("Stash") { desk.active?.activate(.stash) }.disabled(desk.active == nil)
                Button("Worktrees") { desk.active?.activate(.worktrees) }.disabled(desk.active == nil)
                Button("Keyboard Shortcuts") { desk.active?.send(.keymap) }.disabled(desk.active == nil)
            }
            CommandGroup(after: .toolbar) {
                gitCommand("Project", action: .projectFiles, shortcut: GitKeymap.projectFiles)
                gitCommand("Terminal", action: .terminal, shortcut: GitKeymap.terminal)
                Divider()
                Toggle("Подсветка синтаксиса в diff", isOn: $highlightsSyntax)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Предыдущий проект") { desk.selectAdjacent(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(desk.tabs.count < 2)
                Button("Следующий проект") { desk.selectAdjacent(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(desk.tabs.count < 2)
            }
        }
    }
    private func gitCommand(_ title: String, action: RepositoryCommand, shortcut: KeyboardShortcut) -> some View {
        Button(title) { desk.active?.send(action) }
            .keyboardShortcut(shortcut)
            .disabled(desk.active == nil)
    }

}

@MainActor
final class BranchlineTermination: NSObject, NSApplicationDelegate {
    weak var desk: WorkspaceTabs?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let desk, desk.hasUnsavedEditors else { return .terminateNow }
        Task { sender.reply(toApplicationShouldTerminate: await desk.flushEditors()) }
        return .terminateLater
    }
}

private struct ProjectTabFrames: PreferenceKey {
    static let defaultValue: [URL: CGRect] = [:]

    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, last in last })
    }
}

private struct MainWindow: View {
    let desk: WorkspaceTabs
    @Environment(\.scenePhase) private var scenePhase
    @State private var booted = false
    @State private var tabFrames: [URL: CGRect] = [:]
    @State private var tabDropTarget: URL?
    private let tabCoordinateSpace = "project-tabs"

    var body: some View {
        VStack(spacing: 0) {
            if let workspace = desk.active {
                RepositoryView(workspace: workspace, openWorktree: desk.open) {
                    projectTabs
                }
                .id(desk.activeID)
            } else {
                HStack(spacing: 5) {
                    if !desk.tabs.isEmpty { projectTabs }
                    WindowDragSpace()
                        .frame(maxWidth: .infinity)
                }
                .padding(.leading, 78)
                .padding(.trailing, 8)
                .frame(height: WorkbenchLayout.titleHeight)
                .background(Palette.header)
                welcome
            }
        }
        .foregroundStyle(Palette.text)
        .tint(Palette.accent)
        .background(Palette.base)
        .ignoresSafeArea(.container, edges: .top)
        .workbenchHints()
        .dropDestination(for: URL.self) { urls, _ in desk.openFolders(urls) }
        .task {
            guard !booted else { return }
            booted = true
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "--repo"), args.indices.contains(index + 1) {
                desk.open(URL(fileURLWithPath: args[index + 1], isDirectory: true))
            } else if args.contains("--demo") {
                desk.demo()
            } else {
                desk.restore()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, desk.active?.activity == nil { desk.active?.refresh() }
        }
        .alert(desk.notice?.title ?? "", isPresented: Binding(
            get: { desk.notice != nil }, set: { if !$0 { desk.clearNotice() } }
        )) {
            Button("Закрыть", role: .cancel) { desk.clearNotice() }
        } message: {
            Text(desk.notice?.message ?? "")
        }
    }

    private var projectTabs: some View {
        HStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) { tabButtons }
                    .fixedSize(horizontal: true, vertical: false)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 2) { tabButtons }
                    }
                    .scrollIndicators(.never)
                    .onChange(of: desk.activeID, initial: true) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            DeferredVisibility(isPending: desk.loading && desk.active != nil) { showProgress in
                Button(action: desk.chooseRepository) {
                    ZStack {
                        if showProgress { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                        else { Image(systemName: "plus").font(.system(size: 12, weight: .medium)) }
                    }
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(WorkbenchIconButton(keepsEnabledAppearance: desk.loading))
                .accessibilityLabel(showProgress ? "Открываем репозиторий" : "Открыть репозитории")
                .disabled(desk.loading)
                .workbenchHint("Открыть репозитории", shortcut: KeyboardShortcut("o"))
            }
        }
        .coordinateSpace(name: tabCoordinateSpace)
        .onPreferenceChange(ProjectTabFrames.self) { tabFrames = $0 }
    }

    private var tabButtons: some View {
        ForEach(desk.tabs) { tab in
            projectTab(tab).id(tab.id)
        }
    }

    private func projectTab(_ tab: WorkspaceTabs.Tab) -> some View {
        let selected = tab.id == desk.activeID
        return HStack(spacing: 0) {
            Button { desk.select(tab.id) } label: {
                Text(tab.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 9)
                    .padding(.trailing, 4)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.root.path)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .overlay {
                ProjectTabPointer(
                    click: { desk.select(tab.id) },
                    move: { point in
                        let target = tabTarget(from: tab.id, at: point)
                        if tabDropTarget != target { tabDropTarget = target }
                    },
                    drop: { point in
                        tabDropTarget = nil
                        if let target = tabTarget(from: tab.id, at: point) { desk.move(tab.id, to: target) }
                    },
                    cancel: { tabDropTarget = nil }
                )
            }
            let indexing = tab.loaded?.isUpdatingIndex == true
            DeferredVisibility(isPending: !selected && !indexing && tab.loaded?.activity != nil) { showProgress in
                Button { desk.close(tab.id) } label: {
                    ZStack {
                        if showProgress { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                        else { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }
                    }
                    .frame(width: 23, height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(WorkbenchIconButton(keepsEnabledAppearance: indexing))
                .accessibilityLabel(showProgress ? "Git-операция в проекте \(tab.name)" : "Закрыть вкладку \(tab.name)")
                .workbenchHint(showProgress ? "Git-операция в процессе" : "Закрыть вкладку",
                               shortcut: selected ? KeyboardShortcut("w") : nil)
                .disabled(tab.loaded?.activity != nil)
            }
        }
        .foregroundStyle(selected ? Palette.text : Palette.muted)
        .frame(maxWidth: 210)
        .background(selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: ProjectTabFrames.self,
                    value: [tab.id: geometry.frame(in: .named(tabCoordinateSpace))])
            }
        }
        .overlay {
            if tabDropTarget == tab.id {
                RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.accentBorder).allowsHitTesting(false)
            }
        }
        .contextMenu {
            if let index = desk.tabs.firstIndex(where: { $0.id == tab.id }) {
                if index > 0 {
                    Button("Переместить влево") { desk.move(tab.id, to: desk.tabs[index - 1].id) }
                }
                if index + 1 < desk.tabs.count {
                    Button("Переместить вправо") { desk.move(tab.id, to: desk.tabs[index + 1].id) }
                }
            }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([tab.root]) }
            Button("Закрыть вкладку") { desk.close(tab.id) }
                .disabled(tab.loaded?.activity != nil)
        }
    }

    private func tabTarget(from source: URL, at point: CGPoint) -> URL? {
        guard let origin = tabFrames[source]?.origin else { return nil }
        let location = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
        return desk.tabs.first(where: { $0.id != source && tabFrames[$0.id]?.contains(location) == true })?.id
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            if !booted || desk.loading {
                DeferredVisibility(isPending: desk.loading) { showProgress in
                    if showProgress {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Открываем репозиторий")
                    }
                }
            } else {
                Text("Откройте Git-репозиторий")
                    .font(.system(size: 22, weight: .semibold))
                HStack(spacing: 8) {
                    Button("Выбрать папку…", action: desk.chooseRepository)
                        .buttonStyle(StudioButton(kind: .primary))
                    Button("Открыть демо", action: desk.demo)
                        .buttonStyle(StudioButton())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}


struct WindowDragSpace: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window, window.isMovable { window.isMovable = false }
    }

    private final class DragView: NSView {
        private var start: (pointer: CGPoint, origin: CGPoint)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // A hidden title bar still receives system-level window drags on some macOS versions.
            window?.isMovable = false
        }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            start = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let window else { return }
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            window.setFrameOrigin(CGPoint(x: start.origin.x + pointer.x - start.pointer.x,
                                          y: start.origin.y + pointer.y - start.pointer.y))
        }

        override func mouseUp(with event: NSEvent) {
            start = nil
        }
    }
}

private struct ProjectTabPointer: NSViewRepresentable {
    let click: () -> Void
    let move: (CGPoint) -> Void
    let drop: (CGPoint) -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> Pointer { Pointer() }

    func updateNSView(_ view: Pointer, context: Context) {
        view.click = click
        view.move = move
        view.drop = drop
        view.cancel = cancel
    }

    final class Pointer: NSView {
        var click: (() -> Void)?
        var move: ((CGPoint) -> Void)?
        var drop: ((CGPoint) -> Void)?
        var cancel: (() -> Void)?
        private var start: CGPoint?
        private var dragging = false

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let location = event.locationInWindow
            if !dragging {
                dragging = hypot(location.x - start.x, location.y - start.y) >= 5
            }
            if dragging { move?(convert(location, from: nil)) }
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            let point = convert(event.locationInWindow, from: nil)
            if dragging {
                dragging = false
                drop?(point)
            } else if bounds.contains(point) {
                click?()
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, dragging { cancel?() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
