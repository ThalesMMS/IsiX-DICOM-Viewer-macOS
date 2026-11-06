/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:  OsiriX
 Copyright (c) OsiriX Team
 All rights reserved.
 Distributed under GNU - LGPL
 
 See http://www.osirix-viewer.com/copyright.html for details.
   This software is distributed WITHOUT ANY WARRANTY; without even
   the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
   PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// XMLController (DICOM editing): writing tag edits into DICOM files, which the
// metadata editor, the database's entities and the merge ask for, through
// Adapters/DCMTK/IsiXDCMTKTagEditor; the dcmodify-style command line of
// +modifyDicom:encoding: (Adapters/DCMTK/IsiXDCMTKModifyCLI); and the DICOM
// dictionary the editor offers names from (IsiXDCMTKDictionary).

extension XMLController {

    /// Writes the edits into the files, on the calling thread: the entities
    /// call it from any thread. NO may mean partial success.
    @objc(modifyDicom:dicomFiles:) @discardableResult
    public nonisolated class func modifyDicom(_ tagAndValues: [Any]!, dicomFiles: [Any]!) -> Bool {
        return modifyDicom(tagAndValues, dicomFiles: dicomFiles, reasons: nil)
    }

    /// As above, and reports why each refused field could not be written.
    /// An entry of one element removes that tag; two replaces it, and an empty
    /// string is a value rather than a removal. Accepted edits are published per
    /// file atomically; NO may mean partial success. Reasons include saved counts,
    /// full refused addresses and files whose originals were preserved.
    @objc(modifyDicom:dicomFiles:reasons:) @discardableResult
    public nonisolated class func modifyDicom(_ tagAndValues: [Any]!, dicomFiles: [Any]!,
                                              reasons: AutoreleasingUnsafeMutablePointer<NSArray?>?) -> Bool {
        return IsiXDCMTKTagEditor.modifyFiles(dicomFiles ?? [], withEntries: tagAndValues ?? [], reasons: reasons)
    }

    /// The Specific Character Set a file has to declare before these text values
    /// are written into it: nil when its own encodes them, ISO_IR 192 when it
    /// declares none and all its text is ASCII. *refused is YES, with nil, when the
    /// file cannot take them without re-encoding its other text, or cannot be read.
    @objc(characterSetToDeclareForValues:inDicomFile:refused:)
    public nonisolated class func characterSetToDeclare(forValues values: [Any]!, inDicomFile path: String!,
                                                        refused: UnsafeMutablePointer<ObjCBool>?) -> String? {
        return IsiXDCMTKTagEditor.characterSetToDeclare(forValues: values ?? [], inFileAtPath: path ?? "", refused: refused)
    }

    /// dcmodify's command line: params[0] is the program's name, then options
    /// and values, then one or more files. The number of errors.
    @objc(modifyDicom:encoding:)
    public nonisolated class func modifyDicom(_ params: [Any]!, encoding: UInt) -> Int32 {
        return HorosModifyDICOMCLI(params, encoding)
    }

    /// The tag of a dictionary keyword: 0, or -1 when the dictionary has none.
    @objc(getGroupAndElementForName:group:element:)
    public func getGroupAndElement(forName name: String!, group gp: UnsafeMutablePointer<Int32>!,
                                   element el: UnsafeMutablePointer<Int32>!) -> Int32 {
        var group: UInt32 = 0xffff, element: UInt32 = 0xffff
        if !DICOMKeyword.resolve(name, group: &group, element: &element) {
            return -1
        }
        gp.pointee = Int32(group)
        el.pointee = Int32(element)
        return 0
    }

    /// Fills the dictionary array with "(0xgggg,0xeeee) Keyword" for each public
    /// attribute of the DICOM dictionary, by tag, group 0000 left out.
    @objc public func prepareDictionaryArray() {
        let list = dictionaryArray
        do {
            try IsiXDCMTKDictionary.enumeratePublicAttributes { tag, keyword in
                list?.add(String(format: "(0x%04x,0x%04x) %@", tag >> 16, tag & 0xffff, keyword))
            }
        } catch {
            NSLog("---- the DICOM dictionary could not be listed: %@", error.localizedDescription)
        }
    }
}
