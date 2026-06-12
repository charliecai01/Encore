import Foundation

/// Dynamic JSON value used to traverse InnerTube's deeply nested, frequently
/// shifting response shapes without rigid Codable models.
public enum JSONValue {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(any: Any) {
        switch any {
        case let dict as [String: Any]:
            self = .object(dict.mapValues { JSONValue(any: $0) })
        case let arr as [Any]:
            self = .array(arr.map { JSONValue(any: $0) })
        case let str as String:
            self = .string(str)
        case let num as NSNumber:
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                self = .bool(num.boolValue)
            } else {
                self = .number(num.doubleValue)
            }
        default:
            self = .null
        }
    }

    public static func parse(_ data: Data) -> JSONValue {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .null
        }
        return JSONValue(any: obj)
    }

    public subscript(_ key: String) -> JSONValue {
        if case .object(let dict) = self, let v = dict[key] { return v }
        return .null
    }

    public subscript(_ index: Int) -> JSONValue {
        if case .array(let arr) = self, index >= 0, index < arr.count { return arr[index] }
        return .null
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var double: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    public var int: Int? {
        if case .number(let d) = self { return Int(d) }
        return nil
    }

    /// Int that tolerates numbers encoded as strings (InnerTube does this for ms timestamps).
    public var intLike: Int? {
        switch self {
        case .number(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var exists: Bool { !isNull }

    /// Joined text of a `{"runs": [{"text": ...}]}` node.
    public var runsText: String? {
        guard let runs = self["runs"].array else { return nil }
        let text = runs.compactMap { $0["text"].string }.joined()
        return text.isEmpty ? nil : text
    }

    public var runs: [JSONValue] {
        self["runs"].array ?? []
    }

    /// Depth-first search for every value stored under `key` anywhere in the tree.
    public func findAll(_ key: String, limit: Int = Int.max) -> [JSONValue] {
        var out: [JSONValue] = []
        func walk(_ v: JSONValue) {
            guard out.count < limit else { return }
            switch v {
            case .object(let dict):
                if let hit = dict[key] {
                    out.append(hit)
                    if out.count >= limit { return }
                }
                for k in dict.keys.sorted() {
                    walk(dict[k]!)
                    if out.count >= limit { return }
                }
            case .array(let arr):
                for sub in arr {
                    walk(sub)
                    if out.count >= limit { return }
                }
            default:
                break
            }
        }
        walk(self)
        return out
    }

    public func findFirst(_ key: String) -> JSONValue? {
        findAll(key, limit: 1).first
    }
}
