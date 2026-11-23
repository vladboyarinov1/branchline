import AppKit
import SwiftUI

struct WorkbenchDockDivider: NSViewRepresentable {
    let height: CGFloat
    let limits: ClosedRange<CGFloat>
    let label: String
    let resize: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> Handle { Handle() }

    func updateNSView(_ view: Handle, context: Context) {
        view.height = height
        view.resize = resize
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(Int(height.rounded()))
        view.setAccessibilityMinValue(Int(limits.lowerBound.rounded()))
        view.setAccessibilityMaxValue(Int(limits.upperBound.rounded()))
    }

    final class Handle: NSView {
        var height: CGFloat = 0
        var resize: ((CGFloat, Bool) -> Void)?
        private var drag: (startY: CGFloat, height: CGFloat)?

        init() {
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.splitter)
            setAccessibilityHelp("Перетащите разделитель или используйте стрелки вверх и вниз.")
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override var acceptsFirstResponder: Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            drag = (event.locationInWindow.y, height)
        }

        override func mouseDragged(with event: NSEvent) { move(event, finished: false) }
        override func mouseUp(with event: NSEvent) {
            if let drag, event.locationInWindow.y != drag.startY || height != drag.height {
                move(event, finished: true)
            }
            drag = nil
        }

        override func keyDown(with event: NSEvent) {
            switch event.specialKey {
            case .upArrow: _ = accessibilityPerformIncrement()
            case .downArrow: _ = accessibilityPerformDecrement()
            default: super.keyDown(with: event)
            }
        }

        override func accessibilityPerformIncrement() -> Bool { adjust(by: 16) }
        override func accessibilityPerformDecrement() -> Bool { adjust(by: -16) }

        private func adjust(by delta: CGFloat) -> Bool {
            guard let resize else { return false }
            resize(height + delta, true)
            return true
        }

        private func move(_ event: NSEvent, finished: Bool) {
            guard let drag else { return }
            resize?(drag.height + event.locationInWindow.y - drag.startY, finished)
        }
    }
}

private enum WorkbenchPaneBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func measureWorkbenchPane() -> some View {
        transformAnchorPreference(key: WorkbenchPaneBounds.self, value: .bounds) { panes, bounds in
            panes.append(bounds)
        }
    }

    func paintWorkbenchGutter() -> some View {
        // Cover the native divider without replacing its resize hit target.
        overlayPreferenceValue(WorkbenchPaneBounds.self) { panes in
            GeometryReader { geometry in
                let frames = panes.map { geometry[$0] }.sorted { $0.minX < $1.minX }
                let gutters = zip(frames, frames.dropFirst()).compactMap { before, after -> CGRect? in
                    let start = before.maxX
                    let end = after.minX
                    let thickness = end - start
                    guard thickness > 0, thickness <= WorkbenchLayout.gutter else { return nil }
                    return CGRect(x: start, y: 0, width: thickness, height: geometry.size.height)
                }
                ForEach(gutters.indices, id: \.self) { index in
                    let rect = gutters[index]
                    Palette.workbench
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
