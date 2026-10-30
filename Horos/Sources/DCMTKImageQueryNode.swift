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

/// An image of a node's series, as an IMAGE level search lists it.
@objc(DCMTKImageQueryNode)
final class DCMTKImageQueryNode: DCMTKQueryNode, @unchecked Sendable {
    private var studyInstanceUIDValue: String?
    private var seriesInstanceUIDValue: String?
    private var sopClassUIDValue: String?

    required init(dataset: IsiXDCMTKDataset?, callingAET: String?, calledAET: String?, hostname: String?, port: Int32,
                  transferSyntax: Int32, compression: Float, extraParameters: [AnyHashable: Any]?) {
        super.init(dataset: dataset, callingAET: callingAET, calledAET: calledAET, hostname: hostname, port: port,
                   transferSyntax: transferSyntax, compression: compression, extraParameters: extraParameters)
        guard let dataset else { return }
        let (characterSet, encodings) = dataset.characterSetEncodings()
        specificCharacterSet = characterSet
        uidValue = dataset.latin1Value(.sopInstanceUID)
        seriesInstanceUIDValue = dataset.latin1Value(.seriesInstanceUID)
        sopClassUIDValue = dataset.latin1Value(.sopClassUID)
        studyInstanceUIDValue = dataset.latin1Value(.studyInstanceUID)
        nameValue = dataset.text(.instanceNumber, encodings: encodings)
        dateValue = dataset.latin1Value(.instanceCreationDate).flatMap { DICOMCalendarDate.dicomDate($0) }
        timeValue = dataset.latin1Value(.instanceCreationTime).flatMap { DICOMCalendarDate.dicomTime($0) }
    }

    @objc func seriesInstanceUID() -> String! { seriesInstanceUIDValue }
    @objc func studyInstanceUID() -> String! { studyInstanceUIDValue }
    /// The SOP class the IMAGE level answered with, when it did.
    @objc func sopClassUID() -> String! { sopClassUIDValue }

    override func moveIdentifier() -> DICOMQueryIdentifier? { QueryIdentifiers.retrieve(image: uidValue) }

    @objc(type) func nodeType() -> String! { "Image" }

    override var description: String { "DCMTKImageQueryNode: \(uidValue ?? "(null)")" }
}
