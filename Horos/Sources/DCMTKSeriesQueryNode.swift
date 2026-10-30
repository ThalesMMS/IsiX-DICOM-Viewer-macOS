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

/// A series of a node's study. Its children are its images. It answers the
/// messages a DicomSeries answers, so that the browser and the viewer show it
/// among the local series.
@objc(DCMTKSeriesQueryNode)
final class DCMTKSeriesQueryNode: DCMTKQueryNode, @unchecked Sendable {
    var studyInstanceUIDValue: String?
    /// The study it was listed in, not retained.
    @objc weak var study: DCMTKStudyQueryNode?

    required init(dataset: IsiXDCMTKDataset?, callingAET: String?, calledAET: String?, hostname: String?, port: Int32,
                  transferSyntax: Int32, compression: Float, extraParameters: [AnyHashable: Any]?) {
        super.init(dataset: dataset, callingAET: callingAET, calledAET: calledAET, hostname: hostname, port: port,
                   transferSyntax: transferSyntax, compression: compression, extraParameters: extraParameters)
        guard let dataset else { return }
        let (characterSet, encodings) = dataset.characterSetEncodings()
        specificCharacterSet = characterSet
        uidValue = dataset.latin1Value(.seriesInstanceUID)
        studyInstanceUIDValue = dataset.latin1Value(.studyInstanceUID) ?? extraParameters?["StudyInstanceUID"] as? String
        descriptionValue = dataset.text(.seriesDescription, encodings: encodings, replaceBadCharacters: false)
        nameValue = dataset.text(.seriesNumber, encodings: encodings)
        commentsValue = dataset.text(.imageComments, encodings: encodings, replaceBadCharacters: false)
        dateValue = dataset.latin1Value(.seriesDate).flatMap { DICOMCalendarDate.dicomDate($0) }
        timeValue = dataset.latin1Value(.seriesTime).flatMap { DICOMCalendarDate.dicomTime($0) }
        modalityValue = dataset.latin1Value(.modality)
        numberImagesValue = dataset.latin1Value(.numberOfSeriesRelatedInstances).map { NSNumber(value: ($0 as NSString).intValue) }
    }

    /// When a series is opened: its images.
    override func queryPrototype() -> DICOMQueryIdentifier? {
        QueryIdentifiers.images(ofSeries: uidValue, study: studyInstanceUIDValue, options: QueryReturnKeyOptions(
            commentsAndStatus: UserDefaults.standard.bool(forKey: "CFINDCommentsAndStatusSupport")))
    }

    override func moveIdentifier() -> DICOMQueryIdentifier? {
        QueryIdentifiers.retrieve(series: uidValue, study: studyInstanceUIDValue)
    }

    @objc func studyInstanceUID() -> String! { studyInstanceUIDValue ?? "" }
    @objc func seriesInstanceUID() -> String! { uidValue ?? "" }

    override func addChild(_ response: IsiXDCMTKDataset?) {
        childrenLock.lock(); defer { childrenLock.unlock() }
        if childrenStorage == nil { childrenStorage = NSMutableArray() }
        guard let response else { return }
        childrenStorage?.add(child(DCMTKImageQueryNode.self, from: response))
    }

    // MARK: What a DicomSeries answers

    @objc(type) func nodeType() -> String! { "Series" }
    @objc func isFault() -> Bool { false }
    @objc func noFiles() -> NSNumber! { numberImagesValue }
    @objc func seriesDescription() -> String! { Self.displayed(descriptionValue) }
    override func stateText() -> NSNumber! { NSNumber(value: ((interpretationStatusIDValue ?? "") as NSString).intValue) }
    @objc func dateOpened() -> Date! { nil }
    @objc func dateAdded() -> Date! { nil }
    @objc func id() -> String! { nil }
    @objc func localstring() -> String! { nil }
    @objc func albumsNames() -> String! { nil }
    @objc func comment2() -> String! { "" }
    @objc func comment3() -> String! { "" }
    @objc func comment4() -> String! { "" }
    @objc func images() -> Set<AnyHashable>! { nil }
    override func date() -> DICOMCalendarDate! {
        DICOMCalendarDate.dicomDateTime(withDicomDate: dateValue, dicomTime: timeValue)
    }
    @objc func rawNoFiles() -> NSNumber! { numberImagesValue }
    @objc func numberOfImages() -> NSNumber! { numberImagesValue }
}
