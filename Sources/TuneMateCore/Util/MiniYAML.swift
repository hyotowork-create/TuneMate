import Foundation

/// 의존성 없는 작은 YAML 부분집합 파서.
/// 지원: 중첩 매핑(들여쓰기), 블록 시퀀스(- 항목), 인라인 시퀀스 [a, b], 인라인 매핑 { a: 1 }, 스칼라(문자열·정수·실수·불·null·0x 헥사), # 주석.
public indirect enum YAMLValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([YAMLValue])
    case dict([(String, YAMLValue)])

    public static func == (l: YAMLValue, r: YAMLValue) -> Bool {
        switch (l, r) {
        case (.string(let a), .string(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        case (.array(let a), .array(let b)): return a == b
        case (.dict(let a), .dict(let b)): return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public subscript(key: String) -> YAMLValue? {
        if case .dict(let d) = self { return d.first { $0.0 == key }?.1 }
        return nil
    }
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: return nil
        }
    }
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s):
            if s.lowercased() == "-inf" { return -.infinity }
            return Double(s)
        default: return nil
        }
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [YAMLValue]? { if case .array(let a) = self { return a }; return nil }
    public var dictValue: [(String, YAMLValue)]? { if case .dict(let d) = self { return d }; return nil }
    public var intArray: [Int]? { arrayValue?.compactMap(\.intValue) }
}

public enum MiniYAML {
    public struct ParseError: Error, CustomStringConvertible { public let line: Int; public let message: String; public var description: String { "YAML line \(line): \(message)" } }

    private struct Line { let indent: Int; let text: String; let number: Int }

