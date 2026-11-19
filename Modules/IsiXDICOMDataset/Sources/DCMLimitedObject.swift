/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Â version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. Â See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. Â If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Â  OsiriX
 Â Copyright (c) OsiriX Team
 Â All rights reserved.
 Â Distributed under GNU - LGPL
 Â 
 Â See http://www.osirix-viewer.com/copyright.html for details.
 Â  Â  This software is distributed WITHOUT ANY WARRANTY; without even
 Â  Â  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Â  Â  PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IsiXDICOMFile

/// The three subclasses of DCMObject the SDK of Horos and OsiriX had, each a
/// reader that stopped early or kept less: DCMLimitedObject read up to a
/// group, DCMObjectDBImport kept the attributes the database wanted, and
/// DCMObjectPixelDataImport those the image needed. The host's DICOM reader
/// reads the whole dataset, or up to a group, so each is DCMObject with the
/// class a plugin asks for by name: what +objectWith... answers is an
/// instance of the subclass, with everything the reader read.
///
/// They live beside DCMObject, in the module the linker always loads with it.
/// A plugin's own Objective-C subclass of one of them has the limits of any
/// Objective-C subclass of a Swift class: it sees the methods, not the Swift
/// initializers' guarantees.
@objc(DCMLimitedObject)
public class DCMLimitedObject: DCMObject {
    @objc(objectWithData:lastGroup:)
    public class func object(with data: Data?, lastGroup: UInt16) -> DCMLimitedObject? {
        DCMLimitedObject(data: data, lastGroup: lastGroup)
    }

    @objc(objectWithContentsOfFile:lastGroup:)
    public class func object(withContentsOfFile path: String?, lastGroup: UInt16) -> DCMLimitedObject? {
        DCMLimitedObject(contentsOfFile: path, lastGroup: lastGroup)
    }

    @objc(objectWithContentsOfURL:lastGroup:)
    public class func object(withContentsOf url: URL?, lastGroup: UInt16) -> DCMLimitedObject? {
        DCMLimitedObject(contentsOf: url, lastGroup: lastGroup)
    }

    @objc(initWithData:lastGroup:)
    public convenience init?(data: Data?, lastGroup: UInt16) {
        self.init(taking: data.flatMap {
            DCMHost.reader?.object(data: $0, transferSyntax: nil, decodingPixelData: false, lastGroup: lastGroup)
        })
    }

    @objc(initWithContentsOfFile:lastGroup:)
    public convenience init?(contentsOfFile path: String?, lastGroup: UInt16) {
        self.init(taking: DCMObject.object(contentsOfFile: path, decodingPixelData: false, lastGroup: lastGroup))
    }

    @objc(initWithContentsOfURL:lastGroup:)
    public convenience init?(contentsOf url: URL?, lastGroup: UInt16) {
        guard let url else { return nil }
        if url.isFileURL {
            self.init(contentsOfFile: url.path, lastGroup: lastGroup)
        } else {
            self.init(data: try? Data(contentsOf: url), lastGroup: lastGroup)
        }
    }

    /// The bytes of `container` from `byteOffset`, read up to group `lastGroup`.
    @objc(initWithDataContainer:lengthToRead:byteOffset:characterSet:lastGroup:)
    public convenience init?(dataContainer container: DCMDataContainer?, lengthToRead: Int32,
                             byteOffset: UnsafeMutablePointer<Int32>?, characterSet: DICOMCharacterSet?,
                             lastGroup: UInt16) {
        self.init(taking: DCMObject.object(readingFrom: container, lengthToRead: lengthToRead,
                                           byteOffset: byteOffset, decodingPixelData: false, lastGroup: lastGroup))
        if specificCharacterSet == nil, let characterSet { setCharacterSet(characterSet) }
    }

    /// Reads on, into this object, up to group `lastGroup`; answers the offset
    /// reached, or -1 when the bytes are not a dataset.
    @objc(readDataSet:toGroup:byteOffset:)
    public func readDataSet(_ container: DCMDataContainer?, toGroup lastGroup: UInt16,
                            byteOffset: UnsafeMutablePointer<Int32>?) -> Int32 {
        read(container, lengthToRead: -1, byteOffset: byteOffset, lastGroup: lastGroup)
    }
}

@objc(DCMObjectDBImport)
public class DCMObjectDBImport: DCMObject {
    public override class func object(withContentsOfFile path: String?, decodingPixelData: Bool) -> DCMObject? {
        DCMObjectDBImport(taking: super.object(withContentsOfFile: path, decodingPixelData: decodingPixelData))
    }

    /// Every attribute is kept: the reader reads the whole dataset.
    public override func isNeededAttribute(_ tagString: UnsafeMutablePointer<CChar>?) -> Bool {
        true
    }
}

@objc(DCMObjectPixelDataImport)
public class DCMObjectPixelDataImport: DCMObject {
    public override class func object(withContentsOfFile path: String?, decodingPixelData: Bool) -> DCMObject? {
        DCMObjectPixelDataImport(taking: super.object(withContentsOfFile: path, decodingPixelData: decodingPixelData))
    }
}
