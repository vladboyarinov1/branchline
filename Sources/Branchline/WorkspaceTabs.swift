import AppKit
import Foundation
import Observation

@MainActor @Observable
final class WorkspaceTabs {
    struct Tab: Identifiable {
        var id: URL { root }
        let root: URL
        var loaded: Workspace?
        var name: String { root.lastPathComponent }
    }

    private(set) var tabs: [Tab] = []
    private(set) var activeID: URL?
    private(set) var recent = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
    private(set) var notice: GitNotice?
    private(set) var loading = false
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var opening: Task<Void, Never>?

    var active: Workspace? { tabs.first(where: { $0.id == activeID })?.loaded }

    func restore() {
        guard !restored else { return }
        restored = true
        let defaults = UserDefaults.standard
        tabs = (defaults.stringArray(forKey: "openRepositories") ?? [])
            .map { Tab(root: URL(fileURLWithPath: $0, isDirectory: true), loaded: nil) }
        guard let first = tabs.first else { return }
        let last = defaults.string(forKey: "activeRepository")
        select(tabs.first(where: { $0.root.path == last })?.id ?? first.id)
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Открыть"
        panel.message = "Выберите одну или несколько папок Git-репозиториев"
        if let root = activeID { panel.directoryURL = root.deletingLastPathComponent() }
        guard panel.runModal() == .OK else { return }
        _ = openFolders(panel.urls)
    }

    func openFolders(_ urls: [URL]) -> Bool {
        let folders = urls.filter { url in
            guard url.isFileURL else { return false }
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
        guard !folders.isEmpty else { return false }
        startOpening {
            var last: Git?
            var failures: [String] = []
            for url in folders {
                try Task.checkCancellation()
                do {
                    let git = try await Git.discover(url)
                    try Task.checkCancellation()
                    last = git
                    self.add(git.root)
                } catch {
                    failures.append("\(url.lastPathComponent) — \(error.localizedDescription)")
                }
            }
            if let last { try await self.show(last) }
            if !failures.isEmpty {
                self.notice = GitNotice(title: "Некоторые папки не открылись", message: failures.joined(separator: "\n\n"))
            }
        }
        return true
    }

    func open(_ folder: URL) {
        startOpening {
            let git = try await Git.discover(folder)
            self.add(git.root)
            try await self.show(git)
        }
    }

    func demo() {
        startOpening {
            let folder = try await DemoRepository.prepare()
            let git = try await Git.discover(folder)
            self.add(git.root)
            try await self.show(git)
        }
    }

    func select(_ id: URL) {
        guard activeID != id || loading else { return }
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if let workspace = tab.loaded {
            opening?.cancel()
            loading = false
            switchTo(tab.id, workspace: workspace)
        } else {
            startOpening {
                let git = try await Git.discover(tab.root)
                guard self.tabs.contains(where: { $0.id == id }) else { return }
                try await self.show(git)
            }
        }
    }

    func selectAdjacent(_ offset: Int) {
        guard !tabs.isEmpty else { return }
        if let index = tabs.firstIndex(where: { $0.id == activeID }) {
            select(tabs[(index + offset + tabs.count) % tabs.count].id)
        } else if let id = tabs.first?.id {
            select(id)
        }
    }

    func close(_ id: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].loaded?.activity == nil else { return }
        let tab = tabs[index]
        if let terminal = tab.loaded?.terminalDock, terminal.hasRunningSessions {
            let alert = NSAlert()
            alert.messageText = "Закрыть проект «\(tab.name)»?"
            alert.informativeText = "Сеансы терминала и запущенные в них команды завершатся."
            alert.addButton(withTitle: "Отмена").keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: "Закрыть проект").hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        tab.loaded?.terminalDock?.stopAll()
        let wasActive = activeID == id
        if wasActive {
            active?.setFront(false)
            activeID = nil
        }
        tabs.remove(at: index)
        save()
        if wasActive && !tabs.isEmpty { select(tabs[min(index, tabs.count - 1)].id) }
    }

    func clearNotice() { notice = nil }

    private func add(_ root: URL) {
        guard !tabs.contains(where: { $0.root == root }) else { return }
        tabs.append(Tab(root: root, loaded: nil))
        save()
    }

    private func show(_ git: Git) async throws {
        try Task.checkCancellation()
        add(git.root)
        if let existing = tabs.first(where: { $0.id == git.root })?.loaded {
            switchTo(git.root, workspace: existing)
            return
        }
        let workspace = Workspace()
        try await workspace.attach(git)
        try Task.checkCancellation()
        guard let index = tabs.firstIndex(where: { $0.id == git.root }) else { return }
        tabs[index].loaded = workspace
        switchTo(git.root, workspace: workspace)
    }

    private func switchTo(_ id: URL, workspace: Workspace) {
        if activeID != id { active?.setFront(false) }
        activeID = id
        workspace.setFront(true)
        recent = [id.path] + recent.filter { $0 != id.path }.prefix(12)
        UserDefaults.standard.set(recent, forKey: "recentRepositories")
        save()
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(tabs.map { $0.root.path }, forKey: "openRepositories")
        defaults.set(activeID?.path, forKey: "activeRepository")
    }

    private func startOpening(_ action: @escaping @MainActor () async throws -> Void) {
        opening?.cancel()
        loading = true
        opening = Task {
            defer { if !Task.isCancelled { loading = false } }
            do { try await action() }
            catch is CancellationError {}
            catch { if !Task.isCancelled {
                notice = GitNotice(title: "Не удалось открыть репозиторий", message: error.localizedDescription)
            } }
        }
    }
}
