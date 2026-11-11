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

/// What a retrieve asked for in the Query window fetches, as its Activity
/// line names it while it waits and runs: how many studies and series, whose
/// they are when they are all of one patient, and which series when it is a
/// single one. Series count as series: a line that called one "1 study" and
/// showed its number where the patient goes could not be told from the rest
/// of the queue.
public struct RetrieveRequestSummary: Equatable, Sendable {

    /// A row chosen in the window.
    public struct Item: Equatable, Sendable {
        public var isSeries: Bool
        /// The patient, as the row's study names them (with DICOM's ^).
        public var patientName: String?
        /// A series' description, or its number without one.
        public var seriesLabel: String?

        public init(isSeries: Bool, patientName: String?, seriesLabel: String? = nil) {
            self.isSeries = isSeries
            self.patientName = patientName
            self.seriesLabel = seriesLabel
        }
    }

    public var studies: Int
    public var series: Int
    /// The one patient of every row; nil with several, or none known.
    public var patientName: String?
    /// The label of the series, when a single series is all there is.
    public var seriesLabel: String?

    public init(items: [Item]) {
        studies = items.filter { !$0.isSeries }.count
        series = items.count - studies
        let names = items.map { Self.readable($0.patientName) }
        patientName = names.first.flatMap { first in first.isEmpty || names.contains { $0 != first } ? nil : first }
        let label = items.count == 1 && series == 1 ? Self.readable(items[0].seriesLabel) : ""
        seriesLabel = label.isEmpty ? nil : label
    }

    /// The line: the counts, then the patient, then the series.
    /// `studyCount` and `seriesCount` word a count in the user's language.
    public func text(studyCount: (Int) -> String, seriesCount: (Int) -> String) -> String {
        var counts: [String] = []
        if studies > 0 { counts.append(studyCount(studies)) }
        if series > 0 { counts.append(seriesCount(series)) }
        return ([counts.joined(separator: ", ")] + [patientName, seriesLabel].compactMap { $0 }).joined(separator: " - ")
    }

    private static func readable(_ name: String?) -> String {
        (name ?? "").replacingOccurrences(of: "^", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
