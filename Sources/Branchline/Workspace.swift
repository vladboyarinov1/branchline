import AppKit
import Foundation
import Observation

enum WorkspaceMode: String, CaseIterable {
    case changes = "Изменения"
    case history = "История"

    var icon: String {
        switch self {
        case .changes: "doc.badge.ellipsis"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum RepositoryCommand: Equatable {
    case commitTool, commit, commitAndPush, amend, log, terminal, projectFiles, push, update, diff, stage, rollback, vcsActions, findAction, branches, keymap
}

enum CommitMode: String, CaseIterable {
    case selectedFiles, index
}

extension GitPatchContext {
    var isWorkingFile: Bool {
        switch self {
        case .working, .staged, .unstaged: true
        case .commit, .comparison: false
        }
    }
}

struct CommandRequest: Equatable {
    let id = UUID()
    let command: RepositoryCommand
}

struct FileFocus: Hashable, Identifiable {
    struct ID: Hashable {
        let fileID: String
        let context: GitPatchContext
    }

    let file: GitFile
    let context: GitPatchContext
    var id: ID { ID(fileID: file.id, context: context) }
}

struct GitNotice: Identifiable {
    var id: String { title + message }
    let title: String
    let message: String
}

@MainActor @Observable
final class Workspace {
    private struct HistoryQuery: Equatable {
        let ref: String?
        let search: String
        let author: String
        let path: String?
    }

    private struct HistoryTracking {
        let head: String
        let upstream: String
        let directions: [String: GitSyncDirection]
    }

    @ObservationIgnored private var historyTracking: HistoryTracking?

    private struct DetailRequest: Equatable {
        let hash: String
        let preferred: FileFocus.ID?
        let updatePreview: Bool
        let fileRevision: UInt
    }

    private struct CommitSelectionAnchor: Equatable {
        let head: String
        let branch: String

        init(_ snapshot: GitStatus) {
            head = snapshot.head ?? ""
            branch = snapshot.branch ?? ""
        }
    }

    var mode: WorkspaceMode = .changes
    var historyToolVisible = true
    var commitToolVisible = true {
        didSet {
            if let git { UserDefaults.standard.set(commitToolVisible, forKey: "commitTool:" + git.root.path) }
        }
    }
    private(set) var favoriteRefs = Set<String>()
    var commandRequest: CommandRequest?
    var terminalDock: TerminalDock?
    var npmScript: String?
    private(set) var npmScripts: [String] = []
    private(set) var npmManifestRevision: UInt = 0
    var projectFiles: ProjectFilesModel?
    private(set) var commitMode: CommitMode = .selectedFiles
    private(set) var includedPaths = Set<String>()
    private(set) var operation: GitOperation?
    private(set) var historyPath: String?
    var historyAuthor = "" {
        didSet { if historyAuthor != oldValue { queueHistory(debounce: true) } }
    }

    private(set) var git: Git?
    private(set) var status: GitStatus?
    private(set) var refs: [GitRef] = []
    private(set) var entries: [HistoryEntry] = []
    private(set) var selectedRef: GitRef?
    private(set) var scope = "HEAD"
    private(set) var detail: GitCommitDetail?
    private(set) var comparedRef: GitRef?
    private(set) var comparedFiles: [GitFile] = []
    private(set) var focus: FileFocus?
    private(set) var diffSource: DiffSource?
    var patch: String? { diffSource?.patch }
    private(set) var patchError: String?
    private(set) var detailError: String?
    private(set) var notice: GitNotice?
    private(set) var feedback: String?
    private(set) var activity: String?
    enum NetworkOperation: String {
        case fetch = "Fetch"
        case push = "Push"
    }

    private(set) var networkOperation: NetworkOperation?
    private(set) var isCancellingNetworkOperation = false
    private(set) var isUpdatingIndex = false
    private(set) var hasWorkingStatus = false
    private(set) var isHistoryLoading = false
    private(set) var isHistoryReplacing = false
    private(set) var historyError: String?
    private(set) var historyPageError: String?
    private(set) var isDetailLoading = false
    private(set) var hasMore = false
    var branchFilter = ""
    var commitMessage = "" {
        didSet {
            guard let draftKey, commitMessage != oldValue else { return }
            if commitMessage.isEmpty { UserDefaults.standard.removeObject(forKey: draftKey) }
            else { UserDefaults.standard.set(commitMessage, forKey: draftKey) }
        }
    }
    var amend = false
    var search = "" {
        didSet {
            if search != oldValue { queueHistory(debounce: true) }
        }
    }
    private(set) var selection: String?

    @ObservationIgnored private var watcher: RepositoryWatcher?
    @ObservationIgnored private var gitDirectory: URL?
    @ObservationIgnored private var commonGitDirectory: URL?
    @ObservationIgnored private var draftKey: String?
    @ObservationIgnored private var networkTask: Task<Void, Error>?
    @ObservationIgnored private var restoreHistoryCount = 0
    @ObservationIgnored private var historyOffset = 0
    @ObservationIgnored private var loadedHistoryQuery: HistoryQuery?
    @ObservationIgnored private var commitSelectionAnchor: CommitSelectionAnchor?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var detailRequest: DetailRequest?
    @ObservationIgnored private var patchTask: Task<Void, Never>?
    @ObservationIgnored private var patchRequest: UInt = 0
    @ObservationIgnored private var fileSelectionRevision: UInt = 0
    @ObservationIgnored private var watchedRefresh: Task<Void, Never>?
    @ObservationIgnored private var pendingChanges = RepositoryChanges()
    @ObservationIgnored private var pendingManualRefresh = false
    @ObservationIgnored private var readingChanges = RepositoryChanges()
    @ObservationIgnored private var readingManualRefresh = false
    @ObservationIgnored private var isFront = false
    @ObservationIgnored private var commitAndPushPending = false
    private let pageSize = 128

    var branch: String { status?.branch ?? (status == nil ? "HEAD" : "Detached HEAD") }
    var staged: [GitFile] { status?.files.filter { $0.staged != nil } ?? [] }
    var unstaged: [GitFile] { status?.files.filter { $0.unstaged != nil } ?? [] }
    var trackedChanges: [GitFile] { status?.files.filter { !Self.isUnversioned($0) } ?? [] }
    var unversionedFiles: [GitFile] { status?.files.filter(Self.isUnversioned) ?? [] }
    var workingContext: GitPatchContext { .working(unborn: status?.isUnborn == true) }
    var workingFiles: [FileFocus] {
        switch commitMode {
        case .selectedFiles:
            let context = workingContext
            return (trackedChanges + unversionedFiles).map { FileFocus(file: $0, context: context) }
        case .index:
            return staged.map { FileFocus(file: $0, context: .staged) }
                + unstaged.map { FileFocus(file: $0, context: .unstaged) }
        }
    }
    var canCommit: Bool { activity == nil && canCommitWhenIdle }
    var canCommitWhenIdle: Bool {
        guard hasWorkingStatus, operation == nil, let status,
              !amend || canAmend,
              !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !status.files.contains(where: { $0.unstaged == .conflicted }) else { return false }
        if canAmend { return true }
        switch commitMode {
        case .selectedFiles: return status.files.contains(where: isIncluded)
        case .index: return status.files.contains { $0.staged != nil }
        }
    }
    var canEnableAmend: Bool {
        guard let status, !status.isUnborn, status.branch != nil, operation == nil else { return false }
        return status.upstream == nil || status.ahead > 0
    }
    var canAmend: Bool { amend && canEnableAmend }
    var historyTitle: String { scope == "HEAD" ? branch : (selectedRef?.name ?? "Все ветки") }
    var patchLabels: (String, String) {
        switch focus?.context {
        case .working(let unborn):
            let isNew = unborn || focus?.file.staged == .added || (focus.map { Self.isUnversioned($0.file) } ?? false)
            return (isNew ? "Новый файл" : "HEAD", "Рабочая копия")
        case .staged: return ("HEAD", "В индексе")
        case .unstaged: return (focus?.file.unstaged == .untracked ? "Новый файл" : "В индексе", "Рабочая копия")
        case .commit(let hash):
            let parent = detail?.commit.hash == hash ? detail?.commit.parents.first : nil
            return (parent.map { String($0.prefix(8)) } ?? "До коммита", String(hash.prefix(8)))
        case .comparison: return (branch, comparedRef?.name ?? "Ветка")
        case nil: return ("До", "После")
        }
    }

    func attach(_ repository: Git) async throws {
        async let common = try? repository.commonDirectory()
        async let privateDir = try? repository.gitDirectory()
        commonGitDirectory = await common
        gitDirectory = await privateDir
        try Task.checkCancellation()
        git = repository
        // Start watching before taking the initial snapshot to cover changes during startup.
        startWatching(repository)
        status = try await repository.status()
        hasWorkingStatus = true
        if let status { loadCommitSelection(from: status, root: repository.root) }
        updateOperation()
        let key = "commitDraft:" + repository.root.path
        draftKey = key
        let saved = UserDefaults.standard.object(forKey: "commitTool:" + repository.root.path) as? Bool
        commitToolVisible = saved ?? true
        favoriteRefs = Set(UserDefaults.standard.stringArray(forKey: "favoriteRefs:" + repository.root.path) ?? [])
        commitMessage = UserDefaults.standard.string(forKey: key) ?? ""
    }

    func setFront(_ value: Bool, keepSnapshot: Bool = false) {
        guard isFront != value else { return }
        isFront = value
        if value {
            guard let git else { return }
            let initialSnapshot = watcher?.isRunning == true && pendingChanges.isEmpty ? status : nil
            if watcher?.isRunning != true { startWatching(git) }
            // Read the remembered file while status checks the rest of the working tree.
            let restoringPreview = initialSnapshot == nil && activity == nil && focusIsWorkingFile && patch == nil
                ? focus : nil
            if let restoringPreview { selectPatch(restoringPreview.file, restoringPreview.context) }
            if mode == .history && comparedRef == nil && entries.isEmpty { isHistoryLoading = true }
            refresh(.everything, snapshot: initialSnapshot, restoringPreview: restoringPreview)
            if mode == .history && comparedRef == nil && !focusIsWorkingFile { queueDetails(preferred: focus) }
            if let focus, comparedRef != nil { loadPreview(focus, force: true) }
            projectFiles?.refresh()
        } else {
            watcher = nil
            watchedRefresh?.cancel()
            updateTask?.cancel()
            updateTask = nil
            readingChanges = RepositoryChanges()
            readingManualRefresh = false
            pendingChanges = RepositoryChanges()
            pendingManualRefresh = false
            historyTask?.cancel()
            historyTask = nil
            cancelDetailRead()
            cancelPatchRead()
            isHistoryLoading = false
            isHistoryReplacing = false
            projectFiles?.pauseLoads()
            if !keepSnapshot { discardInactiveSnapshot() }
        }
    }

    var needsPreviewPreparation: Bool {
        guard !isFront, activity == nil else { return false }
        if let project = activeProjectFiles, let path = project.previewPath {
            return !project.previewCache.contains(path)
        }
        guard diffSource == nil, patchError == nil else { return false }
        return focus != nil || mode == .changes && (!hasWorkingStatus || initialWorkingFile != nil)
    }

    var activeProjectFiles: ProjectFilesModel? {
        guard comparedRef == nil, mode == .changes || mode == .history,
              let projectFiles, projectFiles.visible else { return nil }
        return projectFiles
    }

    func preparePreview() async throws {
        guard needsPreviewPreparation, let git else { return }
        if let project = activeProjectFiles, let path = project.previewPath {
            await project.previewCache.load(model: project, path: path, revision: project.previewRevision)
            try Task.checkCancellation()
            return
        }
        if !hasWorkingStatus && (mode == .changes || focusIsWorkingFile) {
            let snapshot = try await git.status()
            try Task.checkCancellation()
            status = snapshot
            hasWorkingStatus = true
        }
        let target: FileFocus?
        if let focus, focus.context.isWorkingFile {
            target = workingFile(matching: focus.file).map { FileFocus(file: $0, context: workingContext(for: $0, previous: focus.context)) }
                ?? initialWorkingFile.map { FileFocus(file: $0, context: workingContext(for: $0)) }
        } else if let focus {
            target = focus
        } else {
            target = mode == .changes ? initialWorkingFile.map { FileFocus(file: $0, context: workingContext(for: $0)) } : nil
        }
        guard let target else {
            focus = nil
            return
        }
        do {
            let source = try await readDiff(target, in: git)
            try Task.checkCancellation()
            focus = target
            diffSource = source
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            focus = target
            patchError = error.localizedDescription
        }
    }

    func discardInactiveSnapshot() {
        guard !isFront else { return }
        hasWorkingStatus = false
        if !entries.isEmpty { restoreHistoryCount = entries.count }
        entries = []
        historyTracking = nil
        refs = []
        status?.files = []
        detail = nil
        diffSource = nil
        patchError = nil
        projectFiles?.suspend()
    }

    private func startWatching(_ repository: Git) {
        watcher = RepositoryWatcher(root: repository.root, gitDirectory: gitDirectory, commonDirectory: commonGitDirectory) {
            [weak self] changes in self?.repositoryDidChange(changes)
        }
    }

    func selectInitialChange() {
        guard let file = initialWorkingFile else {
            clearPreview()
            return
        }
        selectPatch(file, workingContext(for: file))
    }

    private var initialWorkingFile: GitFile? {
        let files = status?.files ?? []
        return files.first(where: { $0.unstaged != nil }) ?? files.first
    }

    private func workingFile(matching previous: GitFile) -> GitFile? {
        let files = status?.files ?? []
        return files.first(where: { $0.path == previous.path })
            ?? files.first(where: { $0.originalPath == previous.path || $0.path == previous.originalPath })
    }

    func activate(_ value: WorkspaceMode) {
        guard mode != value || comparedRef != nil else { return }
        let showWorkingFile = focusIsWorkingFile
        cancelModeReads(keepPreview: showWorkingFile)
        mode = value
        comparedRef = nil
        comparedFiles = []
        switch value {
        case .changes:
            if !showWorkingFile { selectInitialChange() }
        case .history:
            historyToolVisible = true
            queueHistory()
        }
    }

    private var focusIsWorkingFile: Bool {
        focus?.context.isWorkingFile == true
    }

    private func cancelModeReads(keepPreview: Bool = false) {
        historyTask?.cancel()
        historyTask = nil
        cancelDetailRead()
        isHistoryLoading = false
        isHistoryReplacing = false
        historyError = nil
        historyPageError = nil
        detail = nil
        detailError = nil
        if !keepPreview { clearPreview() }
    }

    func send(_ command: RepositoryCommand) {
        commandRequest = CommandRequest(command: command)
    }

    func toggleFavorite(_ ref: GitRef) {
        guard let git else { return }
        if !favoriteRefs.insert(ref.id).inserted { favoriteRefs.remove(ref.id) }
        UserDefaults.standard.set(favoriteRefs.sorted(), forKey: "favoriteRefs:" + git.root.path)
    }

    func showFileHistory(_ file: GitFile) {
        browse(nil, path: file.path)
    }

    func clearFileHistory() {
        browse(selectedRef, all: scope.isEmpty)
    }

    func browse(_ ref: GitRef?, all: Bool = false, path: String? = nil) {
        terminalDock?.hide()
        historyToolVisible = true
        let nextScope = ref?.fullName ?? (all ? "" : "HEAD")
        let staysInLog = mode == .history && comparedRef == nil
        if staysInLog {
            guard nextScope != scope || path != historyPath || historyError != nil else { return }
            cancelDetailRead()
            detailError = nil
        } else {
            cancelModeReads(keepPreview: focusIsWorkingFile)
        }
        restoreHistoryCount = 0
        mode = .history
        selectedRef = ref
        scope = nextScope
        historyPath = path
        comparedRef = nil
        comparedFiles = []
        queueHistory(replacing: true)
    }

    func refresh(userInitiated: Bool = false) {
        if !userInitiated && updateTask != nil { return }
        refresh(.everything, userInitiated: userInitiated)
    }

    private func refresh(_ changes: RepositoryChanges, userInitiated: Bool = false, snapshot preloaded: GitStatus? = nil,
                         restoringPreview: FileFocus? = nil) {
        guard isFront, let git else { return }
        pendingChanges.merge(changes)
        pendingManualRefresh = pendingManualRefresh || userInitiated
        guard updateTask == nil, activity == nil else { return }
        watchedRefresh?.cancel()
        watchedRefresh = nil
        let changes = pendingChanges
        let userInitiated = pendingManualRefresh
        pendingChanges = RepositoryChanges()
        pendingManualRefresh = false
        readingChanges = changes
        readingManualRefresh = userInitiated
        updateTask = Task {
            defer {
                if !Task.isCancelled {
                    updateTask = nil
                    readingChanges = RepositoryChanges()
                    readingManualRefresh = false
                    loadWaitingHistory()
                    scheduleWatchedRefresh()
                }
            }
            do {
                try await reloadState(git, changes: changes, userInitiated: userInitiated,
                                      snapshot: preloaded, restoringPreview: restoringPreview)
                if userInitiated { feedback = "Репозиторий обновлён" }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if userInitiated { report("Не удалось обновить репозиторий", error) }
                else { feedback = error.localizedDescription }
            }
        }
    }

    private func reloadState(_ git: Git, changes: RepositoryChanges, userInitiated: Bool,
                             snapshot preloaded: GitStatus? = nil, restoringPreview: FileFocus? = nil) async throws {
        var snapshot: GitStatus
        if let preloaded { snapshot = preloaded }
        else { snapshot = try await git.status() }
        try Task.checkCancellation()
        guard self.git?.root == git.root else { return }
        let sawHead = snapshot.head != status?.head || snapshot.branch != status?.branch
        if !isFront { snapshot.files = [] }
        if status != snapshot { status = snapshot }
        if changes.metadataChanged || sawHead { updateOperation() }
        if amend && !canEnableAmend { amend = false }
        guard isFront else { return }
        hasWorkingStatus = true
        projectFiles?.refreshPreview(affectedBy: changes)
        reconcileCommitSelection(with: snapshot)
        let hasConflicts = operation != nil && snapshot.files.contains(where: { $0.unstaged == .conflicted })
        let switchToChanges = hasConflicts && activity != nil && mode != .changes
        let choosesInitialFile = switchToChanges && !focusIsWorkingFile
        if switchToChanges { activate(.changes) }
        if hasConflicts && !commitToolVisible {
            commitToolVisible = true
        }
        if hasConflicts && activity != nil { projectFiles?.visible = false }
        if !choosesInitialFile && (mode == .changes || focusIsWorkingFile) {
            let focusedPathChanged = focus.map {
                changes.affectsWorkingPatch(for: $0.file.path, originalPath: $0.file.originalPath)
            } ?? false
            reconcileWorkingPreview(refreshPatch: sawHead || (focusedPathChanged && focus != restoringPreview))
        }
        if changes.metadataChanged || sawHead {
            let updatedRefs = try await git.refs()
            try Task.checkCancellation()
            guard isFront, self.git?.root == git.root else { return }
            let sawRefs = refs != updatedRefs
            if sawRefs { refs = updatedRefs }
            if mode == .history && comparedRef == nil &&
                (sawHead || sawRefs || (entries.isEmpty && historyTask == nil) || userInitiated) {
                queueHistory(replacing: isHistoryReplacing)
            }
        }
    }

    private func repositoryDidChange(_ changes: RepositoryChanges) {
        guard watcher != nil else { return }
        if changes.affectsWorkingPatch(for: "package.json", originalPath: nil) {
            npmManifestRevision &+= 1
        }
        pendingChanges.merge(changes)
        scheduleWatchedRefresh()
    }

    func loadNPMScripts() async {
        guard let root = git?.root else { return }
        let names = await Task.detached(priority: .utility) { NPMScripts.names(in: root) }.value
        if !Task.isCancelled, npmScripts != names { npmScripts = names }
    }

    func runNPMScript(_ name: String) {
        guard let root = git?.root, activity == nil, npmScripts.contains(name) else { return }
        if terminalDock == nil { terminalDock = TerminalDock(root: root) }
        terminalDock?.runScript(name)
    }

    func worktreeFileDidChange() {
        projectFiles?.refresh()
        refresh()
    }

    private func scheduleWatchedRefresh() {
        guard isFront, updateTask == nil, activity == nil, !pendingChanges.isEmpty else { return }
        watchedRefresh?.cancel()
        watchedRefresh = Task {
            do {
                try await Task.sleep(for: .milliseconds(550))
                if !Task.isCancelled {
                    watchedRefresh = nil
                    refresh(RepositoryChanges())
                }
            } catch {}
        }
    }

    private func reconcileWorkingPreview(refreshPatch: Bool) {
        guard let previous = focus, previous.context.isWorkingFile else {
            if focus == nil { selectInitialChange() }
            return
        }
        guard let file = workingFile(matching: previous.file) else {
            selectInitialChange()
            return
        }
        let context = workingContext(for: file, previous: previous.context)
        if refreshPatch || previous.file != file || previous.context != context {
            loadPreview(FileFocus(file: file, context: context), force: true)
        }
    }

    private func workingContext(for file: GitFile, previous: GitPatchContext? = nil) -> GitPatchContext {
        if commitMode == .selectedFiles { return workingContext }
        if previous == .staged && file.staged != nil { return .staged }
        return file.unstaged != nil ? .unstaged : .staged
    }

    func loadMore(retrying: Bool) {
        guard hasMore, !isHistoryLoading, !isHistoryReplacing, !entries.isEmpty,
              historyPageError == nil || retrying else { return }
        queueHistory(append: true)
    }

    private func loadWaitingHistory() {
        if isHistoryLoading && historyTask == nil { queueHistory() }
    }

    private func queueHistory(debounce: Bool = false, append: Bool = false, replacing: Bool = false) {
        guard isFront, mode == .history, comparedRef == nil, let git else { return }
        historyTask?.cancel()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = scope.isEmpty ? nil : scope
        let author = historyAuthor
        let filePath = historyPath
        let requested = HistoryQuery(ref: ref, search: query, author: author, path: filePath)
        if append && requested != loadedHistoryQuery { return }
        let replacing = replacing || debounce || isHistoryReplacing || (!entries.isEmpty && requested != loadedHistoryQuery)
        let start = append ? historyOffset : 0
        let take = append || replacing ? pageSize : min(896, max(pageSize, restoreHistoryCount, entries.count))
        restoreHistoryCount = 0
        historyError = nil
        historyPageError = nil
        isHistoryLoading = true
        isHistoryReplacing = replacing
        historyTask = Task {
            defer {
                if !Task.isCancelled {
                    historyTask = nil
                    isHistoryLoading = false
                    isHistoryReplacing = false
                }
            }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(240)) }
                async let result = git.log(ref: ref, skip: start, limit: take + 1, search: query, author: author, path: filePath)
                let directions = await historySyncDirections(in: git, reference: ref)
                let commits = try await result
                try Task.checkCancellation()
                guard isFront, mode == .history, comparedRef == nil, self.git?.root == git.root else { return }
                let refsByCommit = Dictionary(grouping: refs, by: \.hash)
                let page = commits.prefix(take).map { commit in
                    HistoryEntry(id: commit.hash, parents: query.isEmpty && author.isEmpty && filePath == nil ? commit.parents : [],
                                 subject: commit.subject, author: commit.author, date: commit.date,
                                 refs: refsByCommit[commit.hash, default: []].map { ref in
                                     if ref.isCurrent { return "HEAD -> " + ref.name }
                                     if ref.kind == .tag { return "tag: " + ref.name }
                                     return ref.name
                                 }, isMerge: commit.parents.count > 1, syncDirection: directions[commit.hash])
                }
                historyOffset = start + page.count
                hasMore = commits.count > take
                if append {
                    let existing = Set(entries.map(\.id))
                    entries.append(contentsOf: page.filter { !existing.contains($0.id) })
                } else {
                    let scopeChanged = loadedHistoryQuery?.ref != requested.ref
                        || loadedHistoryQuery?.path != requested.path
                    loadedHistoryQuery = requested
                    if entries != page { entries = page }
                    let next = !scopeChanged && page.contains(where: { $0.id == selection })
                        ? selection : page.first?.id
                    if selection != next || detail?.commit.hash != next || next == nil {
                        selection = next
                        queueDetails(updatePreview: !focusIsWorkingFile)
                    }
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if append {
                    historyPageError = error.localizedDescription
                } else if replacing || entries.isEmpty {
                    entries = []
                    selection = nil
                    hasMore = false
                    queueDetails(updatePreview: !focusIsWorkingFile)
                    historyError = error.localizedDescription
                } else {
                    feedback = error.localizedDescription
                }
            }
        }
    }

    private func historySyncDirections(in git: Git, reference: String?) async -> [String: GitSyncDirection] {
        let branch = refs.first(where: { $0.kind == .local && $0.fullName == reference })
            ?? refs.first(where: \.isCurrent)
        guard let branch, branch.tracking.ahead > 0 || branch.tracking.behind > 0,
              let upstreamRef = branch.upstream,
              let upstream = refs.first(where: { $0.fullName == upstreamRef })?.hash else {
            historyTracking = nil
            return [:]
        }
        let head = branch.hash
        if let cached = historyTracking, cached.head == head, cached.upstream == upstream {
            return cached.directions
        }
        guard let directions = try? await git.syncDirections(head: head, upstream: upstream),
              !Task.isCancelled else { return [:] }
        historyTracking = HistoryTracking(head: head, upstream: upstream, directions: directions)
        return directions
    }

    func selectCommit(_ hash: String?, revealDiff: Bool = false) {
        guard !isHistoryReplacing, hash != selection || revealDiff else { return }
        projectFiles?.closePreview()
        selection = hash
        queueDetails()
    }

    private func queueDetails(preferred: FileFocus? = nil, updatePreview: Bool = true) {
        guard isFront, mode == .history, comparedRef == nil else { return }
        guard let selection else {
            cancelDetailRead()
            detail = nil
            detailError = nil
            if updatePreview { clearPreview() }
            return
        }
        let preferred = preferred ?? focus
        if let detail, detail.commit.hash == selection {
            cancelDetailRead()
            detailError = nil
            if updatePreview { previewDetail(detail, preferred: preferred) }
            return
        }
        loadDetail(hash: selection, preferred: preferred, updatePreview: updatePreview)
    }

    private func cancelDetailRead() {
        detailTask?.cancel()
        detailTask = nil
        detailRequest = nil
        isDetailLoading = false
    }

    private func loadDetail(hash: String, preferred: FileFocus?, updatePreview: Bool) {
        guard isFront, let git else { return }
        let request = DetailRequest(hash: hash, preferred: preferred?.id,
                                    updatePreview: updatePreview, fileRevision: fileSelectionRevision)
        guard !isDetailLoading || request != detailRequest else { return }
        detailTask?.cancel()
        detailRequest = request
        isDetailLoading = true
        detailError = nil
        detailTask = Task {
            defer {
                if !Task.isCancelled, detailRequest == request {
                    detailTask = nil
                    detailRequest = nil
                    isDetailLoading = false
                }
            }
            do {
                let result = try await git.details(hash)
                try Task.checkCancellation()
                guard isCurrentDetail(request, at: git.root) else { return }
                detail = result
                if updatePreview && request.fileRevision == fileSelectionRevision {
                    previewDetail(result, preferred: preferred)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, isCurrentDetail(request, at: git.root) else { return }
                detail = nil
                detailError = error.localizedDescription
                if updatePreview && request.fileRevision == fileSelectionRevision { clearPreview() }
            }
        }
    }

    private func isCurrentDetail(_ request: DetailRequest, at root: URL) -> Bool {
        isFront && mode == .history && comparedRef == nil && selection == request.hash &&
            git?.root == root && detailRequest == request
    }

    private func previewDetail(_ detail: GitCommitDetail, preferred: FileFocus?) {
        let context = GitPatchContext.commit(detail.commit.hash)
        let chosen = preferred?.context == context
            ? detail.files.first(where: { $0.id == preferred?.file.id }) : nil
        if let file = chosen ?? detail.files.first {
            loadPreview(FileFocus(file: file, context: context), force: false)
        } else {
            clearPreview()
        }
    }

    func preview(_ file: GitFile, _ context: GitPatchContext) {
        projectFiles?.closePreview()
        selectPatch(file, context)
    }

    private func selectPatch(_ file: GitFile, _ context: GitPatchContext) {
        fileSelectionRevision &+= 1
        loadPreview(FileFocus(file: file, context: context), force: false)
    }

    func previewWorkingFile(at path: String) -> Bool {
        guard let file = status?.files.first(where: { $0.path == path }) else { return false }
        preview(file, workingContext(for: file))
        return true
    }

    private func loadPreview(_ target: FileFocus, force: Bool) {
        guard isFront, let git else { return }
        guard force || focus != target || (patch == nil && patchTask == nil) else { return }
        cancelPatchRead()
        let request = patchRequest
        if focus?.id != target.id { diffSource = nil }
        if focus != target { focus = target }
        if patchError != nil { patchError = nil }
        patchTask = Task {
            defer { if request == patchRequest { patchTask = nil } }
            do {
                let result = try await readDiff(target, in: git)
                try Task.checkCancellation()
                guard isCurrentPreview(target.id, request: request, at: git.root) else { return }
                if patch != result.patch { diffSource = result }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, isCurrentPreview(target.id, request: request, at: git.root) else { return }
                diffSource = nil
                patchError = error.localizedDescription
            }
        }
    }

    private func readDiff(_ target: FileFocus, in git: Git) async throws -> DiffSource {
        let patch = try await git.patch(target.file, context: target.context)
        try Task.checkCancellation()
        if let diffSource, diffSource.patch == patch { return diffSource }
        return await DiffSource.parse(patch)
    }

    private func isCurrentPreview(_ id: FileFocus.ID, request: UInt, at root: URL) -> Bool {
        isFront && patchRequest == request && git?.root == root && focus?.id == id
    }

    private func cancelPatchRead() {
        patchRequest &+= 1
        patchTask?.cancel()
        patchTask = nil
    }

    private func clearPreview() {
        cancelPatchRead()
        focus = nil
        diffSource = nil
        patchError = nil
    }

    func setCommitMode(_ value: CommitMode) {
        guard activity == nil, commitMode != value else { return }
        commitMode = value
        if let git {
            UserDefaults.standard.set(value.rawValue, forKey: "commitMode:" + git.root.path)
        }
        if hasWorkingStatus && focusIsWorkingFile {
            fileSelectionRevision &+= 1
            reconcileWorkingPreview(refreshPatch: true)
        }
    }

    func isIncluded(_ file: GitFile) -> Bool {
        file.unstaged != .conflicted && includedPaths.contains(file.path)
    }

    func setIncluded(_ files: [GitFile], included: Bool) {
        guard activity == nil, commitMode == .selectedFiles, hasWorkingStatus, let status else { return }
        let paths = Set(files.map(\.path))
        var updated = includedPaths
        if included {
            updated.formUnion(status.files.lazy.filter {
                $0.unstaged != .conflicted && paths.contains($0.path)
            }.map(\.path))
        } else {
            updated.subtract(paths)
        }
        if updated != includedPaths {
            includedPaths = updated
            saveCommitSelection()
        }
    }

    private static func isUnversioned(_ file: GitFile) -> Bool {
        file.staged == nil && file.unstaged == .untracked
    }

    private func loadCommitSelection(from snapshot: GitStatus, root: URL) {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "commitMode:" + root.path), let mode = CommitMode(rawValue: saved) {
            commitMode = mode
        } else { commitMode = .selectedFiles }

        let anchor = CommitSelectionAnchor(snapshot)
        commitSelectionAnchor = anchor
        if let saved = defaults.dictionary(forKey: "commitSelection:" + root.path) {
            if saved["head"] as? String == anchor.head && saved["branch"] as? String == anchor.branch {
                includedPaths = Set(saved["paths"] as? [String] ?? [])
                reconcileCommitSelection(with: snapshot)
            } else { includedPaths = [] }
        } else {
            // Expanding a partially staged path to its whole working copy would
            // include edits the user previously excluded from the index.
            includedPaths = Set(snapshot.files.lazy.filter { $0.staged != nil && $0.unstaged == nil }.map(\.path))
            saveCommitSelection()
        }
    }

    private func reconcileCommitSelection(with snapshot: GitStatus) {
        let anchor = CommitSelectionAnchor(snapshot)
        if commitSelectionAnchor != anchor {
            commitSelectionAnchor = anchor
            if !includedPaths.isEmpty { includedPaths = [] }
            saveCommitSelection()
        } else if !includedPaths.isEmpty {
            let remaining = Set(snapshot.files.lazy.filter(isIncluded).map(\.path))
            if includedPaths != remaining {
                includedPaths = remaining
                saveCommitSelection()
            }
        }
    }

    private func saveCommitSelection() {
        guard let git, let anchor = commitSelectionAnchor else { return }
        UserDefaults.standard.set(["head": anchor.head, "branch": anchor.branch, "paths": includedPaths.sorted()],
                                  forKey: "commitSelection:" + git.root.path)
    }

    func stage(_ files: [GitFile], undo: Bool = false) {
        guard !files.isEmpty else { return }
        var changedPaths = RepositoryChanges()
        for file in files {
            changedPaths.include(file.path)
            if let original = file.originalPath { changedPaths.include(original) }
        }
        perform(undo ? "Убираем из индекса" : "Обновляем индекс", success: nil,
                changes: changedPaths, updatingIndex: true) { git in
            if undo { try await git.unstage(files) }
            else { try await git.stage(files) }
        }
    }

    func checkout(_ ref: GitRef) {
        perform("Переключаем ветку", success: "Переключено на «\(ref.name)»") { git in
            try await git.checkout(ref)
            self.browse(nil)
        }
    }

    func createBranch(_ name: String, checkout: Bool, from start: GitRef? = nil) {
        perform("Создаём ветку", success: "Ветка «\(name)» создана") { git in
            try await git.createBranch(name, checkout: checkout, from: start)
            if checkout { self.browse(nil) }
        }
    }

    func renameBranch(_ ref: GitRef, to name: String) {
        perform("Переименовываем ветку", success: "Ветка переименована в «\(name)»") { git in
            try await git.renameBranch(ref, to: name)
            if self.selectedRef == ref { self.browse(nil) }
        }
    }

    func deleteBranch(_ ref: GitRef) {
        perform("Удаляем ветку", success: "Ветка «\(ref.name)» удалена") { git in
            try await git.deleteBranch(ref)
            if self.selectedRef == ref { self.browse(nil) }
        }
    }

    func integrate(_ ref: GitRef, using operation: GitOperation, into branch: String) {
        perform(operation.name, success: "\(operation.name) завершён") {
            try await $0.integrateBranch(ref, operation: operation, into: branch)
        }
    }

    func applyCommit(_ hash: String, operation: GitOperation, into branch: String) {
        perform(operation.name, success: "\(operation.name) завершён") {
            try await $0.applyCommit(hash, operation: operation, into: branch)
        }
    }

    func finish(_ operation: GitOperation, abort: Bool) {
        perform(operation.name, success: abort ? "\(operation.name) отменён" : "\(operation.name) завершён") {
            try await $0.finishOperation(operation, abort: abort)
        }
    }

    func rollback(_ file: GitFile) {
        perform("Откатываем изменения", success: "Изменения в «\(file.name)» отменены") {
            try await $0.restoreUnstaged(file)
        }
    }

    private func updateOperation() {
        let updated = gitDirectory.flatMap { GitOperation.detect(in: $0) }
        if operation != updated { operation = updated }
    }

    func compare(_ ref: GitRef) {
        guard let git, activity == nil, comparedRef?.id != ref.id else { return }
        let previousMode = mode
        let previousRef = comparedRef
        let previousScope = scope
        let previousSelection = selection
        let previousFileRevision = fileSelectionRevision
        activity = "Сравниваем ветки"
        Task {
            defer {
                activity = nil
                scheduleWatchedRefresh()
            }
            @MainActor func isCurrent() -> Bool {
                isFront && self.git?.root == git.root && mode == previousMode && scope == previousScope &&
                selection == previousSelection && comparedRef == previousRef && fileSelectionRevision == previousFileRevision
            }
            do {
                let result = try await git.compare(ref)
                guard isCurrent() else { return }
                let context = GitPatchContext.comparison(ref.fullName)
                var initialSource: DiffSource?
                var initialError: String?
                if let file = result.first {
                    do { initialSource = try await readDiff(FileFocus(file: file, context: context), in: git) }
                    catch { initialError = error.localizedDescription }
                }
                guard isCurrent() else { return }
                cancelModeReads()
                mode = .history
                comparedRef = ref
                comparedFiles = result
                focus = result.first.map { FileFocus(file: $0, context: context) }
                diffSource = initialSource
                patchError = initialError
            } catch {
                if isCurrent() { report("Не удалось сравнить ветки", error) }
            }
        }
    }

    func closeComparison() {
        comparedRef = nil
        comparedFiles = []
        historyToolVisible = true
        detailError = nil
        clearPreview()
        if entries.isEmpty { queueHistory() }
        if selection == nil { selection = entries.first?.id }
        queueDetails()
    }

    func updateAmend(_ value: Bool) {
        amend = value
        if value && commitMessage.isEmpty, let git {
            Task {
                if let head = try? await git.details("HEAD"), self.git?.root == git.root,
                   amend, commitMessage.isEmpty {
                    commitMessage = head.message
                }
            }
        }
    }

    func commit(pushAfter: Bool = false) {
        let message = commitMessage
        let amend = self.amend
        guard canCommit, let status else { return }
        let files = commitMode == .selectedFiles ? status.files.filter(isIncluded) : nil
        perform(amend ? "Изменяем последний коммит" : "Создаём коммит", success: "Коммит сохранён") { git in
            if let files {
                try await git.commit(message, amend: amend, files: files)
                self.includedPaths.subtract(files.map(\.path))
                self.saveCommitSelection()
            } else {
                try await git.commit(message, amend: amend)
            }
            self.amend = false
            self.commitAndPushPending = pushAfter
        }
    }

    func consumeCommitAndPush() -> Bool {
        let pending = commitAndPushPending && activity == nil
        if pending { commitAndPushPending = false }
        return pending
    }

    var canUpdateFromUpstream: Bool {
        guard let status else { return false }
        return status.branch != nil && status.upstream != nil && status.behind > 0 && operation == nil
    }

    func fetch() {
        performNetwork(.fetch, label: "Получаем коммиты") { try await $0.fetch() }
    }

    func updateFromUpstream() {
        guard let branch = status?.branch, canUpdateFromUpstream else { return }
        perform("Обновляем ветку", success: "Ветка обновлена", conflictOperation: .merge) {
            try await $0.updateFromUpstream(expectedBranch: branch)
        }
    }
    func push(_ preview: GitPushPreview) {
        performNetwork(.push, label: "Отправляем коммиты") { try await $0.push(preview) }
    }

    func canCancel(_ operation: NetworkOperation) -> Bool {
        networkOperation == operation && !isCancellingNetworkOperation
    }

    func cancelNetworkOperation(_ operation: NetworkOperation) {
        guard canCancel(operation) else { return }
        isCancellingNetworkOperation = true
        networkTask?.cancel()
    }

    private func performNetwork(_ operation: NetworkOperation, label: String,
                                action: @escaping (Git) async throws -> Void) {
        guard let git, activity == nil else { return }
        let task = Task { try await action(git) }
        networkTask = task
        networkOperation = operation
        perform(label, success: "\(operation.rawValue) завершён",
                cancellationFeedback: "\(operation.rawValue) отменён") { _ in
            defer {
                self.networkTask = nil
                self.networkOperation = nil
                self.isCancellingNetworkOperation = false
            }
            try await task.value
        }
    }

    func reset(to hash: String, mode: GitResetMode, branch: String, head: String) {
        guard operation == nil else { return }
        perform("Сбрасываем ветку", success: "Ветка сброшена") { [projectFiles] git in
            if let failed = await projectFiles?.flushEditors() {
                throw GitError.command("Сохраните изменения в «\(failed.path)» и повторите сброс.")
            }
            try await git.reset(to: hash, mode: mode, expectedBranch: branch, expectedHead: head)
        }
    }

    private func perform(_ label: String, success: String?, changes: RepositoryChanges = .everything,
                         updatingIndex: Bool = false, conflictOperation: GitOperation? = nil,
                         cancellationFeedback: String? = nil, action: @escaping (Git) async throws -> Void) {
        guard let git, activity == nil else { return }
        isUpdatingIndex = updatingIndex
        activity = label
        if !updatingIndex { feedback = nil }
        pendingChanges.merge(readingChanges)
        pendingManualRefresh = pendingManualRefresh || readingManualRefresh
        readingChanges = RepositoryChanges()
        readingManualRefresh = false
        updateTask?.cancel()
        updateTask = nil
        watchedRefresh?.cancel()
        watchedRefresh = nil
        Task {
            defer {
                activity = nil
                isUpdatingIndex = false
                loadWaitingHistory()
                scheduleWatchedRefresh()
            }
            do {
                try await action(git)
                if let success { feedback = success }
            } catch is CancellationError where cancellationFeedback != nil {
                feedback = cancellationFeedback
            } catch {
                if let conflictOperation, gitDirectory.flatMap({ GitOperation.detect(in: $0) }) == conflictOperation {
                    updateOperation()
                } else {
                    report(label, error)
                }
            }

            // Publish status and its selected file together using one authoritative post-write read.
            var invalidation = changes
            invalidation.merge(pendingChanges)
            let userInitiated = pendingManualRefresh
            pendingChanges = RepositoryChanges()
            pendingManualRefresh = false
            do {
                try await reloadState(git, changes: invalidation, userInitiated: userInitiated)
                if userInitiated && success == nil { feedback = "Репозиторий обновлён" }
            } catch {
                commitAndPushPending = false
                if userInitiated { report("Не удалось обновить репозиторий", error) }
                else { feedback = error.localizedDescription }
            }
        }
    }

    func clearNotice() { notice = nil }
    func clearFeedback() { feedback = nil }

    func report(_ title: String, _ error: Error) {
        notice = GitNotice(title: title, message: error.localizedDescription)
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        feedback = "Скопировано"
    }
}
