import AppKit
import SwiftUI

struct HistoryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let parents: [String]
    let subject: String
    let author: String
    let date: Date
    let refs: [String]
    var isMerge = false
    var syncDirection: GitSyncDirection? = nil
}

struct HistoryAction {
    let title: String
    let systemImage: String
    let run: () -> Void
}

struct HistoryView: View {
    var entries: [HistoryEntry]
    var title: String
    @Binding var search: String
    @Binding var selection: String?
    var hasMore: Bool
    var isLoading: Bool
    var loadMore: (_ retrying: Bool) -> Void
    var authorFilter: Binding<String>? = nil
    var showDiff: ((HistoryEntry) -> Void)? = nil
    var commitActions: ((HistoryEntry) -> [HistoryAction])? = nil
    var branchesVisible = true
    var toggleBranches: (() -> Void)? = nil
    var clearFileFilter: (() -> Void)? = nil
    var fileFilter: String? = nil
    var isReplacing = false
    var loadError: String? = nil
    var pageError: String? = nil
    var scopeID: String? = nil
    var retryLoad: (() -> Void)? = nil

    @FocusState private var searchFocused: Bool
    @FocusState private var authorFocused: Bool
    @State private var showAuthorFilter = false
    @State private var authorDraft = ""
    @State private var lastPresentedScope: HistoryScope?
    @State private var loadingIndicatorVisible = false

