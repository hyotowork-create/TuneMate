import Foundation

/// 공급자 간 공통으로 쓰는 JSON 값.
public indirect enum JSONValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid JSON") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): if n == n.rounded() && abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? {
        switch self { case .number(let n): return n; case .string(let s): return Double(s); case .bool(let b): return b ? 1 : 0; default: return nil }
    }
    public var intValue: Int? { doubleValue.map { Int($0) } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; if case .string(let s) = self { return Bool(s) }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    public var description: String { (try? jsonString(pretty: false)) ?? "<json>" }

    public func jsonString(pretty: Bool = true) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return String(decoding: try enc.encode(self), as: UTF8.self)
    }
    public static func parse(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
    public static func parse(_ s: String) throws -> JSONValue { try parse(Data(s.utf8)) }

    // 편의 생성자
    public static func obj(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }
    public static func num(_ i: Int) -> JSONValue { .number(Double(i)) }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
}
