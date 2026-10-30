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
import IsiXDICOMDataset
import IsiXImaging

/// What the app's DCMPix does with a DICOM file when it loads the image's
/// first frame, without the app: the file parsed by DCMTK (HorosDCMTKObject,
/// which the dataset model finds by name), the image's attributes read and
/// the frame decoded and converted by the IsiXImaging module
/// (ImageAttributeLoad, FrameLoad). The validation before importing runs it
/// to find the file that brings a process down before the database's does,
/// and the file that cannot be read. A file DCMTK cannot parse and that does
/// not say it is DICOM is another kind of file the importer may take (an
/// image, a document): it is not this test's to refuse.
enum FirstFrameTest {

    /// Whether the first frame of the file at `path` loads; `name` is the
    /// file as the application knows it, for the messages.
    static func loads(_ path: String, named name: String) -> Bool {
        var loaded = false
        do {
            try HorosObjCException.perform { loaded = load(path, named: name) }
        } catch {
            let exception = (error as NSError).userInfo[HorosObjCExceptionKey] ?? error
            NSLog("-- testFiles: %@ raised %@", name, "\(exception)")
            return false
        }
        return loaded
    }

    private static func load(_ path: String, named name: String) -> Bool {
        guard let object = DCMObject.object(contentsOfFile: path) else {
            if hasDICOMPreamble(path) { return false }
            NSLog("-- testFiles: %@ is not a DICOM file; not tested", name)
            return true
        }
        let attributes = ImageAttributeLoad()
        attributes.file = name
        attributes.readIdentification(from: object)
        // As the app's loading, a reading that raised stops it there.
        guard attributes.readImage(from: object) else {
            NSLog("-- testFiles: %@ raised %@", name, attributes.raisedException.map { "\($0)" } ?? "(null)")
            return false
        }
        guard object.attributeValue(withName: "PixelData") != nil else { return true }
        let frame = FrameLoad()
        frame.file = name
        frame.setSamples(width: attributes.width, height: attributes.height, bitsAllocated: attributes.bitsAllocated,
                         bitsStored: attributes.bitsStored, signed: attributes.isSigned)
        frame.setModalityLUT(slope: attributes.slope, offset: attributes.intercept)
        frame.planarConfiguration = attributes.planarConfiguration
        let pixels = object.attribute(withName: "PixelData") as? DCMPixelDataAttribute
        let loaded = frame.load(pixels?.decodeFrame(at: 0), of: object, applyingVOILUT: nil)
        if let image = frame.image { free(image) }
        return loaded
    }

    /// A Part 10 file says so with "DICM" after its 128-byte preamble.
    private static func hasDICOMPreamble(_ path: String) -> Bool {
        guard let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: 132), head.count == 132 else { return false }
        return head.suffix(4) == Data("DICM".utf8)
    }
}
