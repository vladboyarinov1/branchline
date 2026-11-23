import SwiftUI

struct FileTypeIcon: View {
    let name: String

    private var type: (mark: String, color: Color, badge: Bool) {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["package.json", "package-lock.json"].contains(name) { return ("shippingbox", Palette.green, false) }
        if name == "Dockerfile" { return ("shippingbox", Palette.blue, false) }
        if [".gitignore", ".gitattributes", ".gitmodules"].contains(name) {
            return ("point.3.connected.trianglepath.dotted", Palette.red, false)
        }
        switch ext {
        case "tsx": return ("TSX", Palette.blue, true)
        case "ts", "mts", "cts": return ("TS", Palette.blue, true)
        case "jsx": return ("JSX", Palette.yellow, true)
        case "js", "mjs", "cjs": return ("JS", Palette.yellow, true)
        case "json", "jsonc": return ("curlybraces", Palette.yellow, false)
        case "css", "scss", "sass", "less": return ("number", Palette.lavender, false)
        case "md", "mdx": return ("doc.text", Palette.blue, false)
        case "html", "htm", "xml", "vue", "svelte": return ("chevron.left.forwardslash.chevron.right", Palette.red, false)
        case "yaml", "yml", "toml", "ini", "env": return ("gearshape", Palette.lavender, false)
        case "sh", "bash", "zsh", "fish": return ("terminal", Palette.green, false)
        case "swift": return ("swift", Palette.red, false)
        case "py": return ("PY", Palette.yellow, true)
        case "png", "jpg", "jpeg", "webp", "svg", "gif", "ico", "heic": return ("photo", Palette.green, false)
        case "zip", "tar", "gz": return ("archivebox", Palette.yellow, false)
        case "lock": return ("lock", Palette.muted, false)
        default: return ("doc", Palette.muted, false)
        }
    }

    var body: some View {
        let type = type
        Group {
            if type.badge {
                Text(type.mark)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
            } else {
                Image(systemName: type.mark)
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .frame(width: 17)
        .foregroundStyle(type.color)
        .accessibilityHidden(true)
    }
}
