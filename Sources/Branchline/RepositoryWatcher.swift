import CoreServices
import Darwin
import Foundation

struct RepositoryChanges: Sendable {
    private static let pathLimit = 256

    private(set) var metadataChanged = false
    private(set) var allWorkingPatches = false
    private var paths: Set<String> = []

    static var everything: Self {
        var changes = Self()
        changes.metadataChanged = true
        changes.invalidateWorkingPatches()
        return changes
    }

    var isEmpty: Bool { !metadataChanged && !allWorkingPatches && paths.isEmpty }

    mutating func include(_ path: String) {
        guard !allWorkingPatches else { return }
        paths.insert(path)
        if paths.count > Self.pathLimit { invalidateWorkingPatches() }
    }

    mutating func invalidateWorkingPatches() {
        allWorkingPatches = true
        paths = []
    }

    mutating func merge(_ other: Self) {
        metadataChanged = metadataChanged || other.metadataChanged
        if other.allWorkingPatches { invalidateWorkingPatches() }
        else { for path in other.paths { include(path) } }
    }

    func affectsWorkingPatch(for path: String, originalPath: String?) -> Bool {
        allWorkingPatches || paths.contains { changed in
            Self.overlaps(changed, path) || originalPath.map { Self.overlaps(changed, $0) } == true
        }
    }

    private static func overlaps(_ first: String, _ second: String) -> Bool {
        // Treat case-only renames conservatively on case-insensitive volumes.
        let first = first.lowercased()
        let second = second.lowercased()
        return first == second || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }
}

final class RepositoryWatcher {
    private final class Handler: Sendable {
        static let unreliableEvents = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
        )

        let root: String
        let gitDirectories: Set<String>
        let indexPath: String?
        let change: @MainActor @Sendable (RepositoryChanges) -> Void

        init(root: String, gitDirectories: Set<String>, indexPath: String?,
             change: @escaping @MainActor @Sendable (RepositoryChanges) -> Void) {
            self.root = root
            self.gitDirectories = gitDirectories
            self.indexPath = indexPath
            self.change = change
        }

        func changes(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>) -> RepositoryChanges {
            var changes = RepositoryChanges()
            for (index, path) in paths.enumerated() {
                if flags[index] & Self.unreliableEvents != 0 { return .everything }
                if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }

                if let indexPath, path == indexPath || path == indexPath + ".lock" {
                    // Index updates affect both sides of working diffs without moving refs.
                    changes.invalidateWorkingPatches()
                    continue
                }
                if gitDirectories.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    return .everything
                }
                guard path.hasPrefix(root + "/") else { return .everything }
                let relative = String(path.dropFirst(root.count + 1))
                if relative == ".gitattributes" || relative.hasSuffix("/.gitattributes") || relative == ".gitmodules" {
                    changes.invalidateWorkingPatches()
                } else {
                    changes.include(relative)
                }
            }
            return changes
        }
    }

    private static let queue = DispatchQueue(label: "Branchline.RepositoryWatcher", qos: .utility)
    private let handler: Handler
    private var stream: FSEventStreamRef?
    var isRunning: Bool { stream != nil }

    init(root: URL, gitDirectory: URL?, commonDirectory: URL?,
         change: @escaping @MainActor @Sendable (RepositoryChanges) -> Void) {
        let worktree = Self.fileSystemPath(root)
        let privateGit = gitDirectory.map(Self.fileSystemPath)
        let commonGit = commonDirectory.map(Self.fileSystemPath)
        let metadata = Set([worktree + "/.git", privateGit, commonGit].compactMap { $0 })
        let paths = [worktree] + metadata.sorted().filter { candidate in
            !candidate.hasPrefix(worktree + "/") && candidate != worktree
                && !metadata.contains { $0 != candidate && candidate.hasPrefix($0 + "/") }
        }
        handler = Handler(root: worktree, gitDirectories: metadata, indexPath: privateGit.map { $0 + "/index" }, change: change)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
                                           retain: { opaque in
                                               guard let opaque else { return nil }
                                               _ = Unmanaged<Handler>.fromOpaque(opaque).retain()
                                               return opaque
                                           }, release: { opaque in
                                               if let opaque { Unmanaged<Handler>.fromOpaque(opaque).release() }
                                           }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, context, count, eventPaths, flags, _ in
            guard let context else { return }
            let recipient = Unmanaged<Handler>.fromOpaque(context).takeUnretainedValue()
            let items = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            let changes = if let paths = items as? [String], paths.count == count {
                recipient.changes(paths: paths, flags: flags)
            } else { RepositoryChanges.everything }
            guard !changes.isEmpty else { return }
            Task { @MainActor in recipient.change(changes) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.45, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, Self.queue)
        if FSEventStreamStart(stream) {
            self.stream = stream
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private static func fileSystemPath(_ url: URL) -> String {
        // FSEvents reports physical paths, including /private for paths beneath /var.
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return url.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
