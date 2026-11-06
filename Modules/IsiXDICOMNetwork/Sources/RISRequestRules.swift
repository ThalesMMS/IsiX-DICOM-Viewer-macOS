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

/// How the app reads the parameters of a request a RIS sends by XML-RPC, a
/// horos:// link or AppleScript, and how it names them back to the user.
///
/// A parameter is read as text only when it is text: a number or a struct
/// where an identifier is expected is a request the method cannot read.
public enum RISRequestRules {

    /// `value` when it is a string, nil otherwise.
    public static func text(_ value: Any?) -> String? {
        if let string = value as? NSString { return string as String }
        return nil
    }

    /// `value` when it is a string with at least one character.
    public static func nonEmptyText(_ value: Any?) -> String? {
        guard let string = text(value), (string as NSString).length > 0 else { return nil }
        return string
    }

    // MARK: DisplayStudy

    /// The identifiers of a study that DisplayStudy accepts, each under its
    /// name and, when that is absent, the same name with a lowercase initial.
    public struct StudyIdentifiers {
        public let patientID: String?
        public let studyInstanceUID: String?
        public let accessionNumber: String?
        public let studyID: String?

        /// `parameter` gives the request's value for a name, or nil.
        public init(_ parameter: (String) -> Any?) {
            func read(_ name: String, _ alias: String) -> String? {
                // The alias is read only when the name is absent, not when it
                // is empty.
                let value = parameter(name) ?? parameter(alias)
                return RISRequestRules.text(value)
            }
            patientID = read("PatientID", "patientID")
            studyInstanceUID = read("StudyInstanceUID", "studyInstanceUID")
            accessionNumber = read("AccessionNumber", "accessionNumber")
            studyID = read("StudyID", "studyID")
        }

        /// The database attribute and the value of each identifier given, in
        /// the order the predicate tests them.
        public var equalities: [(attribute: String, value: String)] {
            var list: [(String, String)] = []
            if let patientID, !patientID.isEmpty { list.append(("patientID", patientID)) }
            if let studyInstanceUID, !studyInstanceUID.isEmpty { list.append(("studyInstanceUID", studyInstanceUID)) }
            if let accessionNumber, !accessionNumber.isEmpty { list.append(("accessionNumber", accessionNumber)) }
            if let studyID, !studyID.isEmpty { list.append(("id", studyID)) }
            return list
        }

        /// The studies of the database that match every identifier given; nil
        /// when none is given, which is a bad request.
        public var predicate: NSPredicate? {
            RISRequestRules.predicate(equalities)
        }

        /// The same identifiers as query keys of a DICOM node, for PACS
        /// On-Demand and for the message that tells the user nothing matched.
        public var queryKeys: [String: String] {
            var keys: [String: String] = [:]
            if let patientID, !patientID.isEmpty { keys["PatientID"] = patientID }
            if let studyInstanceUID, !studyInstanceUID.isEmpty { keys["StudyInstanceUID"] = studyInstanceUID }
            if let accessionNumber, !accessionNumber.isEmpty { keys["AccessionNumber"] = accessionNumber }
            if let studyID, !studyID.isEmpty { keys["StudyID"] = studyID }
            return keys
        }
    }

    // MARK: DisplaySeries

    /// The identifiers of a series that DisplaySeries accepts.
    public struct SeriesIdentifiers {
        public let patientID: String?
        public let seriesInstanceUID: String?

        public init(_ parameter: (String) -> Any?) {
            patientID = RISRequestRules.text(parameter("PatientID"))
            seriesInstanceUID = RISRequestRules.text(parameter("SeriesInstanceUID"))
        }

        public var equalities: [(attribute: String, value: String)] {
            var list: [(String, String)] = []
            if let patientID, !patientID.isEmpty { list.append(("study.patientID", patientID)) }
            if let seriesInstanceUID, !seriesInstanceUID.isEmpty { list.append(("seriesDICOMUID", seriesInstanceUID)) }
            return list
        }

        /// The series that match every identifier given; nil when none is.
        public var predicate: NSPredicate? {
            RISRequestRules.predicate(equalities)
        }
    }

