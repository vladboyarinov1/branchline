import SwiftUI

struct GitAction: Identifiable {
    var id: String { title }
    let title: String
    let detail: String
    let icon: String
    var shortcut: KeyboardShortcut? = nil
    var enabled = true
    let run: () -> Void
}

extension GitTracking {
    var isEmpty: Bool { ahead == 0 && behind == 0 }

    var accessibilitySummary: String {
        [ahead > 0 ? "К отправке: \(ahead)" : nil, behind > 0 ? "Входящих: \(behind)" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

struct BranchSyncBadge: View {
    let tracking: GitTracking

    var body: some View {
        HStack(spacing: 5) {
            if tracking.ahead > 0 {
                count(tracking.ahead, icon: "arrow.up.right", color: Palette.green)
            }
            if tracking.behind > 0 {
                count(tracking.behind, icon: "arrow.down.left", color: Palette.blue)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func count(_ value: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8, weight: .semibold))
            Text(value.formatted()).font(.system(size: 10, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(color)
    }
}

struct GitActionPicker: View {
    let title: String
    let actions: [GitAction]
    let select: (GitAction) -> Void
    @State private var query = ""
    @State private var selection: String?

    private var visible: [GitAction] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return actions.filter { action in
            terms.allSatisfy { "\(action.title) \(action.detail)".localizedCaseInsensitiveContains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                GitPickerSearch(prompt: title, query: $query, move: move, submit: apply)
                DismissGitPicker()
            }
            .padding(8)
            if visible.isEmpty {
                EmptyPanel(icon: "magnifyingglass", title: "Нет подходящих команд")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(visible) { action in
                                GitPickerAction(action: action, isSelected: selection == action.id, select: select)
                                    .id(action.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .onChange(of: selection) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(width: 500, height: 420)
        .foregroundStyle(Palette.text)
        .background(Palette.panel)
        .workbenchHints()
        .onChange(of: query, initial: true) { _, _ in selection = visible.first(where: \.enabled)?.id }
    }

    private func move(_ offset: Int) {
        let available = visible.filter(\.enabled)
        guard !available.isEmpty else { return }
        let index = available.firstIndex { $0.id == selection } ?? 0
        selection = available[max(0, min(index + offset, available.count - 1))].id
    }

    private func apply() {
        if let action = visible.first(where: { $0.id == selection && $0.enabled }) { select(action) }
    }
}

struct GitBranchPicker: View {
    let refs: [GitRef]
    let actions: (GitRef) -> [GitAction]
    let create: () -> Void
    let select: (GitAction) -> Void
    var canCreate = true
    @State private var query = ""
    @State private var selection: String?

    private var filtered: [GitRef] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return refs }
        return refs.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        let candidates = filtered
        let chosen = candidates.first { $0.id == selection }
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                GitPickerSearch(prompt: "Найти ветку или тег", query: $query, move: move) { apply(chosen) }
                Button(action: create) { Label("New Branch…", systemImage: "plus") }
                    .buttonStyle(StudioButton())
                    .disabled(!canCreate)
                    .workbenchHint("Создать ветку от HEAD")
                DismissGitPicker()
            }
            if candidates.isEmpty {
                EmptyPanel(icon: "arrow.triangle.branch", title: refs.isEmpty ? "Нет веток и тегов" : "Ветки и теги не найдены")
            } else {
                HStack(spacing: 8) {
                    ScrollViewReader { proxy in
                        List(selection: $selection) {
                            section("Local", kind: .local, candidates: candidates)
                            section("Remote", kind: .remote, candidates: candidates)
                            section("Tags", kind: .tag, candidates: candidates)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
                        .onKeyPress(.return) { apply(chosen); return .handled }
                    }
                    .background(Palette.base, in: RoundedRectangle(cornerRadius: 6))
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if let chosen {
                                ForEach(actions(chosen)) { action in
                                    GitPickerAction(action: action, select: select)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(width: 245)
                    .background(Palette.base, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(8)
        .frame(width: 560, height: 420)
        .foregroundStyle(Palette.text)
        .background(Palette.panel)
        .workbenchHints()
        .onChange(of: candidates, initial: true) { _, next in
            if !next.contains(where: { $0.id == selection }) {
                selection = next.first(where: \.isCurrent)?.id ?? next.first?.id
            }
        }
    }

    @ViewBuilder private func section(_ title: String, kind: GitRefKind, candidates: [GitRef]) -> some View {
        let refs = candidates.filter { $0.kind == kind }
        if !refs.isEmpty {
            Section(title) {
                ForEach(refs) { ref in
                    HStack(spacing: 8) {
                        Label(ref.name, systemImage: ref.isCurrent ? "checkmark" : (kind == .tag ? "tag" : "arrow.triangle.branch"))
                        Spacer(minLength: 3)
                        if !ref.tracking.isEmpty { BranchSyncBadge(tracking: ref.tracking) }
                    }
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(ref.name)
                        .accessibilityValue([ref.isCurrent ? "Текущая ветка" : "", ref.tracking.accessibilitySummary]
                            .filter { !$0.isEmpty }.joined(separator: ", "))
                        .help(ref.name)
                        .tag(ref.id)
                        .contextMenu {
                            ForEach(actions(ref)) { action in
                                Button { select(action) } label: { Label(action.title, systemImage: action.icon) }
                                    .disabled(!action.enabled)
                            }
                        }
                }
            }
        }
    }

    private func move(_ offset: Int) {
        let candidates = filtered
        guard !candidates.isEmpty else { return }
        let index = candidates.firstIndex { $0.id == selection } ?? 0
        selection = candidates[max(0, min(index + offset, candidates.count - 1))].id
    }

    private func apply(_ ref: GitRef?) {
        if let ref, let action = actions(ref).first(where: \.enabled) { select(action) }
    }
}

private struct GitPickerAction: View {
    let action: GitAction
    var isSelected = false
    let select: (GitAction) -> Void

    var body: some View {
        Button { select(action) } label: {
            HStack(spacing: 8) {
                Image(systemName: action.icon)
                    .foregroundStyle(action.enabled ? Palette.muted : Palette.disabled)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(action.title)
                Spacer(minLength: 4)
                if let shortcut = action.shortcut {
                    Text(GitKeymap.display(shortcut))
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(action.enabled ? Palette.muted : Palette.disabled)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioButton(kind: .quiet))
        .background(isSelected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
        .disabled(!action.enabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .workbenchHint(action.detail, shortcut: action.shortcut)
        .accessibilityHint(action.detail)
    }
}

private struct GitPickerSearch: View {
    let prompt: String
    @Binding var query: String
    let move: (Int) -> Void
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            TextField(prompt, text: $query, prompt: Text(prompt).foregroundStyle(Palette.muted))
                .textFieldStyle(.plain)
                .focused($focused)
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onSubmit(submit)
            if !query.isEmpty {
                Button {
                    query = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.muted)
                        .frame(width: 20, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить поиск")
                .workbenchHint("Очистить поиск")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Palette.base, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Palette.accentBorder : Palette.stroke) }
        .onAppear { focused = true }
    }
}

private struct DismissGitPicker: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button(role: .cancel) { dismiss() } label: {
            Image(systemName: "xmark")
                .frame(width: 14)
        }
        .buttonStyle(StudioButton(kind: .quiet))
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Закрыть")
        .workbenchHint("Закрыть · Esc")
    }
}
