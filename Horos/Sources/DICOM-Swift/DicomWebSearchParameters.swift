// Modified for Horos by Thales Matheus M Santos (ThalesMMS), 2026: a match
// names its VR by its two-letter code instead of DicomData's DicomVR, the
// server-side parse(queryItems:) is left out, and query values are encoded
// with an ASCII-only set, so a non-ASCII filter is percent-encoded.
// Original: DICOM-Swift, DicomCore/DicomWebSearchParameters.swift, revision 1947fefa46e6.
// Licensed under the Apache License, Version 2.0; see LICENSE in this folder.

import Foundation

public struct DicomWebSearchParameters: Equatable, Sendable {
    public enum Level: String, Sendable { case study, series, instance }
    public struct Match: Equatable, Sendable {
        public let attribute: String
        /// The two-letter VR code, such as "UI"; only UI matches may list several values.
        public let vr: String
        public let values: [String]
        public init(_ attribute: String, vr: String, values: [String]) {
            self.attribute = attribute
            self.vr = vr
            self.values = values
        }
    }
    public var level: Level
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var matches: [Match]
    public var fuzzyMatching: Bool?
    public var includeFields: [String]
    public var limit: Int?
    public var offset: Int?

    public init(level: Level = .study, studyInstanceUID: String? = nil, seriesInstanceUID: String? = nil,
                matches: [Match] = [], fuzzyMatching: Bool? = nil, includeFields: [String] = ["all"],
                limit: Int? = nil, offset: Int? = nil) {
        self.level = level
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.matches = matches
        self.fuzzyMatching = fuzzyMatching
        self.includeFields = includeFields
        self.limit = limit
        self.offset = offset
    }

    public func pathComponents() throws -> [String] {
        guard limit.map({ $0 >= 0 }) ?? true, offset.map({ $0 >= 0 }) ?? true,
              seriesInstanceUID == nil || (studyInstanceUID != nil && level == .instance),
              level != .study || studyInstanceUID == nil else { throw DicomWebError(kind: .badRequest) }
        var path: [String] = []
        if let studyInstanceUID { path += ["studies", studyInstanceUID] }
        if let seriesInstanceUID { path += ["series", seriesInstanceUID] }
        path += [level == .study ? "studies" : level == .series ? "series" : "instances"]
        return path
    }

    public func queryItems() throws -> [URLQueryItem] {
        _ = try pathComponents()
        guard !includeFields.contains("all") || includeFields == ["all"],
              Set(matches.map(\.attribute)).count == matches.count else { throw DicomWebError(kind: .badRequest) }
        var items: [URLQueryItem] = []
        for match in matches {
            guard !match.attribute.isEmpty, !["limit", "offset", "includefield", "fuzzymatching"].contains(match.attribute),
                  !match.values.isEmpty, match.vr == "UI" || match.values.count == 1,
                  match.values.allSatisfy({ !$0.utf8.contains(13) && !$0.utf8.contains(10) }) else {
                throw DicomWebError(kind: .badRequest)
            }
            items.append(.init(name: match.attribute, value: match.values.joined(separator: ",")))
        }
        if let fuzzyMatching { items.append(.init(name: "fuzzymatching", value: String(fuzzyMatching))) }
        if !includeFields.isEmpty { items.append(.init(name: "includefield", value: includeFields.joined(separator: ","))) }
        if let limit { items.append(.init(name: "limit", value: String(limit))) }
        if let offset { items.append(.init(name: "offset", value: String(offset))) }
        return items
    }

    public func url(relativeTo base: URL) throws -> URL {
        var url = base
        for part in try pathComponents() { url.appendPathComponent(part) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DicomWebError(kind: .badRequest)
        }
        // ASCII only: CharacterSet.alphanumerics would leave letters such as "é"
        // unencoded, which URLComponents refuses as a percent-encoded query.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~*")
        components.percentEncodedQuery = try queryItems().map {
            ($0.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" +
            (($0.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        guard let result = components.url else { throw DicomWebError(kind: .badRequest) }
        return result
    }
}
