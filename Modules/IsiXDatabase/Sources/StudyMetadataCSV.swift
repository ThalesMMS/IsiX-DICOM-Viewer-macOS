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

/// Studies out to a spreadsheet, with the columns somebody asked for, and the
/// database list of the study list.
///
/// The database list exports the study list's own columns, tab separated, with
/// no escaping at all: a study description holding a tab moves every field
/// after it into the wrong column, and one holding a carriage return splits the
/// row in two. The metadata export writes the format that survives that - RFC
/// 4180 - and takes its columns from DICOM rather than from what the table
/// happens to be showing. Reading the files and the study list is the app's.
public enum StudyMetadataCSV {

    /// The columns most people want, and a starting point somebody can edit.
    public static let suggestedColumns = [
        "PatientName", "PatientID", "PatientBirthDate", "PatientSex",
        "StudyDate", "StudyTime", "AccessionNumber", "StudyDescription",
        "Modality", "InstitutionName", "StudyInstanceUID",
    ]

    /// The text the column editor starts from: the stored columns, or the
    /// suggested ones, one per line, when none are stored.
    public static func editableColumns(stored: String?) -> String {
        let stored = stored ?? ""
        return stored.isEmpty ? suggestedColumns.joined(separator: "\n") : stored
    }

    /// One specification per line: a DICOM keyword (`PatientName`) or a tag
    /// written `(0010,0010)`. Blank lines and `#` comments are dropped, and a
    /// repeated column is kept once - a spreadsheet with the same header twice
    /// is a spreadsheet nobody can read back.
    public static func columns(fromText text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            var spec = line
            if let hash = spec.firstIndex(of: "#") { spec = String(spec[spec.startIndex ..< hash]) }
            spec = spec.trimmingCharacters(in: .whitespaces)
            guard !spec.isEmpty, !seen.contains(spec) else { continue }
            seen.insert(spec)
            out.append(spec)
        }
        return out
    }

    /// One field of a CSV row. A value that holds a comma, a quote, a carriage
    /// return or a line feed is quoted, and a quote inside it is doubled.
    public static func escaped(_ field: String?) -> String {
        let value = field ?? ""
        let needsQuoting = value.contains(",") || value.contains("\"")
            || value.contains("\r") || value.contains("\n")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The whole file, CRLF between records as the format says.
    public static func csv(fromRows rows: [[String]]) -> String {
        rows.map { $0.map { escaped($0) }.joined(separator: ",") }.joined(separator: "\r\n")
            + (rows.isEmpty ? "" : "\r\n")
    }

    /// UTF-8 with the byte order mark, because a spreadsheet opening a CSV
    /// without one reads the accents as whatever its locale happens to be.
    public static func data(forCSV text: String) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }

    /// The last column, which says which fields a study did not have.
    public static let missingHeader = "Missing"

    /// The header row: the specifications as written, plus `missingHeader`.
    public static func headerRow(columns: [String]) -> [String] {
        columns + [missingHeader]
    }

    /// One study's row. `values` holds only the fields the study actually has,
    /// so an absent field is an empty cell *and* a mention in the last column -
    /// an empty cell on its own cannot be told apart from a field that is there
    /// and empty, which DICOM allows.
    public static func row(columns: [String], values: [String: String]) -> [String] {
        var row: [String] = []
        var missing: [String] = []
        for column in columns {
            if let value = values[column] {
                row.append(cleaned(value))
            } else {
                row.append("")
                missing.append(column)
            }
        }
        row.append(missing.joined(separator: " "))
        return row
    }

    /// DICOM pads with spaces and separates multiple values with a backslash;
    /// neither belongs in a spreadsheet cell as it stands.
    public static func cleaned(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "; ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }

    /// The studies of the rows, each once, in the order of its first row:
    /// selecting a study and one of its series must not write the study twice.
    public static func firstOccurrences<Study: Hashable>(_ studies: [Study]) -> [Study] {
        var seen = Set<Study>()
        return studies.filter { seen.insert($0).inserted }
    }

    /// The whole metadata file of the studies' values, in order: the header,
    /// then one row per study.
    public static func table(columns: [String], studies: [[String: String]]) -> [[String]] {
        [headerRow(columns: columns)] + studies.map { row(columns: columns, values: $0) }
    }

    /// The database list: the column titles, then one line per study, the
    /// cells separated by tabs and the lines by carriage returns, nothing
    /// after the last. A list without a study is empty, header included.
    /// A cell that could not be read is empty and keeps its tab, so that the
    /// next ones stay under their titles.
    public static func databaseList(header: [String], rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }
        return ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\r")
    }
}
