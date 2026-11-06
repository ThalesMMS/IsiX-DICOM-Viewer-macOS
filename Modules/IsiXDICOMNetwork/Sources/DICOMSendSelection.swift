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

/// How the images chosen for a send become its batches, one per patient.
public enum DICOMSendSelection {
    /// One image chosen for a send, as read from the database where it was
    /// chosen.
    public struct Item: Sendable, Hashable {
        /// The patient UID of its study.
        public var patientUID: String?
        /// The name of its study's patient.
        public var patientName: String?
        /// Its file; nil when the image has none.
        public var path: String?
        /// Whether its series is one the app keeps as DICOM SR for itself (its
        /// ROIs, report, annotations, window states or no-autodeletion mark),
        /// sent only when ROIs are.
        public var isAppSeries: Bool

        public init(patientUID: String?, patientName: String?, path: String?, isAppSeries: Bool = false) {
            self.patientUID = patientUID
            self.patientName = patientName
            self.path = path
            self.isAppSeries = isAppSeries
        }
    }

    /// The batches of a send:
    /// - the items in the order of their patient UID (a literal comparison,
    ///   those without one first), keeping their order otherwise;
    /// - each file once, with the first item that names it;
    /// - consecutive items of the same patient UID (compared without case,
    ///   diacritics or width) in one batch;
    /// - the app's own series left out unless `sendsAppSeries`;
    /// - a batch left empty by that dropped; each other one under the name of
    ///   its last item, with the files of its items that have one.
    public static func batches(of items: [Item], sendsAppSeries: Bool) -> [DICOMSendRequest.Batch] {
        let sorted = items.enumerated().sorted { left, right in
            switch comparePatientUIDs(left.element.patientUID, right.element.patientUID) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return left.offset < right.offset
            }
        }.map(\.element)

        // Equal as `unique(_:)` compares them.
        var seen = Set<[UInt16]>()
        let unique = sorted.filter { item in
            guard let path = item.path else { return true }
            return seen.insert(Array(path.utf16)).inserted
        }

        var batches: [DICOMSendRequest.Batch] = []
        func close(_ items: [Item]) {
            let kept = sendsAppSeries ? items : items.filter { !$0.isAppSeries }
            guard let last = kept.last else { return }
            batches.append(DICOMSendRequest.Batch(patientName: last.patientName, files: kept.compactMap(\.path)))
        }

        var current: [Item] = []
        var currentPatientUID: String?
        for item in unique {
            if !current.isEmpty {
                let same = ((currentPatientUID ?? "") as NSString).compare(item.patientUID ?? "",
                                                                          options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
                if !same {
                    close(current)
                    current = []
                }
            }
            if current.isEmpty {
                currentPatientUID = item.patientUID
            }
            current.append(item)
        }
        close(current)
        return batches
    }

    /// The paths in order, each once. Two paths are equal when their UTF-16
    /// code units are, as `-isEqualToString:` compares them: a path and its
    /// canonically equivalent spelling are two files.
    public static func unique(_ paths: [String]) -> [String] {
        var seen = Set<[UInt16]>()
        return paths.filter { seen.insert(Array($0.utf16)).inserted }
    }

    /// The order of a sort by patient UID: `-compare:` of the texts, and a
    /// missing UID before any.
    private static func comparePatientUIDs(_ left: String?, _ right: String?) -> ComparisonResult {
        switch (left, right) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (left?, right?): return (left as NSString).compare(right)
        }
    }
}
