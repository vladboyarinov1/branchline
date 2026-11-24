import SwiftUI

enum Palette {
    // Surface and accent colors from the Islands Dark theme.
    static let base = Color(hex: 0x191A1C)
    static let workbench = Color(hex: 0x26282C)
    static let panel = base
    static let rail = panel
    static let header = workbench
    static let control = Color(hex: 0x212326)
    static let controlPressed = Color(hex: 0x33353B)
    static let stroke = Color(hex: 0x40434A)
    static let separator = workbench
    static let text = Color(hex: 0xD1D3D9)
    static let muted = Color(hex: 0x9FA2A8)
    static let disabled = Color(hex: 0x73767C)
    static let accent = Color(hex: 0x92B7FF)
    static let accentBorder = Color(hex: 0x538AF9)
    static let selection = Color(hex: 0x2A4371)
    static let selectionMuted = Color(hex: 0x233558)
    static let primaryButton = Color(hex: 0x3871E1)
    static let primaryPressed = Color(hex: 0x2F5EB9)
    static let primaryDisabled = selectionMuted
    static let onPrimary = Color.white
    static let green = Color(hex: 0x8EC39D)
    static let blue = accent
    static let red = Color(hex: 0xFF9B9F)
    static let yellow = Color(hex: 0xF5D273)
    static let lavender = Color(hex: 0xB589EC)
    static let pink = Color(hex: 0xCF84CF)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}

enum WorkbenchLayout {
    static let titleHeight: CGFloat = 34
    static let gutter: CGFloat = 8
    static let panelInset: CGFloat = 8
    static let panelHeaderHeight: CGFloat = 28
    static let radius: CGFloat = 9
}

struct DeferredVisibility<Content: View>: View {
    let isPending: Bool
    @ViewBuilder let content: (Bool) -> Content
    @State private var visible = false

    var body: some View {
        content(isPending && visible)
            .task(id: isPending) {
                visible = false
                guard isPending else { return }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    try Task.checkCancellation()
                    visible = true
                } catch {}
            }
    }
}

enum GitGlyph: Shape {
    case branch, commit

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scale = min(rect.width, rect.height) / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 8) * scale, y: rect.midY + (y - 8) * scale)
        }
        func node(_ x: CGFloat, _ y: CGFloat, radius: CGFloat) {
            let origin = point(x - radius, y - radius)
            path.addEllipse(in: CGRect(origin: origin, size: CGSize(width: radius * 2 * scale, height: radius * 2 * scale)))
        }
        switch self {
        case .branch:
            node(4.5, 3.5, radius: 1.75)
            node(4.5, 12.5, radius: 1.75)
            node(11.5, 3.5, radius: 1.75)
            path.move(to: point(4.5, 5.25))
            path.addLine(to: point(4.5, 10.75))
            path.move(to: point(11.5, 5.25))
            path.addCurve(to: point(4.5, 9.5), control1: point(11.5, 8), control2: point(9, 9.5))
        case .commit:
            node(8, 8, radius: 2.75)
            path.move(to: point(1.5, 8))
            path.addLine(to: point(5.25, 8))
            path.move(to: point(10.75, 8))
            path.addLine(to: point(14.5, 8))
        }
        return path
    }

    func glyph(size: CGFloat = 15) -> some View {
        stroke(style: StrokeStyle(lineWidth: size / 11, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct WorkbenchIconButton: ButtonStyle {
    var selected = false
    var keepsEnabledAppearance = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Chrome(label: configuration.label, pressed: configuration.isPressed, selected: selected,
               enabled: isEnabled || keepsEnabledAppearance)
    }

    private struct Chrome<Label: View>: View {
        let label: Label
        let pressed: Bool
        let selected: Bool
        let enabled: Bool
        @State private var hovering = false

        var body: some View {
            label
                .foregroundStyle(selected ? Palette.accent : (enabled && hovering ? Palette.text : Palette.muted))
                .background(background, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.5)
                .onHover { hovering = $0 }
        }

        private var background: Color {
            if pressed { return Palette.controlPressed }
            if selected { return Palette.selection }
            return enabled && hovering ? Palette.control : .clear
        }
    }
}

struct StudioButton: ButtonStyle {
    enum Kind { case primary, regular, quiet }
    var kind: Kind = .regular
    var keepsEnabledAppearance = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, kind == .quiet ? 8 : 11)
            .frame(height: 30)
            .foregroundStyle(foreground)
            .background {
                RoundedRectangle(cornerRadius: 6).fill(background(pressed: configuration.isPressed))
            }
            .overlay {
                if kind == .regular {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(appearsEnabled ? Palette.stroke : Palette.separator, lineWidth: 1)
                }
            }
    }

    private var appearsEnabled: Bool { isEnabled || keepsEnabledAppearance }

    private var foreground: Color {
        if kind == .primary {
            return appearsEnabled ? Palette.onPrimary : Palette.onPrimary.opacity(0.4)
        }
        return appearsEnabled ? Palette.text : Palette.disabled
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary:
            guard appearsEnabled else { return Palette.primaryDisabled }
            return pressed ? Palette.primaryPressed : Palette.primaryButton
        case .regular: return pressed ? Palette.controlPressed : Palette.control
        case .quiet: return pressed ? Palette.selection : .clear
        }
    }
}

struct StudioSearch: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(Palette.muted))
                .textFieldStyle(.plain)
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить поиск")
                .workbenchHint("Очистить поиск")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 29)
        .background(Palette.base, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.stroke, lineWidth: 1) }
    }
}

struct EmptyPanel: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 15, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StudioRule: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}
