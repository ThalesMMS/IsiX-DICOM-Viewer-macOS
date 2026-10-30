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
import IsiXDICOMFile

/// The text of a file's values: decoded in the file's character sets, cleaned
/// for the database, and the patient identifier made of it. The rules are
/// IsiXDICOMFile's; the DICOM reading calls these for every text value it
/// keeps, so they hand the strings over as Foundation makes them.
@objc(Text) @implementation extension DicomFile {

    @objc(NSreplaceBadCharacter:) class func nSreplaceBadCharacter(_ str: String!) -> String! {
        guard let str else { return nil }
        return ImportedText.cleaned(str as NSString).map { $0 as String }
    }

    class func replaceBadCharacter(_ str: UnsafeMutablePointer<CChar>!, encoding: UInt) -> UnsafeMutablePointer<CChar>! {
        guard let str else { return nil }
        return ImportedText.cleanCString(str, encoding: encoding)
    }

    class func string(withBytes str: UnsafeMutablePointer<CChar>!, encodings encoding: UnsafeMutablePointer<UInt>!) -> NSMutableString! {
        string(withBytes: str, encodings: encoding, replaceBadCharacters: true)
    }

    // Based on dcmtk 3.6 convertString function
    class func string(withBytes str: UnsafeMutablePointer<CChar>!, encodings: UnsafeMutablePointer<UInt>!,
                      replaceBadCharacters replace: Bool) -> NSMutableString! {
        guard let str, let encodings else { return nil }
        let result = DICOMTextDecoding.decode(str, encodings: encodings) { term in
            DICOMCharacterSet.encoding(forDICOMCharacterSet: term)
        }
        if replace { ImportedText.clean(result) }
        return result
    }

    func patientUID() -> String! {
        DicomFile.patientUID(dicomElements())
    }

    class func patientUID(_ src: Any!) -> String! {
        DicomFile.setDefaults()
        let settings = DicomFile.importSettings.settings
        if !settings.usePatientBirthDateForUID && !settings.usePatientIDForUID && !settings.usePatientNameForUID {
            N2LogStackTraceMessage("PatientUID requires at least one parameter.")
        }
        let record = src as? NSObject
        func value(_ key: String) -> Any? { record?.value(forKey: key) }

        // A patient with no date of birth used to be given one: the nil date
        // became 2001-01-01, and, formatted in local time, 2000-12-31 anywhere
        // west of UTC. So a study split in two the moment one instance carried
        // the date and another did not, and two machines in different time
        // zones disagreed about which patient an instance belonged to. An
        // unknown component is empty.
        var birthDate: String?
        if settings.usePatientBirthDateForUID, let date = value("patientBirthDate") as? NSDate {
            birthDate = DICOMCalendarDate.string(from: Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate),
                                                 calendarFormat: "%Y%m%d") ?? "(null)"
        }
        return PatientUIDRule.uid(name: settings.usePatientNameForUID ? value("patientName") as? NSString : nil,
                                  patientID: settings.usePatientIDForUID ? value("patientID") : nil,
                                  birthDate: birthDate, settings: settings)
    }

    @objc(containsString:inArray:) func contains(_ s: String!, in a: [Any]!) -> Bool {
        guard let s else { return false }
        return (a ?? []).contains { ($0 as? NSString)?.isEqual(to: s) == true }
    }

    @objc(containsLocalizerInString:) func containsLocalizer(in str: String!) -> Bool {
        guard let str, !str.isEmpty else { return false }
        let strings = (UserDefaults.standard.value(forKey: "NOLOCALIZER_Strings") as? NSString)?.components(separatedBy: ",") ?? []
        for string in strings {
            var localizerString = string as NSString
            if localizerString.hasPrefix(" ") { localizerString = localizerString.substring(from: 1) as NSString }
            // The Objective-C cut two characters for the trailing space.
            if localizerString.hasSuffix(" ") {
                localizerString = localizerString.substring(to: max(0, localizerString.length - 2)) as NSString
            }
            if (str as NSString).range(of: localizerString as String, options: .caseInsensitive).location != NSNotFound {
                return true
            }
        }
        return false
    }
}
