/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The identifier the database groups a patient's studies by: the name, the
/// patient ID and the date of birth, those the preferences name, joined by
/// hyphens, cleaned and in capitals.
public enum PatientUIDRule {

    /// The identifier of a record (a file's elements, a study) whose name,
    /// patient ID and formatted date of birth are these. A part the settings
    /// leave out is empty; a part that is wanted and missing reads "(null)",
    /// as the format string wrote it.
    ///
    /// - Parameters:
    ///   - name: the patient's name, which loses its hyphens and every
    ///     representation after the first (`=`).
    ///   - patientID: the patient ID, written as `%@` writes it.
    ///   - birthDate: the date of birth as YYYYMMDD, nil for none; a record
    ///     without one has an empty date, not an invented one.
    public static func uid(name: NSString?, patientID: Any?, birthDate: String?, settings: ImportSettings) -> String {
        var namePart: String? = ""
        if settings.usePatientNameForUID {
            if let name, let cleaned = ImportedText.cleaned(name) {
                let unhyphenated = cleaned.replacingOccurrences(of: "-", with: " ") as NSString
                let first = unhyphenated.components(separatedBy: "=")[0]
                namePart = first.isEmpty ? unhyphenated as String : first
            } else {
                namePart = nil
            }
        }
        var datePart: String? = ""
        if settings.usePatientBirthDateForUID, let birthDate {
            datePart = birthDate
        }
        var idPart: String? = ""
        if settings.usePatientIDForUID {
            idPart = (patientID as? NSObject)?.description
        }
        let joined = NSMutableString(string: "\(namePart ?? "(null)")-\(idPart ?? "(null)")-\(datePart ?? "(null)")")
        ImportedText.clean(joined)
        return joined.uppercased
    }
}
