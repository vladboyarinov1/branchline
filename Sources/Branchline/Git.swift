import Darwin
import Foundation

struct GitStatus: Equatable, Sendable {
    var head: String?
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var isUnborn = false
    var files: [GitFile] = []
}

enum GitChange: String, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case untracked = "?"
    case conflicted = "U"
}

struct GitFile: Identifiable, Hashable, Sendable {
    let path: String
    var originalPath: String? = nil
    var staged: GitChange? = nil
    var unstaged: GitChange? = nil
    var previewRevision: String? = nil

    var id: String { previewRevision.map { "\($0)\0\(path)" } ?? path }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var directory: String { path.lastIndex(of: "/").map { String(path[..<$0]) } ?? "" }
}

enum GitRefKind: Hashable, Sendable {
    case local, remote, tag
}

struct GitRef: Identifiable, Hashable, Sendable {
    let fullName: String
    let name: String
    let hash: String
    let kind: GitRefKind
    let isCurrent: Bool
    let remote: String?

    var id: String { fullName }
}

struct GitCommit: Identifiable, Hashable, Sendable {
    let hash: String
    let shortHash: String
    let parents: [String]
    let author: String
    let date: Date
    let subject: String

    var id: String { hash }
}

struct GitCommitDetail: Sendable {
    let commit: GitCommit
    let email: String
    let message: String
    let files: [GitFile]
}

enum GitPatchContext: Hashable, Sendable {
    case staged, unstaged, working(unborn: Bool), commit(String), comparison(String)
}

struct GitStash: Identifiable, Hashable, Sendable {
    let ref: String
    let hash: String
    let message: String
    let date: Date

    var id: String { ref }
}

struct GitWorktree: Identifiable, Hashable, Sendable {
    let path: String
    var branch: String? = nil
    var hash: String? = nil
    var isBare = false
    var isLocked = false
    var isPrunable = false

    var id: String { path }
}

enum GitOperation: String, Sendable {
    case merge, rebase, cherryPick = "cherry-pick", revert

    var name: String {
        switch self {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }

    static func detect(in directory: URL) -> Self? {
        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path)
        }
        if exists("rebase-merge") || exists("rebase-apply/rebasing") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        let todo = directory.appendingPathComponent("sequencer/todo")
        guard let file = try? FileHandle(forReadingFrom: todo) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 7) else { return nil }
        let prefix = String(decoding: bytes, as: UTF8.self)
        if prefix.hasPrefix("pick ") { return .cherryPick }
        if prefix == "revert " { return .revert }
        return nil
    }
}

enum GitError: LocalizedError {
    case command(String)
    case outputLimit(Int)
    case notWorkingTree
    case invalidResponse
    case invalidBranch
    case noUpstream
    case destinationChanged
    case dirtyWorktree
    case operationInProgress
    case operationChanged

    var errorDescription: String? {
        switch self {
        case .command(let message): message
        case .outputLimit(let bytes):
            if bytes == Git.patchLimit {
                "Размер diff превышает 1 МБ. Предпросмотр этого файла пропущен."
            } else {
                "Ответ Git превышает лимит \(bytes / 1_048_576) МБ. Сузьте выборку и повторите."
            }
        case .notWorkingTree: "Выберите папку внутри рабочего дерева Git."
        case .invalidResponse: "Не удалось прочитать ответ Git."
        case .invalidBranch: "Для этой операции нужно выбрать локальную ветку."
        case .noUpstream: "У этой ветки ещё нет удалённой ветки для отправки."
        case .destinationChanged: "Текущая ветка или назначение изменились. Проверьте параметры и повторите действие."
        case .dirtyWorktree: "Сначала сделайте коммит или сохраните локальные изменения в Stash."
        case .operationInProgress: "Сначала завершите текущую Git-операцию."
        case .operationChanged: "Состояние Git изменилось. Обновите репозиторий и повторите действие."
        }
    }
}

struct Git: Sendable {
    let root: URL

    static let patchLimit = 1_048_576
    private static let commitFormat = "%H%x00%h%x00%P%x00%aN%x00%at%x00%s"
    private static let diffOptions = ["--no-ext-diff", "--no-textconv", "--color=never", "-M", "--submodule=short"]

    static func discover(_ directory: URL) async throws -> Git {
        let candidate = Git(root: directory.standardizedFileURL)
        let output = try await candidate.read(["rev-parse", "--show-toplevel"], allowed: [0, 128])
        guard output.status == 0, !output.string.isEmpty else { throw GitError.notWorkingTree }
        let path = output.string.dropLast(output.string.hasSuffix("\n") ? 1 : 0)
        return Git(root: URL(fileURLWithPath: String(path), isDirectory: true).standardizedFileURL)
    }

    func gitDirectory() async throws -> URL {
        try await directoryPath(for: "--git-dir")
    }

