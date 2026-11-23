import Darwin
import Foundation

enum ProjectFileContent: Sendable {
    case text(String, truncated: Bool)
    case unsupported

    private static let byteLimit = 512 * 1024

    static func read(root: URL, path: String) throws -> Self {
        try Task.checkCancellation()
        let components = try ProjectFileSystem.components(path)
        guard let name = components.last else { throw POSIXError(.EINVAL) }
        let directory = try ProjectFileSystem.openDirectory(root: root, components: components.dropLast())
        defer { close(directory) }

        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        let file = name.withCString { openat(directory, $0, flags) }
        guard file >= 0 else {
            if errno == ELOOP { return .unsupported }
            throw ProjectFileSystem.error()
        }
        defer { close(file) }

        guard let snapshot = try readBytes(file),
              let text = decode(snapshot.bytes, truncated: snapshot.truncated),
              !text.unicodeScalars.contains(where: isBinaryControl) else { return .unsupported }
        return .text(text, truncated: snapshot.truncated)
    }

    fileprivate static func readBytes(_ file: Int32) throws -> (bytes: Data, truncated: Bool, info: stat)? {
        var info = stat()
        guard fstat(file, &info) == 0 else { throw ProjectFileSystem.error() }
        guard info.st_mode & S_IFMT == S_IFREG else { return nil }
        var bytes = Data(count: Int(min(info.st_size, off_t(byteLimit))))
        let count = try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.read(file, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ProjectFileSystem.error()
                }
                if count == 0 { break }
                offset += count
            }
            return offset
        }
        bytes.count = count
        try Task.checkCancellation()

        var latest = stat()
        guard fstat(file, &latest) == 0 else { throw ProjectFileSystem.error() }
        guard info.st_size == latest.st_size,
              info.st_mtimespec.tv_sec == latest.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == latest.st_mtimespec.tv_nsec else { throw WorktreeFileError.changed }
        return (bytes, info.st_size > byteLimit && count == byteLimit, info)
    }

    fileprivate static func encoding(of bytes: Data) -> (bomSize: Int, value: String.Encoding) {
        if bytes.starts(with: [0xFF, 0xFE]) {
            return (2, .utf16LittleEndian)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            return (2, .utf16BigEndian)
        }
        return (bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0, .utf8)
    }

    fileprivate static func decode(_ bytes: Data, truncated: Bool) -> String? {
        let (skip, encoding) = encoding(of: bytes)
        let payload = bytes.dropFirst(skip)
        if let text = String(data: payload, encoding: encoding) { return text }
        guard truncated else { return nil }

        // The byte cap can fall in the middle of the last Unicode scalar.
        for length in 1...3 {
            if let text = String(data: payload.dropLast(length), encoding: encoding) { return text }
        }
        return nil
    }

    fileprivate static func isBinaryControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F...0x9F: true
        default: false
        }
    }
}

enum ProjectFileSystem {
    static func components(_ path: String) throws -> [String] {
        guard !path.isEmpty else { return [] }
        guard !path.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        let components = path.utf8.split(separator: 0x2F, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard components.first != ".git", components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw POSIXError(.EINVAL)
        }
        return components
    }

    static func openDirectory(root: URL, components: ArraySlice<String>) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
        var directory = try root.withUnsafeFileSystemRepresentation { name in
            guard let name else { throw POSIXError(.EINVAL) }
            let descriptor = open(name, flags)
            guard descriptor >= 0 else { throw error() }
            return descriptor
        }
        do {
            for component in components {
                try Task.checkCancellation()
                // Resolve each child relative to the open parent and never traverse a symlink.
                let child = component.withCString { openat(directory, $0, flags | O_NOFOLLOW) }
                guard child >= 0 else { throw error() }
                close(directory)
                directory = child
            }
            return directory
        } catch {
            close(directory)
            throw error
        }
    }

    static func error() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

enum WorktreeFileError: LocalizedError {
    case unsupported, changed

    var errorDescription: String? {
        switch self {
        case .unsupported: "Редактировать можно текстовые файлы размером до 512 КиБ."
        case .changed: "Файл изменился на диске. Откройте его заново перед сохранением."
        }
    }
}

struct WorktreeFileDraft: Sendable {
    let text: String
    private let original: Data

    static func read(root: URL, path: String) throws -> Self {
        try withParent(root: root, path: path) { directory, name in
            let snapshot = try snapshot(in: directory, name: name)
            guard let text = ProjectFileContent.decode(snapshot.bytes, truncated: false),
                  !text.unicodeScalars.contains(where: ProjectFileContent.isBinaryControl) else {
                throw WorktreeFileError.unsupported
            }
            return Self(text: text, original: snapshot.bytes)
        }
    }

    func save(_ text: String, root: URL, path: String) throws {
        guard !text.utf8.elementsEqual(self.text.utf8) else { return }
        let (bomSize, encoding) = ProjectFileContent.encoding(of: original)
        guard let payload = text.data(using: encoding) else { throw WorktreeFileError.unsupported }
        var bytes = Data(original.prefix(bomSize))
        bytes.append(payload)
        try Self.withParent(root: root, path: path) { directory, name in
            let current = try Self.snapshot(in: directory, name: name)
            guard current.bytes == original else { throw WorktreeFileError.changed }
            let temporary = ".branchline-edit-" + UUID().uuidString
            let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw ProjectFileSystem.error() }
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { _ = unlinkat(directory, temporary, 0) }
            try output.write(contentsOf: bytes)
            guard fchmod(descriptor, current.info.st_mode & 0o777) == 0 else { throw ProjectFileSystem.error() }
            try output.close()

            let latest = try Self.snapshot(in: directory, name: name)
            guard latest.info.st_ino == current.info.st_ino, latest.bytes == original else {
                throw WorktreeFileError.changed
            }
            guard renameat(directory, temporary, directory, name) == 0 else { throw ProjectFileSystem.error() }
        }
    }

    static func trash(root: URL, path: String) throws {
        try withParent(root: root, path: path) { directory, name in
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ProjectFileSystem.error()
            }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFLNK else { throw POSIXError(.EINVAL) }
            var parent = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(directory, F_GETPATH, &parent) == 0 else { throw ProjectFileSystem.error() }
            let url = URL(fileURLWithFileSystemRepresentation: parent, isDirectory: true, relativeTo: nil)
            try FileManager.default.trashItem(at: url.appendingPathComponent(name), resultingItemURL: nil)
        }
    }

    private static func snapshot(in directory: Int32, name: String) throws -> (bytes: Data, info: stat) {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw ProjectFileSystem.error() }
        defer { close(file) }
        guard let snapshot = try ProjectFileContent.readBytes(file), !snapshot.truncated else {
            throw WorktreeFileError.unsupported
        }
        return (snapshot.bytes, snapshot.info)
    }

    private static func withParent<T>(root: URL, path: String, _ action: (Int32, String) throws -> T) throws -> T {
        let components = try ProjectFileSystem.components(path)
        guard let name = components.last else { throw POSIXError(.EINVAL) }
        let directory = try ProjectFileSystem.openDirectory(root: root, components: components.dropLast())
        defer { close(directory) }
        return try action(directory, name)
    }
}
