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
    let ahead: Int?
    let remotes: [String]
    let action: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""

    private var target: String? {
        upstream ?? (remotes.contains(remote) ? "\(remote)/\(branch)" : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GitSheetHeading(title: "Отправить коммиты", icon: "arrow.up")
            if upstream != nil {
                route
                if let ahead {
                    Text("Коммитов к отправке по локальным данным · \(ahead)")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            } else if !remotes.isEmpty {
                Picker("Удалённый репозиторий", selection: $remote) {
                    ForEach(remotes, id: \.self) { Text($0).tag($0) }
                }
                route
                Text("Git настроит отслеживание после первой отправки.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            } else {
                Text("Добавьте адрес удалённого репозитория в настройках Git.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GitSheetButtons(title: "Отправить", enabled: target != nil) {
                dismiss()
                action(upstream == nil ? remote : nil)
            }
        }
        .padding(16)
        .frame(width: 420)
        .foregroundStyle(Palette.text)
        .background(Palette.panel)
        .onAppear {
            remote = remotes.contains("origin") ? "origin" : remotes.first ?? ""
        }
    }

    @ViewBuilder private var route: some View {
        if let target {
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
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Отмена", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(StudioButton())
            Button(title, action: action)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(StudioButton(kind: .primary))
                .disabled(!enabled)
        }
    }
}
