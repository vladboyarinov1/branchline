import AppKit
import CoreText
import SwiftUI

struct DiffFileNavigation {
    let index: Int
    let count: Int
    let previous: () -> Void
    let next: () -> Void

    fileprivate var position: DiffFilePosition { DiffFilePosition(index: index, count: count) }

    fileprivate func move(_ direction: DiffDirection) {
        guard position.canMove(direction) else { return }
        switch direction {
        case .previous: previous()
        case .next: next()
        }
    }
}

private struct DiffFilePosition: Equatable {
    let index: Int
    let count: Int

    func canMove(_ direction: DiffDirection) -> Bool {
        (0..<count).contains(index + direction.offset)
    }
}

struct DiffView: View {
    static let syntaxHighlightingKey = "branchline.diff.syntaxHighlighting"
    let focus: FileFocus
    let source: DiffSource?
    let oldLabel: String
    let newLabel: String
    let fileNavigation: DiffFileNavigation?
    let error: String?
    let focusRequest: UInt
    let onFocus: ((UInt) -> Void)?

    @AppStorage("branchline.diff.layout") private var mode: DiffLayout = .split
    @AppStorage(DiffView.syntaxHighlightingKey) private var highlightsSyntax = true
    @State private var preview: DiffPreview?
    @State private var activeHunk = 0
    @State private var jump: DiffJump?
    @State private var pendingFileStep: DiffDirection?
    @State private var handledFocusRequest: UInt = 0

    init(focus: FileFocus, source: DiffSource?, oldLabel: String, newLabel: String,
         fileNavigation: DiffFileNavigation? = nil, error: String? = nil,
         focusRequest: UInt = 0, onFocus: ((UInt) -> Void)? = nil) {
        self.focus = focus
        self.source = source
        self.oldLabel = oldLabel
        self.newLabel = newLabel
        self.fileNavigation = fileNavigation
        self.error = error
        self.focusRequest = focusRequest
        self.onFocus = onFocus
        if let source, error == nil {
            let target = DiffPreviewTarget(focus: focus, oldLabel: oldLabel, newLabel: newLabel)
            _preview = State(initialValue: DiffPreview(target: target, patch: source.patch,
                                                       position: fileNavigation?.position, document: source.document))
        }
    }