    func commonDirectory() async throws -> URL {
        try await directoryPath(for: "--git-common-dir")
    }

    private func directoryPath(for option: String) async throws -> URL {
        let output = try await read(["rev-parse", "--path-format=absolute", option])
        let path = String(output.string.dropLast(output.string.hasSuffix("\n") ? 1 : 0))
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func status() async throws -> GitStatus {
        let result = try await read(["status", "--porcelain=v2", "--branch", "--ahead-behind", "--untracked-files=all", "--find-renames", "-z"])
        let records = Self.fields(result.data)
        var status = GitStatus()
        var filePositions: [String: Int] = [:]
        var index = 0

        while index < records.count {
            let record = records[index]
            index += 1
            if record.hasPrefix("# ") {
                Self.readStatusHeader(record, into: &status)
                continue
            }

            var file: GitFile
            switch record.first {
            case "1", "2", "u":
                let prefixCount = record.first == "1" ? 8 : (record.first == "2" ? 9 : 10)
                let parts = record.split(separator: " ", maxSplits: prefixCount, omittingEmptySubsequences: false)
                guard parts.count == prefixCount + 1 else { throw GitError.invalidResponse }
                let changes = parts[1]
                file = GitFile(path: String(parts[prefixCount]))
                if record.first == "2" {
                    guard index < records.count else { throw GitError.invalidResponse }
                    file.originalPath = records[index]
                    index += 1
                }
                if record.first == "u" {
                    file.unstaged = .conflicted
                } else {
                    file.staged = changes.first.flatMap { GitChange(rawValue: String($0)) }
                    file.unstaged = changes.last.flatMap { GitChange(rawValue: String($0)) }
                }
            case "?":
                file = GitFile(path: String(record.dropFirst(2)), unstaged: .untracked)
            default:
                continue
            }

            if let position = filePositions[file.path] {
                status.files[position].staged = file.staged ?? status.files[position].staged
                status.files[position].unstaged = file.unstaged ?? status.files[position].unstaged
            } else {
                filePositions[file.path] = status.files.count
                status.files.append(file)
            }
        }
        return status
    }

    func refs() async throws -> [GitRef] {
        let result = try await read([
            "for-each-ref", "--sort=refname", "--format=%(refname)%00%(objectname)%00%(*objectname)%00%(HEAD)%00%(symref)",
            "refs/heads", "refs/remotes", "refs/tags",
        ])
        return result.string.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count == 5, parts[4].isEmpty else { return nil }
            let fullName = String(parts[0])
            let hash = String(parts[2].isEmpty ? parts[1] : parts[2])
            let kind: GitRefKind
            let prefix: String
            switch fullName {
            case let name where name.hasPrefix("refs/heads/"):
                kind = .local
                prefix = "refs/heads/"
            case let name where name.hasPrefix("refs/remotes/"):
                kind = .remote
                prefix = "refs/remotes/"
            case let name where name.hasPrefix("refs/tags/"):
                kind = .tag
                prefix = "refs/tags/"
            default: return nil
            }
            let name = String(fullName.dropFirst(prefix.count))
            let remote = kind == .remote ? name.split(separator: "/", maxSplits: 1).first.map(String.init) : nil
            return GitRef(fullName: fullName, name: name, hash: hash, kind: kind, isCurrent: parts[3] == "*", remote: remote)
        }
    }

    func log(ref: String?, skip: Int = 0, limit: Int = 150, search: String = "", author: String? = nil, path: String? = nil) async throws -> [GitCommit] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var options = ["log", "--topo-order", "--no-show-signature", "-z", "--format=\(Self.commitFormat)",
                       "--skip=\(max(0, skip))", "--max-count=\(min(1_000, max(0, limit)))"]
        if !query.isEmpty || !author.isEmpty {
            options += ["--fixed-strings", "--regexp-ignore-case"]
        }
        if !author.isEmpty { options.append("--author=\(author)") }

