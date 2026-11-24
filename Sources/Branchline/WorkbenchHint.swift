import AppKit
import Observation
import SwiftUI

extension View {
    /// Presents a delayed visual hint. The control keeps its own accessibility label.
    func workbenchHint(_ title: String, shortcut: KeyboardShortcut? = nil) -> some View {
        modifier(WorkbenchHintModifier(
            hint: WorkbenchHint(title: title, shortcut: shortcut.map(GitKeymap.display))
        ))
    }

    /// Hosts one hint above the controls in this workbench.
    func workbenchHints() -> some View {
        modifier(WorkbenchHintHost())
    }
}

private struct WorkbenchHint: Equatable {
    let title: String
    let shortcut: String?

    var helpText: String {
        shortcut.map { "\(title) (\($0))" } ?? title
    }
}

private struct PresentedWorkbenchHint {
    var hint: WorkbenchHint
    let point: CGPoint
}

@MainActor @Observable
private final class WorkbenchHintState {
    private(set) var shown: PresentedWorkbenchHint?
    @ObservationIgnored weak var anchorView: NSView?
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var pendingHint: WorkbenchHint?
    @ObservationIgnored private var reveal: Task<Void, Never>?

    func enter(_ id: UUID, hint: WorkbenchHint) {
        if owner == id {
            update(id, hint: hint)
            return
        }

        dismiss()
        owner = id
        pendingHint = hint
        reveal = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, owner == id, let pendingHint else { return }
            reveal = nil
            guard let anchorView, let window = anchorView.window else { return }
            let bounds = anchorView.bounds
            let mouse = anchorView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard bounds.contains(mouse) else { return }
            let point = CGPoint(x: mouse.x - bounds.minX,
                                y: anchorView.isFlipped ? mouse.y - bounds.minY : bounds.maxY - mouse.y)
            shown = PresentedWorkbenchHint(hint: pendingHint, point: point)
        }
    }

    func update(_ id: UUID, hint: WorkbenchHint) {
        guard owner == id, pendingHint != hint else { return }
        pendingHint = hint
        if shown != nil { shown?.hint = hint }
    }

    func leave(_ id: UUID) {
        if owner == id { dismiss() }
    }

    func dismiss() {
        reveal?.cancel()
        reveal = nil
        owner = nil
        pendingHint = nil
        if shown != nil { shown = nil }
    }
}

private struct WorkbenchHintStateKey: EnvironmentKey {
    static let defaultValue: WorkbenchHintState? = nil
}

private struct WorkbenchHintModifier: ViewModifier {
    let hint: WorkbenchHint
    @Environment(\.workbenchHintState) private var state
    @State private var id: UUID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let state {
            let tracked = content
                .onHover { hovering in
                    if hovering {
                        let activeID = id ?? UUID()
                        if id == nil { id = activeID }
                        state.enter(activeID, hint: hint)
                    } else if let id {
                        state.leave(id)
                    }
                }
                .onChange(of: hint) { _, newHint in
                    if let id { state.update(id, hint: newHint) }
                }
                .onDisappear {
                    if let id { state.leave(id) }
                }

            if let shortcut = hint.shortcut {
                tracked.accessibilityHint("Сочетание клавиш \(shortcut)")
            } else {
                tracked
            }
        } else {
            content.help(hint.helpText)
        }
    }
}

private extension EnvironmentValues {
    var workbenchHintState: WorkbenchHintState? {
        get { self[WorkbenchHintStateKey.self] }
        set { self[WorkbenchHintStateKey.self] = newValue }
    }
}

private struct WorkbenchHintHost: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = WorkbenchHintState()

    func body(content: Content) -> some View {
        content
            .environment(\.workbenchHintState, state)
            .background {
                WorkbenchHintAnchor(state: state)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            .overlay {
                if let shown = state.shown {
                    WorkbenchHintPlacement(point: shown.point) {
                        WorkbenchHintCard(hint: shown.hint)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { state.dismiss() }
            }
            .onDisappear { state.dismiss() }
    }
}

private struct WorkbenchHintAnchor: NSViewRepresentable {
    let state: WorkbenchHintState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        state.anchorView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private struct WorkbenchHintPlacement: Layout {
    let point: CGPoint

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first, bounds.width > 12, bounds.height > 12 else { return }
        let available = bounds.insetBy(dx: 6, dy: 6)
        let maxSize = ProposedViewSize(width: min(310, available.width), height: available.height)
        let size = card.sizeThatFits(maxSize)

        let x = min(max(bounds.minX + point.x + 12, available.minX),
                    max(available.minX, available.maxX - size.width))
        let below = bounds.minY + point.y + 17
        let above = bounds.minY + point.y - size.height - 10
        let preferredY = below + size.height <= available.maxY ? below : above
        let y = min(max(preferredY, available.minY),
                    max(available.minY, available.maxY - size.height))
        card.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

private struct WorkbenchHintCard: View {
    let hint: WorkbenchHint

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(hint.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.text)
                .lineLimit(2)
            if let shortcut = hint.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium).monospaced())
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Palette.control, in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.stroke) }
    }
}
