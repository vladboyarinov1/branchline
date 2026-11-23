import Foundation
import SwiftUI

enum NPMScripts {
    static func names(in root: URL) -> [String] {
        guard case .text(let text, truncated: false) = try? ProjectFileContent.read(root: root, path: "package.json"),
              let manifest = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let scripts = manifest["scripts"] as? [String: String] else { return [] }
        return scripts.keys.filter { !$0.isEmpty && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // The script name travels as an argument, including names with shell metacharacters.
    static func arguments(for script: String) -> [String] {
        ["-lc", "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"; exec npm run -- \"$1\"", "branchline-npm", script]
    }
}

struct NPMRunControl: View {
    let workspace: Workspace

    var body: some View {
        let scripts = workspace.npmScripts
        if let first = scripts.first {
            let selected = scripts.first(where: { $0 == workspace.npmScript }) ??
                scripts.first(where: { $0 == "format" }) ??
                scripts.first(where: { $0 == "prettier" }) ?? first
            HStack(spacing: 0) {
                Menu {
                    ForEach(scripts, id: \.self) { name in
                        Button {
                            workspace.npmScript = name
                        } label: {
                            if name == selected { Label(name, systemImage: "checkmark") }
                            else { Text(name) }
                        }
                    }
                } label: {
                    Text(selected.count > 18 ? String(selected.prefix(17)) + "…" : selected)
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(height: 28)
                .padding(.leading, 9)
                .accessibilityLabel("npm-скрипт")
                .accessibilityValue(selected)
                Button {
                    workspace.runNPMScript(selected)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(workspace.terminalDock?.isRunningScript == true ? Palette.disabled : Palette.green)
                        .frame(width: 27, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Запустить npm: \(selected)")
                .workbenchHint("npm run \(selected)")
                .disabled(workspace.terminalDock?.isRunningScript == true || workspace.activity != nil)
            }
            .background(Palette.control, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
