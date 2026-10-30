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

/// A C-FIND identifier asked of a DICOMweb node: the QIDO-RS resource and its
/// parameters.
public struct DICOMwebSearch: Equatable, Sendable {
    /// The resource, relative to the node's QIDO root: "studies",
    /// "studies/{study}/series", "studies/{study}/series/{series}/instances",
    /// or "series" and "instances" when the identifier does not name the parents.
    public let path: String
    /// Match filters by "GGGGEEEE", and "includefield" for the attributes asked for.
    public let parameters: [String: String]
    /// The path names the study, or the study and the series, of its results:
    /// a server need not return them, and a result is given them.
    public let studyInPath: Bool
    public let seriesInPath: Bool

    public enum Failure: Error, Equatable, Sendable {
        /// A filter value could not be read in the character set of the preference.
        case unencodableFilter
    }

    /// The resource a query of `level` asks for. `study` and `series` are the
    /// identifier's UIDs, empty when it has none.
    public static func path(level: String, study: String, series: String) -> String {
        var path = "studies"
        if level == QueryRetrieveLevel.series.rawValue { path = study.isEmpty ? "series" : "studies/\(study)/series" }
        if level == QueryRetrieveLevel.image.rawValue {
            path = !study.isEmpty && !series.isEmpty ? "studies/\(study)/series/\(series)/instances" : "instances"
        }
        return path
    }

    /// The search for an identifier whose attributes are `elements`, in tag
    /// order, each with its value as the dataset reads it (nil or empty: asked
    /// for). `decode` reads a filter value in the character set of the
    /// preference. A UID the path already names is not repeated as a match
    /// filter: it says nothing more, and a strict server refuses a query that
    /// matches on the resource it is asked about.
    public static func make(level: String, study: String, series: String,
                            elements: [(tag: DICOMTag, value: [UInt8]?)],
                            decode: ([UInt8]) -> String?) -> Result<DICOMwebSearch, Failure> {
        let path = path(level: level, study: study, series: series)
        let studyInPath = path.hasPrefix("studies/")
        let seriesInPath = level == QueryRetrieveLevel.image.rawValue && studyInPath
        var parameters: [String: String] = [:]
        var include: [String] = []
        for (tag, value) in elements {
            if tag == .queryRetrieveLevel || tag == .specificCharacterSet { continue }
            if (studyInPath && tag == .studyInstanceUID) || (seriesInPath && tag == .seriesInstanceUID) { continue }
            if let value, !value.isEmpty {
                guard let text = decode(value) else { return .failure(.unencodableFilter) }
                parameters[tag.dicomwebKey] = text
            } else {
                include.append(tag.dicomwebKey)
            }
        }
        if !include.isEmpty { parameters["includefield"] = include.joined(separator: ",") }
        return .success(DICOMwebSearch(path: path, parameters: parameters, studyInPath: studyInPath, seriesInPath: seriesInPath))
    }

    /// The attribute every result of a level must carry: what the node is.
    public static func identity(ofLevel level: String) -> DICOMTag {
        switch level {
        case QueryRetrieveLevel.study.rawValue: return .studyInstanceUID
        case QueryRetrieveLevel.series.rawValue: return .seriesInstanceUID
        default: return .sopInstanceUID
        }
    }
}