    var body: some View {
        let colors = DiffColors.islandsDark
        let target = DiffPreviewTarget(focus: focus, oldLabel: oldLabel, newLabel: newLabel)
        let current = preview?.target.key == target.key
        let pending = !current && error == nil
        let visible = error == nil ? preview : nil
        let showsPriorSelection = visible != nil && !current
        let displayedTarget = visible?.target ?? target
        let document = visible?.document
        let showRows = document.map { $0.rowCount > 0 && !($0.isBinary && $0.hunks.isEmpty) } ?? false
        let syntax = highlightsSyntax ? visible.flatMap { DiffSyntax(path: $0.target.file.path) } : nil
        let request = DiffPreviewRequest(target: target, patch: error == nil ? source?.patch : nil, position: fileNavigation?.position)
        VStack(spacing: 0) {
            CodeFileHeading(file: displayedTarget.file, pending: pending,
                            loadingLabel: "Загрузка сравнения", colors: colors)
            StudioRule()
            toolbar(visible, position: showsPriorSelection ? visible?.position : request.position,
                    enabled: !showsPriorSelection, colors: colors)
            let layout = effectiveMode(document)
            DiffColumnsLayout(canResize: layout == .split && showRows, colors: colors) { width in
                VStack(spacing: 0) {
                    columnHeaders(document: document, target: displayedTarget, leftWidth: width, colors: colors)
                    Divider()
                    ZStack {
                        DiffTableSurface(
                            preview: visible, isShowing: showRows, mode: layout, colors: colors,
                            splitLeftWidth: width, syntax: syntax,
                            jump: jump, focusRequest: current && showRows && focusRequest != 0 && focusRequest != handledFocusRequest ? focusRequest : nil,
                            onFocus: {
                                handledFocusRequest = $0
                                onFocus?($0)
                            },
                            onScroll: { index in
                                if index != activeHunk {
                                    activeHunk = index
                                    pendingFileStep = nil
                                }
                            }
                        )
                        .allowsHitTesting(showRows)
                        .accessibilityHidden(!showRows)
                        if let error {
                            message("Diff недоступен", description: error, icon: "exclamationmark.circle")
                        } else if let document, document.isBinary && document.hunks.isEmpty {
                            message("Двоичный файл", description: nil, icon: "doc")
                        } else if let document, document.rowCount == 0 {
                            message("Нет текстовых изменений", description: nil, icon: "equal.square")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let document {
                if let pendingFileStep {
                    let shortcut = GitKeymap.display(pendingFileStep.blockShortcut)
                    let hint = pendingFileStep == .next
                        ? "Нажмите \(shortcut) ещё раз, чтобы открыть следующий файл."
                        : "Нажмите \(shortcut) ещё раз, чтобы открыть предыдущий файл."
                    notice(hint, symbol: "doc.on.doc", colors: colors)
                } else if document.isTruncated {
                    notice("Предпросмотр сокращён.", symbol: "scissors", colors: colors)
                }
            }
        }
        .foregroundStyle(Color(nsColor: colors.text))
        .background(Color(nsColor: colors.canvas))
        .background {
            DiffShortcutHost { command in
                switch command {
                case .block(let direction):
                    guard current, let document else { return false }
                    return moveBlock(direction, count: document.hunks.count, canCrossFiles: true)
                case .file(let direction):
                    return moveFile(direction)
                }
            }
            .frame(width: 0, height: 0)
        }
        .task(id: request) { load(request) }
        .onChange(of: target.key) { _, _ in pendingFileStep = nil }
        .onChange(of: error) { _, value in
            if value != nil {
                preview = nil
                jump = nil
                pendingFileStep = nil
            }
        }
        .onChange(of: mode) { _, _ in jump = DiffJump(index: activeHunk) }
    }

    private func load(_ request: DiffPreviewRequest) {
        guard !Task.isCancelled, let source, let patch = request.patch else { return }
        if let preview, preview.patch == patch, preview.target == request.target, preview.position == request.position { return }
        let document = source.document
        if preview?.document.id != document.id || preview?.target.key != request.target.key {
            if preview?.target.key.keepsViewport(for: request.target.key) == true {
                activeHunk = min(activeHunk, max(0, document.hunks.count - 1))
            } else {
                activeHunk = 0
            }
            jump = nil
            pendingFileStep = nil
        }
        preview = DiffPreview(target: request.target, patch: patch, position: request.position, document: document)
    }

    private func toolbar(_ preview: DiffPreview?, position: DiffFilePosition?, enabled: Bool, colors: DiffColors) -> some View {
        ViewThatFits(in: .horizontal) {
            toolbarContents(preview, position: position, enabled: enabled, colors: colors, showChangeCounts: true)
            toolbarContents(preview, position: position, enabled: enabled, colors: colors, showChangeCounts: false)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Color(nsColor: colors.chrome))
    }

    private func toolbarContents(_ preview: DiffPreview?, position: DiffFilePosition?, enabled: Bool,
                                 colors: DiffColors, showChangeCounts: Bool) -> some View {
        let document = preview?.document
        return HStack(spacing: 8) {
            if let position, position.count > 1 {
                fileControls(position, enabled: enabled, colors: colors)
            }
            if showChangeCounts, let document, !document.hunks.isEmpty {
                HStack(spacing: 7) {
                    Text("+\(document.additions)")
                        .foregroundStyle(Color(nsColor: colors.addedInk))
                        .accessibilityLabel("Добавлено строк: \(document.additions)")
                    Text("−\(document.deletions)")
                        .foregroundStyle(Color(nsColor: colors.removedInk))
                        .accessibilityLabel("Удалено строк: \(document.deletions)")
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
            }
            Spacer(minLength: 4)
            if let document, document.hunks.count > 1 {
                HStack(spacing: 2) {
                    blockButton("Предыдущий блок изменений", symbol: "chevron.up", direction: .previous,
                                count: document.hunks.count, enabled: enabled)
                    Text("\(activeHunk + 1) / \(document.hunks.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color(nsColor: colors.muted))
                        .fixedSize()
                        .accessibilityLabel("Блок \(activeHunk + 1) из \(document.hunks.count)")
                    blockButton("Следующий блок изменений", symbol: "chevron.down", direction: .next,
                                count: document.hunks.count, enabled: enabled)
                }
            }
            if document?.hunks.isEmpty == false {
                HStack(spacing: 1) {
                    layoutButton(.split, title: "Сравнение рядом", symbol: "rectangle.split.2x1", colors: colors)
                    layoutButton(.unified, title: "Сравнение одним списком", symbol: "rectangle", colors: colors)
                }
                .padding(1)
                .background(Color(nsColor: colors.canvas), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Режим сравнения")
            }
            if let patch = preview?.patch, !patch.isEmpty {
                toolbarButton("Скопировать патч", symbol: "doc.on.doc", enabled: enabled) {
                    copyDiffText(patch)
                }
            } else {
                Color.clear.frame(width: 25, height: 23).accessibilityHidden(true)
            }
        }
    }

    private func fileControls(_ position: DiffFilePosition, enabled: Bool, colors: DiffColors) -> some View {
        HStack(spacing: 2) {
            toolbarButton("Предыдущий файл", symbol: "arrow.left", shortcut: GitKeymap.previousFile,
                          enabled: enabled && position.canMove(.previous)) {
                _ = moveFile(.previous)
            }
            Text("\(position.index + 1) / \(position.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color(nsColor: colors.muted))
                .fixedSize()
                .accessibilityLabel("Файл \(position.index + 1) из \(position.count)")
            toolbarButton("Следующий файл", symbol: "arrow.right", shortcut: GitKeymap.nextFile,
                          enabled: enabled && position.canMove(.next)) {
                _ = moveFile(.next)
            }
        }
    }

    private func blockButton(_ title: String, symbol: String, direction: DiffDirection, count: Int, enabled: Bool) -> some View {
        let canMove = enabled && (0..<count).contains(activeHunk + direction.offset)
        return toolbarButton(title, symbol: symbol, shortcut: direction.blockShortcut, enabled: canMove) {
            _ = moveBlock(direction, count: count)
        }
    }

    private func layoutButton(_ layout: DiffLayout, title: String, symbol: String, colors: DiffColors) -> some View {
        let selected = mode == layout
        return toolbarButton(title, symbol: symbol) { mode = layout }
            .foregroundStyle(Color(nsColor: selected ? colors.text : colors.muted))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: colors.selectedBackground(over: colors.chrome, focused: true)))
                }
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toolbarButton(_ title: String, symbol: String, shortcut: KeyboardShortcut? = nil, enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 25, height: 23)
                .opacity(enabled ? 1 : 0.40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .workbenchHint(title, shortcut: shortcut)
    }

    private func moveBlock(_ direction: DiffDirection, count: Int, canCrossFiles: Bool = false) -> Bool {
        guard count > 0 else { return false }
        let index = activeHunk + direction.offset
        if (0..<count).contains(index) {
            pendingFileStep = nil
            activeHunk = index
            jump = DiffJump(index: index)
            return true
        }
        guard canCrossFiles, fileNavigation?.position.canMove(direction) == true else { return false }
        if pendingFileStep == direction {
            return moveFile(direction)
        }
        pendingFileStep = direction
        return true
    }

    private func moveFile(_ direction: DiffDirection) -> Bool {
        guard let navigation = fileNavigation, navigation.position.canMove(direction) else { return false }
        pendingFileStep = nil
        navigation.move(direction)
        return true
    }

    private func notice(_ text: String, symbol: String, colors: DiffColors) -> some View {
        VStack(spacing: 0) {
            Divider()
            Label(text, systemImage: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: colors.muted))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: colors.chrome))
        }
    }

    private func columnHeaders(document: DiffDocument?, target: DiffPreviewTarget, leftWidth: CGFloat,
                               colors: DiffColors) -> some View {
        HStack(spacing: 0) {
            if document?.hunks.isEmpty == true {
                columnLabel("Метаданные файла", colors: colors)
                    .padding(.horizontal, 10)
            } else if mode == .split {
                columnLabel(target.oldLabel, colors: colors)
                    .padding(.horizontal, 10)
                    .frame(width: leftWidth, alignment: .leading)
                    .clipped()
                Rectangle().fill(Color(nsColor: colors.separator)).frame(width: DiffSplitGeometry.lineWidth)
                columnLabel(target.newLabel, colors: colors)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    columnLabel(target.oldLabel, colors: colors)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(nsColor: colors.muted))
                        .accessibilityHidden(true)
                    columnLabel(target.newLabel, colors: colors)
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 24)
        .background(Color(nsColor: colors.canvas))
    }

    private func columnLabel(_ label: String, colors: DiffColors) -> some View {
        Text(label)
            .lineLimit(1)
            .truncationMode(.middle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(nsColor: colors.muted))
            .help(label)
    }

    private func message(_ title: String, description: String?, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 23)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .semibold))
            if let description {
                Text(description).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func effectiveMode(_ document: DiffDocument?) -> DiffLayout {
        document?.hunks.isEmpty == true ? .unified : mode
    }
}

struct ProjectFilePreview: View {
    let model: ProjectFilesModel
    let path: String
    let revision: UInt
    @AppStorage(DiffView.syntaxHighlightingKey) private var highlightsSyntax = true
    @State private var loaded: Loaded?
    @State private var discard: InlineFileBuffer?

    init(model: ProjectFilesModel, path: String, revision: UInt) {
        self.model = model
        self.path = path
        self.revision = revision
        _loaded = State(initialValue: model.previewCache.content(at: path))
    }

    private struct Request: Equatable {
        let path: String
        let revision: UInt
    }

    fileprivate struct Loaded {
        let path: String
        let content: Content
    }

    fileprivate enum Content {
        case editor(InlineFileBuffer)
        case readOnly(DiffDocument)
        case unsupported
        case failed(String)
    }

    var body: some View {
        let colors = DiffColors.islandsDark
        let shownPath = loaded?.path ?? path
        let syntax = highlightsSyntax ? DiffSyntax(path: shownPath) : nil
        let request = Request(path: path, revision: revision)
        VStack(spacing: 0) {
            CodeFileHeading(file: GitFile(path: shownPath), pending: loaded?.path != path,
                            loadingLabel: "Загрузка файла", colors: colors)
            StudioRule()
            switch loaded?.content {
            case .editor(let editor):
                InlineCodeEditor(buffer: editor, text: editor.text, colors: colors,
                                 syntax: syntax, editable: path == shownPath)
                    .id(ObjectIdentifier(editor))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = editor.error {
                    HStack(spacing: 8) {
                        Text(error).font(.system(size: 11)).foregroundStyle(Palette.red)
                        Spacer()
                        Button("Повторить", action: editor.saveNow)
                        Button("Перечитать…") { discard = editor }
                    }
                    .padding(WorkbenchLayout.panelInset)
                }
            case .readOnly(let document):
                ProjectFileTable(document: document, path: shownPath, colors: colors, syntax: syntax)
                Text("Предпросмотр больших файлов доступен для чтения.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: colors.muted))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, WorkbenchLayout.panelInset)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: colors.chrome))
            case .unsupported:
                EmptyPanel(icon: "doc", title: "Для этого файла нет текстового предпросмотра")
            case .failed(let reason):
                EmptyPanel(icon: "exclamationmark.circle", title: "Не удалось прочитать файл", subtitle: reason)
            case nil:
                Color.clear.accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color(nsColor: colors.text))
        .background(Color(nsColor: colors.canvas))
        .task(id: request) {
            await model.previewCache.load(model: model, path: request.path, revision: request.revision)
            if !Task.isCancelled, let content = model.previewCache.content(at: request.path) { loaded = content }
        }
        .confirmationDialog("Отбросить несохранённый текст и перечитать файл?", isPresented: Binding(
            get: { discard != nil }, set: { if !$0 { discard = nil } }
        ), titleVisibility: .visible, presenting: discard) { editor in
            Button("Перечитать с диска", role: .destructive) { model.discardEditor(editor) }
        }
    }

}

@MainActor
final class ProjectPreviewCache {
    private var loaded: ProjectFilePreview.Loaded?

    func contains(_ path: String) -> Bool { loaded?.path == path }

    fileprivate func content(at path: String) -> ProjectFilePreview.Loaded? {
        contains(path) ? loaded : nil
    }

    func clear() { loaded = nil }

    func load(model: ProjectFilesModel, path: String, revision: UInt) async {
        if let editor = model.pendingEditor(at: path) {
            loaded = ProjectFilePreview.Loaded(path: path, content: .editor(editor))
            return
        }
        let root = model.root
        let read = Task.detached(priority: .userInitiated) {
            let snapshot = try ProjectFileContent.load(root: root, path: path)
            if let draft = snapshot.draft { return FileRead.editable(draft) }
            if case .text(let text, let truncated) = snapshot.content {
                return FileRead.readOnly(DiffDocument(source: text, truncated: truncated))
            }
            return FileRead.unsupported
        }
        let result = await withTaskCancellationHandler { await read.result } onCancel: { read.cancel() }
        guard !Task.isCancelled, model.previewPath == path, model.previewRevision == revision else { return }
        let content: ProjectFilePreview.Content
        if let editor = model.pendingEditor(at: path) {
            content = .editor(editor)
        } else {
            switch result {
            case .success(.editable(let draft)):
                if loaded?.path == path, case .editor(let editor) = loaded?.content,
                   !editor.dirty, !editor.saving {
                    editor.refreshIfClean(from: draft)
                    return
                }
                content = .editor(model.editor(at: path, draft: draft))
            case .success(.readOnly(let document)):
                if loaded?.path == path, case .readOnly(let previous) = loaded?.content,
                   document.matchesSource(previous) { return }
                content = .readOnly(document)
            case .success(.unsupported):
                content = .unsupported
            case .failure(let error):
                content = .failed(error.localizedDescription)
            }
        }
        loaded = ProjectFilePreview.Loaded(path: path, content: content)
    }

    private enum FileRead: Sendable {
        case editable(WorktreeFileDraft), readOnly(DiffDocument), unsupported
    }
}

private struct InlineCodeEditor: NSViewRepresentable {
    let buffer: InlineFileBuffer
    let text: String
    let colors: DiffColors
    let syntax: DiffSyntax?
    let editable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(buffer: buffer, displayedText: text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        // The surrounding SwiftUI surface already paints the editor background.
        scroll.drawsBackground = false
        let text = CodeTextView(usingTextLayoutManager: false)
        text.drawsBackground = false
        // Let AppKit lay out the visible lines without walking the whole file.
        text.layoutManager?.allowsNonContiguousLayout = true
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.font = DiffCellView.font
        text.string = self.text
        text.textContainerInset = NSSize(width: 11, height: 8)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = true
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = text.maxSize
        text.setAccessibilityLabel("Содержимое файла")
        text.delegate = context.coordinator
        text.prepareHighlighting = { [weak coordinator = context.coordinator] text in
            coordinator?.highlight(text)
        }
        text.save = { [weak buffer] in buffer?.saveNow() }
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.viewportChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? CodeTextView else { return }
        let coordinator = context.coordinator
        let styleChanged = coordinator.syntax != syntax || coordinator.colors != colors
        let contentChanged = !coordinator.displayedText.hasSameFileBytes(as: self.text)
        if text.isEditable != editable { text.isEditable = editable }
        if styleChanged || coordinator.colors == nil {
            text.textColor = colors.text
            text.insertionPointColor = colors.text
        }
        if contentChanged {
            let selection = text.selectedRange()
            text.string = self.text
            coordinator.displayedText = self.text
            let length = (text.string as NSString).length
            text.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            text.undoManager?.removeAllActions()
        }
        coordinator.syntax = syntax
        coordinator.colors = colors
        if styleChanged || contentChanged { coordinator.highlight(text, reset: true, clear: styleChanged) }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: NSView.boundsDidChangeNotification,
                                                 object: scroll.contentView)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        private let buffer: InlineFileBuffer
        var colors: DiffColors?
        var syntax: DiffSyntax?

        var displayedText: String
        private var highlightedLines: NSRange?

        init(buffer: InlineFileBuffer, displayedText: String) {
            self.buffer = buffer
            self.displayedText = displayedText
        }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            displayedText = text.string
            buffer.replaceText(displayedText)
            highlightedLines = nil
            highlight(text)
        }

        @objc func viewportChanged(_ notification: Notification) {
            guard let clip = notification.object as? NSClipView, let text = clip.documentView as? NSTextView else { return }
            highlight(text)
        }

        func highlight(_ text: NSTextView, reset: Bool = false, clear: Bool = false) {
            guard let layout = text.layoutManager, let container = text.textContainer,
                  let string = text.textStorage?.string, !string.isEmpty else { return }
            if reset { highlightedLines = nil }
            if clear {
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: string.utf16.count))
            }
            guard let syntax, let colors else { return }
            let origin = text.textContainerOrigin
            let bounds = text.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
            guard !bounds.isEmpty else { return }
            let glyphs = layout.glyphRange(forBoundingRect: bounds, in: container)
            let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let nsString = string as NSString
            guard characters.length > 0, NSMaxRange(characters) <= nsString.length else { return }
            let lines = nsString.lineRange(for: characters)
            guard highlightedLines != lines else { return }
            highlightedLines = lines
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: lines)
            nsString.enumerateSubstrings(in: lines, options: .byLines) { line, range, _, _ in
                guard let line else { return }
                for token in syntax.tokens(in: line) {
                    let target = NSRange(location: range.location + token.range.location, length: token.range.length)
                    layout.addTemporaryAttribute(.foregroundColor, value: colors.syntaxInk(token.kind), forCharacterRange: target)
                }
            }
        }
    }

    private final class CodeTextView: NSTextView {
        var prepareHighlighting: ((NSTextView) -> Void)?
        var save: (() -> Void)?

        override func viewWillDraw() {
            prepareHighlighting?(self)
            super.viewWillDraw()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self, isEditable,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "s" {
                save?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}

private struct CodeFileHeading: View {
    let file: GitFile
    let pending: Bool
    let loadingLabel: String
    let colors: DiffColors

    var body: some View {
        HStack(spacing: 7) {
            Text(file.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !file.directory.isEmpty {
                Text(file.directory)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: colors.muted))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            DeferredVisibility(isPending: pending) { showProgress in
                ZStack {
                    if showProgress {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color(nsColor: colors.muted))
                            .scaleEffect(0.65)
                            .accessibilityLabel(loadingLabel)
                    }
                }
                .frame(width: 25, height: 23)
            }
        }
        .help(file.path)
        .padding(.horizontal, WorkbenchLayout.panelInset)
        .frame(height: WorkbenchLayout.panelHeaderHeight)
        .background(Color(nsColor: colors.chrome))
    }
}

private struct DiffSplitGeometry {
    static let lineWidth: CGFloat = 1
    static let handleWidth: CGFloat = 11
    let width: CGFloat

    var available: CGFloat { max(0, width - Self.lineWidth) }
    var limits: ClosedRange<CGFloat> {
        let minimum = floor(min(112, available / 2))
        return minimum...max(minimum, floor(available - minimum))
    }

    func leftWidth(for fraction: Double) -> CGFloat {
        let preferred = fraction.isFinite ? fraction : 0.5
        return floor(clamp(CGFloat(preferred) * available))
    }

    func fraction(at position: CGFloat) -> Double {
        available > 0 ? Double(clamp(position) / available) : 0.5
    }

    private func clamp(_ position: CGFloat) -> CGFloat {
        min(max(position, limits.lowerBound), limits.upperBound)
    }
}

private struct DiffColumnsLayout<Content: View>: View {
    let canResize: Bool
    let colors: DiffColors
    @ViewBuilder let content: (CGFloat) -> Content
    @AppStorage("branchline.diff.splitFraction") private var fraction = 0.5
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let geometry = DiffSplitGeometry(width: proxy.size.width)
            let leftWidth = geometry.leftWidth(for: dragFraction ?? fraction)
            content(leftWidth)
                .overlay(alignment: .leading) {
                    if canResize && geometry.limits.lowerBound < geometry.limits.upperBound {
                        DiffSplitHandle(position: leftWidth, geometry: geometry, colors: colors) { position, finished in
                            let updated = geometry.fraction(at: position)
                            if finished {
                                fraction = updated
                                dragFraction = nil
                            } else {
                                dragFraction = updated
                            }
                        }
                        .frame(width: DiffSplitGeometry.handleWidth, height: proxy.size.height)
                        .offset(x: leftWidth + (DiffSplitGeometry.lineWidth - DiffSplitGeometry.handleWidth) / 2)
                    }
                }
        }
        .onChange(of: canResize) { _, enabled in
            if !enabled { dragFraction = nil }
        }
    }
}