    public static func parse(_ text: String) throws -> YAMLValue {
        var lines: [Line] = []
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let stripped = stripComment(raw)
            guard !stripped.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indent = stripped.prefix { $0 == " " }.count
            lines.append(Line(indent: indent, text: stripped.trimmingCharacters(in: .whitespaces), number: i + 1))
        }
        var idx = 0
        guard !lines.isEmpty else { return .dict([]) }
        return try parseBlock(lines, &idx, indent: lines[0].indent)
    }

    private static func stripComment(_ s: String) -> String {
        var inSingle = false, inDouble = false
        var out = ""
        for ch in s {
            if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "\"" && !inSingle { inDouble.toggle() }
            if ch == "#" && !inSingle && !inDouble { break }
            out.append(ch)
        }
        return out
    }

    private static func parseBlock(_ lines: [Line], _ idx: inout Int, indent: Int) throws -> YAMLValue {
        guard idx < lines.count else { return .null }
        if lines[idx].text.hasPrefix("- ") || lines[idx].text == "-" {
            var items: [YAMLValue] = []
            while idx < lines.count, lines[idx].indent == indent, lines[idx].text.hasPrefix("-") {
                let line = lines[idx]
                let rest = line.text.dropFirst(1).trimmingCharacters(in: .whitespaces)
                idx += 1
                if rest.isEmpty {
                    items.append(idx < lines.count && lines[idx].indent > indent ? try parseBlock(lines, &idx, indent: lines[idx].indent) : .null)
                } else if let (k, v) = splitKeyValue(rest) {
                    // "- key: value" 로 시작하는 매핑
                    var pairs: [(String, YAMLValue)] = []
                    let childIndent = indent + 2
                    if v.isEmpty {
                        pairs.append((k, idx < lines.count && lines[idx].indent > indent ? try parseBlock(lines, &idx, indent: lines[idx].indent) : .null))
                    } else {
                        pairs.append((k, try parseScalarOrInline(v, line: line.number)))
                    }
                    while idx < lines.count, lines[idx].indent >= childIndent, !lines[idx].text.hasPrefix("-") {
                        if case .dict(let more) = try parseBlock(lines, &idx, indent: lines[idx].indent) { pairs.append(contentsOf: more) }
                    }
                    items.append(.dict(pairs))
                } else {
                    items.append(try parseScalarOrInline(rest, line: line.number))
                }
            }
            return .array(items)
        }
        var pairs: [(String, YAMLValue)] = []
        while idx < lines.count, lines[idx].indent == indent {
            let line = lines[idx]
            if line.text.hasPrefix("-") { break }
            guard let (k, v) = splitKeyValue(line.text) else { throw ParseError(line: line.number, message: "expected key: value") }
            idx += 1
            if v.isEmpty {
                if idx < lines.count, lines[idx].indent > indent || (lines[idx].indent == indent && lines[idx].text.hasPrefix("-")) {
                    pairs.append((k, try parseBlock(lines, &idx, indent: lines[idx].indent)))
                } else { pairs.append((k, .null)) }
            } else {
                pairs.append((k, try parseScalarOrInline(v, line: line.number)))
            }
        }
        if idx < lines.count, lines[idx].indent > indent {
            throw ParseError(line: lines[idx].number, message: "unexpected indentation")
        }
        return .dict(pairs)
    }

    private static func splitKeyValue(_ s: String) -> (String, String)? {
        var inSingle = false, inDouble = false, depth = 0
        for (i, ch) in s.enumerated() {
            if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "\"" && !inSingle { inDouble.toggle() }
            if ch == "[" || ch == "{" { depth += 1 }
            if ch == "]" || ch == "}" { depth -= 1 }
            if ch == ":" && !inSingle && !inDouble && depth == 0 {
                let next = s.index(s.startIndex, offsetBy: i + 1)
                if next == s.endIndex || s[next] == " " {
                    let key = String(s[..<s.index(s.startIndex, offsetBy: i)]).trimmingCharacters(in: .whitespaces)
                    let val = String(s[next...]).trimmingCharacters(in: .whitespaces)
                    return (unquote(key), val)
                }
            }
        }
        return nil
    }

    private static func parseScalarOrInline(_ s: String, line: Int) throws -> YAMLValue {
        if s.hasPrefix("[") && s.hasSuffix("]") {
            let inner = String(s.dropFirst().dropLast())
            return .array(try splitTopLevel(inner).map { try parseScalarOrInline($0, line: line) })
        }
        if s.hasPrefix("{") && s.hasSuffix("}") {
            let inner = String(s.dropFirst().dropLast())
            var pairs: [(String, YAMLValue)] = []
            for part in try splitTopLevel(inner) {
                guard let (k, v) = splitKeyValue(part) else { throw ParseError(line: line, message: "bad inline mapping") }
                pairs.append((k, try parseScalarOrInline(v, line: line)))
            }
            return .dict(pairs)
        }
        return scalar(s)
    }

    private static func splitTopLevel(_ s: String) throws -> [String] {
        var parts: [String] = []
        var cur = ""
        var depth = 0, inSingle = false, inDouble = false
        for ch in s {
            if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "\"" && !inSingle { inDouble.toggle() }
            if !inSingle && !inDouble {
                if ch == "[" || ch == "{" { depth += 1 }
                if ch == "]" || ch == "}" { depth -= 1 }
                if ch == "," && depth == 0 { parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            }
            cur.append(ch)
        }
        let last = cur.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    private static func unquote(_ s: String) -> String {
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")), s.count >= 2 { return String(s.dropFirst().dropLast()) }
        return s
    }

    static func scalar(_ raw: String) -> YAMLValue {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "~" || s.lowercased() == "null" { return .null }
        if s.hasPrefix("\"") || s.hasPrefix("'") { return .string(unquote(s)) }
        switch s.lowercased() {
        case "true", "yes", "on": return .bool(true)
        case "false", "no", "off": return .bool(false)
        default: break
        }
        if s.lowercased().hasPrefix("0x"), let v = Int(s.dropFirst(2), radix: 16) { return .int(v) }
        if let i = Int(s) { return .int(i) }
        if let d = Double(s) { return .double(d) }
        return .string(s)
    }
}