        if query.count >= 4, query.count <= 64, query.utf8.allSatisfy(Self.isHexDigit) {
            let match = try await read(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(query)^{commit}"], allowed: [0, 1])
            if match.status == 0 {
                let hash = match.string.trimmingCharacters(in: .newlines)
                if let ref {
                    let ancestry = try await read(["merge-base", "--is-ancestor", hash, ref], allowed: [0, 1, 128])
                    if ancestry.status == 0 {
                        return try await exactLog(hash, options: options, skip: skip, limit: limit, path: path, ref: ref)
                    }
                } else {
                    return try await exactLog(hash, options: options, skip: skip, limit: limit, path: path, ref: nil)
                }
            }
        }
        if !query.isEmpty { options.append("--grep=\(query)") }
        if path != nil { options.append("--follow") }

        if let ref {
            options += ["--end-of-options", ref, "--"]
        } else {
            options += ["--exclude=refs/stash", "--all", "--"]
        }
        if let path { options.append(path) }
        let result = try await read(options, allowed: ref == "HEAD" ? [0, 128] : [0], literalPaths: path != nil)
        if result.status == 128 {
            let head = try await read(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], allowed: [0, 1])
            if head.status == 1 { return [] }
            throw Self.commandError(result, command: "log")
        }
        return try Self.commits(result.data)
    }

    func details(_ hash: String) async throws -> GitCommitDetail {
        async let header = read([
            "show", "--no-patch", "--no-show-signature", "-z", "--format=\(Self.commitFormat)%x00%aE%x00%B",
            "--end-of-options", hash, "--",
        ])
        async let changes = read(["show", "--diff-merges=first-parent", "--format=", "--name-status", "-z"]
            + Self.diffOptions + ["--end-of-options", hash, "--"])
        let values = try await (header, changes)
        let fields = Self.fields(values.0.data)
        guard fields.count == 8, let commit = Self.parseCommit(fields[0..<6]) else { throw GitError.invalidResponse }
        return GitCommitDetail(commit: commit, email: fields[6], message: fields[7], files: try Self.parseChanges(values.1.data))
    }

    func compare(_ ref: GitRef) async throws -> [GitFile] {
        let result = try await read(["diff", "--name-status", "-z"] + Self.diffOptions + ["--end-of-options", "HEAD", ref.fullName, "--"])
        return try Self.parseChanges(result.data)
    }

    func patch(_ file: GitFile, context: GitPatchContext) async throws -> String {
        let diffOptions = Self.diffOptions + ["--src-prefix=a/", "--dst-prefix=b/", "--unified=3", "--no-color-moved"]
        let paths = [file.originalPath, file.path].compactMap { $0 }
        if case .unstaged = context, file.unstaged == .untracked {
            return try await newFilePatch(file, options: diffOptions)
        }
        let options: [String]
        switch context {
        case .staged:
            options = ["diff", "--cached"] + diffOptions
        case .unstaged:
            options = ["diff"] + diffOptions + (file.unstaged == .conflicted ? ["--ours"] : [])
        case .working(let unborn):
            return try await workingPatch(file, unborn: unborn, options: diffOptions, paths: paths)
        case .commit(let hash):
            options = ["show", "--format=", "--diff-merges=first-parent", "-p"] + diffOptions + ["--end-of-options", file.previewRevision ?? hash]
        case .comparison(let ref):
            options = ["diff"] + diffOptions + ["--end-of-options", "HEAD", ref]
        }
        return try await read(options + ["--"] + paths, limit: Self.patchLimit, literalPaths: true).string
    }

    private func newFilePatch(_ file: GitFile, options: [String]) async throws -> String {
        let result = try await read(["diff", "--no-index"] + options + ["--", "/dev/null", file.path],
                                    allowed: [0, 1], limit: Self.patchLimit)
        if result.status == 1, result.data.isEmpty, !result.error.isEmpty {
            throw Self.commandError(result, command: "diff")
        }
        return result.string
    }

    private func workingPatch(_ file: GitFile, unborn: Bool, options: [String], paths: [String]) async throws -> String {
        if unborn || (file.unstaged == .untracked && file.staged == nil) {
            if unborn && file.unstaged == .deleted { return "" }
            return try await newFilePatch(file, options: options)
        }
        let arguments = ["diff"] + options + ["HEAD", "--"] + paths
        guard file.staged == .deleted && file.unstaged == .untracked else {
            return try await read(arguments, limit: Self.patchLimit, literalPaths: true).string
        }
        // A staged deletion hides a recreated file from `git diff HEAD` using the real index.
        let scratch = try GitScratchDirectory()
        defer { scratch.remove() }
        let index = scratch.url.appendingPathComponent("index")
        try await write(["read-tree", "HEAD"], indexFile: index)
        return try await read(arguments, limit: Self.patchLimit, literalPaths: true, indexFile: index).string
    }

    func stage(_ files: [GitFile]) async throws {
        let paths = files.flatMap { file in
            file.unstaged == .renamed ? [file.originalPath, file.path].compactMap { $0 } : [file.path]
        }
        guard !paths.isEmpty else { return }
        try await write(["add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul"], input: Self.pathInput(paths), literalPaths: true)
    }

    func unstage(_ files: [GitFile]) async throws {
        let paths = files.flatMap { file in
            file.staged == .renamed ? [file.originalPath, file.path].compactMap { $0 } : [file.path]
        }
        guard !paths.isEmpty else { return }
        try await write(["reset", "-q", "--pathspec-from-file=-", "--pathspec-file-nul"], input: Self.pathInput(paths), literalPaths: true)
    }

    func checkout(_ ref: GitRef) async throws {
        switch ref.kind {
        case .local:
            try await write(["switch", "--no-guess", "--", ref.name])
        case .remote:
            let branch = ref.remote.map { String(ref.name.dropFirst($0.count + 1)) } ?? ref.name
            let local = try await read(["for-each-ref", "--count=1", "--format=%(upstream)", "refs/heads/\(branch)"])
            if local.string == "\(ref.fullName)\n" {
                try await write(["switch", "--no-guess", "--", branch])
            } else {
                try await write(["switch", "--track", "-c", branch, "--", ref.fullName])
            }
        case .tag:
            try await write(["switch", "--detach", "--", ref.fullName])
        }
    }

    func createBranch(_ name: String, checkout: Bool = true, from ref: GitRef? = nil) async throws {
        try await validateBranch(name)
        let start = ref.map { [$0.fullName] } ?? []
        if checkout {
            try await write(["switch", "-c", name, "--"] + start)
        } else {
            try await write(["branch", "--", name] + start)
        }
    }

    private func validateBranch(_ name: String) async throws {
        guard !name.hasPrefix("-") else { throw GitError.invalidBranch }
        let valid = try await read(["check-ref-format", "--branch", name], allowed: [0, 128])
        guard valid.status == 0, valid.string == "\(name)\n" else { throw GitError.invalidBranch }
    }

    func renameBranch(_ ref: GitRef, to name: String) async throws {
        guard ref.kind == .local else { throw GitError.invalidBranch }
        try await validateBranch(name)
        try await write(["branch", "--move", "--", ref.name, name])
    }

    func deleteBranch(_ ref: GitRef) async throws {
        guard ref.kind == .local else { throw GitError.invalidBranch }
        try await write(["branch", "--delete", "--", ref.name])
    }

    func integrateBranch(_ ref: GitRef, operation: GitOperation, into branch: String) async throws {
        try await requireCleanBranch(branch)
        switch operation {
        case .merge:
            try await write(["merge", "--no-edit", "--no-autostash", "--", ref.hash])
        case .rebase:
            try await writeWithDefaultEditor(["rebase", "--no-autostash", "--no-update-refs", "--", ref.hash])
        case .cherryPick, .revert:
            throw GitError.operationChanged
        }
    }

    func applyCommit(_ hash: String, operation: GitOperation, into branch: String) async throws {
        guard operation == .cherryPick || operation == .revert,
              (40...64).contains(hash.count), hash.utf8.allSatisfy(Self.isHexDigit) else {
            throw GitError.invalidResponse
        }
        try await requireCleanBranch(branch)
        try await write([operation.rawValue, "--no-edit", "--", hash])
    }

    func finishOperation(_ operation: GitOperation, abort: Bool) async throws {
        let directory = try await gitDirectory()
        guard GitOperation.detect(in: directory) == operation else { throw GitError.operationChanged }
        try await writeWithDefaultEditor([operation.rawValue, abort ? "--abort" : "--continue"])
    }

    func restoreUnstaged(_ file: GitFile) async throws {
        let snapshot = try await status()
        let current = snapshot.files.first { $0.path == file.path }
        guard let change = current?.unstaged, change != .untracked, change != .conflicted else {
            throw GitError.operationChanged
        }
        try await write(["restore", "--worktree", "--", file.path], literalPaths: true)
    }

    private func requireCleanBranch(_ branch: String) async throws {
        let snapshot = try await status()
        guard snapshot.branch == branch, !snapshot.isUnborn else { throw GitError.destinationChanged }
        let directory = try await gitDirectory()
        guard GitOperation.detect(in: directory) == nil else { throw GitError.operationInProgress }
        guard !snapshot.files.contains(where: { $0.staged != nil || ($0.unstaged != nil && $0.unstaged != .untracked) }) else {
            throw GitError.dirtyWorktree
        }
    }

    private func writeWithDefaultEditor(_ args: [String]) async throws {
        try await write(args, defaultEditor: true)
    }

    func commit(_ message: String, amend: Bool = false) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitError.command("Введите сообщение коммита.")
        }
        var arguments = ["commit", "--file=-"]
        if amend { arguments.append("--amend") }
        try await write(arguments, input: Data(message.utf8))
    }

    func commit(_ message: String, amend: Bool, files: [GitFile]) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitError.command("Введите сообщение коммита.")
        }
        guard amend || !files.isEmpty else { throw GitError.command("Выберите файлы для коммита.") }
        try Task.checkCancellation()
        // Finish the commit and index publication even if the caller stops waiting.
        try await Task.detached(priority: .userInitiated) {
            try await commitSelection(message, amend: amend, paths: files.map(\.path))
        }.value
    }

    private func commitSelection(_ message: String, amend: Bool, paths: [String]) async throws {
        let directory = try await gitDirectory()
        guard GitOperation.detect(in: directory) == nil else { throw GitError.operationInProgress }
        var arguments = ["commit", "--only", "--file=-"]
        if amend { arguments.append("--amend") }
        let messageData = Data(message.utf8)

        let index = try GitIndexTransaction(directory: directory)
        let snapshot = try await status()
        guard !snapshot.files.contains(where: { $0.unstaged == .conflicted }) else {
            throw GitError.command("Разрешите конфликты в индексе перед коммитом выбранных файлов.")
        }

        if !paths.isEmpty {
            let current = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0) })
            let files = try paths.map { path in
                guard let file = current[path] else { throw GitError.operationChanged }
                return file
            }
            let selected = Set(files.flatMap { [$0.path] + [$0.originalPath].compactMap { $0 } })
            let commitPaths = try selectedPathspec(selected, in: snapshot.files)

            let newPaths = files.filter { $0.unstaged == .untracked }.map(\.path)
            if !newPaths.isEmpty {
                try await write(["add", "--intent-to-add", "--pathspec-from-file=-", "--pathspec-file-nul"],
                                input: Self.pathInput(newPaths), literalPaths: true, indexFile: index.scratchIndex)
            }
            let scratch = try GitScratchDirectory()
            defer { scratch.remove() }
            let pathspec = scratch.url.appendingPathComponent("paths")
            try Self.pathInput(commitPaths).write(to: pathspec)
            arguments += ["--pathspec-from-file=\(pathspec.path)", "--pathspec-file-nul"]
            guard GitOperation.detect(in: directory) == nil else { throw GitError.operationInProgress }
            try await write(arguments, input: messageData, literalPaths: true, indexFile: index.scratchIndex)
        } else {
            guard GitOperation.detect(in: directory) == nil else { throw GitError.operationInProgress }
            try await write(arguments, input: messageData, indexFile: index.scratchIndex)
        }
        try index.install()
    }

    private func selectedPathspec(_ selected: Set<String>, in files: [GitFile]) throws -> [String] {
        guard selected.allSatisfy({ path in
            !path.utf8.contains(0) && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        }) else { throw GitError.command("Выберите отдельные файлы для коммита.") }

        func ancestors(of path: String) -> [String] {
            var result: [String] = []
            var remaining = path[...]
            while let separator = remaining.lastIndex(of: "/") {
                remaining = remaining[..<separator]
                result.append(String(remaining))
            }
            return result
        }

        // Handle replacements of a file with a directory (or the reverse) as one selection.
        let selectedAncestors = Set(selected.flatMap(ancestors(of:)))
        for path in files.lazy.flatMap({ [$0.path] + [$0.originalPath].compactMap { $0 } }) where !selected.contains(path) {
            if selectedAncestors.contains(path) || ancestors(of: path).contains(where: selected.contains) {
                throw GitError.command("Путь «\(path)» связан с выбранным изменением. Включите его в коммит или снимите выбор со связанных путей.")
            }
        }
        return selected.sorted().filter { path in
            guard selectedAncestors.contains(path) else { return true }
            // Adding explicitly selected descendants also removes a tracked ancestor file that became a directory.
            var info = stat()
            let absolutePath = root.appendingPathComponent(path).path
            return lstat(absolutePath, &info) != 0 || (info.st_mode & S_IFMT) != S_IFDIR
        }
    }

    func fetch() async throws {
        try await write(["fetch", "--all", "--no-prune", "--no-prune-tags"])
    }

    func pull() async throws {
        try await write(["pull", "--ff-only", "--no-rebase", "--no-autostash", "--no-squash", "--no-prune"])
    }

    func push(expectedBranch: String? = nil, expectedUpstream: String? = nil) async throws {
        let branch = try await currentBranch(expected: expectedBranch)
        let format = "%(upstream:remotename)%00%(upstream:remoteref)%00%(upstream:short)"
        let result = try await read(["for-each-ref", "--count=1", "--format=\(format)", branch])
        let upstream = result.string.trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false)
        guard upstream.count == 3, !upstream[0].isEmpty, upstream[1].hasPrefix("refs/heads/") else {
            throw GitError.noUpstream
        }
        if let expectedUpstream, upstream[2] != expectedUpstream { throw GitError.destinationChanged }
        try await write(["push", "--no-follow-tags", "--recurse-submodules=no", "--", String(upstream[0]), "\(branch):\(upstream[1])"])
    }

    func remotes() async throws -> [String] {
        try await read(["remote"]).string.split(separator: "\n").map(String.init)
    }

    func push(setUpstreamTo remote: String, expectedBranch: String? = nil) async throws {
        let branch = try await currentBranch(expected: expectedBranch)
        let configured = try await remotes()
        guard configured.contains(remote) else { throw GitError.noUpstream }
        try await write(["push", "--no-follow-tags", "--recurse-submodules=no", "--set-upstream", "--", remote, "\(branch):\(branch)"])
    }

    func stashes() async throws -> [GitStash] {
        let result = try await read(["stash", "list", "-z", "--format=%gd%x00%H%x00%at%x00%s"])
        let fields = Self.fields(result.data)
        guard fields.count.isMultiple(of: 4) else { throw GitError.invalidResponse }
        return try stride(from: 0, to: fields.count, by: 4).map { index in
            guard let seconds = TimeInterval(fields[index + 2]) else { throw GitError.invalidResponse }
            return GitStash(ref: fields[index], hash: fields[index + 1], message: fields[index + 3],
                            date: Date(timeIntervalSince1970: seconds))
        }
    }

    func stashDetails(_ stash: GitStash) async throws -> GitCommitDetail {
        let stored = try await details(stash.hash)
        guard stored.commit.parents.count == 3, let untrackedRevision = stored.commit.parents.last else { return stored }
        let untracked = try await read(["show", "--format=", "--name-status", "-z", "--end-of-options", untrackedRevision, "--"])
        let untrackedFiles = try Self.parseChanges(untracked.data).map { file in
            GitFile(path: file.path, staged: .untracked, previewRevision: untrackedRevision)
        }
        return GitCommitDetail(commit: stored.commit, email: stored.email, message: stored.message, files: stored.files + untrackedFiles)
    }

    func stash(_ message: String = "") async throws {
        var options = ["stash", "push", "--include-untracked"]
        if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            options += ["--message", message]
        }
        try await write(options)
    }

    func applyStash(_ stash: GitStash) async throws {
        try await write(["stash", "apply", "--index", stash.hash])
    }

    func worktrees() async throws -> [GitWorktree] {
        let result = try await read(["worktree", "list", "--porcelain", "-z"])
        return Self.fields(result.data).split(separator: "").compactMap { fields in
            guard let entry = fields.first, entry.hasPrefix("worktree ") else { return nil }
            var worktree = GitWorktree(path: String(entry.dropFirst("worktree ".count)))
            for field in fields.dropFirst() {
                if field.hasPrefix("HEAD ") { worktree.hash = String(field.dropFirst("HEAD ".count)) }
                if field.hasPrefix("branch refs/heads/") { worktree.branch = String(field.dropFirst("branch refs/heads/".count)) }
                if field == "bare" { worktree.isBare = true }
                if field == "locked" || field.hasPrefix("locked ") { worktree.isLocked = true }
                if field == "prunable" || field.hasPrefix("prunable ") { worktree.isPrunable = true }
            }
            return worktree
        }
    }

    private func exactLog(_ hash: String, options: [String], skip: Int, limit: Int, path: String?, ref: String?) async throws -> [GitCommit] {
        guard skip <= 0, limit > 0 else { return [] }
        if let path {
            // Walk from the scope tips to the candidate so --follow can resolve prior names.
            let scope = ref.map { ["--end-of-options", $0] } ?? ["--exclude=refs/stash", "--all"]
            let lineage = try await read(["log", "--follow", "--topo-order", "--no-show-signature", "-z", "--format=%H"]
                + scope + ["\(hash)^!", "--", path], literalPaths: true)
            guard Self.fields(lineage.data).contains(hash) else { return [] }
        }
        let result = try await read(options + ["--no-walk", "--end-of-options", hash, "--"])
        return try Self.commits(result.data)
    }

    private func currentBranch(expected: String?) async throws -> String {
        let result = try await read(["symbolic-ref", "--quiet", "HEAD"], allowed: [0, 1])
        guard result.status == 0, result.string.hasPrefix("refs/heads/") else { throw GitError.invalidBranch }
        let branch = result.string.trimmingCharacters(in: .newlines)
        if let expected, branch != "refs/heads/\(expected)" { throw GitError.destinationChanged }
        return branch
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func readStatusHeader(_ record: String, into status: inout GitStatus) {
        if record == "# branch.oid (initial)" {
            status.isUnborn = true
        } else if record.hasPrefix("# branch.oid ") {
            status.head = String(record.dropFirst("# branch.oid ".count))
        } else if record.hasPrefix("# branch.head ") {
            let branch = String(record.dropFirst("# branch.head ".count))
            status.branch = branch == "(detached)" ? nil : branch
        } else if record.hasPrefix("# branch.upstream ") {
            status.upstream = String(record.dropFirst("# branch.upstream ".count))
        } else if record.hasPrefix("# branch.ab ") {
            let counts = record.dropFirst("# branch.ab ".count).split(separator: " ")
            if counts.count == 2 {
                status.ahead = Int(counts[0].dropFirst()) ?? 0
                status.behind = Int(counts[1].dropFirst()) ?? 0
            }
        }
    }

    private static func commits(_ data: Data) throws -> [GitCommit] {
        let fields = fields(data)
        guard fields.count.isMultiple(of: 6) else { throw GitError.invalidResponse }
        return try stride(from: 0, to: fields.count, by: 6).map { index in
            guard let commit = parseCommit(fields[index..<index + 6]) else { throw GitError.invalidResponse }
            return commit
        }
    }

    private static func parseCommit(_ fields: ArraySlice<String>) -> GitCommit? {
        let start = fields.startIndex
        guard let seconds = TimeInterval(fields[start + 4]) else { return nil }
        return GitCommit(hash: fields[start], shortHash: fields[start + 1],
                         parents: fields[start + 2].split(separator: " ").map(String.init),
                         author: fields[start + 3], date: Date(timeIntervalSince1970: seconds), subject: fields[start + 5])
    }

    private static func parseChanges(_ data: Data) throws -> [GitFile] {
        let records = fields(data)
        var files: [GitFile] = []
        var index = 0
        while index < records.count {
            if records[index].isEmpty {
                index += 1
                continue
            }
            guard index + 1 < records.count else { throw GitError.invalidResponse }
            let change = records[index].first.flatMap { GitChange(rawValue: String($0)) } ?? .modified
            let path = records[index + 1]
            if change == .renamed || change == .copied {
                guard index + 2 < records.count else { throw GitError.invalidResponse }
                files.append(GitFile(path: records[index + 2], originalPath: path, staged: change))
                index += 3
            } else {
                files.append(GitFile(path: path, staged: change))
                index += 2
            }
        }
        return files
    }

    private static func fields(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        let result = data.last == 0 ? records.dropLast() : records[...]
        return result.map { String(decoding: $0, as: UTF8.self) }
    }

    private static func pathInput(_ paths: [String]) -> Data {
        var seen: Set<String> = []
        var data = Data()
        for path in paths where seen.insert(path).inserted {
            data.append(contentsOf: path.utf8)
            data.append(0)
        }
        return data
    }

    private func read(_ arguments: [String], allowed: Set<Int32> = [0], limit: Int = 4 * 1_048_576,
                      literalPaths: Bool = false, indexFile: URL? = nil) async throws -> GitOutput {
        let options = literalPaths ? ["--literal-pathspecs"] + arguments : arguments
        let result = try await GitProcess.run(options, in: root, limit: limit, readOnly: true, input: nil, indexFile: indexFile)
        guard allowed.contains(result.status) else { throw Self.commandError(result, command: arguments[0]) }
        return result
    }

    private func write(_ arguments: [String], input: Data? = nil, literalPaths: Bool = false,
                       defaultEditor: Bool = false, indexFile: URL? = nil) async throws {
        let options = literalPaths ? ["--literal-pathspecs"] + arguments : arguments
        let result = try await GitProcess.run(options, in: root, limit: 4 * 1_048_576, readOnly: false,
                                              input: input, defaultEditor: defaultEditor, indexFile: indexFile)
        guard result.status == 0 else { throw Self.commandError(result, command: arguments[0]) }
    }

    private static func commandError(_ output: GitOutput, command: String) -> GitError {
        let error = output.error.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = output.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = stdout.isEmpty ? "Команда git \(command) завершилась с кодом \(output.status)." : stdout
        return .command(error.isEmpty ? fallback : error)
    }
}

