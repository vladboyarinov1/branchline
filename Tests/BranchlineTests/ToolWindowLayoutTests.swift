import AppKit
import SwiftUI
import XCTest
@testable import Branchline

final class ToolWindowLayoutTests: XCTestCase {
    @MainActor
    func testCommitAndStashKeepTheEditorAtFullHeight() async throws {
        _ = NSApplication.shared
        for populated in [true, false] {
            let root = try makeRepository(populated: populated)
            defer { try? FileManager.default.removeItem(at: root) }

            let workspace = Workspace()
            try await workspace.attach(Git(root: root))
            workspace.setFront(true)
            defer { workspace.setFront(false) }
            workspace.selectInitialChange()

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 780),
                                  styleMask: [.titled, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            let host = NSHostingView(rootView: RepositoryView(workspace: workspace) { Text("Layout test") })
            window.contentView = host

            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if workspace.diffSource != nil, diffHeight(in: host) > 0 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let initial = diffHeight(in: host)
            XCTAssertGreaterThan(initial, 400, "The working diff must be visible before switching tools")

            for _ in 0..<8 {
                workspace.activate(workspace.mode == .stash ? .changes : .stash)
                for _ in 0..<16 {
                    try await Task.sleep(for: .milliseconds(3))
                    host.layoutSubtreeIfNeeded()
                    let height = diffHeight(in: host)
                    guard height >= initial * 0.8 else {
                        XCTFail("Editor collapsed from \(initial) to \(height) in \(workspace.mode), populated stash: \(populated)")
                        return
                    }
                }
            }
        }
    }

    @MainActor
    private func diffHeight(in view: NSView) -> CGFloat {
        if String(describing: type(of: view)) == "DiffSurfaceView" {
            return view.frame.height
        }
        return view.subviews.lazy.map { self.diffHeight(in: $0) }.first { $0 > 0 } ?? 0
    }

    private func makeRepository(populated: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try git(["init", "--quiet", "--initial-branch=main"], at: root)
            let file = root.appendingPathComponent("sample.txt")
            try Data("base\n".utf8).write(to: file)
            try git(["add", "sample.txt"], at: root)
            try git(["commit", "--quiet", "-m", "Initial"], at: root)
            if populated {
                try Data("base\nstash\n".utf8).write(to: file)
                try git(["stash", "push", "--quiet", "-m", "Test stash"], at: root)
            }
            try Data("base\nworking\n".utf8).write(to: file)
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func git(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        process.arguments = ["-c", "user.name=Layout Test", "-c", "user.email=layout@example.invalid",
                             "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "LayoutTest.Git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Git failed: \(arguments.joined(separator: " "))"])
        }
    }
}
