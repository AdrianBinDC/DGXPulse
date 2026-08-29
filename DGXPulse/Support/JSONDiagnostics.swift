import Foundation

/// Compact JSON summaries for Console.app / the in-app diagnostics log.
nonisolated enum JSONDiagnostics {
    nonisolated static func summarize(_ data: Data, previewLimit: Int = 360) -> String {
        let keys = flattenedKeys(in: data)
        let keyPart =
            keys.isEmpty ? "keys=<unparseable>" : "keys=[\(keys.joined(separator: ", "))]"
        return "\(keyPart) preview=\(truncatedUTF8(data, limit: previewLimit))"
    }

    nonisolated static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return String(describing: error)
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing '\(key.stringValue)' at \(codingPath(context))"
        case .typeMismatch(let type, let context):
            return "type mismatch \(type) at \(codingPath(context)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "null \(type) at \(codingPath(context))"
        case .dataCorrupted(let context):
            return "corrupt at \(codingPath(context)): \(context.debugDescription)"
        @unknown default:
            return String(describing: decoding)
        }
    }

    nonisolated static func flattenedKeys(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var keys: [String] = []
        collectKeys(object, path: "", into: &keys)
        return keys
    }

    private nonisolated static func collectKeys(_ value: Any, path: String, into keys: inout [String]) {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary.sorted(by: { $0.key < $1.key }) {
                let next = path.isEmpty ? key : "\(path).\(key)"
                if nested is [String: Any] || nested is [Any] {
                    collectKeys(nested, path: next, into: &keys)
                } else {
                    keys.append(next)
                }
            }
        } else if let array = value as? [Any] {
            let next = "\(path)[]"
            if let first = array.first {
                collectKeys(first, path: next, into: &keys)
            } else {
                keys.append(next)
            }
        }
    }

    private nonisolated static func codingPath(_ context: DecodingError.Context) -> String {
        let parts = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }
        return parts.isEmpty ? "<root>" : parts.joined(separator: ".")
    }

    private nonisolated static func truncatedUTF8(_ data: Data, limit: Int) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "…"
    }
}
