import SwiftUI

enum WorkbenchSplit: Hashable {
    case editor, dock

    fileprivate var isVertical: Bool { self == .dock }
}

private enum WorkbenchPaneBounds: PreferenceKey {
    static var defaultValue: [WorkbenchSplit: [Anchor<CGRect>]] { [:] }

    static func reduce(value: inout [WorkbenchSplit: [Anchor<CGRect>]],
                       nextValue: () -> [WorkbenchSplit: [Anchor<CGRect>]]) {
        value.merge(nextValue(), uniquingKeysWith: +)
    }
}

extension View {
    func measureWorkbenchPane(in split: WorkbenchSplit) -> some View {
        transformAnchorPreference(key: WorkbenchPaneBounds.self, value: .bounds) { panes, bounds in
            panes[split, default: []].append(bounds)
        }
    }

    func paintWorkbenchGutter(in split: WorkbenchSplit) -> some View {
        // Cover the native divider without replacing its resize hit target.
        overlayPreferenceValue(WorkbenchPaneBounds.self) { panes in
            GeometryReader { geometry in
                let frames = panes[split, default: []].map { geometry[$0] }.sorted {
                    split.isVertical ? $0.minY < $1.minY : $0.minX < $1.minX
                }
                let gutters = zip(frames, frames.dropFirst()).compactMap { before, after -> CGRect? in
                    let start = split.isVertical ? before.maxY : before.maxX
                    let end = split.isVertical ? after.minY : after.minX
                    let thickness = end - start
                    guard thickness > 0, thickness <= WorkbenchLayout.gutter else { return nil }
                    return split.isVertical
                        ? CGRect(x: 0, y: start, width: geometry.size.width, height: thickness)
                        : CGRect(x: start, y: 0, width: thickness, height: geometry.size.height)
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