private struct DiffSplitHandle: NSViewRepresentable {
    let position: CGFloat
    let geometry: DiffSplitGeometry
    let colors: DiffColors
    let move: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> DiffSplitHandleView { DiffSplitHandleView() }

    func updateNSView(_ view: DiffSplitHandleView, context: Context) {
        view.configure(position: position, geometry: geometry, colors: colors, move: move)
    }
}

private final class DiffSplitHandleView: NSView {
    private var position: CGFloat = 0
    private var geometry = DiffSplitGeometry(width: 0)
    private var colors = DiffColors.islandsDark
    private var move: ((CGFloat, Bool) -> Void)?
    private var dragStart: (pointer: CGFloat, position: CGFloat)?
    private var hasDragged = false
    private var tracking: NSTrackingArea?
    private var hovered = false

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Разделитель сравнения")
        setAccessibilityHelp("Перетащите или используйте стрелки. Двойной щелчок возвращает равные колонки.")
        toolTip = "Потяните вправо, чтобы расширить левую колонку, или влево, чтобы расширить правую. Двойной щелчок делит ширину поровну."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func configure(position: CGFloat, geometry: DiffSplitGeometry, colors: DiffColors,
                   move: @escaping (CGFloat, Bool) -> Void) {
        self.position = position
        self.geometry = geometry
        if self.colors != colors { needsDisplay = true }
        self.colors = colors
        self.move = move
        setAccessibilityValue(percent(at: position))
        setAccessibilityMinValue(percent(at: geometry.limits.lowerBound))
        setAccessibilityMaxValue(percent(at: geometry.limits.upperBound))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        (hovered || focused ? NSColor(Palette.focusBorder) : colors.separator).setFill()
        NSRect(x: floor(bounds.midX), y: 0, width: DiffSplitGeometry.lineWidth, height: bounds.height).fill()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        hasDragged = false
        if event.clickCount == 2 {
            dragStart = nil
            move?(geometry.available / 2, true)
        } else {
            dragStart = (event.locationInWindow.x, position)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        hasDragged = true
        drag(with: event, finished: false)
    }

    override func mouseUp(with event: NSEvent) {
        if hasDragged { drag(with: event, finished: true) }
        dragStart = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow: _ = accessibilityPerformDecrement()
        case .rightArrow: _ = accessibilityPerformIncrement()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { adjust(by: 1) }
    override func accessibilityPerformDecrement() -> Bool { adjust(by: -1) }

    private func drag(with event: NSEvent, finished: Bool) {
        guard let dragStart else { return }
        let translation = event.locationInWindow.x - dragStart.pointer
        move?(dragStart.position + translation, finished)
    }

    private func adjust(by direction: CGFloat) -> Bool {
        guard let move else { return false }
        move(position + direction * max(12, geometry.available * 0.05), true)
        return true
    }

    private func percent(at position: CGFloat) -> Int {
        Int((geometry.fraction(at: position) * 100).rounded())
    }
}

private struct DiffPreviewKey: Equatable {
    let path: String
    let identity: FileFocus.ID?

    func keepsViewport(for target: DiffPreviewKey) -> Bool {
        guard path == target.path else { return false }
        return identity == target.identity ||
            (identity?.context.isWorkingFile == true && target.identity?.context.isWorkingFile == true)
    }
}

private struct DiffPreviewTarget: Equatable {
    let focus: FileFocus
    let oldLabel: String
    let newLabel: String

    var file: GitFile { focus.file }
    var key: DiffPreviewKey { DiffPreviewKey(path: focus.file.path, identity: focus.id) }
}

private struct DiffPreviewRequest: Equatable {
    let target: DiffPreviewTarget
    let patch: String?
    let position: DiffFilePosition?
}

private struct DiffPreview {
    let target: DiffPreviewTarget
    let patch: String
    let position: DiffFilePosition?
    let document: DiffDocument
}

struct DiffSource: Sendable {
    let patch: String
    fileprivate let document: DiffDocument

    static func parse(_ patch: String) async -> Self {
        let parser = Task.detached(priority: .userInitiated) { DiffDocument(patch: patch) }
        let document = await withTaskCancellationHandler {
            await parser.value
        } onCancel: {
            parser.cancel()
        }
        return Self(patch: patch, document: document)
    }
}

private enum DiffDirection: Sendable {
    case previous, next

    var offset: Int { self == .previous ? -1 : 1 }
    var blockShortcut: KeyboardShortcut { self == .previous ? GitKeymap.previousDifference : GitKeymap.nextDifference }
}

private enum DiffShortcut: Sendable {
    case block(DiffDirection)
    case file(DiffDirection)

    private static let bindings: [(KeyboardShortcut, DiffShortcut)] = [
        (GitKeymap.previousDifference, .block(.previous)),
        (GitKeymap.nextDifference, .block(.next)),
        (GitKeymap.previousFile, .file(.previous)),
        (GitKeymap.nextFile, .file(.next)),
        (KeyboardShortcut(.upArrow, modifiers: [.command, .option]), .block(.previous)),
        (KeyboardShortcut(.downArrow, modifiers: [.command, .option]), .block(.next)),
    ]

    init?(event: NSEvent) {
        guard let character = event.charactersIgnoringModifiers?.first else { return nil }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        var modifiers: EventModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        guard let match = Self.bindings.first(where: { $0.0.key.character == character && $0.0.modifiers == modifiers }) else {
            return nil
        }
        self = match.1
    }
}

private struct DiffShortcutHost: NSViewRepresentable {
    let action: (DiffShortcut) -> Bool

    func makeNSView(context: Context) -> DiffShortcutView { DiffShortcutView() }

    func updateNSView(_ view: DiffShortcutView, context: Context) { view.action = action }

    static func dismantleNSView(_ view: DiffShortcutView, coordinator: Void) {
        view.stopMonitoring()
    }
}

private final class DiffShortcutView: NSView {
    var action: ((DiffShortcut) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow,
                  (event.window ?? NSApp.keyWindow) === window, !self.isHiddenOrHasHiddenAncestor,
                  let command = DiffShortcut(event: event) else { return event }
            if let editor = window.firstResponder as? NSTextView, editor.isEditable { return event }
            // Only separate key presses can confirm crossing a file boundary.
            if event.isARepeat { return nil }
            return self.action?(command) == true ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private enum DiffLayout: String, Sendable {
    case split, unified
}

private struct DiffJump: Equatable {
    let id = UUID()
    let index: Int
}

private enum DiffLineKind: Sendable {
    case source, context, addition, deletion, hunk, metadata

    var label: String {
        switch self {
        case .source: "Код"
        case .context: "Контекст"
        case .addition: "Добавлено"
        case .deletion: "Удалено"
        case .hunk: "Блок изменений"
        case .metadata: "Метаданные"
        }
    }

    var marker: String {
        switch self {
        case .addition: "+"
        case .deletion: "−"
        default: ""
        }
    }
}

private struct DiffLine: Sendable {
    let kind: DiffLineKind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?

    var hunkContext: Substring? {
        let fields = text.split(separator: " ", maxSplits: 4)
        return fields.count == 5 ? fields[4] : nil
    }
}

private struct DiffRow: Sendable {
    let textRange: Range<String.Index>?
    let oldPosition: Int
    let newPosition: Int
    let kind: DiffLineKind

    init(kind: DiffLineKind, textRange: Range<String.Index>?, oldNumber: Int? = nil, newNumber: Int? = nil) {
        self.kind = kind
        self.textRange = textRange
        self.oldPosition = oldNumber ?? -1
        self.newPosition = newNumber ?? -1
    }
}

private struct DiffPair: Sendable {
    // A preview contains at most 8,000 rows, so its row indices fit in 16 bits.
    private let oldIndex: UInt16?
    private let newIndex: UInt16?

    init(old: Int?, new: Int?) {
        oldIndex = old.map(UInt16.init)
        newIndex = new.map(UInt16.init)
    }

    var old: Int? { oldIndex.map(Int.init) }
    var new: Int? { newIndex.map(Int.init) }
}

private struct DiffHunk: Sendable {
    let unifiedRow: Int
    let splitRow: Int

    func row(in layout: DiffLayout) -> Int {
        layout == .split ? splitRow : unifiedRow
    }
}

private struct DiffDocument: Sendable {
    static let previewLineLimit = 8_000
    static let longLineLimit = 3_000
    private static let newlineNote = "Нет перевода строки в конце файла"

    let id = UUID()
    // Store ranges into a shared patch. Only requested rows need their own text.
    private let patch: String
    private let rows: [DiffRow]
    let pairs: [DiffPair]
    let hunks: [DiffHunk]
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let isSource: Bool
    let isTruncated: Bool
    let longestLine: Int
    let numberDigits: Int

    init(patch: String) {
        var rows: [DiffRow] = []
        var pairs: [DiffPair] = []
        var hunks: [DiffHunk] = []
        var removed: [Int] = []
        var inserted: [Int] = []
        var pendingNotes: [DiffPair] = []
        var oldNumber = 0
        var newNumber = 0
        var oldRemaining = 0
        var newRemaining = 0
        var additions = 0
        var deletions = 0
        var isBinary = false
        var isTruncated = false
        var longestLine = 0
        var largestNumber = 0

        func flushChanges() {
            for index in 0..<max(removed.count, inserted.count) {
                pairs.append(DiffPair(
                    old: index < removed.count ? removed[index] : nil,
                    new: index < inserted.count ? inserted[index] : nil
                ))
            }
            pairs.append(contentsOf: pendingNotes)
            removed.removeAll(keepingCapacity: true)
            inserted.removeAll(keepingCapacity: true)
            pendingNotes.removeAll(keepingCapacity: true)
        }

        func append(_ line: DiffRow, columns: Int) {
            let row = rows.count
            rows.append(line)
            longestLine = max(longestLine, min(columns, Self.longLineLimit * 4))
            largestNumber = max(largestNumber, line.oldPosition, line.newPosition)
            if columns > Self.longLineLimit { isTruncated = true }
            switch line.kind {
            case .deletion:
                removed.append(row)
            case .addition:
                inserted.append(row)
            default:
                flushChanges()
                pairs.append(DiffPair(old: row, new: row))
            }
        }

        func append(_ kind: DiffLineKind, text: Substring, oldNumber: Int? = nil, newNumber: Int? = nil) {
            let range = text.startIndex..<text.endIndex
            let columns = text.utf16.count + 3 * text.utf8.lazy.filter { $0 == 9 }.count
            append(DiffRow(kind: kind, textRange: range, oldNumber: oldNumber, newNumber: newNumber), columns: columns)
        }

        patch.enumerateSubstrings(in: patch.startIndex..<patch.endIndex, options: [.byLines, .substringNotRequired]) { _, range, _, stop in
            if Task.isCancelled {
                stop = true
                return
            }
            if rows.count >= Self.previewLineLimit {
                isTruncated = true
                stop = true
                return
            }
            let line = patch[range]
            if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                isBinary = true
                return
            }
            if let header = DiffDocument.hunkHeader(line) {
                flushChanges()
                oldNumber = header.old.start
                newNumber = header.new.start
                oldRemaining = header.old.count
                newRemaining = header.new.count
                hunks.append(DiffHunk(unifiedRow: rows.count, splitRow: pairs.count))
                if line.split(separator: " ", maxSplits: 4).count == 5 {
                    append(.hunk, text: line)
                }
                return
            }
            if oldRemaining > 0 || newRemaining > 0, let prefix = line.first {
                let contents = line.dropFirst()
                switch prefix {
                case " " where oldRemaining > 0 && newRemaining > 0:
                    append(.context, text: contents, oldNumber: oldNumber, newNumber: newNumber)
                    oldNumber += 1
                    newNumber += 1
                    oldRemaining -= 1
                    newRemaining -= 1
                    return
                case "-" where oldRemaining > 0:
                    append(.deletion, text: contents, oldNumber: oldNumber)
                    oldNumber += 1
                    oldRemaining -= 1
                    deletions += 1
                    return
                case "+" where newRemaining > 0:
                    append(.addition, text: contents, newNumber: newNumber)
                    newNumber += 1
                    newRemaining -= 1
                    additions += 1
                    return
                default:
                    break
                }
            }
            if line == "\\ No newline at end of file", let previous = rows.last {
                let note = DiffRow(kind: .metadata, textRange: nil)
                if previous.kind == .deletion || previous.kind == .addition {
                    let index = rows.count
                    rows.append(note)
                    longestLine = max(longestLine, Self.newlineNote.utf16.count)
                    if previous.kind == .addition, let last = pendingNotes.last, last.new == nil {
                        pendingNotes[pendingNotes.count - 1] = DiffPair(old: last.old, new: index)
                    } else {
                        pendingNotes.append(DiffPair(old: previous.kind == .deletion ? index : nil,
                                                     new: previous.kind == .addition ? index : nil))
                    }
                } else {
                    append(note, columns: Self.newlineNote.utf16.count)
                }
            } else if !line.isEmpty, !line.hasPrefix("diff --git "), !line.hasPrefix("index "),
                      !line.hasPrefix("--- "), !line.hasPrefix("+++ ") {
                append(.metadata, text: line)
            }
        }
        flushChanges()
        self.patch = patch
        self.rows = rows
        self.pairs = pairs
        self.hunks = hunks
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.isSource = false
        self.isTruncated = isTruncated
        self.longestLine = longestLine
        self.numberDigits = max(3, String(largestNumber).count)
    }

    init(source: String, truncated: Bool) {
        var rows: [DiffRow] = []
        var longestLine = 0
        var isTruncated = truncated
        source.enumerateSubstrings(in: source.startIndex..<source.endIndex, options: [.byLines, .substringNotRequired]) { _, range, _, stop in
            if Task.isCancelled || rows.count >= Self.previewLineLimit {
                isTruncated = true
                stop = true
                return
            }
            let line = source[range]
            let columns = line.utf16.count + 3 * line.utf8.lazy.filter { $0 == 9 }.count
            longestLine = max(longestLine, min(columns, Self.longLineLimit * 4))
            if columns > Self.longLineLimit { isTruncated = true }
            rows.append(DiffRow(kind: .source, textRange: range, oldNumber: rows.count + 1))
        }
        self.patch = source
        self.rows = rows
        self.pairs = []
        self.hunks = []
        self.additions = 0
        self.deletions = 0
        self.isBinary = false
        self.isSource = true
        self.isTruncated = isTruncated
        self.longestLine = longestLine
        self.numberDigits = max(3, String(rows.count).count)
    }

    func matchesSource(_ other: DiffDocument) -> Bool {
        isTruncated == other.isTruncated && patch.utf8.elementsEqual(other.patch.utf8)
    }

    var rowCount: Int { rows.count }

    func line(at index: Int) -> DiffLine {
        let row = rows[index]
        return DiffLine(kind: row.kind, text: row.textRange.map { String(patch[$0]) } ?? Self.newlineNote,
                        oldNumber: row.oldPosition >= 0 ? row.oldPosition : nil,
                        newNumber: row.newPosition >= 0 ? row.newPosition : nil)
    }

    func matchesLine(at row: Int, layout: DiffLayout, right: Bool, previous: DiffDocument) -> Bool {
        guard let index = lineIndex(at: row, layout: layout, right: right),
              let previousIndex = previous.lineIndex(at: row, layout: layout, right: right) else { return false }
        let line = rows[index]
        let prior = previous.rows[previousIndex]
        guard line.kind == prior.kind, line.oldPosition == prior.oldPosition, line.newPosition == prior.newPosition else {
            return false
        }
        switch (line.textRange, prior.textRange) {
        case let (range?, priorRange?):
            return patch[range].utf8.elementsEqual(previous.patch[priorRange].utf8)
        case (nil, nil): return true
        default: return false
        }
    }

    private func lineIndex(at row: Int, layout: DiffLayout, right: Bool) -> Int? {
        if layout == .unified { return rows.indices.contains(row) ? row : nil }
        guard pairs.indices.contains(row) else { return nil }
        return right ? pairs[row].new : pairs[row].old
    }

    private static func hunkHeader(_ line: Substring) -> (old: (start: Int, count: Int), new: (start: Int, count: Int))? {
        guard line.hasPrefix("@@ ") else { return nil }
        let parts = line.split(separator: " ", maxSplits: 4)
        guard parts.count >= 4, parts[3] == "@@", parts[1].first == "-", parts[2].first == "+",
              let old = hunkRange(parts[1]), let new = hunkRange(parts[2]) else { return nil }
        return (old, new)
    }

    private static func hunkRange(_ part: Substring) -> (Int, Int)? {
        let bounds = part.dropFirst().split(separator: ",", maxSplits: 1)
        guard let first = bounds.first, let start = Int(first), start >= 0 else { return nil }
        let count = bounds.count == 1 ? 1 : Int(bounds[1])
        guard let count, count >= 0, start <= Int.max - count else { return nil }
        return (start, count)
    }

    func hunkIndex(at row: Int, in mode: DiffLayout) -> Int {
        var low = 0
        var high = hunks.count
        while low < high {
            let middle = (low + high) / 2
            if hunks[middle].row(in: mode) <= row {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(0, low - 1)
    }
}

private struct DiffColors: Equatable {
    static let islandsDark = DiffColors()

    let canvas = NSColor(Palette.base)
    let chrome = NSColor(Palette.control)
    let separator = NSColor(Palette.stroke)
    let text = NSColor(Color(hex: 0xBCBEC4))
    let muted = NSColor(Palette.muted)

    private let selected = NSColor(Palette.selection)
    private let selectedMuted = NSColor(Palette.selectionMuted)
    let addedInk = NSColor(Palette.green)
    let removedInk = NSColor(Palette.red)

    private let addedLine = NSColor(Color(hex: 0x192C20))
    private let removedLine = NSColor(Color(hex: 0x3F1E21))
    private let addedGutter = NSColor(Color(hex: 0x203B2A))
    private let removedGutter = NSColor(Color(hex: 0x56272B))
    private let addedHighlight = NSColor(Color(hex: 0x4E9D6C).opacity(0.08))
    private let removedHighlight = NSColor(Color(hex: 0xE4656E).opacity(0.08))

    private let keyword = NSColor(Color(hex: 0xCF8E6D))
    private let string = NSColor(Color(hex: 0x6AAB73))
    private let number = NSColor(Color(hex: 0x2AACB8))
    private let property = NSColor(Palette.pink)
    private let type = NSColor(Color(hex: 0x9C9CFF))
    private let tag = NSColor(Color(hex: 0xD5B778))

    func background(_ kind: DiffLineKind?) -> NSColor {
        switch kind {
        case .addition: addedLine
        case .deletion: removedLine
        case .hunk: selectedMuted
        case .metadata, .none: chrome
        default: canvas
        }
    }

    func gutterBackground(_ kind: DiffLineKind) -> NSColor? {
        switch kind {
        case .addition: addedGutter
        case .deletion: removedGutter
        default: nil
        }
    }

    func ink(_ kind: DiffLineKind) -> NSColor {
        switch kind {
        case .addition: addedInk
        case .deletion: removedInk
        default: muted
        }
    }

    func syntaxInk(_ kind: DiffSyntax.Kind) -> NSColor {
        switch kind {
        case .keyword: keyword
        case .string: string
        case .number: number
        case .property: property
        case .comment: muted
        case .type: type
        case .tag: tag
        }
    }

    func changeHighlight(_ kind: DiffLineKind) -> NSColor {
        kind == .addition ? addedHighlight : removedHighlight
    }

    func selectedBackground(over base: NSColor, focused: Bool) -> NSColor {
        base.blended(withFraction: focused ? 0.20 : 0.12, of: selected) ?? base
    }
}

private struct DiffTableSurface: NSViewRepresentable {
    let preview: DiffPreview?
    let isShowing: Bool
    let mode: DiffLayout
    let colors: DiffColors
    let splitLeftWidth: CGFloat
    let syntax: DiffSyntax?
    let jump: DiffJump?
    let focusRequest: UInt?
    let onFocus: (UInt) -> Void
    let onScroll: (Int) -> Void

    func makeNSView(context: Context) -> DiffSurfaceView {
        DiffSurfaceView()
    }

    func updateNSView(_ view: DiffSurfaceView, context: Context) {
        view.setSplitLeftWidth(splitLeftWidth)
        view.isHidden = !isShowing
        if let preview {
            view.configure(document: preview.document, key: preview.target.key, mode: mode, colors: colors,
                           oldLabel: preview.target.oldLabel, newLabel: preview.target.newLabel, syntax: syntax,
                           onScroll: onScroll)
        } else {
            view.clear()
        }
        if isShowing, let jump { view.goToHunk(jump) }
        view.requestKeyboardFocus(isShowing ? focusRequest : nil, onFocus: onFocus)
    }
}

private struct ProjectFileTable: NSViewRepresentable {
    let document: DiffDocument
    let path: String
    let colors: DiffColors
    let syntax: DiffSyntax?

    func makeNSView(context: Context) -> DiffSurfaceView { DiffSurfaceView() }

    func updateNSView(_ view: DiffSurfaceView, context: Context) {
        view.configure(document: document, key: DiffPreviewKey(path: path, identity: nil), mode: .unified,
                       colors: colors, oldLabel: "Содержимое файла", newLabel: "", syntax: syntax, onScroll: { _ in })
    }
}

private final class DiffSurfaceView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let left = DiffTableView()
    private let right = DiffTableView()
    private let leftScroll = NSScrollView()
    private let rightScroll = NSScrollView()
    private var document: DiffDocument?
    private var previewKey: DiffPreviewKey?
    private var mode = DiffLayout.split
    private var splitLeftWidth: CGFloat?
    private var colors = DiffColors.islandsDark
    private var syntax: DiffSyntax?
    private var performedJump: UUID?
    private var syncing = false
    private var reportedHunk = 0
    private var lastVerticalOffset: CGFloat = 0
    private var onScroll: ((Int) -> Void)?
    private var appliedFocusRequest: UInt?
    private var pendingFocus: (id: UInt, onFocus: (UInt) -> Void)?

    init() {
        super.init(frame: .zero)
        install(left, in: leftScroll)
        install(right, in: rightScroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPendingFocus()
    }

    func clear() {
        guard document != nil else { return }
        document = nil
        previewKey = nil
        performedJump = nil
        for table in [left, right] { table.reloadData() }
    }

    func setSplitLeftWidth(_ width: CGFloat) {
        guard width != splitLeftWidth else { return }
        splitLeftWidth = width
        if mode == .split { needsLayout = true }
    }

    func requestKeyboardFocus(_ request: UInt?, onFocus: @escaping (UInt) -> Void) {
        guard let id = request else {
            pendingFocus = nil
            return
        }
        guard appliedFocusRequest != id, pendingFocus?.id != id else { return }
        pendingFocus = (id, onFocus)
        applyPendingFocus()
    }

    private func applyPendingFocus() {
        guard window != nil, let id = pendingFocus?.id else { return }
        Task { @MainActor [weak self] in
            guard let self, let pending = self.pendingFocus, pending.id == id,
                  self.focusVisibleCode() else { return }
            self.pendingFocus = nil
            self.appliedFocusRequest = id
            pending.onFocus(id)
        }
    }

    private func focusVisibleCode() -> Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        layoutSubtreeIfNeeded()
        let tables = mode == .unified ? [left] : window.firstResponder === left ? [left, right] : [right, left]
        let changedTables = tables.compactMap { table in
            table.visibleRows.first { index in
                let kind = lines(at: index, in: table).0?.kind
                return kind == .addition || kind == .deletion
            }.map { (table, $0) }
        }
        let candidates = changedTables + tables.compactMap { table in
            table.firstSelectableVisibleRow.map { (table, $0) }
        }
        for (table, row) in candidates {
            guard window.makeFirstResponder(table) else { continue }
            table.selectVisibleRowIfNeeded(row)
            return true
        }
        return window.makeFirstResponder(tables[0])
    }

    func configure(document: DiffDocument, key: DiffPreviewKey? = nil, mode: DiffLayout, colors: DiffColors,
                   oldLabel: String, newLabel: String, syntax: DiffSyntax? = nil, onScroll: @escaping (Int) -> Void) {
        self.onScroll = onScroll
        left.setAccessibilityLabel(mode == .split || document.isSource ? oldLabel : "Сравнение файлов")
        right.setAccessibilityLabel(newLabel)
        let previous = self.document
        let changedDocument = document.id != previous?.id
        let changedFile = key != previewKey
        let changedLayout = mode != self.mode
        guard changedDocument || changedFile || changedLayout || colors != self.colors || syntax != self.syntax else { return }
        let keepViewport = !changedLayout && previewKey.flatMap { prior in key.map { prior.keepsViewport(for: $0) } } == true
        let leftOrigin = leftScroll.contentView.bounds.origin
        let rightOrigin = rightScroll.contentView.bounds.origin
        syncing = true
        defer { syncing = false }
        self.document = document
        previewKey = key
        self.mode = mode
        self.colors = colors
        self.syntax = syntax
        for scroll in [leftScroll, rightScroll] { scroll.backgroundColor = colors.canvas }
        for table in [left, right] {
            table.backgroundColor = colors.canvas
            var selection = IndexSet()
            if !changedFile, !changedLayout, let previous {
                if !changedDocument {
                    selection = table.selectedRowIndexes
                } else {
                    let rightColumn = table === right
                    for row in table.selectedRowIndexes where document.matchesLine(at: row, layout: mode,
                                                                                  right: rightColumn, previous: previous) {
                        selection.insert(row)
                    }
                }
            }
            table.reloadData()
            table.selectRowIndexes(selection, byExtendingSelection: false)
        }
        leftScroll.hasVerticalScroller = mode == .unified
        rightScroll.isHidden = mode == .unified
        needsLayout = true
        if changedDocument || changedFile {
            performedJump = nil
            if keepViewport {
                layoutSubtreeIfNeeded()
                scrollView(leftScroll, to: leftOrigin)
                scrollView(rightScroll, to: rightOrigin)
                reportedHunk = -1
                reportVisibleHunk(at: leftScroll.contentView.bounds.minY, document: document)
            } else {
                reportedHunk = 0
                lastVerticalOffset = 0
                for scroll in [leftScroll, rightScroll] { scrollView(scroll, to: .zero) }
            }
        }
    }

    func goToHunk(_ jump: DiffJump) {
        guard performedJump != jump.id, let document, document.hunks.indices.contains(jump.index) else { return }
        performedJump = jump.id
        reportedHunk = jump.index
        syncing = true
        defer { syncing = false }
        let target = document.hunks[jump.index].row(in: mode)
        layoutSubtreeIfNeeded()
        let y = left.rect(ofRow: target).minY
        for scroll in [leftScroll, rightScroll] {
            scrollView(scroll, to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
        }
        lastVerticalOffset = leftScroll.contentView.bounds.minY
    }

    override func layout() {
        super.layout()
        let split = mode == .split
        let geometry = DiffSplitGeometry(width: bounds.width)
        let width = split ? min(splitLeftWidth ?? geometry.leftWidth(for: 0.5), geometry.available) : bounds.width
        leftScroll.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        if split {
            rightScroll.frame = NSRect(x: width + DiffSplitGeometry.lineWidth, y: 0,
                                       width: geometry.available - width, height: bounds.height)
        }
        guard let document else { return }
        let gutters = CGFloat(document.numberDigits) * DiffCellView.glyphWidth + 13
        let gutterColumns: CGFloat = split || document.isSource ? 1 : 2
        let contentWidth = CGFloat(document.longestLine) * DiffCellView.glyphWidth + gutters * gutterColumns + 40
        for (table, scroll) in [(left, leftScroll), (right, rightScroll)] {
            let tableWidth = ceil(max(scroll.contentSize.width, contentWidth))
            guard table.tableColumns[0].width != tableWidth else { continue }
            table.tableColumns[0].width = tableWidth
            table.setFrameSize(NSSize(width: tableWidth, height: table.frame.height))
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let document, tableView !== right || mode == .split else { return 0 }
        return mode == .split ? document.pairs.count : document.rowCount
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("DiffSelectionRow")
        if let reusable = tableView.makeView(withIdentifier: id, owner: nil) as? DiffSelectionRow {
            return reusable
        }
        let view = DiffSelectionRow()
        view.identifier = id
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let document else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("DiffSourceCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffCellView ?? DiffCellView()
        cell.identifier = identifier
        let (line, opposite) = lines(at: row, in: tableView)
        cell.configure(line: line, opposite: opposite, mode: mode, isRight: tableView === right,
                       numberDigits: document.numberDigits, colors: colors, syntax: syntax)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard let line = lines(at: row, in: tableView).0 else { return false }
        return line.kind != .hunk
    }

    private func install(_ table: DiffTableView, in scroll: NSScrollView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Code"))
        column.minWidth = 1
        column.maxWidth = 100_000
        column.resizingMask = []
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.focusRingType = .none
        table.allowsMultipleSelection = true
        table.rowHeight = DiffCellView.rowHeight
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.sourceLines = { [weak self, weak table] indexes in
            guard let self, let table else { return "" }
            return indexes.compactMap { row in
                guard let line = self.lines(at: row, in: table).0, line.kind != .hunk else { return nil }
                return line.text
            }.joined(separator: "\n")
        }
        scroll.documentView = table
        scroll.focusRingType = .none
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(clipDidScroll(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    @objc private func clipDidScroll(_ notification: Notification) {
        guard !syncing, let clip = notification.object as? NSClipView, let document else { return }
        syncing = true
        defer { syncing = false }
        let y = clip.bounds.minY
        if mode == .split {
            let other = clip === leftScroll.contentView ? rightScroll : leftScroll
            if abs(other.contentView.bounds.minY - y) > 0.5 {
                scrollView(other, to: NSPoint(x: other.contentView.bounds.minX, y: y))
            }
        }
        guard abs(lastVerticalOffset - y) > 0.5 else { return }
        reportVisibleHunk(at: y, document: document)
    }

    private func reportVisibleHunk(at y: CGFloat, document: DiffDocument) {
        lastVerticalOffset = y
        let firstRow = Int(max(0, y) / DiffCellView.rowHeight)
        let index = document.hunkIndex(at: firstRow, in: mode)
        guard reportedHunk != index else { return }
        reportedHunk = index
        Task { @MainActor [weak self] in
            guard let self, self.document?.id == document.id, self.reportedHunk == index else { return }
            self.onScroll?(index)
        }
    }

    private func scrollView(_ scroll: NSScrollView, to point: NSPoint) {
        let clip = scroll.contentView
        let target = clip.constrainBoundsRect(NSRect(origin: point, size: clip.bounds.size)).origin
        clip.scroll(to: target)
        scroll.reflectScrolledClipView(clip)
    }

    private func lines(at row: Int, in table: NSTableView) -> (DiffLine?, DiffLine?) {
        guard let document else { return (nil, nil) }
        if mode == .unified {
            guard (0..<document.rowCount).contains(row) else { return (nil, nil) }
            return (document.line(at: row), nil)
        }
        guard document.pairs.indices.contains(row) else { return (nil, nil) }
        let pair = document.pairs[row]
        let old = pair.old.map { document.line(at: $0) }
        let new = pair.new.map { document.line(at: $0) }
        return table === right ? (new, old) : (old, new)
    }
}

private final class DiffTableView: NSTableView {
    var sourceLines: ((IndexSet) -> String)?
    var hasKeyboardFocus: Bool { window?.firstResponder === self }

    var visibleRows: Range<Int> {
        let range = rows(in: visibleRect)
        guard range.location != NSNotFound, range.location < numberOfRows else { return 0..<0 }
        return range.location..<min(NSMaxRange(range), numberOfRows)
    }

    var firstSelectableVisibleRow: Int? {
        visibleRows.first { delegate?.tableView?(self, shouldSelectRow: $0) != false }
    }

    func selectVisibleRowIfNeeded(_ row: Int) {
        if !selectedRowIndexes.intersects(integersIn: visibleRows) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            if let row = firstSelectableVisibleRow { selectVisibleRowIfNeeded(row) }
            redrawSelection()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { redrawSelection() }
        return accepted
    }

    private func redrawSelection() {
        enumerateAvailableRowViews { view, _ in
            guard view.isSelected else { return }
            for child in view.subviews { child.needsDisplay = true }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0, delegate?.tableView?(self, shouldSelectRow: clicked) != false else { return nil }
        if !selectedRowIndexes.contains(clicked) { selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false) }
        guard selectedRowIndexes.contains(clicked) else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Скопировать строки", action: #selector(copyRows(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c",
           !selectedRowIndexes.isEmpty {
            copyRows(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc(copy:) private func copyRows(_ sender: Any?) {
        guard !selectedRowIndexes.isEmpty, let text = sourceLines?(selectedRowIndexes) else { return }
        copyDiffText(text)
    }
}

private final class DiffSelectionRow: NSTableRowView {
    override var isSelected: Bool {
        didSet { for view in subviews { view.needsDisplay = true } }
    }
}

private final class DiffCellView: NSView {
    static let rowHeight: CGFloat = 20
    static let font: NSFont = {
        if let url = Bundle.main.url(forResource: "JetBrainsMonoNL-Regular", withExtension: "ttf"),
           let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [NSFontDescriptor],
           let descriptor = descriptors.first, let font = NSFont(descriptor: descriptor, size: 12) {
            return font
        }
        return .monospacedSystemFont(ofSize: 12, weight: .regular)
    }()
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    static let markerFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let glyphWidth = ("0" as NSString).size(withAttributes: [.font: font]).width

    private var line: DiffLine?
    private var opposite: DiffLine?
    private var mode = DiffLayout.split
    private var isRight = false
    private var numberDigits = 3
    private var colors = DiffColors.islandsDark
    private var syntax: DiffSyntax?
    private var source: Source?

    private enum Source {
        case plain(String)
        case styled(NSAttributedString)
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func configure(line: DiffLine?, opposite: DiffLine?, mode: DiffLayout, isRight: Bool,
                   numberDigits: Int, colors: DiffColors, syntax: DiffSyntax? = nil) {
        self.line = line
        self.opposite = opposite
        self.mode = mode
        self.isRight = isRight
        self.numberDigits = numberDigits
        self.colors = colors
        self.syntax = syntax
        source = nil
        if let line {
            let showHeader = mode == .unified || !isRight
            setAccessibilityElement(line.kind != .hunk || showHeader)
            let number = (isRight ? line.newNumber : line.oldNumber) ?? line.newNumber
            setAccessibilityRole(.staticText)
            if line.kind == .source, let number {
                setAccessibilityLabel("Строка \(number)")
            } else {
                setAccessibilityLabel(number.map { "Строка \($0). \(line.kind.label)" } ?? line.kind.label)
            }
            if line.kind == .hunk {
                setAccessibilityValue(line.hunkContext.map(String.init))
            } else {
                setAccessibilityValue(line.text)
            }
        } else {
            setAccessibilityElement(false)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = colors.background(line?.kind)
        let selected = (superview as? NSTableRowView)?.isSelected == true
        let focused = (enclosingScrollView?.documentView as? DiffTableView)?.hasKeyboardFocus == true
        (selected ? colors.selectedBackground(over: background, focused: focused) : background).setFill()
        dirtyRect.fill()
        guard let line else { return }
        if line.kind == .hunk {
            if (mode == .unified || !isRight), let context = line.hunkContext {
                (String(context) as NSString).draw(at: NSPoint(x: 10, y: 4), withAttributes: [.font: Self.numberFont, .foregroundColor: colors.muted])
            }
            return
        }
        let gutterWidth = CGFloat(numberDigits) * Self.glyphWidth + 13
        let foreground = colors.ink(line.kind)
        let columns: [Int?]
        if line.kind == .source {
            columns = [line.oldNumber]
        } else if mode == .unified {
            columns = [line.oldNumber, line.newNumber]
        } else {
            columns = [isRight ? line.newNumber : line.oldNumber]
        }
        let gutter = colors.gutterBackground(line.kind)
        for (index, number) in columns.enumerated() {
            guard let number else { continue }
            let gutterX = CGFloat(index) * gutterWidth
            if let gutter {
                (selected ? colors.selectedBackground(over: gutter, focused: focused) : gutter).setFill()
                NSRect(x: gutterX, y: 0, width: gutterWidth, height: bounds.height).fill()
            }
            let label = String(number) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.numberFont, .foregroundColor: gutter == nil ? foreground : colors.text]
            let rightEdge = gutterX + gutterWidth - 8
            label.draw(at: NSPoint(x: rightEdge - label.size(withAttributes: attributes).width, y: 4), withAttributes: attributes)
        }
        let markerX = CGFloat(columns.count) * gutterWidth
        (line.kind.marker as NSString).draw(at: NSPoint(x: markerX, y: 3), withAttributes: [.font: Self.markerFont, .foregroundColor: foreground])
        let contentX = line.kind == .metadata ? 10 : markerX + (line.kind == .source ? 5 : 17)
        drawSource(line, at: NSPoint(x: contentX, y: 3))
    }

    private func drawSource(_ line: DiffLine, at point: NSPoint) {
        let ink = line.kind == .metadata ? colors.ink(line.kind) : colors.text
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: ink]
        if source == nil {
            source = prepareSource(line, attributes: attributes)
        }
        switch source {
        case .plain(let text): (text as NSString).draw(at: point, withAttributes: attributes)
        case .styled(let text): text.draw(at: point)
        case nil: break
        }
    }

    private func prepareSource(_ line: DiffLine, attributes: [NSAttributedString.Key: Any]) -> Source {
        let expanded = expandTabs(line.text, limit: DiffDocument.longLineLimit)
        let tokens = line.kind == .metadata ? [] : (syntax?.tokens(in: expanded) ?? [])
        var changed: NSRange?
        if mode == .split, let opposite, opposite.kind != line.kind,
           line.text.utf16.count <= 512, opposite.text.utf16.count <= 512 {
            changed = changeRange(in: expanded, comparedTo: expandTabs(opposite.text, limit: DiffDocument.longLineLimit))
        }
        guard !tokens.isEmpty || changed != nil else { return .plain(expanded) }
        let attributed = NSMutableAttributedString(string: expanded, attributes: attributes)
        if let changed {
            attributed.addAttribute(.backgroundColor, value: colors.changeHighlight(line.kind), range: changed)
        }
        for token in tokens {
            attributed.addAttribute(.foregroundColor, value: colors.syntaxInk(token.kind), range: token.range)
        }
        return .styled(attributed)
    }

    private func expandTabs(_ line: String, limit: Int) -> String {
        let prefix = line.prefix(limit)
        let clipped = prefix.endIndex != line.endIndex
        guard prefix.utf8.contains(9) else { return clipped ? String(prefix) + "…" : line }
        var expanded = ""
        var column = 0
        for character in prefix {
            if character == "\t" {
                let spaces = 4 - column % 4
                expanded.append(String(repeating: " ", count: spaces))
                column += spaces
            } else {
                expanded.append(character)
                column += 1
            }
        }
        if clipped { expanded.append("…") }
        return expanded
    }

    private func changeRange(in line: String, comparedTo other: String) -> NSRange? {
        var start = line.startIndex
        var otherStart = other.startIndex
        while start != line.endIndex, otherStart != other.endIndex, line[start] == other[otherStart] {
            line.formIndex(after: &start)
            other.formIndex(after: &otherStart)
        }
        var end = line.endIndex
        var otherEnd = other.endIndex
        while end != start, otherEnd != otherStart {
            let last = line.index(before: end)
            let otherLast = other.index(before: otherEnd)
            guard line[last] == other[otherLast] else { break }
            end = last
            otherEnd = otherLast
        }
        return start < end ? NSRange(start..<end, in: line) : nil
    }
}

@MainActor
private func copyDiffText(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