    var body: some View {
        let scope = requestedScope
        let presented = isReplacing ? (lastPresentedScope ?? scope) : scope
        GeometryReader { geometry in
            let columns = HistoryColumns(width: geometry.size.width, showsGraph: !presented.filtered)
            VStack(spacing: 0) {
                toolbar(width: geometry.size.width)
                ZStack {
                    commitList(columns, scope: presented)
                        .accessibilityHidden(entries.isEmpty || isReplacing)
                    if entries.isEmpty { emptyState }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { paginationStatus }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.panel)
        .onChange(of: isReplacing ? nil : scope, initial: true) { _, presented in
            if let presented { lastPresentedScope = presented }
        }
        .task(id: isWaiting) {
            loadingIndicatorVisible = false
            guard isWaiting else { return }
            try? await Task.sleep(for: .milliseconds(260))
            if !Task.isCancelled { loadingIndicatorVisible = true }
        }
    }

    private var isWaiting: Bool { isLoading || isReplacing }

    private var author: String {
        authorFilter?.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var requestedScope: HistoryScope {
        HistoryScope(reference: scopeID, title: title, query: search.trimmingCharacters(in: .whitespacesAndNewlines),
                     author: author, path: fileFilter)
    }

    private func toolbar(width: CGFloat) -> some View {
        let compact = width < 460
        let scoped = title != "Все ветки"
        let showsScope = scoped && !compact && fileFilter == nil

        return HStack(spacing: 8) {
            if let toggleBranches {
                branchPaneControl(action: toggleBranches)
            }

            searchBox(scopeInPrompt: scoped && !showsScope && fileFilter == nil)
                .frame(maxWidth: showsScope ? 318 : .infinity)

            if showsScope {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                    .help(title)
                    .accessibilityLabel("История \(title)")
                Spacer(minLength: 0)
            }

            if let fileFilter, let clearFileFilter {
                fileFilterControl(fileFilter, compact: compact, clear: clearFileFilter)
            }

            if authorFilter != nil {
                authorControl(compact: compact)
            }

        }
        .padding(.horizontal, HistoryColumns.inset)
        .padding(.vertical, 5)
    }

    private func branchPaneControl(action: @escaping () -> Void) -> some View {
        let label = branchesVisible ? "Скрыть ветки" : "Показать ветки"
        return Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(branchesVisible ? Palette.text : Palette.muted)
        }
        .buttonStyle(StudioButton(kind: .quiet))
        .background(branchesVisible ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
        .workbenchHint(label)
        .accessibilityLabel(label)
    }

    private func fileFilterControl(_ path: String, compact: Bool, clear: @escaping () -> Void) -> some View {
        let name = (path as NSString).lastPathComponent
        return Button(action: clear) {
            HStack(spacing: 4) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .fixedSize()
                    .layoutPriority(1)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Palette.accent)
            .frame(maxWidth: compact ? 73 : 131)
        }
        .buttonStyle(StudioButton(kind: .quiet))
        .background(Palette.selection, in: RoundedRectangle(cornerRadius: 5))
        .workbenchHint("Снять фильтр по файлу \(path)")
        .accessibilityLabel("Снять фильтр по файлу")
        .accessibilityValue(path)
    }

    private func searchBox(scopeInPrompt: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                searchFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(searchFocused ? Palette.accent : Palette.muted)
                    .frame(width: 16, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(WorkbenchPlainButton())
            .keyboardShortcut("f", modifiers: .command)
            .workbenchHint("Поиск коммитов", shortcut: GitKeymap.focusCommitSearch)
            .accessibilityLabel("Перейти к поиску коммитов")

            TextField(
                "Поиск коммитов", text: $search,
                prompt: Text(scopeInPrompt ? "Поиск в \(title)" : "Сообщение или хеш")
                    .foregroundStyle(Palette.text.opacity(0.76))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Palette.text)
            .help("Поиск по сообщению или хешу · \(title)")
            .accessibilityLabel("Поиск коммитов по сообщению или хешу")
            .accessibilityHint(title)
            .focused($searchFocused)
            .onExitCommand {
                if search.isEmpty { searchFocused = false }
                else { search = "" }
            }

            ZStack {
                if !search.isEmpty {
                    Button {
                        search = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.muted)
                            .font(.system(size: 12))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(WorkbenchPlainButton())
                    .workbenchHint("Очистить поиск")
                    .accessibilityLabel("Очистить поиск")
                }
            }
            .frame(width: 20, height: 20)
        }
        .padding(.horizontal, 7)
        .frame(minWidth: 115, maxWidth: .infinity)
        .frame(height: 27)
        .background(Palette.base, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            if searchFocused {
                RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.accent)
            }
        }
    }

    private func authorControl(compact: Bool) -> some View {
        let iconOnly = compact
        return Button {
            authorDraft = author
            showAuthorFilter.toggle()
        } label: {
            HStack(spacing: 5) {
                if iconOnly {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 15)
                        .accessibilityHidden(true)
                } else {
                    Text(author.isEmpty ? "Автор" : author).lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(author.isEmpty ? Palette.text : Palette.accent)
            .frame(width: compact ? 15 : 108, alignment: .trailing)
        }
        .buttonStyle(StudioButton(kind: .quiet))
        .background {
            if !author.isEmpty || showAuthorFilter {
                RoundedRectangle(cornerRadius: 5).fill(Palette.selection)
            }
        }
        .workbenchHint(author.isEmpty ? "Фильтр по автору" : "Фильтр по автору · \(author)")
        .accessibilityLabel("Фильтр по автору")
        .accessibilityValue(author.isEmpty ? "Все авторы" : author)
        .popover(isPresented: $showAuthorFilter) { authorPopover }
    }

    private var authorPopover: some View {
        let names = Set(entries.lazy.map(\.author).filter { !$0.isEmpty })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let query = authorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestions = names.lazy.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.prefix(8)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                TextField("Фильтр по автору", text: $authorDraft,
                          prompt: Text("Имя или email").foregroundStyle(Palette.muted))
                    .textFieldStyle(.roundedBorder)
                    .focused($authorFocused)
                    .onSubmit { applyAuthor(authorDraft) }
                Button("Применить") { applyAuthor(authorDraft) }
                    .buttonStyle(StudioButton(kind: .primary))
            }
            authorOption("Все авторы", value: "")
            ForEach(Array(suggestions), id: \.self) { name in
                authorOption(name, value: name)
            }
        }
        .padding(12)
        .frame(width: 280)
        .foregroundStyle(Palette.text)
        .background(Palette.panel)
        .defaultFocus($authorFocused, true)
    }

