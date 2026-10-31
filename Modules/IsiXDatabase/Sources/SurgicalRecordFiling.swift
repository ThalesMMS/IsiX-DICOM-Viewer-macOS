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

/// How the structured reports of a surgical log become the database's own:
/// moved from where they were written into the data folder, then indexed there.
/// Indexed where they were written, in a temporary folder, the system would
/// remove them and no rebuild would find them again, as they were never in the
/// data folder. The application gives the paths of the data folder and the
/// index; a report that was updated keeps its former file until every new one
/// is indexed and saved, so a failure here costs only the import, which the log
/// can repeat.
public enum SurgicalRecordFiling {
    /// What the index did with the files it was given.
    public struct Indexed: Equatable, Sendable {
        /// The names of the files that now have a row.
        public var names: Set<String>
        /// Whether those rows reached the store.
        public var saved: Bool

        public init(names: Set<String>, saved: Bool) {
            self.names = names
            self.saved = saved
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Every report is in the data folder with a row.
        case filed(Int)
        /// A report could not reach the data folder: none was indexed, and none
        /// stayed there.
        case notMoved(reason: String)
        /// The index left out some reports, which left the data folder too.
        case indexedInPart(indexed: Int, offered: Int)
        /// The rows did not reach the store. Their files stay: the context still
        /// has the rows, which a later save would write, and a rebuild reads the
        /// files if none does.
        case notSaved

        /// The text of the alert, or nil when nothing went wrong. The arguments
        /// are the localized sentences: `notMoved` with the reason, `indexedInPart`
        /// with how many were left out and how many were offered.
        public func alertMessage(notMoved: String, indexedInPart: String, notSaved: String) -> String? {
            switch self {
            case .filed:
                return nil
            case .notMoved(let reason):
                return String(format: notMoved, reason)
            case .indexedInPart(let indexed, let offered):
                return String(format: indexedInPart, offered - indexed, offered)
            case .notSaved:
                return notSaved
            }
        }
    }

    /// Moves `written` to the paths `newDataFilePath` answers and indexes them
    /// under those paths with `index`, on the caller's thread. What is not moved
    /// stays where it was written, for the caller to remove. `retire` is given
    /// `former`, the files of the reports these replace, only when all is filed:
    /// the index replaces a report in place only under the same patient, and
    /// under another one it leaves the former row in the former study.
    public static func file(_ written: [String], replacing former: [String] = [], newDataFilePath: () -> String?,
                            index: ([String]) -> Indexed, retire: ([String]) -> Void = { _ in }) -> Outcome {
        let manager = FileManager.default
        var moved: [String] = []
        for source in written {
            var failure: Error = CocoaError(.fileWriteUnknown)
            if let destination = newDataFilePath() {
                do {
                    try manager.moveItem(atPath: source, toPath: destination)
                    moved.append(destination)
                    continue
                } catch {
                    failure = error
                    // The path was free when it was asked for: what is there now
                    // is what a copy between volumes left when it failed.
                    try? manager.removeItem(atPath: destination)
                }
            }
            for path in moved { try? manager.removeItem(atPath: path) }
            return .notMoved(reason: (failure as NSError).localizedDescription)
        }

        let indexed = index(moved)
        let leftOut = moved.filter { !indexed.names.contains(($0 as NSString).lastPathComponent) }
        // The import moves a file it cannot read out of the data folder by itself.
        for path in leftOut { try? manager.removeItem(atPath: path) }
        if !indexed.saved { return .notSaved }
        if !leftOut.isEmpty { return .indexedInPart(indexed: moved.count - leftOut.count, offered: moved.count) }
        if !former.isEmpty { retire(former) }
        return .filed(moved.count)
    }
}
