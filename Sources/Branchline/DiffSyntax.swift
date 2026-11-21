import Foundation

enum DiffSyntax: Equatable, Sendable {
    case javascript, jsx, css, json, swift, shell, python, markup

    enum Kind: Sendable {
        case keyword, string, number, comment, type, property, tag
    }

    struct Token: Equatable, Sendable {
        let range: NSRange
        let kind: Kind
    }

    static let lineLimit = 2_048
    private static let tokenLimit = 128

    init?(path: String) {
        let name = path.split(separator: "/").last?.lowercased() ?? ""
        switch name.split(separator: ".", omittingEmptySubsequences: false).last {
        case "js", "mjs", "cjs", "ts", "mts", "cts": self = .javascript
        case "jsx", "tsx": self = .jsx
        case "css", "scss", "less": self = .css
        case "json", "jsonc", "json5": self = .json
        case "swift": self = .swift
        case "sh", "bash", "zsh", "ksh", "bashrc", "zshrc", "zprofile": self = .shell
        case "py", "pyi", "pyw": self = .python
        case "html", "htm", "xml", "svg", "plist": self = .markup
        default: return nil
        }
    }

    func tokens(in text: String) -> [Token] {
        guard !text.isEmpty, text.utf8.count <= Self.lineLimit else { return [] }
        let units = Array(text.utf16)
        var cursor = 0
        var result: [Token] = []
        var insideTag = false
        var tagExpressionDepth = 0
        var cssValue = false
        let cssSelectorEnd = self == .css ? units.firstIndex(of: 123) : nil

        func emit(_ kind: Kind, from start: Int) {
            result.append(Token(range: NSRange(location: start, length: cursor - start), kind: kind))
        }

        while cursor < units.count && result.count < Self.tokenLimit {
            let start = cursor
            let unit = units[cursor]
            let next = cursor + 1 < units.count ? units[cursor + 1] : 0
            cursor += 1

            if isSlashComment(unit, next) || isHashComment(unit, at: start, in: units) {
                cursor = units.count
                emit(.comment, from: start)
                continue
            }
            if unit == 47, next == 42, Self.slashBlockLanguages.contains(self) {
                cursor = end(of: [42, 47], in: units, after: start + 2)
                emit(.comment, from: start)
                continue
            }
            if self == .markup, unit == 60, units[start...].starts(with: [60, 33, 45, 45]) {
                cursor = end(of: [45, 45, 62], in: units, after: start + 4)
                emit(.comment, from: start)
                continue
            }
            if (self == .markup || self == .jsx), unit == 60 {
                if self == .jsx, next != 47, start > 0, Self.isWord(units[start - 1]) { continue }
                if cursor < units.count, units[cursor] == 47 { cursor += 1 }
                if cursor < units.count, Self.isWordStart(units[cursor]) || units[cursor] == 33 {
                    cursor += 1
                    while cursor < units.count && Self.isMarkupName(units[cursor]) { cursor += 1 }
                    emit(.tag, from: start)
                    insideTag = true
                }
                continue
            }
            if insideTag && self == .jsx {
                if unit == 123 { tagExpressionDepth += 1 }
                if unit == 125 && tagExpressionDepth > 0 { tagExpressionDepth -= 1 }
            }
            let insideAttributes = insideTag && tagExpressionDepth == 0
            if insideAttributes, unit == 62 {
                emit(.tag, from: start)
                insideTag = false
                continue
            }
            if self == .markup && !insideTag { continue }

            if unit == 34 || unit == 39 ||
                unit == 96 && (self == .javascript || self == .jsx || self == .shell) {
                cursor = endOfString(unit, in: units, after: cursor)
                emit(self == .json && Self.nextIs(58, in: units, from: cursor) ? .property : .string, from: start)
                continue
            }
            if isNumberStart(unit, next: next, previous: start > 0 ? units[start - 1] : 0) {
                cursor = endOfNumber(in: units, from: start)
                emit(.number, from: start)
                continue
            }
            if (self == .swift || self == .css) && (unit == 64 || unit == 35 && self == .swift),
               Self.isWordStart(next) {
                while cursor < units.count && (Self.isWord(units[cursor]) || self == .css && units[cursor] == 45) {
                    cursor += 1
                }
                emit(.keyword, from: start)
                continue
            }
            if self == .css {
                if unit == 58 && start > (cssSelectorEnd ?? -1) { cssValue = true }
                if unit == 123 || unit == 125 || unit == 59 { cssValue = false }
                if unit == 35, cssValue {
                    while cursor < units.count && Self.isHexDigit(units[cursor]) { cursor += 1 }
                    if [4, 5, 7, 9].contains(cursor - start),
                       cursor == units.count || !Self.isMarkupName(units[cursor]) {
                        emit(.number, from: start)
                    }
                    continue
                }
            }

            let cssName = self == .css && unit == 45 && (Self.isWordStart(next) || next == 45)
            guard Self.isWordStart(unit) || cssName else { continue }
            while cursor < units.count {
                let next = units[cursor]
                let isName = insideAttributes ? Self.isMarkupName(next) : Self.isWord(next) || self == .css && next == 45
                guard isName else { break }
                cursor += 1
            }
            let declarations = cssSelectorEnd.map { start > $0 } ?? true
            if let kind = kind(of: units[start..<cursor], insideTag: insideAttributes, in: units,
                               after: cursor, cssDeclaration: declarations) {
                emit(kind, from: start)
            }
        }
        return result
    }