    private func authorOption(_ title: String, value: String) -> some View {
        let selected = value == author
        return Button {
            applyAuthor(value)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 12)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
                Text(title).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(StudioButton(kind: .quiet))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func applyAuthor(_ value: String) {
        authorFilter?.wrappedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        showAuthorFilter = false
    }

    private func commitList(_ columns: HistoryColumns, scope: HistoryScope) -> some View {
        ReusableHistoryTable(entries: entries, columns: columns, selection: $selection,
                             showDiff: showDiff, commitActions: commitActions, scope: scope, isReplacing: isReplacing,
                             loadMore: hasMore && !isWaiting && pageError == nil ? { loadMore(false) } : nil)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if isWaiting {
                if loadingIndicatorVisible {
                    ProgressView().controlSize(.small).accessibilityLabel("Загрузка истории")
                }
            } else if let loadError {
                Text("Не удалось загрузить историю")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .help(loadError)
                    .accessibilityHint(loadError)
                if let retryLoad {
                    Button("Повторить", action: retryLoad)
                        .buttonStyle(.link)
                        .tint(Palette.accent)
                }
            } else {
                Text(requestedScope.filtered ? "Коммиты не найдены" : "В истории пока нет коммитов")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
                if requestedScope.filtered {
                    Button("Сбросить фильтры") {
                        search = ""
                        applyAuthor("")
                        if fileFilter != nil { clearFileFilter?() }
                    }
                    .buttonStyle(.link)
                    .tint(Palette.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    @ViewBuilder private var paginationStatus: some View {
        if !entries.isEmpty && isWaiting && loadingIndicatorVisible {
            ProgressView().controlSize(.mini)
                .padding(6)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 5))
                .padding(4)
                .accessibilityLabel("Загрузка истории")
                .allowsHitTesting(false)
        } else if !entries.isEmpty, !isWaiting, let pageError {
            Button("Повторить загрузку коммитов") { loadMore(true) }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(StudioButton())
                .help(pageError)
                .padding(4)
        }
    }
}

private struct HistoryScope: Equatable {
    let reference: String?
    let title: String
    let query: String
    let author: String
    let path: String?

    var filtered: Bool { !query.isEmpty || !author.isEmpty || path != nil }
}

private struct HistoryColumns: Equatable {
    static let inset: CGFloat = 11
    static let spacing: CGFloat = 8
    static let rowHeight: CGFloat = 27

    let width: CGFloat
    let showsGraph: Bool

    var graphLanes = 1
    var preferredAuthorWidth: CGFloat = 140

    var graph: CGFloat { showsGraph ? CGFloat(max(0, graphLanes - 1)) * 8 + 16 : 0 }
    private var fixedWidth: CGFloat {
        graph + (graph > 0 ? Self.spacing : 0) + Self.inset * 2 + Self.spacing * 2 + date
    }
    var author: CGFloat { min(preferredAuthorWidth, max(60, floor((width - fixedWidth) * 0.3))) }
    var layoutWidth: CGFloat { max(width, fixedWidth + author + 100) }
    var message: CGFloat { layoutWidth - fixedWidth - author }
    var date: CGFloat { 91 }
    var refCount: Int {
        if message >= 250 { return 2 }
        return message >= 140 ? 1 : 0
    }
    var refWidth: CGFloat { min(130, (message - 86) / CGFloat(max(1, refCount))) }
}

private enum HistoryColors {
    static let neutralLabel = Palette.control
    static let tagLabel = Palette.lavender.opacity(38.0 / 255)
    static let branch: [Color] = [
        Palette.green, Palette.blue, Palette.yellow, Palette.lavender, Palette.red, Palette.pink
    ]
}

private struct HistoryRow: View, Equatable {
    var entry: HistoryEntry
    var graphRow: HistoryGraph.Row?
    var columns: HistoryColumns
    var selected: Bool

    private static let locale = Locale(identifier: "ru_RU")
    private static let date = Date.FormatStyle(locale: locale).day().month(.abbreviated)
    private static let dateWithYear = date.year(.twoDigits)
    private static let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
    private static let timestamp = Date.FormatStyle(date: .long, time: .shortened, locale: locale)
    private static let refFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)

    private var subject: String { entry.subject.isEmpty ? "Без сообщения" : entry.subject }

    var body: some View {
        HStack(spacing: HistoryColumns.spacing) {
            if columns.graph > 0 {
                HistoryGraphCell(row: graphRow, selected: selected, syncDirection: entry.syncDirection)
                    .frame(width: columns.graph)
                    .accessibilityHidden(true)
            }
            message
                .frame(width: columns.message, alignment: .leading)
            Text(entry.author)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(Palette.muted)
                .frame(width: columns.author, alignment: .leading)
            Text(dateText)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .frame(width: columns.date, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.horizontal, HistoryColumns.inset)
        .frame(height: HistoryColumns.rowHeight)
        .background {
            if selected {
                Palette.selection.background(Palette.panel)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var dateText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(entry.date) { return "Сегодня \(entry.date.formatted(Self.time))" }
        if calendar.isDateInYesterday(entry.date) { return "Вчера \(entry.date.formatted(Self.time))" }
        let sameYear = calendar.isDate(entry.date, equalTo: .now, toGranularity: .year)
        return entry.date.formatted(sameYear ? Self.date : Self.dateWithYear)
    }

    var toolTip: String {
        ([subject, entry.author, entry.date.formatted(Self.timestamp), entry.id] + entry.refs + syncStatus)
            .joined(separator: "\n")
    }

    var accessibilitySummary: String {
        var parts = [subject, entry.author, entry.date.formatted(Self.timestamp), "Хеш \(entry.id)"]
        parts.append(contentsOf: entry.refs + syncStatus)
        return parts.joined(separator: ", ")
    }

    private var syncStatus: [String] {
        switch entry.syncDirection {
        case .outgoing: ["Локальный коммит к отправке"]
        case .incoming: ["Входящий коммит удалённой ветки"]
        case nil: []
        }
    }

    private var message: some View {
        HStack(spacing: 5) {
            Text(subject)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(Palette.text)
                .lineLimit(1)

            if columns.refCount > 0 && !entry.refs.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(entry.refs.prefix(columns.refCount).enumerated()), id: \.offset) { _, ref in
                        refBadge(ref)
                    }
                    if entry.refs.count > columns.refCount {
                        Text("+\(entry.refs.count - columns.refCount)")
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(Palette.muted)
                            .fixedSize()
                    }
                }
                .layoutPriority(1)
            }
        }
    }

    private func refBadge(_ ref: String) -> some View {
        let isHead = ref == "HEAD" || ref.hasPrefix("HEAD -> ")
        let isTag = ref.hasPrefix("tag: ")
        let ink = isHead ? Palette.accent : (isTag ? Palette.lavender : Palette.text)
        let background = isHead ? Palette.selection : (isTag ? HistoryColors.tagLabel : HistoryColors.neutralLabel)
        let label = ref.hasPrefix("HEAD -> ") ? String(ref.dropFirst(8))
            : (isTag ? String(ref.dropFirst(5)) : ref)
        let labelWidth = ceil((label as NSString).size(withAttributes: [.font: Self.refFont]).width)
        let badgeWidth = min(columns.refWidth, labelWidth + (isTag ? 21 : 9))
        return HStack(spacing: 3) {
            if isTag {
                Image(systemName: "tag")
                    .font(.system(size: 8, weight: .medium))
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            Text(label).lineLimit(1).truncationMode(.middle)
        }
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .frame(width: badgeWidth)
            .foregroundStyle(ink)
            .background(background, in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Each active lane points to a parent waiting to appear in topological order.
struct HistoryGraph {
    static let colorCount: UInt8 = 6

    struct Row: Equatable {
        let column: Int
        let color: UInt8
        let hasIncoming: Bool
        private struct Edge: Equatable {
            let lane: Int
            let color: UInt8
        }

        // Usual histories stay inline. Allocate overflow only for unusually wide graphs.
        private var through: UInt64 = 0
        private var outgoing: UInt64 = 0
        private var extraThrough: [Edge] = []
        private var extraOutgoing: [Edge] = []
        private var outgoingCount = 0

        init(column: Int, color: UInt8, hasIncoming: Bool) {
            self.column = column
            self.color = color
            self.hasIncoming = hasIncoming
        }

        var hasMultipleOutgoing: Bool { outgoingCount > 1 }

        mutating func addThrough(_ column: Int, color: UInt8) {
            if column < 21 {
                through |= UInt64(color + 1) << (column * 3)
            } else {
                extraThrough.append(Edge(lane: column, color: color))
            }
        }

        mutating func addOutgoing(to column: Int, color: UInt8) {
            if outgoingCount < 8, column < 32 {
                let edge = (UInt8(column) << 3 | color) + 1
                outgoing |= UInt64(edge) << (outgoingCount * 8)
            } else {
                extraOutgoing.append(Edge(lane: column, color: color))
            }
            outgoingCount += 1
        }

        func forEachThrough(_ draw: (Int, UInt8) -> Void) {
            var bits = through
            var lane = 0
            while bits != 0 {
                let color = UInt8(bits & 0b111)
                if color != 0 { draw(lane, color - 1) }
                bits >>= 3
                lane += 1
            }
            for edge in extraThrough { draw(edge.lane, edge.color) }
        }

        func forEachOutgoing(_ draw: (Int, UInt8) -> Void) {
            var bits = outgoing
            while bits != 0 {
                let encoded = UInt8(truncatingIfNeeded: bits)
                if encoded != 0 {
                    let edge = encoded - 1
                    draw(Int(edge >> 3), edge & 0b111)
                }
                bits >>= 8
            }
            for edge in extraOutgoing { draw(edge.lane, edge.color) }
        }
    }

    private(set) var rows: [String: Row] = [:]
    private(set) var laneCount = 1
    private var lanes: [UInt8?] = []
    private var positions: [String: Int] = [:]
    private var nextColor: UInt8 = 0

    init(entries: [HistoryEntry] = []) {
        append(entries)
    }

    mutating func append(_ entries: some Collection<HistoryEntry>) {
        rows.reserveCapacity(rows.count + entries.count)
        for entry in entries {
            let incoming = positions.removeValue(forKey: entry.id)
            let column = incoming ?? lanes.firstIndex(where: { $0 == nil }) ?? lanes.count
            if column == lanes.count { lanes.append(nil) }
            let nodeColor: UInt8
            if let previous = lanes[column] {
                nodeColor = previous
            } else {
                nodeColor = takeColor()
            }
            lanes[column] = nil
            var row = Row(column: column, color: nodeColor, hasIncoming: incoming != nil)
            for (index, lane) in lanes.enumerated() {
                if let color = lane {
                    row.addThrough(index, color: color)
                }
            }

            for (parentIndex, parent) in entry.parents.enumerated() {
                let target: Int
                let targetColor: UInt8
                if let existing = positions[parent], let color = lanes[existing] {
                    target = existing
                    targetColor = color
                } else {
                    target = parentIndex == 0
                        ? column
                        : (lanes.firstIndex(where: { $0 == nil }) ?? lanes.count)
                    if parentIndex == 0 {
                        targetColor = nodeColor
                    } else {
                        targetColor = takeColor()
                    }
                    if target == lanes.count {
                        lanes.append(targetColor)
                    } else {
                        lanes[target] = targetColor
                    }
                    positions[parent] = target
                }
                row.addOutgoing(to: target, color: targetColor)
            }

            laneCount = max(laneCount, lanes.count)
            rows[entry.id] = row
            while let last = lanes.last, last == nil {
                lanes.removeLast()
            }
        }
    }

    private mutating func takeColor() -> UInt8 {
        let color = nextColor
        nextColor = (nextColor + 1) % Self.colorCount
        return color
    }
}

private struct HistoryGraphCell: View {
    var row: HistoryGraph.Row?
    var selected: Bool
    var syncDirection: GitSyncDirection?

    var body: some View {
        Canvas { context, size in
            guard let row else { return }
            let middle = size.height / 2
            let laneWidth: CGFloat = 1.5
            let syncColor: Color? = switch syncDirection {
            case .outgoing: Palette.green
            case .incoming: Palette.blue
            case nil: nil
            }
            let stroke = StrokeStyle(lineWidth: laneWidth, dash: syncColor == nil ? [] : [2.5, 2.5])
            func x(_ column: Int) -> CGFloat { CGFloat(column) * 8 + 8 }

            row.forEachThrough { lane, lineColor in
                let laneX = x(lane)
                let path = Path { path in
                    path.move(to: CGPoint(x: laneX, y: 0))
                    path.addLine(to: CGPoint(x: laneX, y: size.height))
                }
                context.stroke(path, with: .color(color(lineColor)), lineWidth: laneWidth)
            }
            let node = CGPoint(x: x(Int(row.column)), y: middle)
            if row.hasIncoming {
                let path = Path { path in
                    path.move(to: CGPoint(x: node.x, y: 0))
                    path.addLine(to: node)
                }
                context.stroke(path, with: .color(syncColor ?? color(row.color)), style: stroke)
            }
            row.forEachOutgoing { lane, lineColor in
                let target = CGPoint(x: x(lane), y: size.height)
                let path = Path { path in
                    path.move(to: node)
                    path.addCurve(
                        to: target,
                        control1: CGPoint(x: node.x, y: middle + 11),
                        control2: CGPoint(x: target.x, y: middle + 6)
                    )
                }
                context.stroke(path, with: .color(syncColor ?? color(lineColor)), style: stroke)
            }
            let diameter: CGFloat = row.hasMultipleOutgoing ? 7.5 : 6
            let dot = CGRect(
                x: node.x - diameter / 2, y: middle - diameter / 2, width: diameter, height: diameter
            )
            if selected {
                let ring = Path(ellipseIn: dot.insetBy(dx: -2, dy: -2))
                context.stroke(ring, with: .color(syncColor ?? color(row.color)), lineWidth: 1)
            }
            let marker = Path(ellipseIn: dot)
            if let syncColor {
                context.fill(marker, with: .color(selected ? Palette.selection : Palette.panel))
                context.stroke(marker, with: .color(syncColor), lineWidth: 1.5)
            } else {
                context.fill(marker, with: .color(color(row.color)))
            }
        }
    }

    private func color(_ index: UInt8) -> Color {
        HistoryColors.branch[Int(index)]
    }
}

private struct ReusableHistoryTable: NSViewRepresentable {
    let entries: [HistoryEntry]
    var columns: HistoryColumns
    @Binding var selection: String?
    let showDiff: ((HistoryEntry) -> Void)?
    let commitActions: ((HistoryEntry) -> [HistoryAction])?
    let scope: HistoryScope
    let isReplacing: Bool
    let loadMore: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = HistoryTableView()
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.rowHeight = HistoryColumns.rowHeight
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setAccessibilityLabel("История коммитов")
        let column = NSTableColumn(identifier: Coordinator.cellID)
        column.minWidth = 20
        column.maxWidth = CGFloat.greatestFiniteMagnitude
        column.resizingMask = []
        table.addTableColumn(column)

        let coordinator = context.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClick(_:))
        table.openSelected = { [weak coordinator, weak table] in
            guard let coordinator, let table else { return false }
            return coordinator.open(table.selectedRow)
        }
        table.makeMenu = { [weak coordinator] row in coordinator?.menu(for: row) }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.viewportDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clip)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? HistoryTableView else { return }
        context.coordinator.update(self, in: table)
        context.coordinator.prefetchIfNeeded(in: scroll)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: NSView.boundsDidChangeNotification,
                                                  object: scroll.contentView)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let cellID = NSUserInterfaceItemIdentifier("HistoryCommit")
        private var source: ReusableHistoryTable
        private var graph = HistoryGraph()
        private var updating = false
        private var initialized = false
        private var prefetchScheduled = false
        private var authorWidth: CGFloat = 140

        init(_ source: ReusableHistoryTable) { self.source = source }

        @objc func viewportDidChange(_ notification: Notification) {
            guard let clip = notification.object as? NSClipView, let scroll = clip.enclosingScrollView else { return }
            prefetchIfNeeded(in: scroll)
        }

        func prefetchIfNeeded(in scroll: NSScrollView) {
            guard !updating, !prefetchScheduled, source.loadMore != nil, nearEnd(of: scroll) else { return }
            prefetchScheduled = true
            Task { @MainActor [weak self, weak scroll] in
                guard let self else { return }
                self.prefetchScheduled = false
                guard let scroll, let loadMore = self.source.loadMore, self.nearEnd(of: scroll) else { return }
                loadMore()
            }
        }

        private func nearEnd(of scroll: NSScrollView) -> Bool {
            guard scroll.window != nil, !scroll.isHiddenOrHasHiddenAncestor,
                  let table = scroll.documentView as? HistoryTableView, table.numberOfRows > 0 else { return false }
            let visible = table.rows(in: table.visibleRect)
            return visible.location != NSNotFound && visible.length > 0
                && table.numberOfRows - NSMaxRange(visible) <= 12
        }

        func update(_ source: ReusableHistoryTable, in table: NSTableView) {
            let oldEntries = self.source.entries
            let scopeChanged = initialized && self.source.scope != source.scope
            let orderChanged = !initialized || (oldEntries != source.entries
                && !oldEntries.elementsEqual(source.entries, by: { $0.id == $1.id }))
            let appended = initialized && !scopeChanged && source.entries.count > oldEntries.count
                && source.entries.prefix(oldEntries.count).elementsEqual(oldEntries)
            if source.scope.filtered {
                if !self.source.scope.filtered { graph = HistoryGraph() }
            } else if appended {
                graph.append(source.entries.dropFirst(oldEntries.count))
            } else if orderChanged || self.source.scope.filtered {
                graph = HistoryGraph(entries: source.entries)
            }
            if !initialized || oldEntries != source.entries {
                if !appended { authorWidth = 140 }
                let entries = appended ? source.entries.dropFirst(oldEntries.count) : source.entries[...]
                let nameFont = NSFont.systemFont(ofSize: 11)
                for entry in entries {
                    let name = (entry.author as NSString).size(withAttributes: [.font: nameFont]).width
                    authorWidth = max(authorWidth, min(200, ceil(name) + 8))
                }
            }
            updating = true
            defer { updating = false }
            if scopeChanged, let scroll = table.enclosingScrollView {
                // Reset the visible anchor while the previous document geometry is still valid.
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            self.source = source
            self.source.columns.graphLanes = graph.laneCount
            self.source.columns.preferredAuthorWidth = authorWidth
            let width = ceil(self.source.columns.layoutWidth)
            if let column = table.tableColumns.first, column.width != width || table.frame.width != width {
                column.width = width
                table.setFrameSize(NSSize(width: width, height: table.frame.height))
            }
            let next = source.selection.flatMap { id in source.entries.firstIndex { $0.id == id } } ?? -1
            let interactive = !source.isReplacing
            if table.isEnabled != interactive { table.isEnabled = interactive }
            if appended {
                table.noteNumberOfRowsChanged()
            } else if orderChanged || scopeChanged {
                initialized = true
                table.reloadData()
            }
            if table.selectedRow != next {
                table.selectRowIndexes(next >= 0 ? IndexSet(integer: next) : IndexSet(), byExtendingSelection: false)
            }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            for row in visible.location..<(visible.location + visible.length) {
                guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HistoryHostedCell,
                      let newContent = cellContent(row, selected: row == next) else { continue }
                configure(view, with: newContent)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { source.entries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let content = cellContent(row, selected: tableView.selectedRow == row) else { return nil }
            let view: HistoryHostedCell
            if let reusable = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? HistoryHostedCell {
                view = reusable
                configure(view, with: content)
            } else {
                view = HistoryHostedCell(rootView: content)
                view.identifier = Self.cellID
                view.sizingOptions = []
                view.toolTip = content.toolTip
                view.setAccessibilityLabel(content.accessibilitySummary)
            }
            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, !source.isReplacing, let table = notification.object as? NSTableView else { return }
            let row = table.selectedRow
            let id = source.entries.indices.contains(row) ? source.entries[row].id : nil
            if source.selection != id { source.selection = id }
        }

        private func cellContent(_ row: Int, selected: Bool) -> HistoryRow? {
            guard source.entries.indices.contains(row) else { return nil }
            let entry = source.entries[row]
            return HistoryRow(entry: entry, graphRow: graph.rows[entry.id], columns: source.columns,
                              selected: selected)
        }

        private func configure(_ view: HistoryHostedCell, with content: HistoryRow) {
            guard view.rootView != content else { return }
            if view.rootView.entry != content.entry {
                view.toolTip = content.toolTip
                view.setAccessibilityLabel(content.accessibilitySummary)
            }
            view.rootView = content
        }

        @objc func doubleClick(_ table: NSTableView) { _ = open(table.clickedRow) }

        func open(_ index: Int) -> Bool {
            guard !source.isReplacing, let showDiff = source.showDiff,
                  source.entries.indices.contains(index) else { return false }
            showDiff(source.entries[index])
            return true
        }

        func menu(for index: Int) -> NSMenu? {
            guard !source.isReplacing, source.entries.indices.contains(index) else { return nil }
            let entry = source.entries[index]
            let menu = NSMenu()
            if let showDiff = source.showDiff {
                menu.addItem(HistoryMenuItem("Показать diff", icon: "rectangle.split.2x1") { showDiff(entry) })
            }
            menu.addItem(HistoryMenuItem("Копировать хеш коммита", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.id, forType: .string)
            })
            let actions = source.commitActions?(entry) ?? []
            if !actions.isEmpty { menu.addItem(.separator()) }
            for action in actions {
                menu.addItem(HistoryMenuItem(action.title, icon: action.systemImage, run: action.run))
            }
            return menu
        }
    }
}

private final class HistoryHostedCell: NSHostingView<HistoryRow> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let table = enclosingScrollView?.documentView as? HistoryTableView else { return false }
        return table.presentMenu(for: table.row(for: self))
    }
}

private final class HistoryTableView: NSTableView {
    var makeMenu: ((Int) -> NSMenu?)?
    var openSelected: (() -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if isEnabled { super.mouseDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func accessibilityPerformShowMenu() -> Bool {
        presentMenu(for: selectedRow)
    }

    func presentMenu(for index: Int) -> Bool {
        guard index >= 0, let menu = makeMenu?(index) else { return false }
        scrollRowToVisible(index)
        let row = rect(ofRow: index)
        menu.popUp(positioning: nil, at: NSPoint(x: row.minX + 12, y: row.midY), in: self)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if [36, 76].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           openSelected?() == true { return }
        super.keyDown(with: event)
    }
}

private final class HistoryMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, icon: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        target = self
    }

    required init(coder: NSCoder) { fatalError("HistoryMenuItem is built programmatically") }

    @objc private func invoke() { run() }
}
