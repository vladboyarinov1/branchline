import AppKit
import SwiftUI

struct RepositoryView<ProjectTabs: View>: View {
    @Bindable var workspace: Workspace
    let openWorktree: (URL) -> Void
    let projectTabs: ProjectTabs
    @State private var sheet: ActionSheet?
    @State private var loadingRemotes = false
    @State private var syncTask: Task<Void, Never>?
    @State private var confirmation: Confirmation?
    @State private var queuedAction: (() -> Void)?
    @State private var branchesVisible = true
    @State private var commitFocusRequest: UInt = 0
    @State private var handledCommitFocus: UInt = 0
    @State private var diffFocusRequest: UInt = 0
    @State private var handledDiffFocus: UInt = 0
    @State private var workingReveal: FileFocus.ID?
    @State private var collapsedGroups: Set<ChangeGroup> = []
    @AppStorage("branchline.terminal.height") private var terminalHeight = 270.0
    @State private var historyHeight: CGFloat = 270
    @State private var dockDragHeight: CGFloat?
    @FocusState private var changesFocused: Bool

    init(workspace: Workspace, openWorktree: @escaping (URL) -> Void,
         @ViewBuilder projectTabs: () -> ProjectTabs) {
        self.workspace = workspace
        self.openWorktree = openWorktree
        self.projectTabs = projectTabs()
    }

    private struct Confirmation {
        let title: String
        let message: String
        let button: String
        var destructive = false
        let run: () -> Void
    }

    private enum ActionSheet: Identifiable {
        case branch(GitRef?), rename(GitRef), stash, push(PushDestination, [String]), actions(Bool), branches, keymap
        case editFile(URL, String)
        var id: Int {
            switch self {
            case .branch: 0
            case .rename: 1
            case .stash: 2
            case .push: 3
            case .actions: 4
            case .branches: 5
            case .keymap: 6
            case .editFile: 7
            }
        }
    }

    private struct PushDestination {
        let branch: String
        let upstream: String?
        let ahead: Int
    }

