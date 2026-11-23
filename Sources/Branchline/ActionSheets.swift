import SwiftUI

struct NameSheet: View {
    let title: String
    let prompt: String
    let submit: String
    let icon: String
    let subtitle: String
    var showCheckout = false
    var allowEmpty = false
    var initialValue = ""
    let action: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var checkout = true
    @FocusState private var focused: Bool

    private var name: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { allowEmpty || (!name.isEmpty && name != initialValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GitSheetHeading(title: title, icon: icon)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                Text(prompt).font(.system(size: 12, weight: .medium))
                TextField(prompt, text: $text, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(Palette.base, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Palette.accentBorder : Palette.stroke) }
                    .focused($focused)
            }
            if showCheckout { Toggle("Переключиться на новую ветку", isOn: $checkout) }
            GitSheetButtons(title: submit, enabled: canSubmit) {
                dismiss()
                action(name, checkout)
            }
        }
        .padding(16)
        .frame(width: 390)
        .foregroundStyle(Palette.text)
        .background(Palette.panel)
        .onAppear { text = initialValue; focused = true }
    }
}

struct PushSheet: View {
    let branch: String
    let upstream: String?
    let remotes: [String]
    let load: (String?) async throws -> GitPushPreview
    let action: (GitPushPreview) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRemote: String?
    @State private var result: Result<GitPushPreview, Error>?

    private var remote: String? { selectedRemote ?? (remotes.contains("origin") ? "origin" : remotes.first) }
    private var target: String? { upstream ?? remote.map { "\($0)/\(branch)" } }

    private var preview: GitPushPreview? {
        guard case .success(let preview) = result,
              upstream != nil || preview.remote == remote else { return nil }
        return preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GitSheetHeading(title: "Отправить коммиты", icon: "arrow.up")
            if upstream == nil, remotes.count > 1 {
                Picker("Удалённый репозиторий", selection: Binding(
                    get: { remote ?? "" },
                    set: { selectedRemote = $0; result = nil }
                )) {
                    ForEach(remotes, id: \.self) { Text($0).tag($0) }
                }
            }
            if let target {
                route(to: target)
                if let preview {
                    commitList(preview)
                } else if case .failure(let error) = result {
                    note(error.localizedDescription)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        note("Читаем список коммитов")
                    }
                }
            } else {
                note("Добавьте удалённый репозиторий в настройках Git.")
            }
            GitSheetButtons(title: "Отправить", enabled: preview?.canPush == true) {
                guard let preview else { return }
                dismiss()
                action(preview)
            }
        }
        .padding(16)
        .frame(width: 500)
        .foregroundStyle(Palette.text)
        .background(Palette.panel)
        .task(id: target) {
            guard target != nil else { return }
            do {
                let preview = try await load(upstream == nil ? remote : nil)
                try Task.checkCancellation()
                result = .success(preview)
            } catch {
                if !Task.isCancelled { result = .failure(error) }
            }
        }
    }

    private func route(to target: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(branch).textSelection(.enabled)
            Image(systemName: "arrow.right")
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            Text(target)
                .foregroundStyle(Palette.accent)
                .textSelection(.enabled)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Из ветки \(branch) в \(target)")
    }

    @ViewBuilder private func commitList(_ preview: GitPushPreview) -> some View {
        if preview.commits.isEmpty {
            note(preview.upstream == nil ? "Будет опубликована ветка." : "Коммитов к отправке нет.")
        } else {
            let count = "\(preview.commits.count)\(preview.hasMore ? "+" : "")"
            Text("Коммиты · \(count)")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .vertical) {
                commitRows(preview.commits)
                ScrollView { commitRows(preview.commits) }
            }
            .frame(maxHeight: 238)
            .background(Palette.base, in: RoundedRectangle(cornerRadius: 6))
        }
        if preview.requiresUpdate {
            if preview.upstream == nil {
                note("Одноимённая ветка на сервере содержит другие коммиты. Сначала настройте её отслеживание и обновите локальную ветку.")
            } else {
                note("В удалённой ветке есть изменения. Выполните Fetch и Update Project перед отправкой.")
            }
        } else if preview.destinationHead == nil && !preview.commits.isEmpty {
            note("Список рассчитан по последним полученным данным с сервера.")
        }
    }

    private func commitRows(_ commits: [GitCommit]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(commits, id: \.hash) { commit in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(commit.shortHash)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                    Text(commit.subject.isEmpty ? "Без сообщения" : commit.subject)
                        .font(.system(size: 12))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(commit.subject)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .textSelection(.enabled)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ResetSheet: View {
    let branch: String
    let hash: String
    let subject: String
    let action: (GitResetMode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode = GitResetMode.soft
    @State private var confirmsHardReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GitSheetHeading(title: "Сбросить ветку к коммиту", icon: "arrow.counterclockwise")
            VStack(alignment: .leading, spacing: 5) {
                Text("\(branch) → \(hash)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.accent)
                Text(subject)
                    .font(.system(size: 13))
                    .lineLimit(3)
                    .help(subject)
            }
            .textSelection(.enabled)

            Picker("Режим сброса", selection: $mode) {
                ForEach(GitResetMode.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Режим сброса")
            .onChange(of: mode) { _, _ in confirmsHardReset = false }

            Text(explanation)
                .font(.system(size: 12))
                .foregroundStyle(mode == .hard ? Palette.yellow : Palette.muted)
                .frame(minHeight: 47, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            if mode == .hard {
                Toggle("Удалить незакоммиченные изменения", isOn: $confirmsHardReset)
                    .font(.system(size: 12))
            }
            GitSheetButtons(title: mode == .hard ? "Сбросить (Hard)" : "Сбросить",
                            enabled: mode != .hard || confirmsHardReset, destructive: mode == .hard) {
                dismiss()
                action(mode)
            }
        }
        .padding(16)
        .frame(width: 430)
        .foregroundStyle(Palette.text)
        .background(Palette.panel)
    }

    private var explanation: String {
        switch mode {
        case .soft: "Перенесёт ветку к выбранному коммиту. Файлы и индекс сохранятся, поэтому изменения из снятых коммитов обычно останутся в индексе."
        case .mixed: "Перенесёт ветку и индекс к выбранному коммиту. Файлы сохранятся, а их изменения станут неиндексированными."
        case .hard: "Приведёт файлы и индекс к выбранному коммиту. Удалит незакоммиченные правки и может затронуть мешающие неотслеживаемые файлы."
        case .keep: "Сохранит локальные правки и вернёт остальные файлы к выбранному коммиту. При пересечении изменений Git остановит сброс."
        }
    }
}

private struct GitSheetHeading: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

private struct GitSheetButtons: View {
    let title: String
    let enabled: Bool
    var destructive = false
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Отмена", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(StudioButton())
            if destructive {
                Button(title, role: .destructive, action: action)
                    .buttonStyle(StudioButton())
                    .disabled(!enabled)
            } else {
                Button(title, action: action)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(StudioButton(kind: .primary))
                    .disabled(!enabled)
            }
        }
    }
}
