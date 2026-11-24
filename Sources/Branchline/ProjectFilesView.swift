import AppKit
import Darwin
import Observation
import SwiftUI

@MainActor @Observable
final class ProjectFilesModel {
    let root: URL
    let previewCache = ProjectPreviewCache()
    var visible = false {
        didSet {
            if visible { loadRoot() }
            else { suspend() }
        }
    }

    fileprivate private(set) var selectedPath: String?
    private(set) var previewPath: String?
    private(set) var previewRevision: UInt = 0
    fileprivate private(set) var expanded: Set<String> = []
    fileprivate private(set) var listings: [String: ProjectListing] = [:]
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]
    private var unsavedEditors: [String: InlineFileBuffer] = [:]

    init(root: URL) { self.root = root }

    var hasUnsavedEditors: Bool { !unsavedEditors.isEmpty }

    func pendingEditor(at path: String) -> InlineFileBuffer? { unsavedEditors[path] }

    func editor(at path: String, draft: WorktreeFileDraft) -> InlineFileBuffer {
        if let editor = pendingEditor(at: path) { return editor }
        return InlineFileBuffer(root: root, path: path, draft: draft) { [weak self] editor in
            self?.unsavedEditors[path] = editor.dirty || editor.saving ? editor : nil
        }
    }

    func discardEditor(_ editor: InlineFileBuffer) {
        guard !editor.saving, pendingEditor(at: editor.path) === editor else { return }
        editor.cancelPendingSave()
        unsavedEditors[editor.path] = nil
        previewRevision &+= 1
    }

    func flushEditors() async -> InlineFileBuffer? {
        for editor in Array(unsavedEditors.values) {
            if !(await editor.flush()) { return editor }
        }
        return nil
    }

    func refresh() {
        guard visible else { return }
        load("", refreshing: true)
        if previewPath != nil { previewRevision &+= 1 }
    }

    func refreshPreview(affectedBy changes: RepositoryChanges) {
        guard visible, let previewPath,
              changes.affectsWorkingPatch(for: previewPath, originalPath: nil) else { return }
        previewRevision &+= 1
    }

    func closePreview() {
        if previewPath != nil { previewPath = nil }
        previewCache.clear()
    }

    fileprivate func loadRoot() {
        if visible { load("") }
    }

    func pauseLoads() {
        for load in loads.values { load.cancel() }
        loads.removeAll()
        listings = listings.filter { _, listing in
            if case .loading = listing { return false }
            return true
        }
    }

    func suspend() {
        pauseLoads()
        listings.removeAll()
        previewCache.clear()
    }

    fileprivate func select(_ entry: ProjectFileEntry) {
        selectRow(entry)
        if entry.kind == .directory {
            setExpanded(entry.path, to: !expanded.contains(entry.path))
        }
    }

    private func selectRow(_ entry: ProjectFileEntry) {
        selectedPath = entry.path
        if entry.kind != .directory { previewPath = entry.path }
    }

    fileprivate func navigate(_ key: KeyEquivalent) -> ProjectFileEntry? {
        let rows = rows
        guard let first = rows.first else { return nil }
        guard let index = rows.firstIndex(where: { $0.id == selectedPath }) else {
            selectRow(first.entry)
            return first.entry
        }
        let current = rows[index].entry
        let destination: ProjectFileEntry?
        switch key {
        case .upArrow:
            destination = index > 0 ? rows[index - 1].entry : nil
        case .downArrow:
            destination = index + 1 < rows.count ? rows[index + 1].entry : nil
        case .leftArrow:
            if expanded.contains(current.path) && current.kind == .directory {
                setExpanded(current.path, to: false)
                return nil
            }
            let parent = current.path.lastIndex(of: "/").map { current.path[..<$0] }
            destination = rows.first { parent == $0.id[...] }?.entry
        case .rightArrow:
            guard current.kind == .directory else { return nil }
            if !expanded.contains(current.path) {
                setExpanded(current.path, to: true)
                return nil
            }
            if case .loaded(let children) = listings[current.path] {
                destination = children.first
            } else { destination = nil }
        default:
            return nil
        }
        if let destination {
            selectRow(destination)
        }
        return destination
    }

    fileprivate var selectedFile: ProjectFileEntry? {
        rows.first { $0.id == selectedPath && $0.entry.kind == .file }?.entry
    }

    fileprivate var rows: [ProjectFileRow] {
        guard case let .loaded(entries) = listings[""] else { return [] }
        var visibleRows: [ProjectFileRow] = []
        var remaining = entries.reversed().map { ProjectFileRow(entry: $0, depth: 0) }
        while let row = remaining.popLast() {
            visibleRows.append(row)
            if expanded.contains(row.entry.path), case let .loaded(children) = listings[row.entry.path] {
                remaining.append(contentsOf: children.reversed().map { ProjectFileRow(entry: $0, depth: row.depth + 1) })
            }
        }
        return visibleRows
    }

    private func setExpanded(_ path: String, to value: Bool) {
        if value {
            expanded.insert(path)
            load(path)
        } else {
            discardTree(path)
        }
    }

    private func discardTree(_ path: String) {
        let prefix = path + "/"
        expanded = expanded.filter { $0 != path && !$0.hasPrefix(prefix) }
        for key in Array(listings.keys) where key == path || key.hasPrefix(prefix) {
            listings.removeValue(forKey: key)
            loads.removeValue(forKey: key)?.cancel()
        }
    }

    private func load(_ path: String, refreshing: Bool = false) {
        guard loads[path] == nil, refreshing || listings[path] == nil else { return }
        if listings[path] == nil { listings[path] = .loading }
        let read = Task.detached(priority: .userInitiated) { [root] in
            try ProjectDirectory.read(root: root, path: path)
        }
        loads[path] = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await read.result
            } onCancel: {
                read.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.loads.removeValue(forKey: path)
            switch result {
            case .success(let children):
                if case .loaded(let previous) = self.listings[path] {
                    let directories = Set(children.lazy.filter { $0.kind == .directory }.map(\.path))
                    for removed in previous where removed.kind == .directory && !directories.contains(removed.path) {
                        self.discardTree(removed.path)
                    }
                }
                self.listings[path] = .loaded(children)
                for child in children where child.kind == .directory && self.expanded.contains(child.path) {
                    self.load(child.path, refreshing: refreshing)
                }
            case .failure(let error):
                self.listings[path] = .failed(error.localizedDescription)
            }
        }
    }
}

