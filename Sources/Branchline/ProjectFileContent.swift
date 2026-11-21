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

        var info = stat()
        guard fstat(file, &info) == 0 else { throw ProjectFileSystem.error() }
        guard info.st_mode & S_IFMT == S_IFREG else { return .unsupported }
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

        let truncated = info.st_size > byteLimit && count == byteLimit
        guard let text = decode(bytes, truncated: truncated), !text.unicodeScalars.contains(where: isBinaryControl) else {
            return .unsupported
        }
        return .text(text, truncated: truncated)
    }

    private static func decode(_ bytes: Data, truncated: Bool) -> String? {
        let skip: Int
        let encoding: String.Encoding
        if bytes.starts(with: [0xFF, 0xFE]) {
            skip = 2
            encoding = .utf16LittleEndian
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            skip = 2
            encoding = .utf16BigEndian
        } else {
            skip = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
            encoding = .utf8
        }
        let payload = bytes.dropFirst(skip)
        if let text = String(data: payload, encoding: encoding) { return text }
        guard truncated else { return nil }

        // The byte cap can fall in the middle of the last Unicode scalar.
        for length in 1...3 {
            if let text = String(data: payload.dropLast(length), encoding: encoding) { return text }
        }
        return nil
    }

    private static func isBinaryControl(_ scalar: Unicode.Scalar) -> Bool {
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
