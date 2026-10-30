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

import Foundation
import IsiXDICOMNetwork
import IsiXDICOMFile

/// A study of a node. Its children are its series, or the images an IMAGE
/// level search of it lists. It answers the messages a DicomStudy answers, so
/// that the browser shows it among the local studies.
@objc(DCMTKStudyQueryNode)
final class DCMTKStudyQueryNode: DCMTKQueryNode, @unchecked Sendable {
    /// Children are sorted when they are asked for, not after each one added.
    private var sortChildren = false

    required init(dataset: IsiXDCMTKDataset?, callingAET: String?, calledAET: String?, hostname: String?, port: Int32,
                  transferSyntax: Int32, compression: Float, extraParameters: [AnyHashable: Any]?) {
        super.init(dataset: dataset, callingAET: callingAET, calledAET: calledAET, hostname: hostname, port: port,
                   transferSyntax: transferSyntax, compression: compression, extraParameters: extraParameters)
        guard let dataset else { return }
        let (characterSet, encodings) = dataset.characterSetEncodings()
        specificCharacterSet = characterSet
        uidValue = dataset.latin1Value(.studyInstanceUID)
        descriptionValue = dataset.text(.studyDescription, encodings: encodings, replaceBadCharacters: false)
        nameValue = dataset.text(.patientName, encodings: encodings)
        patientIDValue = dataset.text(.patientID, encodings: encodings, replaceBadCharacters: false)
        accessionNumberValue = dataset.text(.accessionNumber, encodings: encodings, replaceBadCharacters: false)
        commentsValue = dataset.text(.studyComments, encodings: encodings, replaceBadCharacters: false)
        interpretationStatusIDValue = dataset.text(.interpretationStatusID, encodings: encodings, replaceBadCharacters: false)
        referringPhysicianValue = dataset.text(.referringPhysicianName, encodings: encodings)
        performingPhysicianValue = dataset.text(.performingPhysicianName, encodings: encodings)
        institutionNameValue = dataset.text(.institutionName, encodings: encodings)
        birthdateValue = dataset.latin1Value(.patientBirthDate).flatMap { DICOMCalendarDate.dicomDate($0) }
        dateValue = dataset.latin1Value(.studyDate).flatMap { DICOMCalendarDate.dicomDate($0) }
        timeValue = dataset.latin1Value(.studyTime).flatMap { DICOMCalendarDate.dicomTime($0) }
        modalityValue = dataset.latin1Value(.modalitiesInStudy) ?? dataset.latin1Value(.modality)
        numberImagesValue = dataset.latin1Value(.numberOfStudyRelatedInstances).map { NSNumber(value: ($0 as NSString).intValue) }
    }

    /// When a study is opened: its series.
    override func queryPrototype() -> DICOMQueryIdentifier? {
        let defaults = UserDefaults.standard
        return QueryIdentifiers.series(ofStudy: uidValue, options: QueryReturnKeyOptions(
            bodyPartExamined: defaults.bool(forKey: "CFINDBodyPartExaminedSupport"),
            commentsAndStatus: defaults.bool(forKey: "CFINDCommentsAndStatusSupport")))
    }

    override func moveIdentifier() -> DICOMQueryIdentifier? { QueryIdentifiers.retrieve(study: uidValue) }

    // MARK: What a DicomStudy answers