    private static let slashBlockLanguages: [Self] = [.javascript, .jsx, .css, .json, .swift]

    private func isSlashComment(_ unit: UInt16, _ next: UInt16) -> Bool {
        unit == 47 && next == 47 && (self == .javascript || self == .jsx || self == .swift || self == .json)
    }

    private func isHashComment(_ unit: UInt16, at index: Int, in units: [UInt16]) -> Bool {
        guard unit == 35 else { return false }
        if self == .python { return true }
        guard self == .shell else { return false }
        return index == 0 || Self.isSpace(units[index - 1]) || [59, 124, 38, 40, 41].contains(units[index - 1])
    }

    private func end(of marker: [UInt16], in units: [UInt16], after index: Int) -> Int {
        var cursor = index
        while cursor + marker.count <= units.count {
            if units[cursor...].starts(with: marker) { return cursor + marker.count }
            cursor += 1
        }
        return units.count
    }

    private func endOfString(_ quote: UInt16, in units: [UInt16], after index: Int) -> Int {
        var cursor = index
        let escapes = self != .markup && !(self == .shell && quote == 39)
        while cursor < units.count {
            let unit = units[cursor]
            cursor += 1
            if escapes, unit == 92, cursor < units.count { cursor += 1 }
            else if unit == quote { return cursor }
        }
        return cursor
    }

    private func isNumberStart(_ unit: UInt16, next: UInt16, previous: UInt16) -> Bool {
        guard self != .markup, !Self.isWord(previous) else { return false }
        if self == .shell && previous == 35 { return false }
        return Self.isDigit(unit) || unit == 46 && Self.isDigit(next) ||
            unit == 45 && Self.isDigit(next) && (self == .css || self == .json)
    }

    private func endOfNumber(in units: [UInt16], from start: Int) -> Int {
        var cursor = start
        if units[cursor] == 45 { cursor += 1 }
        if units[cursor] == 48, cursor + 1 < units.count {
            let base = units[cursor + 1]
            if [66, 79, 88, 98, 111, 120].contains(base) {
                let radix: UInt16 = (base | 32) == 98 ? 2 : (base | 32) == 111 ? 8 : 16
                cursor += 2
                while cursor < units.count {
                    let unit = units[cursor]
                    if unit == 95 || Self.isDigit(unit) && unit - 48 < radix ||
                        radix == 16 && Self.isHexDigit(unit) { cursor += 1 }
                    else { break }
                }
                if cursor < units.count, units[cursor] == 110 { cursor += 1 }
                return cursor
            }
        }
        while cursor < units.count && (Self.isDigit(units[cursor]) || units[cursor] == 95) { cursor += 1 }
        if cursor + 1 < units.count, units[cursor] == 46, Self.isDigit(units[cursor + 1]) {
            cursor += 1
            while cursor < units.count && (Self.isDigit(units[cursor]) || units[cursor] == 95) { cursor += 1 }
        }
        if cursor + 1 < units.count, units[cursor] == 69 || units[cursor] == 101 {
            var exponent = cursor + 1
            if units[exponent] == 43 || units[exponent] == 45 { exponent += 1 }
            if exponent < units.count, Self.isDigit(units[exponent]) {
                cursor = exponent + 1
                while cursor < units.count && Self.isDigit(units[cursor]) { cursor += 1 }
            }
        }
        if cursor < units.count, units[cursor] == 110 && (self == .javascript || self == .jsx) { cursor += 1 }
        return cursor
    }