private enum ProjectListing {
    case loading
    case loaded([ProjectFileEntry])
    case failed(String)
}

private struct ProjectFileEntry: Sendable {
    enum Kind: Sendable {
        case directory, file, link, other

        var icon: String {
            switch self {
            case .directory: "folder"
            case .link: "link"
            case .file, .other: "doc"
            }
        }
    }

    let path: String
    let name: String
    let kind: Kind
}

private struct ProjectFileRow: Identifiable {
    var id: String { entry.path }
    let entry: ProjectFileEntry
    let depth: Int
}

private enum ProjectDirectory {
    static func read(root: URL, path: String) throws -> [ProjectFileEntry] {
        let components = try ProjectFileSystem.components(path)
        let descriptor = try ProjectFileSystem.openDirectory(root: root, components: components[...])
        guard let stream = fdopendir(descriptor) else {
            let error = ProjectFileSystem.error()
            close(descriptor)
            throw error
        }
        defer { closedir(stream) }

        var entries: [ProjectFileEntry] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let record = readdir(stream) else {
                if errno != 0 { throw ProjectFileSystem.error() }
                break
            }
            let length = Int(record.pointee.d_namlen)
            let name = withUnsafeBytes(of: &record.pointee.d_name) {
                String(bytes: $0.prefix(length), encoding: .utf8)
            }
            guard let name, name != ".", name != "..", !path.isEmpty || name != ".git" else { continue }
            let type = Int32(record.pointee.d_type)
            let kind: ProjectFileEntry.Kind
            switch type {
            case DT_DIR: kind = .directory
            case DT_REG: kind = .file
            case DT_LNK: kind = .link
            case DT_UNKNOWN: kind = entryKind(descriptor: descriptor, name: name)
            default: kind = .other
            }
            let relativePath = path.isEmpty ? name : path + "/" + name
            entries.append(ProjectFileEntry(path: relativePath, name: name, kind: kind))
        }
        return entries.sorted { left, right in
            let leftFolder = left.kind == .directory
            let rightFolder = right.kind == .directory
            if leftFolder != rightFolder { return leftFolder }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private static func entryKind(descriptor: Int32, name: String) -> ProjectFileEntry.Kind {
        var info = stat()
        guard name.withCString({ fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else { return .other }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .link
        default: return .other
        }
    }
}

struct ProjectFilesView: View {
    let model: ProjectFilesModel
    let onEdit: (String) -> Void
    @FocusState private var treeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Project")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 25, height: 23)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Обновить файлы проекта")
                .workbenchHint("Обновить файлы проекта")
            }
            .padding(.horizontal, WorkbenchLayout.panelInset)
            .frame(height: WorkbenchLayout.panelHeaderHeight)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.panel)
        .onAppear(perform: model.loadRoot)
    }

    @ViewBuilder private var content: some View {
        switch model.listings[""] {
        case .loaded(let entries) where !entries.isEmpty:
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.rows) { row in
                            fileRow(row)
                            if case .failed(let reason) = model.listings[row.entry.path] {
                                Text("Папка недоступна")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 27 + CGFloat(row.depth) * 13)
                                    .padding(.vertical, 3)
                                    .help(reason)
                            }
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                }
                .focusable()
                .focused($treeFocused)
                .focusEffectDisabled()
                .onAppear { treeFocused = true }
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: [.down, .repeat]) { key in
                    guard key.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .ignored }
                    if let destination = model.navigate(key.key) {
                        scroll.scrollTo(destination.path)
                    }
                    return .handled
                }
                .onKeyPress(keys: [.return], phases: .down) { key in
                    guard key.modifiers.isEmpty, let entry = model.selectedFile else { return .ignored }
                    open(entry)
                    return .handled
                }
            }
        case .loaded:
            Text("Папка пуста")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            EmptyPanel(icon: "exclamationmark.circle", title: "Папка недоступна", subtitle: reason)
        case .loading, nil:
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityHidden(true)
        }
    }

    private func fileRow(_ row: ProjectFileRow) -> some View {
        let entry = row.entry
        let isFolder = entry.kind == .directory
        let isExpanded = model.expanded.contains(entry.path)
        let selected = model.selectedPath == entry.path
        let url = model.root.appending(path: entry.path)
        return Button {
            treeFocused = true
            model.select(entry)
        } label: {
            HStack(spacing: 5) {
                if isFolder {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 11)
                        .foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: 11, height: 1).accessibilityHidden(true)
                }
                if entry.kind == .file {
                    FileTypeIcon(name: entry.name)
                } else {
                    Image(systemName: entry.kind.icon)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 17)
                        .foregroundStyle(isFolder ? Palette.blue : Palette.muted)
                        .accessibilityHidden(true)
                }
                Text(entry.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .truncationMode(.middle)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 4 + CGFloat(row.depth) * 13)
            .padding(.trailing, 4)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(WorkbenchPlainButton())
        .workbenchRowBackground(selected: selected)
        .overlay {
            if selected && treeFocused {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Palette.focusBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(entry.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(isFolder ? (isExpanded ? "Папка развёрнута" : "Папка свёрнута") : "")
        .help(entry.path)
        .contextMenu {
            if entry.kind == .file {
                Button("Редактировать файл…") { onEdit(entry.path) }
                Button("Открыть во внешнем приложении") { open(entry) }
            }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Скопировать путь") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
        }
    }

    private func open(_ entry: ProjectFileEntry) {
        NSWorkspace.shared.open(model.root.appending(path: entry.path))
    }
}