    override func date() -> DICOMCalendarDate! {
        DICOMCalendarDate.dicomDateTime(withDicomDate: dateValue, dicomTime: timeValue)
    }
    @objc func studyInstanceUID() -> String! { uidValue ?? "" }
    @objc func objectID() -> Any! { self }
    @objc func studyName() -> String! { Self.displayed(descriptionValue) }
    @objc func expanded() -> NSNumber! { NSNumber(value: false) }
    @objc func dateOfBirth() -> Date! { birthdateValue as Date? }
    @objc(type) func nodeType() -> String! { "Study" }
    @objc func patientUID() -> String! {
        // A dictionary made with -dictionaryWithObjectsAndKeys:, which stops at the first nil.
        let patient = NSMutableDictionary()
        if let name = nameValue {
            patient["patientName"] = name
            if let patientID = patientIDValue {
                patient["patientID"] = patientID
                if let birth = birthdateValue { patient["patientBirthDate"] = birth }
            }
        }
        return DicomFile.patientUID(patient)
    }
    @objc func isFault() -> Bool { false }
    @objc func fileType() -> String! { "DICOM" }
    override func comment() -> String! { commentsValue }
    override func stateText() -> NSNumber! { NSNumber(value: ((interpretationStatusIDValue ?? "") as NSString).intValue) }
    @objc func reportURL() -> String! { nil }
    @objc func dateAdded() -> Date! { nil }
    @objc func rawNoFiles() -> NSNumber! { numberImagesValue }
    @objc func numberOfImages() -> NSNumber! { numberImagesValue }
    @objc func noSeries() -> NSNumber! { nil }
    @objc func imageSeries() -> [Any]! { nil }
    @objc func noFiles() -> NSNumber! { numberImagesValue }
    @objc func dateOpened() -> Date! { nil }
    @objc func id() -> String! { nil }
    @objc func localstring() -> String! { nil }
    @objc func albumsNames() -> String! { nil }
    @objc func comment2() -> String! { "" }
    @objc func comment3() -> String! { "" }
    @objc func comment4() -> String! { "" }
    /// A study of a DICOM node has no note.
    @objc func note() -> String! { nil }
    @objc func lockedStudy() -> NSNumber! { NSNumber(value: false) }
    @objc func dictateURL() -> String! { nil }
    override func modality() -> String! {
        DicomStudy.displayedModalities(forSeries: modalityValue.map { $0.components(separatedBy: "\\") as NSArray })
    }

    override func value(forUndefinedKey key: String) -> Any? {
        NSLog("***** DCMTKStudyQueryNode valueForUndefinedKey : %@", key)
        return nil
    }

    /// "POD:host:port:STUDY:uid", the study's identity in the browser.
    @objc func XID() -> String! {
        "POD:\(_hostname ?? ""):\(_port):STUDY:\(studyInstanceUID() ?? "")"
    }

    // MARK: Children

    override func children() -> [Any]! {
        childrenLock.lock(); defer { childrenLock.unlock() }
        if sortChildren {
            sortChildren = false
            childrenStorage?.sort(using: [NSSortDescriptor(key: "time", ascending: true)])
        }
        return super.children()
    }

    /// A response at the SERIES level is a series of this study; one at the
    /// IMAGE level an image of it.
    override func addChild(_ response: IsiXDCMTKDataset?) {
        guard let response else { return }
        childrenLock.lock()
        if childrenStorage == nil { childrenStorage = NSMutableArray() }
        childrenLock.unlock()
        // Its series and images know the study they are of.
        if let parameters = extraParametersStorage, parameters["StudyInstanceUID"] == nil, let uid = uidValue {
            let withStudy = NSMutableDictionary(dictionary: parameters)
            withStudy["StudyInstanceUID"] = uid
            extraParametersStorage = withStudy
        }
        guard let level = response.rawValue(forTag: DICOMTag.queryRetrieveLevel.rawValue) else {
            NSLog("**** queryLevel == nil")
            response.printToStandardOutput()
            return
        }
        childrenLock.lock(); defer { childrenLock.unlock() }
        guard let children = childrenStorage else { return }
        let duplicates = UserDefaults.standard.bool(forKey: "QRRemoveDuplicateEntries")
        if level == Data("IMAGE".utf8) {
            let image = child(DCMTKImageQueryNode.self, from: response)
            let alreadyHere = duplicates && children.contains { object in
                guard let existing = object as? DCMTKImageQueryNode else { return false }
                return Self.same(existing.seriesInstanceUID(), image.seriesInstanceUID())
                    && Self.same(existing.studyInstanceUID(), image.studyInstanceUID())
                    && Self.same(existing.uid(), image.uid()) && Self.same(existing.date(), image.date())
            }
            if !alreadyHere { children.add(image) }
        } else if level == Data("SERIES".utf8) {
            let series = child(DCMTKSeriesQueryNode.self, from: response)
            series.study = self
            let alreadyHere = duplicates && children.contains { object in
                guard let existing = object as? DCMTKSeriesQueryNode else { return false }
                return Self.same(existing.studyInstanceUID(), series.studyInstanceUID()) && Self.same(existing.uid(), series.uid())
            }
            if !alreadyHere { children.add(series) }
        } else {
            NSLog("******** unknown queryLevel *****")
        }
        sortChildren = true
    }
}
