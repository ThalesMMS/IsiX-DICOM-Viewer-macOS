//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// Which earlier studies of a patient go with a routed study, and the durable
/// record of those already queued. The record is of admission to the queue,
/// not of delivery: the queue owns the retries.
public enum PreviousRoutingStudies {
    private static let lock = NSLock()
    /// A prior study queued for a node is not queued for it again within this time.
    static let interval: TimeInterval = 3 * 60 * 60

    /// Whether `candidate` is an earlier study of `current` as the rule asks:
    /// dated before it, of a modality it shares when `modality`, and with a
    /// description the current one contains (without case or diacritics)
    /// when `description`.
    public static func matches(_ candidate: RoutedStudy, currentStudy current: RoutedStudy,
                               modality: Bool, description: Bool) -> Bool {
        guard let date = candidate.date, let currentDate = current.date, date < currentDate else { return false }
        func trimmed(_ text: String?) -> String {
            (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if modality {
            let old = Set(trimmed(candidate.modality).uppercased().split(separator: "\\").map(String.init))
            let new = Set(trimmed(current.modality).uppercased().split(separator: "\\").map(String.init))
            guard !old.isEmpty, !old.isDisjoint(with: new) else { return false }
        }
        if description {
            let old = trimmed(candidate.studyName), new = trimmed(current.studyName)
            guard !old.isEmpty, !new.isEmpty,
                  new.range(of: old, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return false }
        }
        return true
    }

    /// Records that study `study` is queued for `node`, in the database folder;
    /// false when it already was within the interval, or cannot be recorded,
    /// in which case it is not queued.
    public static func reserve(study: String, node: DICOMNode, databasePath: String, now: Date = Date()) -> Bool {
        guard !study.isEmpty, !databasePath.isEmpty,
              let address = node[DICOMNode.Key.address]?.stringValue, !address.isEmpty,
              let ae = node[DICOMNode.Key.aeTitle]?.stringValue, !ae.isEmpty else { return false }
        let port = RoutingDestination.portText(of: node) ?? ""
        guard let number = Int(port), (1...65535).contains(number) else { return false }
        // Each component encoded apart, so punctuation in an AE or UID cannot alias another key.
        let components = [study, address.lowercased(), String(number), ae]
        guard let keyData = try? JSONEncoder().encode(components) else { return false }
        let key = keyData.base64EncodedString()
        let file = URL(fileURLWithPath: databasePath, isDirectory: true)
            .appendingPathComponent("PreviousRoutingStudies.json")
        lock.lock()
        defer { lock.unlock() }
        do {
            var history: [String: Date] = [:]
            if FileManager.default.fileExists(atPath: file.path) {
                history = try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: file))
            }
            history = history.filter { now.timeIntervalSince($0.value) < interval }
            guard history[key] == nil else { return false }
            history[key] = now
            try JSONEncoder().encode(history).write(to: file, options: .atomic)
            return true
        } catch {
            // No patient identifiers, paths or underlying error descriptions in the log.
            NSLog("Autorouting: unable to persist previous-study admission; prior study not queued")
            return false
        }
    }
}