    private func kind(of word: ArraySlice<UInt16>, insideTag: Bool, in units: [UInt16],
                      after index: Int, cssDeclaration: Bool) -> Kind? {
        if insideTag { return .property }
        if self == .css {
            if cssDeclaration && Self.nextIs(58, in: units, from: index) { return .property }
        } else if (self == .javascript || self == .jsx || self == .json), Self.nextIs(58, in: units, from: index) {
            return .property
        }
        if self == .shell, word.first == 36 { return .property }
        guard word.count <= 32 else { return nil }
        let text = String(decoding: word, as: UTF16.self)
        if keywords.contains(text) { return .keyword }
        if types.contains(text) { return .type }
        return nil
    }

    private var keywords: Set<String> {
        switch self {
        case .javascript, .jsx: Self.jsKeywords
        case .swift: Self.swiftKeywords
        case .python: Self.pythonKeywords
        case .shell: Self.shellKeywords
        case .json: Self.jsonKeywords
        case .css: Self.cssKeywords
        case .markup: []
        }
    }

    private var types: Set<String> {
        switch self {
        case .javascript, .jsx: Self.jsTypes
        case .swift: Self.swiftTypes
        case .python: Self.pythonTypes
        default: []
        }
    }

    private static let jsKeywords = Set("""
        abstract as async await break case catch class const continue debugger declare default delete do else enum export extends
        false finally for from function if implements import in infer instanceof interface is keyof let module namespace new null
        of override private protected public readonly return satisfies static super switch this throw true try type typeof undefined
        var void while with yield
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    private static let jsTypes = Set("""
        any bigint boolean never number object string symbol unknown Array BigInt Boolean Date Error Map Number Object Promise
        Record RegExp Set String Symbol WeakMap WeakSet
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    private static let swiftKeywords = Set("""
        actor as associatedtype async await break case catch class continue convenience default defer deinit didSet do else enum
        extension fallthrough false fileprivate final for func get guard if import in indirect init inout internal is isolated lazy
        let mutating nil nonisolated nonmutating open operator override package private protocol public repeat required return self
        set some static struct subscript super switch throws throw true try typealias var where while willSet
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    private static let swiftTypes: Set<String> = [
        "Any", "AnyObject", "Array", "Bool", "Character", "Data", "Date", "Dictionary", "Double", "Float", "Int",
        "Int8", "Int16", "Int32", "Int64", "Never", "Optional", "Result", "Self", "Set", "String", "Substring", "Task",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "URL", "Void",
    ]
    private static let pythonKeywords = Set("""
        False None True and as assert async await break case class continue def del elif else except finally for from global if
        import in is lambda match nonlocal not or pass raise return try while with yield
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    private static let pythonTypes: Set<String> = [
        "bool", "bytes", "complex", "dict", "float", "frozenset", "int", "list", "object", "set", "str", "tuple",
    ]
    private static let shellKeywords: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "readonly",
        "return", "select", "then", "time", "trap", "until", "while",
    ]
    private static let jsonKeywords: Set<String> = ["true", "false", "null", "Infinity", "NaN"]
    private static let cssKeywords: Set<String> = ["important", "inherit", "initial", "revert", "unset"]

    private static func nextIs(_ unit: UInt16, in units: [UInt16], from start: Int) -> Bool {
        var cursor = start
        while cursor < units.count && isSpace(units[cursor]) { cursor += 1 }
        return cursor < units.count && units[cursor] == unit
    }

    private static func isDigit(_ unit: UInt16) -> Bool { (48...57).contains(unit) }
    private static func isHexDigit(_ unit: UInt16) -> Bool { isDigit(unit) || (97...102).contains(unit | 32) }
    private static func isSpace(_ unit: UInt16) -> Bool { unit == 9 || unit == 32 }
    private static func isWordStart(_ unit: UInt16) -> Bool {
        (97...122).contains(unit | 32) || unit == 95 || unit == 36 || unit >= 128
    }
    private static func isWord(_ unit: UInt16) -> Bool { isWordStart(unit) || isDigit(unit) }
    private static func isMarkupName(_ unit: UInt16) -> Bool { isWord(unit) || unit == 45 || unit == 46 || unit == 58 }
}
