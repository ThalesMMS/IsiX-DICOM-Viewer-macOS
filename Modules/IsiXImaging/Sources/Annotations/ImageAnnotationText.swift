/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// What the custom annotations of an image put in a line, field by field
/// (-[DCMPix loadCustomImageAnnotationsPapyLink:DCMLink:]): the rules, apart
/// from where the values come from.
public enum ImageAnnotationText {
    /// Repetition Time (0018,0080).
    public static let repetitionTime: (group: Int32, element: Int32) = (0x0018, 0x0080)
    /// Echo Time (0018,0081).
    public static let echoTime: (group: Int32, element: Int32) = (0x0018, 0x0081)
    /// Transfer Syntax UID (0002,0010), shown as the name of its compression.
    public static let transferSyntax: (group: Int32, element: Int32) = (0x0002, 0x0010)
    /// Patient's Name (0010,0010), marked in the line.
    public static let patientName: (group: Int32, element: Int32) = (0x0010, 0x0010)

    /// The template of `modality` among `templates`: its own, or the default
    /// one when it has none or says it is the same as the default.
    public static func template(forModality modality: String?, in templates: NSDictionary?) -> NSDictionary? {
        var template = modality.flatMap { templates?.object(forKey: $0) } as? NSDictionary
        if template == nil { template = templates?.object(forKey: "Default") as? NSDictionary }
        let same = template?.object(forKey: "sameAsDefault")
        if ((same as? NSNumber)?.int32Value ?? (same as? NSString)?.intValue) == 1 {
            template = templates?.object(forKey: "Default") as? NSDictionary
        }
        return template
    }

    /// The DICOM fields the reading already has, for an MR image: shown from
    /// it, to six digits, when it has them, rather than from the object.
    public enum ReadField: Equatable { case repetitionTime, echoTime }

    /// Which read field (group, element) is; nil for any other.
    public static func readField(group: Int32, element: Int32) -> ReadField? {
        if group == repetitionTime.group && element == repetitionTime.element { return .repetitionTime }
        if group == echoTime.group && element == echoTime.element { return .echoTime }
        return nil
    }

    /// A number as the annotations show decimals: six significant digits.
    public static func decimal(_ value: Float) -> String {
        String(format: "%.6g", Double(value))
    }

    /// The values of a field joined as the annotations show several values.
    public static func joined(_ values: [String]) -> String? {
        values.isEmpty ? nil : values.joined(separator: " / ")
    }

    /// The text of a field with a value, and whether it counts as content: a
    /// field without one is a dash, and a line of dashes is not shown.
    public static func shown(_ value: String?) -> (text: String, isContent: Bool) {
        guard let value, (value as NSString).length > 0 else { return ("-", false) }
        return (value, true)
    }

    /// Text typed into the template, followed by a space; a dash when there is none.
    public static func manual(_ text: String?) -> String {
        guard let text, (text as NSString).length > 0 else { return "- " }
        return text + " "
    }

    /// Which of the patient's ages a special field asks for, by its English or
    /// localized name: the age now, the age at the acquisition, or neither.
    public enum Special { case actualAge, ageAtAcquisition, other }

    public static func special(_ field: String?, localizedActualAge: String, localizedAgeAtAcquisition: String) -> Special {
        guard let field else { return .other }
        if field == localizedActualAge || field == "Patient's Actual Age" { return .actualAge }
        if field == localizedAgeAtAcquisition || field == "Patient's Age At Acquisition" { return .ageAtAcquisition }
        return .other
    }
}
