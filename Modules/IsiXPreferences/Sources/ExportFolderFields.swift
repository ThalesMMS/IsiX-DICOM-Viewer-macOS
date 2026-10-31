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

/// How an export to a folder names its folders, as the export panel keeps it
/// under `DICOMExportFolderFields`: whether the names are customized, and for
/// each level of folders the index of the field, in the panel's menu, that
/// names it.
///
/// Stored as a dictionary of `enabled` (a Boolean) and `patient`, `study` and
/// `series` (integers), the form the export's folder naming reads.
public struct ExportFolderFields: PreferenceObject {
    public var customized: Bool
    /// The index of the field; nil when the stored value has none.
    public var patient: Int?
    public var study: Int?
    public var series: Int?

    public init(customized: Bool, patient: Int?, study: Int?, series: Int?) {
        self.customized = customized
        self.patient = patient
        self.study = study
        self.series = series
    }

    /// As the panel always read the dictionary: customized only for a Boolean
    /// true, and a level's field only when it is an integer.
    public static func reading(present object: Any) -> Self? {
        guard let entry = object as? [String: Any] else { return nil }
        return ExportFolderFields(customized: entry["enabled"] as? Bool == true, patient: entry["patient"] as? Int,
                                  study: entry["study"] as? Int, series: entry["series"] as? Int)
    }

    /// The dictionary the panel writes, which the export's folder naming reads;
    /// a level without a field is left out.
    public var preferenceObject: Any { namingOptions }

    /// The same dictionary, for the export's folder naming.
    public var namingOptions: [String: Any] {
        var options: [String: Any] = ["enabled": customized]
        options["patient"] = patient
        options["study"] = study
        options["series"] = series
        return options
    }
}
