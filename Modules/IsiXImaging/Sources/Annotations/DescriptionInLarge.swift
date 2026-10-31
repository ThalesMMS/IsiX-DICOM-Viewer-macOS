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

/// The text of the large description an image view shows over its image: what
/// tells its series apart from those of the other open viewers.
public enum DescriptionInLarge {
    /// One line per item, separated by carriage returns: the patient's name
    /// when the open studies are not all of the same name, the series' date,
    /// the study's name when the open studies are not all of the same name,
    /// and the series' name. The date's line is begun after a name even when
    /// the series has no date.
    public static func text(patientName: String?, studyName: String?, seriesName: String?, date: String?,
                            openPatientNames: [String?], openStudyNames: [String?]) -> String {
        var text = ""
        if !allIdentical(openPatientNames), let patientName {
            if !text.isEmpty { text += "\r" }
            text += patientName
        }
        if !text.isEmpty { text += "\r" }
        if let date { text += date }
        if !allIdentical(openStudyNames), let studyName {
            if !text.isEmpty { text += "\r" }
            text += studyName
        }
        if let seriesName {
            if !text.isEmpty { text += "\r" }
            text += seriesName
        }
        return text
    }

    /// Whether every value is the same text: false for no value, or when one has no text.
    public static func allIdentical(_ values: [String?]) -> Bool {
        guard let first = values.first, let first else { return false }
        let text = first as NSString
        return values.allSatisfy { value in value.map { text.isEqual(to: $0) } ?? false }
    }
}
