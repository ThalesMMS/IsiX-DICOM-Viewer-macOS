//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The tag a keyword names, from the dictionary DCMTK loaded (the DCMTK
/// adapter's IsiXDCMTKDictionary), in either spelling of the 2011 rename.
extension DICOMKeyword {

    /// The tag of the standard (even group) attribute a keyword names, in
    /// either spelling, the written one first, after the shipped dicom.dic is
    /// laid over DCMTK's dictionary; nil for a keyword DCMTK does not know.
    /// `getDicomField:forFile:`, the C-FIND keys and the XML editor resolve
    /// names this way.
    public static func standardTag(for keyword: String?) -> (group: UInt32, element: UInt32)? {
        guard let keyword, !keyword.isEmpty else { return nil }
        for spelling in spellingsToTry(for: keyword) where !spelling.isEmpty {
            var tag: UInt32 = 0
            if IsiXDCMTKDictionary.getStandardTag(&tag, forKeyword: spelling) {
                return (tag >> 16, tag & 0xffff)
            }
        }
        return nil
    }

    /// The same, for Objective-C: whether there is one, and its group and element.
    @objc(resolveKeyword:group:element:)
    public static func resolve(_ keyword: String?, group: UnsafeMutablePointer<UInt32>?,
                               element: UnsafeMutablePointer<UInt32>?) -> Bool {
        guard let group, let element, let tag = standardTag(for: keyword) else { return false }
        group.pointee = tag.group
        element.pointee = tag.element
        return true
    }
}
