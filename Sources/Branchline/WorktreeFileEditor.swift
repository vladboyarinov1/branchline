import SwiftUI

struct WorktreeFileEditor: View {
    let root: URL
    let path: String
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var draft: WorktreeFileDraft?
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(path)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            if draft != nil {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .background(Palette.base, in: RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.stroke)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("Содержимое файла")
                    .focused($focused)
                    .disabled(saving)
            } else {
                Spacer()
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(Palette.red)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button("Сохранить", action: save)
                    .keyboardShortcut(.defaultAction)
                    .keyboardShortcut("s")
                    .disabled(draft == nil || saving || text.utf8.elementsEqual(draft?.text.utf8 ?? "".utf8))
            }
        }
        .padding(16)
        .frame(minWidth: 590, idealWidth: 780, minHeight: 350, idealHeight: 510)
        .interactiveDismissDisabled(saving)
        .task {
            let root = root
            let path = path
            do {
                let document = try await Task.detached { try WorktreeFileDraft.read(root: root, path: path) }.value
                guard !Task.isCancelled else { return }
                text = document.text
                draft = document
                focused = true
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard let draft, !saving else { return }
        saving = true
        let root = root
        let path = path
        let text = text
        Task {
            defer { saving = false }
            do {
                _ = try await Task.detached { try draft.save(text, root: root, path: path) }.value
                saved()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
