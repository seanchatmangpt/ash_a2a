import Foundation

/// Typed refusal. The approver never signs on any refusal.
public struct ApproverRefusal: Error, Equatable, CustomStringConvertible {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var description: String { "REFUSED(\(code))" }
}

public indirect enum JSONValue: Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int64)
    case bool(Bool)
    case null
}

/// Strict JSON parser: no floats, no duplicate keys, bounded size and depth, no trailing bytes.
public enum StrictJSON {
    public static let maxBytes = 65_536
    static let maxDepth = 16

    public static func parse(_ data: Data, maxBytes: Int = StrictJSON.maxBytes) throws -> JSONValue {
        if data.count > maxBytes { throw ApproverRefusal("oversize") }
        var p = Parser(bytes: [UInt8](data))
        let v = try p.value(depth: 0)
        p.ws()
        if p.i != p.bytes.count { throw ApproverRefusal("trailing_bytes") }
        return v
    }

    /// Parse and require that `data` is byte-identical to its own JCS serialisation.
    public static func parseCanonical(_ data: Data, maxBytes: Int = StrictJSON.maxBytes) throws -> JSONValue {
        let v = try parse(data, maxBytes: maxBytes)
        if JCS.serialize(v) != data { throw ApproverRefusal("not_canonical") }
        return v
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func ws() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            ws()
            if depth > StrictJSON.maxDepth { throw ApproverRefusal("too_deep") }
            guard i < bytes.count else { throw ApproverRefusal("unexpected_end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try lit("true"); return .bool(true)
            case UInt8(ascii: "f"): try lit("false"); return .bool(false)
            case UInt8(ascii: "n"): try lit("null"); return .null
            default: return try number()
            }
        }

        mutating func lit(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= bytes.count, Array(bytes[i..<i + u.count]) == u else { throw ApproverRefusal("bad_literal") }
            i += u.count
        }

        mutating func number() throws -> JSONValue {
            let start = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            let ds = i
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
            if i == ds { throw ApproverRefusal("bad_number") }
            if i < bytes.count, [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[i]) {
                throw ApproverRefusal("float_refused")
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if text.hasPrefix("0") && text.count > 1 || text.hasPrefix("-0") { throw ApproverRefusal("bad_number") }
            guard let n = Int64(text) else { throw ApproverRefusal("integer_out_of_range") }
            return .int(n)
        }

        mutating func string() throws -> String {
            i += 1
            var out = [UInt8]()
            while true {
                guard i < bytes.count else { throw ApproverRefusal("unterminated_string") }
                let b = bytes[i]
                if b == UInt8(ascii: "\"") { i += 1; break }
                if b < 0x20 { throw ApproverRefusal("control_in_string") }
                if b == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { throw ApproverRefusal("unterminated_string") }
                    let e = bytes[i]; i += 1
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var cu = try hex4()
                        if (0xD800...0xDBFF).contains(cu) {
                            guard i + 1 < bytes.count, bytes[i] == 0x5C, bytes[i + 1] == UInt8(ascii: "u") else { throw ApproverRefusal("bad_surrogate") }
                            i += 2
                            let lo = try hex4()
                            guard (0xDC00...0xDFFF).contains(lo) else { throw ApproverRefusal("bad_surrogate") }
                            cu = 0x10000 + ((cu - 0xD800) << 10) + (lo - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(cu) { throw ApproverRefusal("bad_surrogate") }
                        guard let sc = Unicode.Scalar(cu) else { throw ApproverRefusal("bad_escape") }
                        out.append(contentsOf: Array(String(Character(sc)).utf8))
                    default: throw ApproverRefusal("bad_escape")
                    }
                } else { out.append(b); i += 1 }
            }
            guard let s = String(bytes: out, encoding: .utf8) else { throw ApproverRefusal("bad_utf8") }
            return s
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16),
                  bytes[i..<i + 4].allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) })
            else { throw ApproverRefusal("bad_escape") }
            i += 4
            return v
        }

        mutating func array(depth: Int) throws -> JSONValue {
            i += 1
            var items = [JSONValue]()
            ws()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                items.append(try value(depth: depth + 1))
                ws()
                guard i < bytes.count else { throw ApproverRefusal("unexpected_end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw ApproverRefusal("bad_array")
            }
        }

        mutating func object(depth: Int) throws -> JSONValue {
            i += 1
            var d = [String: JSONValue]()
            ws()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(d) }
            while true {
                ws()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw ApproverRefusal("bad_object") }
                let k = try string()
                ws()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw ApproverRefusal("bad_object") }
                i += 1
                if d[k] != nil { throw ApproverRefusal("duplicate_key") }
                d[k] = try value(depth: depth + 1)
                ws()
                guard i < bytes.count else { throw ApproverRefusal("unexpected_end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(d) }
                throw ApproverRefusal("bad_object")
            }
        }
    }
}

/// RFC 8785 (JCS) serialisation of the integer-only JSON subset this approver accepts.
public enum JCS {
    public static func serialize(_ v: JSONValue) -> Data {
        var out = [UInt8]()
        write(v, &out)
        return Data(out)
    }

    static func write(_ v: JSONValue, _ out: inout [UInt8]) {
        switch v {
        case .null: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .int(let n): out += Array(String(n).utf8)
        case .string(let s): writeString(s, &out)
        case .array(let a):
            out.append(UInt8(ascii: "["))
            for (idx, e) in a.enumerated() { if idx > 0 { out.append(UInt8(ascii: ",")) }; write(e, &out) }
            out.append(UInt8(ascii: "]"))
        case .object(let d):
            out.append(UInt8(ascii: "{"))
            // JCS: sort member names by UTF-16 code units.
            let keys = d.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            for (idx, k) in keys.enumerated() {
                if idx > 0 { out.append(UInt8(ascii: ",")) }
                writeString(k, &out)
                out.append(UInt8(ascii: ":"))
                write(d[k]!, &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    static func writeString(_ s: String, _ out: inout [UInt8]) {
        out.append(0x22)
        for sc in s.unicodeScalars {
            switch sc.value {
            case 0x22: out += [0x5C, 0x22]
            case 0x5C: out += [0x5C, 0x5C]
            case 0x08: out += [0x5C, UInt8(ascii: "b")]
            case 0x09: out += [0x5C, UInt8(ascii: "t")]
            case 0x0A: out += [0x5C, UInt8(ascii: "n")]
            case 0x0C: out += [0x5C, UInt8(ascii: "f")]
            case 0x0D: out += [0x5C, UInt8(ascii: "r")]
            case 0..<0x20: out += Array(String(format: "\\u%04x", sc.value).utf8)
            default: out += Array(String(Character(sc)).utf8)
            }
        }
        out.append(0x22)
    }
}
