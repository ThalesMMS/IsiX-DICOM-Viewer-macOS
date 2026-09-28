import Foundation

public struct DicomWebMediaType: Equatable, Sendable {
    public let type: String
    public let parameters: [String: String]

    public init(_ value: String) throws {
        let pieces = Self.split(value, separator: ";")
        let type = (pieces.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard type.split(separator: "/").count == 2, !value.utf8.contains(13), !value.utf8.contains(10) else {
            throw DicomWebError(kind: .badRequest)
        }
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw DicomWebError(kind: .badRequest) }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                guard value.count >= 2, value.hasSuffix("\"") else { throw DicomWebError(kind: .badRequest) }
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            guard parameters[key] == nil else { throw DicomWebError(kind: .badRequest) }
            parameters[key] = value
        }
        self.type = type
        self.parameters = parameters
    }

    public var headerValue: String {
        type + parameters.keys.sorted().map { key in
            let escaped = parameters[key]!.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "; \(key)=\"\(escaped)\""
        }.joined()
    }

    static func split(_ value: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in value {
            if character == separator, !quoted { result.append(current); current = ""; continue }
            current.append(character)
            if escaped { escaped = false }
            else if character == "\\", quoted { escaped = true }
            else if character == "\"" { quoted.toggle() }
        }
        result.append(current)
        return result
    }
}
