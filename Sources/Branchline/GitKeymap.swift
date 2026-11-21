import AppKit
import SwiftUI

enum GitKeymap {
    static let commit = KeyboardShortcut("k")
    static let createCommit = KeyboardShortcut(.return, modifiers: .command)
    static let commitToolWindow = KeyboardShortcut("0")
    static let projectFiles = KeyboardShortcut("1")
    static let log = KeyboardShortcut("9")
    private static let f12 = KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!))
    static let terminal = KeyboardShortcut(f12, modifiers: .option)
    static let push = KeyboardShortcut("k", modifiers: [.command, .shift])
    static let commitAndPush = KeyboardShortcut("k", modifiers: [.command, .option])
    static let update = KeyboardShortcut("t")
    static let vcsOperations = KeyboardShortcut("v", modifiers: .control)
    static let findAction = KeyboardShortcut("a", modifiers: [.command, .shift])
    static let rollback = KeyboardShortcut("z", modifiers: [.command, .option])
    static let amend = KeyboardShortcut("m", modifiers: [.control, .option])
    static let stage = KeyboardShortcut("a", modifiers: [.command, .option])
    static let showDiff = KeyboardShortcut("d")
    static let focusCommitSearch = KeyboardShortcut("f")
    static let previousFile = KeyboardShortcut(.leftArrow, modifiers: [.control, .shift])
    static let nextFile = KeyboardShortcut(.rightArrow, modifiers: [.control, .shift])

    private static let f7 = KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!))
    static let previousDifference = KeyboardShortcut(f7, modifiers: .shift)
    static let nextDifference = KeyboardShortcut(f7, modifiers: [])

    static func display(_ shortcut: KeyboardShortcut) -> String {
        let symbols: [(EventModifiers, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
        ]
        let modifiers = symbols
            .filter { shortcut.modifiers.contains($0.0) }
            .map(\.1)
            .joined()
        let key: String
        switch shortcut.key {
        case f7: key = "F7"
        case f12: key = "F12"
        case .return: key = "↩"
        case .leftArrow: key = "←"
        case .rightArrow: key = "→"
        default: key = String(shortcut.key.character).uppercased()
        }
        return modifiers + key
    }
}

struct GitKeymapView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private struct Shortcut: Identifiable {
        let name: String
        let summary: String
        let shortcut: KeyboardShortcut
        var id: String { name }

        init(_ name: String, _ summary: String, _ shortcut: KeyboardShortcut) {
            self.name = name
            self.summary = summary
            self.shortcut = shortcut
        }

        func matches(_ query: String) -> Bool {
            query.isEmpty || [name, summary, GitKeymap.display(shortcut)]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private struct Group: Identifiable {
        let name: String
        let shortcuts: [Shortcut]
        var id: String { name }
    }

    private static let groups: [Group] = [
        Group(name: "Навигация", shortcuts: [
            Shortcut("Commit Tool Window", "Открыть панель изменений", GitKeymap.commitToolWindow),
            Shortcut("Project", "Показать или скрыть дерево файлов проекта", GitKeymap.projectFiles),
            Shortcut("Git Log", "Открыть граф коммитов", GitKeymap.log),
            Shortcut("Terminal", "Показать или скрыть терминал проекта", GitKeymap.terminal),
            Shortcut("VCS Operations Popup", "Открыть список Git-команд", GitKeymap.vcsOperations),
            Shortcut("Find Action", "Найти команду по имени", GitKeymap.findAction),
            Shortcut("Search Log", "Найти коммит по сообщению или хешу", GitKeymap.focusCommitSearch),
        ]),
        Group(name: "Коммиты и синхронизация", shortcuts: [
            Shortcut("Commit", "Открыть панель и перейти к сообщению коммита", GitKeymap.commit),
            Shortcut("Commit and Push…", "Создать коммит и перейти к подтверждению отправки", GitKeymap.commitAndPush),
            Shortcut("Push…", "Просмотреть назначение перед отправкой", GitKeymap.push),
            Shortcut("Update Project", "Обновить текущую ветку", GitKeymap.update),
            Shortcut("Include in Commit / Stage", "Отметить файл для коммита или добавить в индекс", GitKeymap.stage),
            Shortcut("Amend", "Переключить исправление последнего локального коммита", GitKeymap.amend),
            Shortcut("Rollback…", "Открыть подтверждение отката изменений", GitKeymap.rollback),
        ]),
        Group(name: "Просмотр diff", shortcuts: [
            Shortcut("Show Diff", "Открыть diff выбранного файла", GitKeymap.showDiff),
            Shortcut("Previous Difference", "Перейти к предыдущему изменению", GitKeymap.previousDifference),
            Shortcut("Next Difference", "Перейти к следующему изменению", GitKeymap.nextDifference),
            Shortcut("Compare Previous File", "Открыть diff предыдущего файла", GitKeymap.previousFile),
            Shortcut("Compare Next File", "Открыть diff следующего файла", GitKeymap.nextFile),
        ]),
    ]

    private var results: [Group] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.groups.compactMap { group in
            let matches = group.shortcuts.filter { $0.matches(query) }
            return matches.isEmpty ? nil : Group(name: group.name, shortcuts: matches)
        }
    }

    var body: some View {
        let filtered = results
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 9) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 17))
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                    Text("Сочетания клавиш")
                        .font(.system(size: 20, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Готово") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(StudioButton())
                }
                StudioSearch(placeholder: "Название команды или клавиши", text: $search)
            }
            .padding(16)
            StudioRule()

            if filtered.isEmpty {
                EmptyPanel(icon: "magnifyingglass", title: "Команды не найдены")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(filtered) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(group.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.muted)
                                    .padding(.bottom, 5)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(group.shortcuts) { shortcut in
                                    shortcutRow(shortcut)
                                    if shortcut.id != group.shortcuts.last?.id { StudioRule() }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 560, height: 515)
        .foregroundStyle(Palette.text)
        .background(Palette.panel)
    }

    private func shortcutRow(_ shortcut: Shortcut) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(shortcut.name).font(.system(size: 13, weight: .medium))
                Text(shortcut.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            Text(GitKeymap.display(shortcut.shortcut))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Palette.selection, in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}
