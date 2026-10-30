/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXROI

// The report of the calcium scoring window: what it prints of the patient and
// the study, the printing itself and the DICOM encapsulated PDF it saves into
// the database's incoming folder.
extension CalciumScoringWindowController {

    // MARK: - For printing and PDF creation

    @objc public var institution: String! {
        return viewer?.currentStudy()?.value(forKey: "institutionName") as? String
    }

    @objc public var patientID: String! {
        return viewer?.currentStudy()?.value(forKey: "patientID") as? String
    }

    @objc public var studyDate: Date! {
        return viewer?.currentStudy()?.value(forKey: "date") as? Date
    }

    @objc public var patientsName: String! {
        return viewer?.currentStudy()?.value(forKey: "name") as? String
    }

    @objc public var patientsSex: String! {
        return viewer?.currentStudy()?.value(forKey: "patientSex") as? String
    }

    /// The age at the study, in years, months or days; nil without a birth
    /// date or a study date.
    @objc public var patientsAge: String! {
        guard let dob = viewer?.currentStudy()?.value(forKey: "dateOfBirth") as? Date,
              let studyDate = viewer?.currentStudy()?.value(forKey: "date") as? Date else { return nil }
        var years = 0, months = 0, days = 0
        // +[Horos :years:months:days:hours:minutes:seconds:sinceDate:], whose
        // selector starts with an empty part, which Swift cannot name: its body.
        let calendarDate = DICOMCalendarDate(timeIntervalSinceReferenceDate: studyDate.timeIntervalSinceReferenceDate) as NSObject
        let selector = NSSelectorFromString("years:months:days:hours:minutes:seconds:sinceDate:")
        typealias Difference = @convention(c) (NSObject, Selector, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int>?,
                                               UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int>?,
                                               UnsafeMutablePointer<Int>?, NSDate) -> Void
        unsafeBitCast(calendarDate.method(for: selector), to: Difference.self)(calendarDate, selector, &years, &months, &days,
                                                                              nil, nil, nil, dob as NSDate)
        return CalciumScoringReport.age(years: years, months: months, days: days)
    }

    @objc public var patientsDOB: Date! {
        return viewer?.currentStudy()?.value(forKey: "dateOfBirth") as? Date
    }

    @objc(print:)
    public func print(_ sender: Any!) {
        _printView?.printView(sender)
    }

    // MARK: - The DICOM PDF

    /// Saves the report as a DICOM encapsulated PDF of the study, in the
    /// database's incoming folder.
    @IBAction @objc(saveDocument:)
    func saveDocument(_ sender: Any!) {
        // save ROI as DICOM PDF
        NSLog("Save Calcium Score")
        guard let printView = _printView else { return }
        let pdf = NSMutableData(data: printView.dataWithPDF(inside: printView.frame))
        // if we have an image  get the info we need from the imageRep.
        let study = viewer?.currentStudy()
        // pad data
        if pdf.length % 2 != 0 {
            pdf.increaseLength(by: 1)
        }
        // create DICOM OBJECT
        let dcmObject = DCMObject.encapsulatedPDF(pdf as Data)

        func set(_ values: [Any], _ name: String) {
            dcmObject.setAttributeValues(NSMutableArray(array: values), forName: name)
        }

        set([study?.value(forKey: "studyInstanceUID") as Any], "StudyInstanceUID")
        set(["PDF"], "SeriesDescription")
        // Add name
        set([patientsName ?? ""], "PatientsName")
        // add ID
        set([patientID ?? "0"], "PatientID")
        // Add sex
        set([patientsSex ?? ""], "PatientsSex")
        // add DOB
        if patientsDOB != nil {
            set([DICOMCalendarDate.dicomDate(with: study?.value(forKey: "dateOfBirth") as? Date) as Any], "PatientsBirthDate")
        }

        // set Title
        set(["Calcium Score "], "DocumentTitle")
        // Instance Number
        set([String(format: "%d", Int32(1))], "InstanceNumber")
        // add Study ID
        if let studyID = study?.value(forKey: "id") {
            set([studyID], "StudyID")
        } else {
            set([String(format: "%d", Int32(1))], "StudyID")
        }

        // Add Dates
        if DICOMCalendarDate.dicomDate(with: study?.value(forKey: "date") as? Date) != nil {
            NSLog("Date: %@", String(describing: study?.value(forKey: "date") ?? "(null)") as NSString)
            set([DICOMCalendarDate.dicomDate(with: study?.value(forKey: "date") as? Date) as Any], "StudyDate")
        } else {
            set([DICOMCalendarDate.dicomDate(with: Date()) as Any], "StudyDate")
        }

        if let time = DICOMCalendarDate.dicomTime(with: study?.value(forKey: "date") as? Date) {
            set([time], "StudyTime")
        } else {
            set([DICOMCalendarDate.dicomTime(with: Date()) as Any], "StudyTime")
        }

        set([DICOMCalendarDate.dicomDate(with: Date()) as Any], "SeriesDate")
        set([DICOMCalendarDate.dicomTime(with: Date()) as Any], "SeriesTime")

        // get Incoming Folder Path;
        let destination = String(format: "%@/CalciumScore%d%d.dcm",
                                 (BrowserController.currentBrowser()?.database?.incomingDirPath() ?? "") as NSString, Int32(1), Int32(1))

        if dcmObject.write(toFile: destination, with: DCMTransferSyntax.explicitVRLittleEndianTransferSyntax() as DCMTransferSyntax?,
                           quality: DCMCompressionQuality.lossless.rawValue, atomically: true) {
            NSLog("Wrote Calcium Score to %@", destination as NSString)
        }
    }
}