    private enum ChangeGroup: String {
        case changes = "Changes"
        case unversioned = "Unversioned Files"
        case staged = "Staged"
        case unstaged = "Local Changes"
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceBar
            if let operation = workspace.operation { operationBar(operation) }
            HStack(alignment: .top, spacing: 3) {
                toolStrip
                workArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, WorkbenchLayout.gutter)
            }
            .padding(.vertical, WorkbenchLayout.gutter)
        }
        .background(Palette.workbench)
        .alert(workspace.notice?.title ?? "", isPresented: Binding(
            get: { workspace.notice != nil }, set: { if !$0 { workspace.clearNotice() } }
        )) {
            if let message = workspace.notice?.message {
                Button("Скопировать") { workspace.copy(message) }
            }
            Button("Закрыть", role: .cancel) { workspace.clearNotice() }
        } message: {
            Text(workspace.notice?.message ?? "")
        }
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible) {
            if let confirmation {
                Button(confirmation.button, role: confirmation.destructive ? .destructive : nil, action: confirmation.run)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(confirmation?.message ?? "")
        }
        .sheet(item: $sheet, onDismiss: runQueuedAction) { action in
            switch action {
            case .branch(let start):
                NameSheet(title: "New Branch", prompt: "Имя ветки", submit: "Создать", icon: "arrow.triangle.branch",
                          subtitle: "Ветка начнётся от «\(start?.name ?? workspace.branch)».", showCheckout: true) {
                    workspace.createBranch($0, checkout: $1, from: start)
                }
            case .rename(let ref):
                NameSheet(title: "Rename Branch", prompt: "Новое имя ветки", submit: "Переименовать",
                          icon: "pencil", subtitle: "Локальная ветка «\(ref.name)».", initialValue: ref.name) {
                    name, _ in if name != ref.name { workspace.renameBranch(ref, to: name) }
                }
            case .stash:
                NameSheet(title: "Сохранить в stash", prompt: "Описание", submit: "Сохранить",
                          icon: "archivebox", subtitle: "Включает новые и изменённые файлы.", allowEmpty: true) {
                    name, _ in workspace.stash(name)
                }
            case .push(let destination, let remotes):
                PushSheet(branch: destination.branch, upstream: destination.upstream,
                          ahead: destination.ahead, remotes: remotes) {
                    workspace.push(to: $0, branch: destination.branch, upstream: destination.upstream)
                }
            case .actions(let search):
                GitActionPicker(title: search ? "Find Action" : "VCS Operations",
                                actions: availableActions, select: chooseAction)
            case .branches:
                GitBranchPicker(refs: workspace.refs, actions: branchActions,
                                create: { afterSheet { sheet = .branch(nil) } }, select: chooseAction,
                                canCreate: canCreateBranch)
            case .keymap:
                GitKeymapView().workbenchHints()
            case .editFile(let root, let path):
                WorktreeFileEditor(root: root, path: path, saved: workspace.worktreeFileDidChange)
            }
        }
        .onChange(of: workspace.activity) { _, _ in
            if workspace.consumeCommitAndPush() { preparePush() }
        }
        .onChange(of: workspace.commandRequest) { _, request in
            if let request, sheet == nil, confirmation == nil { handle(request.command) }
        }
        .onAppear {
            if workspace.consumeCommitAndPush() { preparePush() }
        }
        .task(id: workspace.feedback) {
            guard workspace.feedback != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { workspace.clearFeedback() }
        }
        .task(id: workspace.npmManifestRevision) {
            await workspace.loadNPMScripts()
        }
        .onDisappear { syncTask?.cancel() }
    }

    private var toolStrip: some View {
        VStack(spacing: 4) {
            tool("Project", active: projectVisible, shortcut: GitKeymap.projectFiles, action: { handle(.projectFiles) }) {
                Image(systemName: "folder")
            }
            tool("Commit", active: workspace.commitToolVisible && !projectVisible &&
                 (workspace.mode == .changes || workspace.mode == .history && workspace.comparedRef == nil),
                 shortcut: GitKeymap.commitToolWindow, action: { handle(.commitTool) }) {
                GitGlyph.commit.glyph(size: 16)
            }
            tool("Stash", active: workspace.mode == .stash, action: {
                workspace.activate(workspace.mode == .stash ? .changes : .stash)
            }) {
                Image(systemName: "archivebox")
            }
            Spacer(minLength: 0)
            tool("Worktrees", active: workspace.mode == .worktrees, action: {
                workspace.activate(workspace.mode == .worktrees ? .changes : .worktrees)
            }) {
                Image(systemName: "square.on.square")
            }
            tool("Terminal", active: terminalVisible, shortcut: GitKeymap.terminal, action: { handle(.terminal) }) {
                Image(systemName: "terminal")
            }
            tool("Git Log", active: historyVisible,
                 shortcut: GitKeymap.log, action: { handle(.log) }) {
                GitGlyph.branch.glyph(size: 16)
            }
        }
        .padding(.horizontal, 3)
        .frame(width: 38)
    }

    private func tool<Icon: View>(_ title: String, active: Bool, shortcut: KeyboardShortcut? = nil,
                                  action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            icon()
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(WorkbenchIconButton(selected: active))
        .workbenchHint(title, shortcut: shortcut)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var terminalVisible: Bool { workspace.terminalDock?.visible == true }
    private var projectVisible: Bool { workspace.activeProjectFiles != nil }
    private var historyVisible: Bool {
        workspace.mode == .history && workspace.historyToolVisible && workspace.comparedRef == nil && !terminalVisible
    }

    private var workArea: some View {
        GeometryReader { geometry in
            let showsDock = terminalVisible || historyVisible
            let gap = showsDock ? WorkbenchLayout.gutter : 0
            let maxDockHeight = max(0, geometry.size.height - gap - 230)
            let limits = min(190, maxDockHeight)...maxDockHeight
            let preferredHeight = terminalVisible ? CGFloat(terminalHeight) : historyHeight
            let height = showsDock ? min(max(dockDragHeight ?? preferredHeight, limits.lowerBound), limits.upperBound) : 0
            VStack(spacing: 0) {
                content.frame(height: max(0, geometry.size.height - height - gap))
                if showsDock {
                    WorkbenchDockDivider(height: height, limits: limits,
                                         label: terminalVisible ? "Высота терминала" : "Высота Git Log") { proposed, finished in
                        let newHeight = min(max(proposed, limits.lowerBound), limits.upperBound)
                        if finished {
                            if terminalVisible { terminalHeight = Double(newHeight) }
                            else { historyHeight = newHeight }
                            dockDragHeight = nil
                        } else {
                            dockDragHeight = newHeight
                        }
                    }
                    .frame(height: gap)
                    panel {
                        if let dock = workspace.terminalDock, dock.visible { TerminalDockView(dock: dock) }
                        else { logDock }
                    }
                    .frame(height: height)
                }
            }
        }
        .onChange(of: terminalVisible) { _, _ in dockDragHeight = nil }
        .onChange(of: historyVisible) { _, _ in dockDragHeight = nil }
    }

    private var branchPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                StudioSearch(placeholder: "Ветка или тег", text: $workspace.branchFilter)
                Button { sheet = .branch(nil) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                        .frame(width: 25, height: 27)
                        .contentShape(Rectangle())
                }
                .buttonStyle(WorkbenchIconButton())
                .disabled(!canCreateBranch)
                .accessibilityLabel("Создать ветку")
                .workbenchHint("Создать ветку")
            }
            .padding(.leading, 7)
            .padding(.trailing, 3)
            .padding(.vertical, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if workspace.branchFilter.isEmpty {
                        HStack(spacing: 3) {
                            rootBranch("All Branches", label: "All", all: true)
                            rootBranch("HEAD", label: "HEAD", all: false)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let visible = workspace.refs.filter {
                        workspace.branchFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(workspace.branchFilter)
                    }
                    branchGroup("Favorites", refs: visible.filter { workspace.favoriteRefs.contains($0.id) }, grouped: false)
                    branchGroup("Local", refs: visible.filter { $0.kind == .local })
                    branchGroup("Remote", refs: visible.filter { $0.kind == .remote })
                    branchGroup("Tags", refs: visible.filter { $0.kind == .tag })
                    if !workspace.branchFilter.isEmpty && visible.isEmpty {
                        Text("Совпадений нет").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .padding(.horizontal, 9).padding(.vertical, 7)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.rail)
    }

    private func rootBranch(_ title: String, label: String, all: Bool) -> some View {
        let selected = workspace.mode == .history && workspace.comparedRef == nil &&
            workspace.scope == (all ? "" : "HEAD")
        return Button { workspace.browse(nil, all: all) } label: {
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Palette.text : Palette.muted)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func branchGroup(_ title: String, refs: [GitRef], grouped: Bool = true) -> some View {
        if !refs.isEmpty {
            RefGroup(title: title, expanded: title != "Tags" || !workspace.branchFilter.isEmpty) {
                if grouped && workspace.branchFilter.isEmpty && title != "Tags" {
                    let parents = Dictionary(grouping: refs) { ref in
                        ref.name.firstIndex(of: "/").map { String(ref.name[..<$0]) } ?? ""
                    }
                    ForEach(parents["", default: []]) { ref in branchRow(ref) }
                    ForEach(parents.keys.filter { !$0.isEmpty }.sorted(), id: \.self) { prefix in
                        let children = parents[prefix, default: []]
                        RefGroup(title: prefix, expanded: title == "Remote" ||
                                 children.contains(where: { $0.isCurrent || workspace.favoriteRefs.contains($0.id) }),
                                 indent: 13, folder: true) {
                            ForEach(children) { ref in
                                branchRow(ref, label: String(ref.name.dropFirst(prefix.count + 1)), indent: 30)
                            }
                        }
                    }
                } else {
                    ForEach(refs) { ref in branchRow(ref) }
                }
            }
            .id(title + (workspace.branchFilter.isEmpty ? "" : "-filtered"))
        }
    }

    private func branchRow(_ ref: GitRef, label: String? = nil, indent: CGFloat = 17) -> some View {
        let selected = workspace.mode == .history && (workspace.comparedRef?.id == ref.id ||
            workspace.comparedRef == nil && workspace.scope == ref.fullName)
        return Button { workspace.browse(ref) } label: {
            HStack(spacing: 7) {
                Group {
                    if ref.kind == .tag { Image(systemName: "tag").font(.system(size: 11)) }
                    else { GitGlyph.branch.glyph(size: 12) }
                }
                .frame(width: 14)
                .foregroundStyle(ref.isCurrent ? Palette.accent : Palette.muted)
                .accessibilityHidden(true)
                Text(label ?? ref.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 3)
                if !ref.tracking.isEmpty { BranchSyncBadge(tracking: ref.tracking) }
                if workspace.favoriteRefs.contains(ref.id) {
                    Image(systemName: "star.fill").foregroundStyle(Palette.yellow).font(.system(size: 8))
                        .accessibilityLabel("Избранная ветка")
                }
                if ref.isCurrent {
                    Circle().fill(Palette.accent).frame(width: 5, height: 5)
                        .accessibilityLabel("Текущая ветка")
                }
            }
            .font(.system(size: 12, weight: ref.isCurrent ? .semibold : .regular))
            .padding(.leading, indent).padding(.trailing, 8)
            .frame(height: 26)
            .background(selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ref.name)
        .accessibilityValue(ref.tracking.accessibilitySummary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            ForEach(branchActions(ref)) { action in
                Button { action.run() } label: { Label(action.title, systemImage: action.icon) }
                    .disabled(!action.enabled)
            }
        }
    }

    private var workspaceBar: some View {
        let ahead = workspace.status?.ahead ?? 0
        let behind = workspace.status?.behind ?? 0
        let tracking = GitTracking(ahead: ahead, behind: behind)
        let progress = workspace.isUpdatingIndex ? nil : (workspace.activity ?? (loadingRemotes ? "Читаем список remote" : nil))
        return HStack(spacing: 7) {
            projectTabs
                .padding(.leading, 78)
                .layoutPriority(1)
            WindowDragSpace()
                .frame(minWidth: 12, maxWidth: .infinity)
                .accessibilityHidden(true)
                .overlay(alignment: .trailing) {
                    DeferredVisibility(isPending: progress != nil) { showProgress in
                        if let message = showProgress ? progress : (progress == nil ? workspace.feedback : nil) {
                            HStack(spacing: 5) {
                                if showProgress { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                                Text(message).lineLimit(1)
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: 170, alignment: .trailing)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .clipped()
            NPMRunControl(workspace: workspace)
            Button { sheet = .branches } label: {
                HStack(spacing: 5) {
                    GitGlyph.branch.glyph(size: 14).foregroundStyle(Palette.accent)
                    Text(workspace.branch.count > 22
                         ? String(workspace.branch.prefix(10)) + "…" + String(workspace.branch.suffix(11))
                         : workspace.branch)
                    if !tracking.isEmpty { BranchSyncBadge(tracking: tracking) }
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(StudioButton(kind: .quiet))
            .workbenchHint(workspace.status?.upstream.map { "Git Branches · \($0)" } ?? "Git Branches")
            .accessibilityLabel("Git Branches, \(workspace.branch)")
            .accessibilityValue(tracking.accessibilitySummary)
            Button { workspace.fetch() } label: {
                Label("Fetch", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(StudioButton(kind: .quiet))
            .disabled(workspace.activity != nil)
            .workbenchHint("Fetch · Получить сведения с сервера")
            Button { workspace.updateFromUpstream() } label: {
                Image(systemName: "arrow.down.to.line").frame(width: 14)
            }
            .buttonStyle(StudioButton(kind: .quiet, keepsEnabledAppearance: workspace.isUpdatingIndex && canUpdateWhenIdle))
            .accessibilityLabel("Update Project")
            .accessibilityValue(behind > 0 ? "Входящих коммитов: \(behind)" : "")
            .disabled(!canUpdate)
            .workbenchHint(behind > 0 ? "Update Project · Применить входящие коммиты: \(behind)"
                           : "Update Project · Нет полученных коммитов для обновления",
                           shortcut: GitKeymap.update)
            Button(action: preparePush) {
                Text("Push")
            }
            .buttonStyle(StudioButton(keepsEnabledAppearance: workspace.isUpdatingIndex && canPushWhenIdle))
            .accessibilityLabel("Push")
            .accessibilityValue(ahead > 0 ? "Коммитов к отправке: \(ahead)" : "")
            .disabled(!canPush)
            .workbenchHint(ahead > 0 ? "Push · Коммитов к отправке: \(ahead)" : "Push", shortcut: GitKeymap.push)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.trailing, 9)
        .frame(height: WorkbenchLayout.titleHeight)
        .background(Palette.header)
    }

    private func operationBar(_ operation: GitOperation) -> some View {
        let conflicts = workspace.unstaged.contains(where: { $0.unstaged == .conflicted })
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.yellow)
            Text(conflicts ? "Разрешите конфликты и добавьте файлы в индекс" : "\(operation.name) в процессе")
                .font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Spacer()
            if workspace.commitMode == .selectedFiles {
                Button("Git-индекс") {
                    handle(.commit)
                    workspace.setCommitMode(.index)
                }
                .buttonStyle(StudioButton())
                .disabled(workspace.activity != nil)
            }
            Button("Continue") { workspace.finish(operation, abort: false) }
                .buttonStyle(StudioButton())
                .disabled(workspace.activity != nil || conflicts)
            Button("Abort…") {
                confirmation = Confirmation(title: "Отменить \(operation.name)?",
                    message: "Git попытается вернуть рабочую копию в состояние до операции. Исправления конфликтов будут потеряны.",
                    button: "Отменить операцию", destructive: true) {
                    workspace.finish(operation, abort: true)
                }
            }
            .buttonStyle(StudioButton())
            .disabled(workspace.activity != nil)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Palette.header)
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(Palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: WorkbenchLayout.radius))
    }

    @ViewBuilder private var content: some View {
        let inset = WorkbenchLayout.gutter / 2
        let showsChangeSidebar = projectVisible || workspace.commitToolVisible
        let showsEditorInset = workspace.comparedRef != nil || workspace.mode == .stash || showsChangeSidebar
        if workspace.mode == .worktrees {
            panel { worktreesPane }
        } else {
            HSplitView {
                if workspace.comparedRef != nil {
                    panel { branchPane }
                        .frame(minWidth: 162, idealWidth: 184, maxWidth: 235)
                        .padding(.trailing, inset)
                        .measureWorkbenchPane()
                } else if workspace.mode == .stash {
                    panel { stashPane }
                        .frame(minWidth: 235, idealWidth: 282, maxWidth: 370)
                        .padding(.trailing, inset)
                        .measureWorkbenchPane()
                } else if showsChangeSidebar {
                    panel {
                        if let project = workspace.projectFiles, projectVisible {
                            ProjectFilesView(model: project, onEdit: editFile)
                        } else { changesPane }
                    }
                        .frame(minWidth: 244, idealWidth: 276, maxWidth: 310)
                        .padding(.trailing, inset)
                        .measureWorkbenchPane()
                }
                panel { patchPane }
                    .frame(minWidth: 360, maxWidth: .infinity)
                    .padding(.leading, showsEditorInset ? inset : 0)
                    .padding(.trailing, workspace.comparedRef != nil ? inset : 0)
                    .measureWorkbenchPane()
                if let comparedRef = workspace.comparedRef {
                    panel { comparisonPane(comparedRef) }
                        .frame(minWidth: 222, idealWidth: 264, maxWidth: 334)
                        .padding(.leading, inset)
                        .measureWorkbenchPane()
                }
            }
            .paintWorkbenchGutter()
        }
    }

    private var logDock: some View {
        HSplitView {
            if branchesVisible { branchPane.frame(minWidth: 154, idealWidth: 182, maxWidth: 225) }
            HistoryView(entries: workspace.entries, title: workspace.historyTitle,
                        search: $workspace.search, selection: Binding(
                            get: { workspace.selection }, set: { workspace.selectCommit($0) }
                        ),
                        hasMore: workspace.hasMore, isLoading: workspace.isHistoryLoading,
                        loadMore: workspace.loadMore, authorFilter: $workspace.historyAuthor,
                        showDiff: showHistoryDiff, commitActions: logActions,
                        branchesVisible: branchesVisible, toggleBranches: { branchesVisible.toggle() },
                        clearFileFilter: workspace.clearFileHistory, fileFilter: workspace.historyPath,
                        isReplacing: workspace.isHistoryReplacing, loadError: workspace.historyError,
                        pageError: workspace.historyPageError,
                        scopeID: workspace.scope, retryLoad: { workspace.refresh(userInitiated: true) })
                .frame(minWidth: 300, maxWidth: .infinity)
            inspector.frame(minWidth: 210, idealWidth: 242, maxWidth: 305)
        }
        .background(Palette.panel)
    }

    private var changesPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(workspace.commitMode == .index ? "Git-индекс" : "Commit")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Picker("Режим коммита", selection: Binding(
                        get: { workspace.commitMode }, set: workspace.setCommitMode
                    )) {
                        Text("Выбранные файлы").tag(CommitMode.selectedFiles)
                        Text("Git-индекс").tag(CommitMode.index)
                    }
                } label: {
                    Label("Режим коммита", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Режим коммита")
                .workbenchHint("Режим коммита")
                .disabled(workspace.activity != nil)
            }
            .padding(.horizontal, WorkbenchLayout.panelInset)
            .frame(height: WorkbenchLayout.panelHeaderHeight)
            changesAndMessage
        }
        .background(Palette.panel)
    }

    private var changesAndMessage: some View {
        let byIndex = workspace.commitMode == .index
        let first = byIndex ? workspace.staged : workspace.trackedChanges
        let second = byIndex ? workspace.unstaged : workspace.unversionedFiles
        let context = workspace.workingContext
        return VSplitView {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if !first.isEmpty {
                            workingGroup(byIndex ? .staged : .changes, files: first, context: byIndex ? .staged : context)
                        }
                        if !second.isEmpty {
                            workingGroup(byIndex ? .unstaged : .unversioned, files: second, context: byIndex ? .unstaged : context)
                        }
                    }
                    .padding(WorkbenchLayout.panelInset / 2)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($changesFocused)
                .accessibilityLabel("Файлы рабочей копии")
                .onChange(of: workingReveal) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                    workingReveal = nil
                }
                .onMoveCommand { direction in
                    if direction == .up { moveWorkingFile(-1) }
                    if direction == .down { moveWorkingFile(1) }
                }
            }
            .overlay {
                if workspace.hasWorkingStatus && first.isEmpty && second.isEmpty {
                    Text("Рабочая копия чистая")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .allowsHitTesting(false)
                } else if !workspace.hasWorkingStatus {
                    DeferredVisibility(isPending: true) { showProgress in
                        if showProgress {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("Читаем изменения")
                        }
                    }
                }
            }
            .frame(minHeight: 95, idealHeight: 250, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                if workspace.canEnableAmend {
                    Toggle("Amend", isOn: Binding(
                        get: { workspace.amend }, set: workspace.updateAmend
                    ))
                    .font(.system(size: 11))
                    .disabled(workspace.activity != nil && !workspace.isUpdatingIndex)
                }
                CommitMessageEditor(
                    text: $workspace.commitMessage,
                    focusRequest: commitFocusRequest == handledCommitFocus ? 0 : commitFocusRequest,
                    onFocus: { handledCommitFocus = $0 }
                )
                .frame(minHeight: 42, maxHeight: .infinity)
                HStack(spacing: 5) {
                    Button(workspace.amend ? "Amend" : "Commit") { workspace.commit() }
                        .buttonStyle(StudioButton(kind: .primary, keepsEnabledAppearance: workspace.isUpdatingIndex && workspace.canCommitWhenIdle))
                        .keyboardShortcut(GitKeymap.createCommit)
                        .workbenchHint(workspace.amend ? "Исправить последний коммит" : "Создать коммит",
                                       shortcut: GitKeymap.createCommit)
                        .disabled(!workspace.canCommit)
                    Button("Commit and Push…") { workspace.commit(pushAfter: true) }
                        .buttonStyle(StudioButton(keepsEnabledAppearance: workspace.isUpdatingIndex &&
                                                  workspace.canCommitWhenIdle && workspace.status?.branch != nil))
                        .disabled(!workspace.canCommit || workspace.status?.branch == nil)
                        .workbenchHint("Создать коммит и открыть Push", shortcut: GitKeymap.commitAndPush)
                    Spacer(minLength: 0)
                    DeferredVisibility(isPending: workspace.isUpdatingIndex) { showProgress in
                        ZStack {
                            if showProgress {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel("Обновляем индекс")
                            }
                        }
                        .frame(width: 14, height: 24)
                    }
                }
            }
            .padding(WorkbenchLayout.panelInset)
            .frame(minHeight: 114, idealHeight: 128, maxHeight: 147)
        }
        .background(Palette.panel)
    }

    private func workingGroup(_ group: ChangeGroup, files: [GitFile], context: GitPatchContext) -> some View {
        let expanded = !collapsedGroups.contains(group)
        let title = group.rawValue
        func toggleExpanded() {
            if expanded { collapsedGroups.insert(group) }
            else { collapsedGroups.remove(group) }
        }
        return LazyVStack(spacing: 1) {
            HStack(spacing: 4) {
                Button(action: toggleExpanded) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 15, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Свернуть \(title)" : "Раскрыть \(title)")
                if case .working = context {
                    inclusionGroupCheckbox(files, label: title)
                } else {
                    indexCheckbox(files, indexed: context == .staged, label: title)
                }
                Button(action: toggleExpanded) {
                    HStack(spacing: 4) {
                        Text(title).font(.system(size: 11, weight: .semibold))
                        Text(files.count.formatted())
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Palette.muted)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Развёрнуто" : "Свёрнуто")
            }
            .padding(.trailing, WorkbenchLayout.panelInset / 2)
            if expanded {
                ForEach(files) { file in
                    fileRow(file, context: context, change: group == .staged ? file.staged : (file.unstaged ?? file.staged))
                        .id(FileFocus(file: file, context: context).id)
                }
            }
        }
    }

    private func inclusionGroupCheckbox(_ files: [GitFile], label: String) -> some View {
        let eligible = files.filter { $0.unstaged != .conflicted }
        let count = eligible.count(where: workspace.isIncluded)
        let all = count > 0 && count == eligible.count
        let title = "\(inclusionAction(all)) · \(label)"
        return FileCheckbox(state: all ? .on : (count == 0 ? .off : .mixed),
                            label: title, enabled: !eligible.isEmpty && workspace.activity == nil) {
            workspace.setIncluded(eligible, included: $0)
        }
    }

    private func inclusionAction(_ included: Bool) -> String {
        included ? "Исключить из коммита" : "Включить в коммит"
    }

    private func indexCheckbox(_ files: [GitFile], indexed: Bool, label: String) -> some View {
        let action = indexed ? "Убрать из индекса" : "Добавить в индекс"
        return FileCheckbox(state: indexed ? .on : .off, label: "\(action) · \(label)",
                            enabled: workspace.activity == nil || workspace.isUpdatingIndex) { value in
            if value != indexed && workspace.activity == nil { workspace.stage(files, undo: !value) }
        }
        .allowsHitTesting(!workspace.isUpdatingIndex)
    }

    private func fileRow(_ file: GitFile, context: GitPatchContext, change: GitChange?) -> some View {
        let indexed: Bool? = switch context {
        case .staged: true
        case .unstaged: false
        default: nil
        }
        let included: Bool? = if case .working = context { workspace.isIncluded(file) } else { nil }
        let selected = workspace.focus?.id == FileFocus(file: file, context: context).id
        let path = file.originalPath.map { "\($0) → \(file.path)" } ?? file.path
        let checkboxIndent: CGFloat = 31
        return HStack(spacing: 1) {
            if let included {
                let title = "\(inclusionAction(included)) · \(file.name)"
                FileCheckbox(state: included ? .on : .off, label: title,
                             enabled: file.unstaged != .conflicted && workspace.activity == nil) {
                    workspace.setIncluded([file], included: $0)
                }
                .padding(.leading, checkboxIndent)
            } else if let indexed {
                indexCheckbox([file], indexed: indexed, label: file.name)
                    .padding(.leading, checkboxIndent)
            }
            Button {
                workspace.preview(file, context)
                if context.isWorkingFile { changesFocused = true }
            } label: {
                HStack(spacing: 6) {
                    FileTypeIcon(name: file.name)
                    Text(file.name)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if !file.directory.isEmpty && file.directory != "." {
                        Text(file.directory)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(change.map { "\($0.label) · \(path)" } ?? path)
            .accessibilityValue(change?.label ?? "")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .background(selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay {
            if selected && changesFocused && context.isWorkingFile {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Palette.accentBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            Button("Show Diff") {
                workspace.preview(file, context)
                diffFocusRequest &+= 1
            }
            Button("Show History") { workspace.showFileHistory(file) }
            if context.isWorkingFile, file.unstaged != .deleted,
               file.staged != .deleted || file.unstaged != nil {
                Button("Редактировать файл…") { editFile(file.path) }
                    .disabled(workspace.activity != nil)
                Button("Переместить в Корзину…", role: .destructive) { trashFile(file) }
                    .disabled(workspace.activity != nil)
            }
            if context.isWorkingFile, context != .staged, allowsRollback(file) {
                Button("Rollback…") { confirmRollback(file) }.disabled(workspace.activity != nil)
            }
            if let included {
                Button(inclusionAction(included)) { workspace.setIncluded([file], included: !included) }
                    .disabled(file.unstaged == .conflicted || workspace.activity != nil)
            } else if let indexed {
                Button(indexed ? "Убрать из индекса" : "Добавить в индекс") {
                    workspace.stage([file], undo: indexed)
                }
                .disabled(workspace.activity != nil)
            }
            Button("Скопировать путь") { workspace.copy(file.path) }
            Button("Показать в Finder") {
                if let root = workspace.git?.root {
                    NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(file.path)])
                }
            }
        }
    }

    private func editFile(_ path: String) {
        guard workspace.activity == nil, let root = workspace.git?.root else { return }
        sheet = .editFile(root, path)
    }

    private func trashFile(_ file: GitFile) {
        guard workspace.activity == nil, let root = workspace.git?.root else { return }
        confirmation = Confirmation(title: "Переместить «\(file.name)» в Корзину?",
                                    message: file.path, button: "В Корзину", destructive: true) {
            guard workspace.activity == nil else { return }
            Task {
                do {
                    try await Task.detached { try WorktreeFileDraft.trash(root: root, path: file.path) }.value
                    workspace.worktreeFileDidChange()
                } catch {
                    workspace.report("Не удалось переместить файл в Корзину", error)
                }
            }
        }
    }

    private var patchPane: some View {
        VStack(spacing: 0) {
            if projectVisible, let project = workspace.projectFiles, let path = project.previewPath {
                ProjectFilePreview(model: project, path: path, revision: project.previewRevision)
            } else if let focus = workspace.focus {
                let labels = workspace.patchLabels
                DiffView(focus: focus, source: workspace.diffSource, oldLabel: labels.0, newLabel: labels.1,
                         fileNavigation: fileNavigation(for: focus), error: workspace.patchError,
                         focusRequest: diffFocusRequest == handledDiffFocus ? 0 : diffFocusRequest,
                         onFocus: { handledDiffFocus = $0 })
            } else if workspace.mode == .changes && workspace.hasWorkingStatus && workspace.status?.files.isEmpty == true {
                Button("Открыть Git Log") { handle(.log) }
                    .buttonStyle(StudioButton())
                    .workbenchHint("Открыть Git Log", shortcut: GitKeymap.log)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if workspace.isDetailLoading || workspace.isExtrasLoading || !workspace.hasWorkingStatus {
                Color.clear.accessibilityHidden(true)
            } else {
                Text("Выберите файл")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.base)
    }

    private var inspector: some View {
        let detail = workspace.detail
        let locked = workspace.isDetailLoading || workspace.isHistoryReplacing
        return VSplitView {
            VStack(spacing: 0) {
                paneHeading("Changed Files")
                    .overlay(alignment: .trailing) {
                        DeferredVisibility(isPending: workspace.isDetailLoading) { showProgress in
                            if showProgress {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel("Загрузка коммита")
                            }
                        }
                        .padding(.trailing, WorkbenchLayout.panelInset)
                    }
                StudioRule()
                ScrollView {
                    if let detail {
                        LazyVStack(spacing: 1) {
                            ForEach(detail.files) { file in
                                fileRow(file, context: .commit(detail.commit.hash), change: file.staged ?? file.unstaged)
                            }
                        }
                        .padding(WorkbenchLayout.panelInset / 2)
                    }
                }
                .allowsHitTesting(!locked)
                .accessibilityHidden(locked)
                .overlay {
                    if !locked {
                        if let error = workspace.detailError {
                            ScrollView {
                                Text(error)
                                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    .padding(WorkbenchLayout.panelInset)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else if detail?.files.isEmpty == true {
                            Text("Файлы не изменены").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        } else if detail == nil && workspace.selection == nil && !workspace.entries.isEmpty {
                            Text("Выберите коммит").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
            .frame(minHeight: 65, idealHeight: 139)
            ScrollView {
                if let detail {
                    commitMetadata(detail)
                }
            }
            .frame(minHeight: 72, idealHeight: 119)
            .allowsHitTesting(!locked)
            .accessibilityHidden(locked)
        }
        .background(Palette.panel)
    }

    private func commitMetadata(_ detail: GitCommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.commit.subject).font(.system(size: 12, weight: .semibold))
            if let body = detail.message.split(separator: "\n", maxSplits: 1).dropFirst().first {
                Text(body.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 6) {
                Text(detail.commit.author).font(.system(size: 11))
                Text(detail.commit.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 10)).lineLimit(1)
                    .help(detail.commit.date.formatted(date: .long, time: .shortened))
                Spacer(minLength: 1)
                Button(detail.commit.shortHash) { workspace.copy(detail.commit.hash) }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                    .workbenchHint("Скопировать SHA")
                    .accessibilityLabel("Скопировать SHA \(detail.commit.shortHash)")
            }
            .foregroundStyle(Palette.muted)
            if !detail.email.isEmpty {
                Text(detail.email)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .contextMenu {
                        Button("Скопировать email") { workspace.copy(detail.email) }
                    }
            }
        }
        .textSelection(.enabled)
        .padding(WorkbenchLayout.panelInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func comparisonPane(_ ref: GitRef) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Сравнение веток")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { workspace.closeComparison() } label: { Image(systemName: "xmark") }
                    .buttonStyle(StudioButton(kind: .quiet))
                    .accessibilityLabel("Закрыть сравнение")
                    .workbenchHint("Закрыть сравнение")
            }.padding(.horizontal, 12).frame(height: 42)
            StudioRule()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text(workspace.branch).truncationMode(.middle)
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                    Text(ref.name).truncationMode(.middle)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(Palette.accent)
                .help("\(workspace.branch) → \(ref.name)")
                .accessibilityLabel("Из \(workspace.branch) в \(ref.name)")
                if !workspace.comparedFiles.isEmpty {
                    Text("Файлы · \(workspace.comparedFiles.count)")
                        .font(.system(size: 11, weight: .semibold))
                }
            }.padding(12)
            if let error = workspace.detailError {
                EmptyPanel(icon: "exclamationmark.circle", title: "Сравнение недоступно", subtitle: error)
            } else if workspace.comparedFiles.isEmpty {
                if workspace.activity != nil {
                    loadingBody("Сравниваем ветки")
                } else {
                    EmptyPanel(icon: "equal", title: "Различий нет")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(workspace.comparedFiles) { file in
                            fileRow(file, context: .comparison(ref.fullName), change: file.staged ?? file.unstaged)
                        }
                    }.padding(.horizontal, 7)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.panel)
    }

    private var stashPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Stash").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Сохранить…") { sheet = .stash }
                    .buttonStyle(StudioButton())
                    .disabled(workspace.status?.files.isEmpty != false || workspace.activity != nil || workspace.operation != nil)
            }
            .padding(.horizontal, 12).frame(height: 42)
            StudioRule()
            if workspace.stashes.isEmpty {
                if workspace.isExtrasLoading {
                    loadingBody("Загружаем stash")
                } else if let error = workspace.detailError {
                    Text(error).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .padding(WorkbenchLayout.panelInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Stash пуст")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(workspace.stashes) { stash in
                            Button { workspace.selectStash(stash) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(stash.message).font(.system(size: 12, weight: .semibold))
                                        .lineLimit(2)
                                    Text("\(stash.ref) · \(stash.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(workspace.selectedStash?.id == stash.id ? Palette.selection : .clear,
                                                in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(stash.message)
                            .accessibilityAddTraits(workspace.selectedStash?.id == stash.id ? .isSelected : [])
                        }
                        if let stash = workspace.selectedStash {
                            Button("Применить снимок") { workspace.apply(stash) }
                                .buttonStyle(StudioButton())
                                .disabled(workspace.activity != nil || workspace.isDetailLoading)
                            StudioRule()
                            if let detail = workspace.detail {
                                let locked = workspace.isDetailLoading || detail.commit.hash != stash.hash
                                ForEach(detail.files) { file in
                                    fileRow(file, context: .commit(detail.commit.hash), change: file.staged ?? file.unstaged)
                                        .allowsHitTesting(!locked)
                                        .accessibilityHidden(locked)
                                }
                            } else if let error = workspace.detailError {
                                Text(error).font(.system(size: 11)).foregroundStyle(Palette.red)
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }.background(Palette.panel)
    }

    private var worktreesPane: some View {
        VStack(spacing: 0) {
            paneHeading("Worktrees")
            StudioRule()
            if workspace.worktrees.isEmpty {
                if let error = workspace.detailError {
                    Text(error).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if workspace.isExtrasLoading {
                    loadingBody("Загружаем рабочие деревья")
                } else {
                    Text("Рабочих копий нет")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(workspace.worktrees) { tree in
                            HStack(spacing: 12) {
                                Image(systemName: "folder").foregroundStyle(Palette.muted).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(tree.branch ?? "Detached HEAD")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(tree.path).foregroundStyle(Palette.muted)
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 2)
                                if tree.path == workspace.git?.root.path {
                                    Text("Текущая копия").foregroundStyle(Palette.muted).font(.system(size: 11))
                                } else if tree.isBare || tree.isPrunable {
                                    Text(tree.isBare ? "Bare" : "Папка недоступна")
                                        .foregroundStyle(Palette.muted).font(.system(size: 11))
                                } else {
                                    Button("Открыть во вкладке") {
                                        openWorktree(URL(fileURLWithPath: tree.path, isDirectory: true))
                                    }
                                    .buttonStyle(StudioButton())
                                }
                            }
                            .padding(.horizontal, 13)
                            .frame(height: 56)
                            .background(Palette.panel)
                        }
                    }.padding(12)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func paneHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WorkbenchLayout.panelInset)
            .frame(height: WorkbenchLayout.panelHeaderHeight)
    }

    private func loadingBody(_ label: String) -> some View {
        DeferredVisibility(isPending: true) { showProgress in
            if showProgress {
                ProgressView().controlSize(.small).accessibilityLabel(label)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canPush: Bool {
        canPushWhenIdle && workspace.activity == nil && !loadingRemotes
    }

    private var canPushWhenIdle: Bool {
        workspace.status?.branch != nil && workspace.status?.isUnborn == false && workspace.operation == nil
    }

    private var canUpdate: Bool {
        canUpdateWhenIdle && workspace.activity == nil
    }

    private var canUpdateWhenIdle: Bool {
        workspace.canUpdateFromUpstream
    }

    private var canCreateBranch: Bool {
        workspace.activity == nil && workspace.operation == nil && workspace.status?.isUnborn == false
    }

    private var availableActions: [GitAction] {
        let current = workspace.focus
        let mutable = workspace.activity == nil
        let ready = mutable && workspace.status?.isUnborn == false && workspace.operation == nil
        let byIndex = workspace.commitMode == .index
        return [
            GitAction(title: "Commit", detail: "Перейти к сообщению коммита", icon: "square.and.pencil",
                      shortcut: GitKeymap.commit) { handle(.commit) },
            GitAction(title: "Commit and Push…", detail: "Коммит и отправка", icon: "arrow.up",
                      shortcut: GitKeymap.commitAndPush, enabled: mutable) { handle(.commitAndPush) },
            GitAction(title: "Push…", detail: "Отправить коммиты", icon: "arrow.up",
                      shortcut: GitKeymap.push, enabled: canPush) { preparePush() },
            GitAction(title: "Fetch", detail: "Получить удалённые ссылки", icon: "tray.and.arrow.down",
                      enabled: mutable) { workspace.fetch() },
            GitAction(title: "Update Project", detail: "Применить уже полученные коммиты к текущей ветке", icon: "arrow.down.to.line",
                      shortcut: GitKeymap.update, enabled: canUpdate) { handle(.update) },
            GitAction(title: "Refresh File Status", detail: "Обновить список изменённых файлов", icon: "arrow.clockwise",
                      shortcut: KeyboardShortcut("r"), enabled: mutable) { workspace.refresh(userInitiated: true) },
            GitAction(title: "Branches", detail: "Ветки, теги и действия Checkout, Compare, Merge, Rebase", icon: "arrow.triangle.branch") {
                sheet = .branches
            },
            GitAction(title: "New Branch…", detail: "Создать ветку от HEAD", icon: "plus", enabled: ready) { sheet = .branch(nil) },
            GitAction(title: "Git Log", detail: "Открыть или скрыть историю коммитов", icon: "clock.arrow.circlepath",
                      shortcut: GitKeymap.log) { handle(.log) },
            GitAction(title: "Terminal", detail: "Показать или скрыть терминал проекта", icon: "terminal",
                      shortcut: GitKeymap.terminal) { handle(.terminal) },
            GitAction(title: "Project", detail: "Показать или скрыть дерево файлов", icon: "folder",
                      shortcut: GitKeymap.projectFiles) { handle(.projectFiles) },
            GitAction(title: "Show History", detail: "История выбранного файла", icon: "clock",
                      enabled: current != nil) { if let current { workspace.showFileHistory(current.file) } },
            GitAction(title: "Show Diff", detail: "Перейти к сравнению выбранного файла", icon: "rectangle.split.2x1",
                      shortcut: GitKeymap.showDiff, enabled: current != nil) { handle(.diff) },
            GitAction(title: byIndex ? "Stage" : "Toggle Inclusion in Commit",
                      detail: byIndex ? "Добавить выбранный файл в индекс" : "Изменить отметку выбранного файла",
                      icon: "checkmark.square", shortcut: GitKeymap.stage,
                      enabled: mutable && current.map {
                          $0.context.isWorkingFile && $0.context != .staged && $0.file.unstaged != .conflicted
                      } == true) { handle(.stage) },
            GitAction(title: "Rollback…", detail: "Отменить неиндексированные изменения файла", icon: "arrow.uturn.backward",
                      shortcut: GitKeymap.rollback,
                      enabled: mutable && current.map {
                          $0.context.isWorkingFile && $0.context != .staged && allowsRollback($0.file)
                      } == true) {
                handle(.rollback)
            },
            GitAction(title: "Stash Changes…", detail: "Временно сохранить рабочие изменения", icon: "archivebox",
                      enabled: mutable && workspace.operation == nil && workspace.status?.files.isEmpty == false) {
                workspace.activate(.stash)
                sheet = .stash
            },
            GitAction(title: "Worktrees", detail: "Открыть рабочие копии", icon: "square.on.square") {
                workspace.activate(.worktrees)
            },
            GitAction(title: "Keyboard Shortcuts", detail: "Справка по горячим клавишам", icon: "keyboard") { sheet = .keymap },
        ]
    }

    private func branchActions(_ ref: GitRef) -> [GitAction] {
        let able = workspace.activity == nil && workspace.operation == nil
        let target = workspace.status?.branch
        let canIntegrate = able && !ref.isCurrent && target != nil && workspace.status?.isUnborn == false
        var actions = [GitAction(title: "Show in Log", detail: "Отфильтровать историю по ветке",
                                 icon: "clock.arrow.circlepath") { workspace.browse(ref) }]
        if ref.kind != .tag, !ref.isCurrent {
            actions.append(GitAction(title: "Checkout", detail: "Переключить рабочую копию", icon: "arrow.turn.up.right",
                                     enabled: able) { workspace.checkout(ref) })
        }
        actions.append(GitAction(title: "New Branch from Selected…", detail: "Создать ветку от «\(ref.name)»", icon: "plus",
                                 enabled: able) { sheet = .branch(ref) })
        if !ref.isCurrent {
            actions.append(GitAction(title: "Compare with Current", detail: "Сравнить снимки двух веток",
                                     icon: "arrow.left.and.right",
                                     enabled: workspace.activity == nil && workspace.status?.isUnborn == false) {
                workspace.compare(ref)
            })
        }
        if let target, !ref.isCurrent {
            actions.append(GitAction(title: "Merge into Current…", detail: "Слить «\(ref.name)» в «\(target)»",
                                     icon: "point.3.connected.trianglepath.dotted", enabled: canIntegrate) {
                confirmIntegration(ref, operation: .merge, target: target)
            })
            actions.append(GitAction(title: "Rebase Current onto Selected…", detail: "Перенести «\(target)» на «\(ref.name)»",
                                     icon: "arrow.turn.up.right", enabled: canIntegrate) {
                confirmIntegration(ref, operation: .rebase, target: target)
            })
        }
        if ref.kind == .local {
            actions.append(GitAction(title: "Rename…", detail: "Переименовать локальную ветку", icon: "pencil",
                                     enabled: able) { sheet = .rename(ref) })
            if !ref.isCurrent {
                actions.append(GitAction(title: "Delete…", detail: "Удалить слитую локальную ветку", icon: "trash",
                                         enabled: able) {
                    confirmation = Confirmation(title: "Удалить ветку «\(ref.name)»?",
                        message: "Git проверит, что ветка слита.", button: "Удалить ветку", destructive: true) {
                        workspace.deleteBranch(ref)
                    }
                })
            }
        }
        let favorite = workspace.favoriteRefs.contains(ref.id)
        actions.append(GitAction(title: favorite ? "Remove from Favorites" : "Add to Favorites",
                                 detail: "Избранные ветки в Git Log", icon: favorite ? "star.slash" : "star") {
            workspace.toggleFavorite(ref)
        })
        actions.append(GitAction(title: "Copy SHA", detail: "Скопировать хеш вершины ветки",
                                 icon: "document.on.document") { workspace.copy(ref.hash) })
        return actions
    }

    private func confirmIntegration(_ ref: GitRef, operation: GitOperation, target: String) {
        let title = operation == .merge ? "Слить «\(ref.name)» в «\(target)»?" :
            "Перенести «\(target)» на «\(ref.name)»?"
        let message = operation == .merge ? "При расхождении Git создаст merge-коммит." :
            "Rebase изменит SHA перенесённых локальных коммитов."
        confirmation = Confirmation(title: title, message: message, button: operation.name) {
            workspace.integrate(ref, using: operation, into: target)
        }
    }

    private func logActions(_ entry: HistoryEntry) -> [HistoryAction] {
        guard let branch = workspace.status?.branch, workspace.operation == nil,
              workspace.activity == nil, !entry.isMerge else { return [] }
        return [
            HistoryAction(title: "Cherry-pick…", systemImage: "plus.circle") {
                confirmation = Confirmation(title: "Перенести коммит в «\(branch)»?",
                    message: entry.subject, button: "Cherry-pick") {
                    workspace.applyCommit(entry.id, operation: .cherryPick, into: branch)
                }
            },
            HistoryAction(title: "Revert Commit…", systemImage: "arrow.uturn.backward") {
                confirmation = Confirmation(title: "Отменить изменения этого коммита в «\(branch)»?",
                    message: "Git создаст новый коммит с обратными изменениями.\n\(entry.subject)", button: "Revert Commit") {
                    workspace.applyCommit(entry.id, operation: .revert, into: branch)
                }
            },
        ]
    }

    private func handle(_ command: RepositoryCommand) {
        switch command {
        case .commit:
            handledDiffFocus = diffFocusRequest
            workspace.projectFiles?.visible = false
            if workspace.mode == .stash || workspace.mode == .worktrees || workspace.comparedRef != nil {
                workspace.activate(.changes)
            }
            workspace.commitToolVisible = true
            commitFocusRequest &+= 1
        case .commitTool:
            if projectVisible {
                workspace.projectFiles?.visible = false
                workspace.commitToolVisible = true
            } else if workspace.mode == .stash || workspace.mode == .worktrees || workspace.comparedRef != nil {
                workspace.activate(.changes)
                workspace.commitToolVisible = true
            } else {
                workspace.commitToolVisible.toggle()
            }
        case .commitAndPush:
            if workspace.canCommit, workspace.status?.branch != nil { workspace.commit(pushAfter: true) }
            else { handle(.commit) }
        case .amend:
            if workspace.canEnableAmend {
                workspace.updateAmend(!workspace.amend)
                handle(.commit)
            }
        case .log:
            if terminalVisible {
                workspace.terminalDock?.hide()
                if workspace.comparedRef != nil { workspace.closeComparison() }
                else if workspace.mode != .history { workspace.activate(.history) }
                else { workspace.historyToolVisible = true }
            } else if workspace.comparedRef != nil { workspace.closeComparison() }
            else if workspace.mode == .history { workspace.historyToolVisible.toggle() }
            else { workspace.activate(.history) }
        case .terminal:
            if workspace.terminalDock == nil, let root = workspace.git?.root {
                workspace.terminalDock = TerminalDock(root: root)
            }
            workspace.terminalDock?.toggle()
        case .projectFiles:
            if projectVisible {
                workspace.projectFiles?.visible = false
            } else if let root = workspace.git?.root {
                if workspace.mode == .stash || workspace.mode == .worktrees || workspace.comparedRef != nil {
                    workspace.activate(.changes)
                }
                if workspace.projectFiles == nil { workspace.projectFiles = ProjectFilesModel(root: root) }
                workspace.projectFiles?.visible = true
            }
        case .push:
            if canPush { preparePush() }
        case .update:
            if canUpdate { workspace.updateFromUpstream() }
        case .diff:
            handledCommitFocus = commitFocusRequest
            if projectVisible, let path = workspace.projectFiles?.previewPath,
               !workspace.previewWorkingFile(at: path) { return }
            if workspace.focus == nil && workspace.mode == .changes { workspace.selectInitialChange() }
            if workspace.focus != nil { diffFocusRequest &+= 1 }
        case .stage:
            if let selected = workspace.focus {
                if case .working = selected.context {
                    workspace.setIncluded([selected.file], included: !workspace.isIncluded(selected.file))
                } else if selected.context == .unstaged {
                    workspace.stage([selected.file])
                }
            }
        case .rollback:
            if let selected = workspace.focus, selected.context.isWorkingFile, selected.context != .staged,
               workspace.activity == nil, allowsRollback(selected.file) { confirmRollback(selected.file) }
        case .vcsActions:
            sheet = .actions(false)
        case .findAction:
            sheet = .actions(true)
        case .branches:
            sheet = .branches
        case .keymap:
            sheet = .keymap
        }
    }

    private func showHistoryDiff(_ entry: HistoryEntry) {
        workspace.selectCommit(entry.id, revealDiff: true)
        diffFocusRequest &+= 1
    }

    private func chooseAction(_ action: GitAction) {
        guard action.enabled else { return }
        afterSheet(action.run)
    }

    private func afterSheet(_ action: @escaping () -> Void) {
        queuedAction = action
        sheet = nil
    }

    private func runQueuedAction() {
        let action = queuedAction
        queuedAction = nil
        action?()
    }

    private func allowsRollback(_ file: GitFile) -> Bool {
        guard let change = file.unstaged else { return false }
        return change != .untracked && change != .conflicted
    }

    private func confirmRollback(_ file: GitFile) {
        confirmation = Confirmation(title: "Отменить изменения в «\(file.name)»?",
            message: "Рабочая версия файла будет заменена версией из индекса.",
            button: "Rollback", destructive: true) {
            workspace.rollback(file)
        }
    }

    private func revealWorkingFile(_ target: FileFocus) {
        let group: ChangeGroup
        switch target.context {
        case .working:
            group = target.file.staged == nil && target.file.unstaged == .untracked ? .unversioned : .changes
        case .staged: group = .staged
        case .unstaged: group = .unstaged
        default: return
        }
        collapsedGroups.remove(group)
        workingReveal = target.id
    }

    private func moveWorkingFile(_ offset: Int) {
        let list = workspace.workingFiles
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == workspace.focus?.id } ?? (offset > 0 ? -1 : list.count)
        let target = list[max(0, min(current + offset, list.count - 1))]
        guard target.id != workspace.focus?.id else { return }
        workspace.preview(target.file, target.context)
        revealWorkingFile(target)
    }

    private func fileNavigation(for focus: FileFocus) -> DiffFileNavigation? {
        let files: [FileFocus]
        switch focus.context {
        case .working, .staged, .unstaged:
            files = workspace.workingFiles
        case .commit(let hash):
            guard let detail = workspace.detail, detail.commit.hash == hash else { return nil }
            files = detail.files.map { FileFocus(file: $0, context: focus.context) }
        case .comparison(let ref):
            guard workspace.comparedRef?.fullName == ref else { return nil }
            files = workspace.comparedFiles.map { FileFocus(file: $0, context: focus.context) }
        }
        guard let index = files.firstIndex(where: { $0.id == focus.id }), files.count > 1 else { return nil }
        func select(_ index: Int) {
            guard files.indices.contains(index) else { return }
            let next = files[index]
            workspace.preview(next.file, next.context)
            if !projectVisible && workspace.commitToolVisible { revealWorkingFile(next) }
        }
        return DiffFileNavigation(index: index, count: files.count,
                                  previous: { select(index - 1) }, next: { select(index + 1) })
    }

    private func preparePush() {
        guard let git = workspace.git, let status = workspace.status, let branch = status.branch,
              workspace.activity == nil, !status.isUnborn, !loadingRemotes else { return }
        let destination = PushDestination(branch: branch, upstream: status.upstream, ahead: status.ahead)
        if destination.upstream != nil {
            sheet = .push(destination, [])
            return
        }
        loadingRemotes = true
        syncTask = Task {
            defer { loadingRemotes = false }
            do {
                let remotes = try await git.remotes()
                try Task.checkCancellation()
                sheet = .push(destination, remotes)
            } catch is CancellationError {
            } catch {
                workspace.report("Не удалось прочитать список remote", error)
            }
        }
    }
}

private struct FileCheckbox: View {
    let state: NSControl.StateValue
    let label: String
    let enabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        NativeFileCheckbox(state: state, label: label, enabled: enabled, onToggle: onToggle)
            .frame(width: 22, height: 24)
    }
}

private struct NativeFileCheckbox: NSViewRepresentable {
    let state: NSControl.StateValue
    let label: String
    let enabled: Bool
    let onToggle: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.controlSize = .mini
        button.allowsMixedState = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.state = state
        context.coordinator.onToggle = onToggle
        button.state = state
        button.isEnabled = enabled
        button.setAccessibilityLabel(label)
    }

    @MainActor
    final class Coordinator: NSObject {
        var state: NSControl.StateValue = .off
        var onToggle: ((Bool) -> Void)?

        @objc func toggle(_ sender: NSButton) {
            let included = state != .on
            state = included ? .on : .off
            sender.state = state
            onToggle?(included)
        }
    }
}

private struct RefGroup<Content: View>: View {
    let title: String
    @State var expanded: Bool
    var indent: CGFloat = 5
    var folder = false
    @ViewBuilder var content: Content

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 15)
                    if folder {
                        Image(systemName: "folder").font(.system(size: 10))
                    }
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(Palette.muted)
                .padding(.leading, indent)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Развёрнуто" : "Свёрнуто")
            if expanded { content }
        }
    }
}

private extension GitChange {
    var label: String {
        switch self {
        case .modified: "Изменён"
        case .added: "Добавлен"
        case .deleted: "Удалён"
        case .renamed: "Переименован"
        case .copied: "Скопирован"
        case .typeChanged: "Изменён тип файла"
        case .untracked: "Новый файл"
        case .conflicted: "Конфликт"
        }
    }
}
