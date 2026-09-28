// Modified for Horos by Thales Matheus M Santos (ThalesMMS), 2026: reads the
// DICOM JSON response with JSONSerialization instead of DicomData's JSON codec,
// and refuses a native XML response, whose codec is not vendored.
// Original: DICOM-Swift, DicomCore/DicomWebStoreResponse.swift, revision 1947fefa46e6.
// Licensed under the Apache License, Version 2.0; see LICENSE in this folder.

import Foundation

public struct DicomWebStoreResponse: Equatable, Sendable {
    public enum Outcome: String, Sendable { case accepted, warning, failed, unknown }
    public struct Instance: Equatable, Sendable {
        public let sopClassUID: String?
        public let sopInstanceUID: String?
        public let retrieveURL: String?
        public let warningReason: Int?
        public let failureReason: Int?
        public let outcome: Outcome
    }
    public let retrieveURL: String?
    public let instances: [Instance]
    public let otherFailureReasons: [Int]
    /// Warning outcomes also identify successfully stored SOP Instances (Annex I).
    public var acceptedInstanceCount: Int { instances.filter { $0.outcome == .accepted || $0.outcome == .warning }.count }

    public static func decode(_ data: Data, contentType: String?) throws -> Self {
        if data.isEmpty { return .init(retrieveURL: nil, instances: [], otherFailureReasons: []) }
        // Compatibility with the pre-Annex-I in-memory helper. Identifiers are retained as unknown,
        // and its submitted-count field never establishes successful storage.
        if contentType?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
           let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let identifiers = object["sopInstanceUIDs"] as? [String] {
            return .init(retrieveURL: nil, instances: identifiers.map {
                .init(sopClassUID: nil, sopInstanceUID: $0, retrieveURL: nil,
                      warningReason: nil, failureReason: nil, outcome: .unknown)
            }, otherFailureReasons: [])
        }
        // Only DICOM JSON is decoded here: the Accept header asks for it, and
        // DicomData's JSON and native XML codecs are not vendored.
        guard contentType?.lowercased().contains("xml") != true,
              let object = try? JSONSerialization.jsonObject(with: data) else { throw DicomWebError(kind: .invalidResponse) }
        let dataSets: [JSONDataSet]
        if let single = object as? [String: Any] { dataSets = [JSONDataSet(single)] }
        else if let many = object as? [[String: Any]] { dataSets = many.map(JSONDataSet.init) }
        else { throw DicomWebError(kind: .invalidResponse) }
        var instances: [Instance] = []
        var other: [Int] = []
        for set in dataSets {
            for tag in [0x00081199, 0x00081198] {
                for item in set.sequenceItems(for: tag) {
                    let entry = item
                    let warning = entry.int(for: 0x00081196)
                    let failure = entry.int(for: 0x00081197)
                    let uid = entry.string(for: 0x00081155)
                    let outcome: Outcome = uid == nil ? .unknown : tag == 0x00081198 ? .failed : warning != nil ? .warning : .accepted
                    instances.append(.init(sopClassUID: entry.string(for: 0x00081150), sopInstanceUID: uid,
                                           retrieveURL: entry.string(for: 0x00081190), warningReason: warning,
                                           failureReason: failure, outcome: outcome))
                }
            }
            other += set.sequenceItems(for: 0x0008119A).compactMap { $0.int(for: 0x00081197) }
        }
        return .init(retrieveURL: dataSets.first?.string(for: 0x00081190), instances: instances, otherFailureReasons: other)
    }
}

/// The few DICOM JSON reads a store response needs.
private struct JSONDataSet {
    let object: [String: Any]
    init(_ object: [String: Any]) { self.object = object }

    private func values(for tag: Int) -> [Any] {
        let attribute = object[String(format: "%08X", tag)] ?? object[String(format: "%08x", tag)]
        return (attribute as? [String: Any])?["Value"] as? [Any] ?? []
    }
    func string(for tag: Int) -> String? {
        guard let value = values(for: tag).first else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    func int(for tag: Int) -> Int? {
        guard let value = values(for: tag).first else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    func sequenceItems(for tag: Int) -> [JSONDataSet] {
        values(for: tag).compactMap { ($0 as? [String: Any]).map(JSONDataSet.init) }
    }
}
