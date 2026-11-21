import AppKit
import CoreText
import SwiftUI

struct CommitMessageEditor: View {
    @Binding var text: String
    let focusRequest: UInt
    var onFocus: (UInt) -> Void = { _ in }
    @State private var isFocused = false

    private static let focusedStroke = Color(nsColor: NSColor(Palette.stroke)
        .blended(withFraction: 0.55, of: NSColor(Palette.accentBorder)) ?? NSColor(Palette.accentBorder))

    var body: some View {
        let boundary = RoundedRectangle(cornerRadius: 5)
        NativeMessageEditor(text: $text, focusRequest: focusRequest, onFocus: onFocus) { focused in
            isFocused = focused
        }
        .background(Palette.base, in: boundary)
        .clipShape(boundary)
        .overlay {
            boundary.strokeBorder(isFocused ? Self.focusedStroke : Palette.stroke, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

private struct NativeMessageEditor: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UInt
    let onFocus: (UInt) -> Void
    let focusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = EditorScrollView()
        scroll.borderType = .noBorder
        scroll.focusRingType = .none
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let editor = MessageView(frame: .zero)
        editor.configure()
        editor.focusChanged = focusChanged
        editor.delegate = context.coordinator
        editor.string = text
        editor.refreshPlaceholder()
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? MessageView else { return }
        editor.focusChanged = focusChanged
        let coordinator = context.coordinator
        coordinator.text = $text
        if editor.string != text {
            let selection = editor.selectedRanges
            editor.string = text
            let length = (text as NSString).length
            editor.selectedRanges = selection.map { value in
                let range = value.rangeValue
                let location = min(range.location, length)
                return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
            }
            editor.refreshPlaceholder()
        }
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            if focusRequest == 0 {
                editor.cancelFocusRequest()
            } else {
                editor.requestFocus { onFocus(focusRequest) }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var lastFocusRequest: UInt = 0

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? MessageView else { return }
            editor.refreshPlaceholder()
            if text.wrappedValue != editor.string { text.wrappedValue = editor.string }
        }
    }

    private final class EditorScrollView: NSScrollView {
        override func layout() {
            super.layout()
            guard let editor = documentView as? MessageView else { return }
            let height = contentSize.height
            if editor.minSize.height != height {
                editor.minSize = NSSize(width: 0, height: height)
            }
            if editor.frame.height < height {
                editor.setFrameSize(NSSize(width: editor.frame.width, height: height))
            }
        }
    }

    private final class MessageView: NSTextView {
        private static let prompt = "Сообщение коммита"
        private var pendingFocus: (() -> Void)?
        private var showingPlaceholder = true
        var focusChanged: ((Bool) -> Void)?
        private lazy var promptLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: Self.prompt,
            attributes: [.font: Self.editorFont, .foregroundColor: NSColor(Palette.muted)]
        ))
        private static let editorFont = NSFont.systemFont(ofSize: 12)

        func configure() {
            isRichText = false
            allowsUndo = true
            importsGraphics = false
            drawsBackground = false
            focusRingType = .none
            font = Self.editorFont
            textColor = NSColor(Palette.text)
            insertionPointColor = NSColor(Palette.text)
            isAutomaticQuoteSubstitutionEnabled = false
            isAutomaticDashSubstitutionEnabled = false
            isAutomaticTextReplacementEnabled = false
            isAutomaticSpellingCorrectionEnabled = false
            isHorizontallyResizable = false
            isVerticallyResizable = true
            autoresizingMask = [.width]
            minSize = .zero
            maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textContainerInset = NSSize(width: 8, height: 6)
            textContainer?.containerSize = NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
            textContainer?.widthTracksTextView = true
            textContainer?.lineFragmentPadding = 0
            setAccessibilityLabel(Self.prompt)
            setAccessibilityPlaceholderValue(Self.prompt)
        }

        func refreshPlaceholder() {
            let empty = string.isEmpty
            guard showingPlaceholder != empty else { return }
            showingPlaceholder = empty
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard showingPlaceholder, let layoutManager, let textContainer,
                  let graphics = NSGraphicsContext.current?.cgContext else { return }
            layoutManager.ensureLayout(for: textContainer)
            let origin = textContainerOrigin
            let line = layoutManager.extraLineFragmentRect
            let baseline = origin.y + line.minY + layoutManager.defaultBaselineOffset(for: Self.editorFont)
            graphics.saveGState()
            graphics.translateBy(x: origin.x + line.minX + textContainer.lineFragmentPadding, y: baseline)
            graphics.scaleBy(x: 1, y: -1)
            graphics.textMatrix = .identity
            graphics.textPosition = .zero
            CTLineDraw(promptLine, graphics)
            graphics.restoreGState()
        }

        func requestFocus(_ onFocus: @escaping () -> Void) {
            pendingFocus = onFocus
            focusWhenAttached()
        }

        func cancelFocusRequest() { pendingFocus = nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusWhenAttached()
        }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            publishFocus()
            return true
        }

        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            publishFocus()
            return true
        }

        private func publishFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                focusChanged?(window?.firstResponder === self)
            }
        }

        private func focusWhenAttached() {
            guard pendingFocus != nil, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let onFocus = pendingFocus, let window, window.makeFirstResponder(self) else { return }
                pendingFocus = nil
                onFocus()
            }
        }
    }
}
