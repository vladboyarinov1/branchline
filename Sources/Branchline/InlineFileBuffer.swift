import Foundation
import Observation

@MainActor @Observable
final class InlineFileBuffer {
    let path: String
    private(set) var text: String
    private(set) var dirty = false
    private(set) var saving = false
    private(set) var error: String?

    private let root: URL
    @ObservationIgnored private var baseline: WorktreeFileDraft
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private let changed: (InlineFileBuffer) -> Void

    init(root: URL, path: String, draft: WorktreeFileDraft, changed: @escaping (InlineFileBuffer) -> Void) {
        self.root = root
        self.path = path
        baseline = draft
        text = draft.text
        self.changed = changed
    }

    func replaceText(_ value: String) {
        text = value
        updateDirtyState()
        schedule()
    }

    func saveNow() {
        timer?.cancel()
        timer = nil
        guard writer == nil, dirty else { return }
        let draft = baseline
        let text = text
        let root = root
        let path = path
        saving = true
        error = nil
        changed(self)
        writer = Task {
            let result = await Task.detached(priority: .userInitiated) {
                try draft.save(text, root: root, path: path)
            }.result
            switch result {
            case .success(let saved):
                baseline = saved
            case .failure(let failure):
                error = failure.localizedDescription
            }
            saving = false
            writer = nil
            updateDirtyState()
            if error == nil, dirty { schedule() }
        }
    }

    func flush() async -> Bool {
        while dirty || saving {
            if let writer {
                await writer.value
            } else {
                saveNow()
                await writer?.value
            }
            if error != nil { return false }
        }
        return true
    }

    func cancelPendingSave() {
        timer?.cancel()
        timer = nil
    }

    func refreshIfClean(from draft: WorktreeFileDraft) {
        guard !dirty, !saving else { return }
        baseline = draft
        if !text.utf8.elementsEqual(draft.text.utf8) { text = draft.text }
    }

    private func updateDirtyState() {
        dirty = !text.utf8.elementsEqual(baseline.text.utf8)
        if !dirty { error = nil }
        changed(self)
    }

    private func schedule() {
        timer?.cancel()
        guard dirty, writer == nil else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            self?.saveNow()
        }
    }
}