    /// `attribute == value` for each pair, all required; nil for none.
    static func predicate(_ equalities: [(attribute: String, value: String)]) -> NSPredicate? {
        guard !equalities.isEmpty else { return nil }
        let subpredicates = equalities.map { NSPredicate(format: "%K == %@", $0.attribute, $0.value) }
        return NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)
    }

    // MARK: FindObject

    /// The `key == constant` terms of a FindObject request, as query keys of
    /// a DICOM node: the request itself when it is one comparison, or the
    /// comparisons of an AND. Other terms, and comparisons of another kind,
    /// are left out; a term whose constant is nil names no value to ask for.
    public static func equalityKeys(of predicate: NSPredicate) -> [String: Any] {
        var comparisons: [NSComparisonPredicate] = []
        if let comparison = predicate as? NSComparisonPredicate {
            comparisons.append(comparison)
        }
        if let compound = predicate as? NSCompoundPredicate, compound.compoundPredicateType == .and {
            for case let comparison as NSComparisonPredicate in compound.subpredicates {
                comparisons.append(comparison)
            }
        }
        var keys: [String: Any] = [:]
        for comparison in comparisons
        where comparison.comparisonPredicateModifier == .direct && comparison.predicateOperatorType == .equalTo {
            let left = comparison.leftExpression, right = comparison.rightExpression
            if left.expressionType == .keyPath && right.expressionType == .constantValue {
                if let value = right.constantValue { keys[left.keyPath] = value }
            } else if right.expressionType == .keyPath && left.expressionType == .constantValue {
                if let value = left.constantValue { keys[right.keyPath] = value }
            }
        }
        return keys
    }

    // MARK: Retrieve and CMove

    /// The filters of a Retrieve request: `filterKey`/`filterValue`, then
    /// `filterKey2`/`filterValue2` up to 9, each pair taken when both are
    /// given, whatever their type.
    public static func retrieveFilters(_ parameter: (String) -> Any?) -> [(name: Any, value: Any)] {
        var filters: [(name: Any, value: Any)] = []
        for index in 1..<10 {
            let suffix = index == 1 ? "" : String(index)
            if let name = parameter("filterKey" + suffix), let value = parameter("filterValue" + suffix) {
                filters.append((name, value))
            }
        }
        return filters
    }

    /// The accession number a CMove asks for, as text: a value that is not a
    /// string is written as `%@` writes it ("(null)" when absent, which the
    /// node is then asked for).
    public static func accessionNumber(_ value: Any?) -> String {
        if let string = value as? NSString { return string as String }
        guard let value else { return "(null)" }
        return (value as AnyObject).description ?? "(null)"
    }

    /// The accession number as the query sends it, without surrounding blanks.
    public static func accessionFilterValue(_ accessionNumber: String) -> String {
        (accessionNumber as NSString).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The retrieve modes a request may ask for instead of the node's own.
    public static let cGetRetrieveMode = DICOMRetrieveMode.cGet.rawValue
    public static let wadoRetrieveMode = DICOMRetrieveMode.wado.rawValue

    /// The mode a Retrieve uses: the node's, unless the request asks for C-GET
    /// or WADO by `retrieveMode`.
    public static func retrieveMode(node: Int, requested: Int) -> Int {
        if requested == wadoRetrieveMode || requested == cGetRetrieveMode { return requested }
        return node
    }

    // MARK: DownloadURL

    /// The `studyUID` and `seriesUID` of a WADO URL's query: the last value
    /// given for each, the text after its first `=`.
    public static func wadoIdentifiers(ofURL url: String) -> (studyUID: String?, seriesUID: String?) {
        var studyUID: String?, seriesUID: String?
        let query = (url as NSString).components(separatedBy: "?").last ?? ""
        for term in (query as NSString).components(separatedBy: "&") {
            let text = term as NSString
            let separator = text.range(of: "=")
            if separator.location == NSNotFound { continue }
            let name = text.substring(to: separator.location) as NSString
            if name.isEqual(to: "studyUID") { studyUID = text.substring(from: separator.location + 1) }
            if name.isEqual(to: "seriesUID") { seriesUID = text.substring(from: separator.location + 1) }
        }
        return (studyUID, seriesUID)
    }

    // MARK: Naming a request

    /// How the filters of a request read in a message: `PatientID = 123`.
    public static func describe(filters: [String: Any]) -> String {
        let terms = filters.keys.sorted().map { "\($0) = \(String(describing: filters[$0]! as AnyObject))" }
        return terms.isEmpty ? "-" : terms.joined(separator: ", ")
    }

    /// How a link reads in a message: its method, then its other parameters.
    public static func describe(method: String?, parameters: [String: String]) -> String {
        var filters = parameters
        filters["methodName"] = nil
        return (method ?? "image") + (filters.isEmpty ? "" : " (" + describe(filters: filters) + ")")
    }
}
