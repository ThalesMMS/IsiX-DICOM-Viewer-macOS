/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXContracts
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXDatabase

// DICOM objects read by the browser: the meta-data window of an image and
// the ROIs of an RTSTRUCT. Raw pixel data imported as secondary captures is
// RawDataImport (RawDataImport.swift).

extension BrowserController {

    #if !OSIRIX_LIGHT

    /// "Import Raw Data" (RawDataImport).
    @objc(importRawData:)
    func importRawData(_ sender: Any!) {
        rawDataImport.chooseAndImport()
    }

    /// The meta-data window of the first image of the thumbnails' selection.
    @objc(viewXML:)
    func viewXML(_ sender: Any!) {
        let image = firstObjectForDatabaseMatrixSelection()
        let name = String(format: NSLocalizedString("Meta-Data: %@", comment: ""),
                          String(describing: image?.value(forKey: "completePath") ?? "(null)"))
        let controller = XMLController(image: image, windowName: name, viewer: nil)
        controller?.showWindow(self)
    }

    // MARK: RTSTRUCT

    /// The ROIs of the RTSTRUCTs among the selected thumbnails, on the
    /// preview's image.
    @objc(createROIsFromRTSTRUCT:)
    func createROIsFromRTSTRUCT(_ sender: Any!) {
        let objects = NSMutableArray()
        guard let paths = files(forDatabaseMatrixSelection: objects) else { return }
        for index in 0 ..< objects.count where index < paths.count {
            guard BrowserObjC.literallyEqual((objects[index] as AnyObject).value(forKey: "modality") as? String, "RTSTRUCT") else { continue }
            let object = (paths[index] as? String).flatMap { DCMObject.object(contentsOfFile: $0) }
            // One DCMPix goes with an RTSTRUCT.
            let pix = HorosObjCException.synchronized(horos_previewPixThumbnails) { horos_previewPix?.object(at: 0) as? DCMPix }
            pix?.createROIs(fromRTSTRUCT: object)
        }
    }

    #endif
}
