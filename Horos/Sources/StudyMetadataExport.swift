//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import IsiXDatabase

/// The metadata export's rules under the names Objective-C and the diagnostic
/// probes call; the rules themselves are StudyMetadataCSV's (IsiXDatabase).
@objc(HorosStudyMetadataExport)
public final class StudyMetadataExport: NSObject {
    @objc public static let suggestedColumns = StudyMetadataCSV.suggestedColumns

    @objc(columnsFromText:)
    public static func columns(fromText text: String) -> [String] {
        StudyMetadataCSV.columns(fromText: text)
    }

    @objc(escapedField:)
    public static func escaped(_ field: String?) -> String {
        StudyMetadataCSV.escaped(field)
    }

    @objc(csvFromRows:)
    public static func csv(fromRows rows: [[String]]) -> String {
        StudyMetadataCSV.csv(fromRows: rows)
    }

    @objc(dataForCSV:)
    public static func data(forCSV text: String) -> Data {
        StudyMetadataCSV.data(forCSV: text)
    }

    @objc public static let missingHeader = StudyMetadataCSV.missingHeader

    @objc(headerRowForColumns:)
    public static func headerRow(columns: [String]) -> [String] {
        StudyMetadataCSV.headerRow(columns: columns)
    }

    @objc(rowForColumns:values:)
    public static func row(columns: [String], values: [String: String]) -> [String] {
        StudyMetadataCSV.row(columns: columns, values: values)
    }
}