private struct GitScratchDirectory {
    let url: URL

    init() throws {
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("branchline-git-XXXXXX").path
        var path = Array(template.utf8CString)
        guard mkdtemp(&path) != nil else { throw GitError.command("Не удалось подготовить временную папку для Git.") }
        url = URL(fileURLWithPath: path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, isDirectory: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private final class GitIndexTransaction {
    let scratchIndex: URL
    private let liveIndex: URL
    private let lockFile: URL
    private let lockDescriptor: Int32
    private var retainScratchIndex = false

    init(directory: URL) throws {
        let liveIndex = directory.appendingPathComponent("index").resolvingSymlinksInPath()
        let lockFile = URL(fileURLWithPath: liveIndex.path + ".lock")
        let descriptor = open(lockFile.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw GitError.command("Индекс занят другой операцией Git. Повторите после её завершения.") }
            throw GitError.command("Не удалось заблокировать индекс Git.")
        }
        let scratch = liveIndex.deletingLastPathComponent().appendingPathComponent("branchline-index-" + UUID().uuidString)
        do {
            if FileManager.default.fileExists(atPath: liveIndex.path) {
                try FileManager.default.copyItem(at: liveIndex, to: scratch)
            }
        } catch {
            close(descriptor)
            unlink(lockFile.path)
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        self.liveIndex = liveIndex
        self.lockFile = lockFile
        lockDescriptor = descriptor
        scratchIndex = scratch
    }

    func install() throws {
        guard rename(scratchIndex.path, liveIndex.path) == 0 else {
            retainScratchIndex = true
            throw GitError.command("Коммит создан, но обновить индекс не удалось. Новый индекс сохранён в «\(scratchIndex.path)».")
        }
    }

    deinit {
        close(lockDescriptor)
        unlink(lockFile.path)
        if !retainScratchIndex { try? FileManager.default.removeItem(at: scratchIndex) }
    }
}

private struct GitOutput: Sendable {
    let data: Data
    let error: String
    let status: Int32

    var string: String { String(decoding: data, as: UTF8.self) }
}

private final class GitProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var stderr = Data()

    private static let queue = DispatchQueue(label: "Branchline.Git.Process", qos: .userInitiated, attributes: .concurrent)
    private static let executables = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
    private static let repositoryEnvironment = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX",
        "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS",
    ]

    static func run(_ arguments: [String], in root: URL, limit: Int, readOnly: Bool, input: Data?,
                    defaultEditor: Bool = false, indexFile: URL? = nil) async throws -> GitOutput {
        let operation = GitProcess()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let output: GitOutput = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try operation.execute(arguments, in: root, limit: limit, readOnly: readOnly,
                                              input: input, defaultEditor: defaultEditor, indexFile: indexFile)
                    })
                }
            }
            try Task.checkCancellation()
            return output
        } onCancel: {
            operation.cancel()
        }
    }

    private func execute(_ arguments: [String], in root: URL, limit: Int, readOnly: Bool, input: Data?,
                         defaultEditor: Bool, indexFile: URL?) throws -> GitOutput {
        guard let executable = Self.executables.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw GitError.command("Git не найден. Установите Command Line Tools или Git через Homebrew.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = root
        process.arguments = ["--no-pager", "-c", "color.ui=false", "-c", "core.quotepath=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in Self.repositoryEnvironment { environment.removeValue(forKey: key) }
        if let indexFile { environment["GIT_INDEX_FILE"] = indexFile.path }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(path):/opt/homebrew/bin:/usr/local/bin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if readOnly { environment["GIT_OPTIONAL_LOCKS"] = "0" }
        if defaultEditor {
            environment["GIT_EDITOR"] = "/usr/bin/true"
            environment["GIT_SEQUENCE_EDITOR"] = "/usr/bin/true"
        }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = try input.map(Self.temporaryInput) ?? FileHandle.nullDevice
        defer { if input != nil { try? stdin.close() } }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
            self.process = process
        }
        defer { lock.withLock { self.process = nil } }

        let drain = DispatchGroup()
        drain.enter()
        Self.queue.async { [self] in
            defer { drain.leave() }
            let result = try? Self.read(stderr.fileHandleForReading, limit: 64 * 1024)
            lock.withLock { self.stderr = result?.data ?? Data() }
        }
        let output = Result { try Self.read(stdout.fileHandleForReading, limit: limit) {
            if readOnly { self.terminate() }
        } }
        process.waitUntilExit()
        drain.wait()
        if lock.withLock({ cancelled }) { throw CancellationError() }
        let result = try output.get()
        if readOnly, result.truncated { throw GitError.outputLimit(limit) }
        let diagnostic = lock.withLock { String(decoding: self.stderr, as: UTF8.self) }
        return GitOutput(data: result.data, error: diagnostic, status: process.terminationStatus)
    }

    private func cancel() {
        lock.withLock {
            cancelled = true
            terminateProcess()
        }
    }

    private func terminate() {
        lock.withLock { terminateProcess() }
    }

    private func terminateProcess() {
        if let process, process.isRunning { process.terminate() }
    }

    private static func read(_ handle: FileHandle, limit: Int, onOverflow: () -> Void = {}) throws -> (data: Data, truncated: Bool) {
        defer { try? handle.close() }
        var data = Data()
        var truncated = false
        while let chunk = try handle.read(upToCount: 32 * 1024), !chunk.isEmpty {
            let remaining = limit - data.count
            if remaining >= chunk.count {
                data.append(chunk)
            } else if !truncated {
                data.append(contentsOf: chunk.prefix(remaining))
                truncated = true
                onOverflow()
            }
        }
        return (data, truncated)
    }

    private static func temporaryInput(_ input: Data) throws -> FileHandle {
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("branchline-input-XXXXXX").path
        var characters = Array(template.utf8CString)
        let fileDescriptor = mkstemp(&characters)
        guard fileDescriptor >= 0 else { throw GitError.command("Не удалось подготовить данные для Git.") }
        _ = unlink(&characters)
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        try handle.write(contentsOf: input)
        try handle.seek(toOffset: 0)
        return handle
    }
}
