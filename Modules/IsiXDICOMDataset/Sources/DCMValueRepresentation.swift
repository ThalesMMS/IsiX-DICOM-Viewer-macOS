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

/// What a value representation is, from its two letters: the questions the
/// parser of DCM.framework asked while it read and wrote a dataset. The model
/// reads and writes through the host's DCMTK now and does not ask them; the
/// class stays for a plugin built for Horos or OsiriX, which looks it up by
/// this name. Only the first two characters are read, as they were; a string
/// shorter than that, or nil, is no representation.
///
/// A subclass a plugin makes in Objective-C of a Swift class of a module has
/// no Swift metadata of its own: none is known, and the class is final.
@objc(DCMValueRepresentation)
public final class DCMValueRepresentation: NSObject {
    private static func letters(_ vr: String?) -> (UInt8, UInt8) {
        let bytes = Array((vr ?? "").utf8.prefix(2))
        return (bytes.count > 0 ? bytes[0] : 0, bytes.count > 1 ? bytes[1] : 0)
    }

    private static func isVR(_ vr: String?, _ code: StaticString) -> Bool {
        let letters = letters(vr)
        return code.withUTF8Buffer { letters.0 == $0[0] && letters.1 == $0[1] }
    }

    @objc(isApplicationEntityVR:) public class func isApplicationEntityVR(_ vr: String?) -> Bool { isVR(vr, "AE") }
    @objc(isAgeStringVR:) public class func isAgeStringVR(_ vr: String?) -> Bool { isVR(vr, "AS") }
    @objc(isAttributeTagVR:) public class func isAttributeTagVR(_ vr: String?) -> Bool { isVR(vr, "AT") }
    @objc(isCodeStringVR:) public class func isCodeStringVR(_ vr: String?) -> Bool { isVR(vr, "CS") }
    @objc(isDateVR:) public class func isDateVR(_ vr: String?) -> Bool { isVR(vr, "DA") }
    @objc(isDateTimeVR:) public class func isDateTimeVR(_ vr: String?) -> Bool { isVR(vr, "DT") }
    @objc(isDecimalStringVR:) public class func isDecimalStringVR(_ vr: String?) -> Bool { isVR(vr, "DS") }
    @objc(isFloatDoubleVR:) public class func isFloatDoubleVR(_ vr: String?) -> Bool { isVR(vr, "FD") }
    @objc(isFloatSingleVR:) public class func isFloatSingleVR(_ vr: String?) -> Bool { isVR(vr, "FL") }
    @objc(isIntegerStringVR:) public class func isIntegerStringVR(_ vr: String?) -> Bool { isVR(vr, "IS") }
    @objc(isLongStringVR:) public class func isLongStringVR(_ vr: String?) -> Bool { isVR(vr, "LO") }
    @objc(isLongTextVR:) public class func isLongTextVR(_ vr: String?) -> Bool { isVR(vr, "LT") }
    @objc(isOtherByteVR:) public class func isOtherByteVR(_ vr: String?) -> Bool { isVR(vr, "OB") }
    @objc(isOtherFloatVR:) public class func isOtherFloatVR(_ vr: String?) -> Bool { isVR(vr, "OF") }
    @objc(isOtherWordVR:) public class func isOtherWordVR(_ vr: String?) -> Bool { isVR(vr, "OW") }
    @objc(isOtherUnspecifiedVR:) public class func isOtherUnspecifiedVR(_ vr: String?) -> Bool { isVR(vr, "OX") }
    @objc(isPersonNameVR:) public class func isPersonNameVR(_ vr: String?) -> Bool { isVR(vr, "PN") }
    @objc(isShortStringVR:) public class func isShortStringVR(_ vr: String?) -> Bool { isVR(vr, "SH") }
    @objc(isSignedLongVR:) public class func isSignedLongVR(_ vr: String?) -> Bool { isVR(vr, "SL") }
    @objc(isSequenceVR:) public class func isSequenceVR(_ vr: String?) -> Bool { isVR(vr, "SQ") }
    @objc(isSignedShortVR:) public class func isSignedShortVR(_ vr: String?) -> Bool { isVR(vr, "SS") }
    @objc(isShortTextVR:) public class func isShortTextVR(_ vr: String?) -> Bool { isVR(vr, "ST") }
    @objc(isTimeVR:) public class func isTimeVR(_ vr: String?) -> Bool { isVR(vr, "TM") }
    @objc(isUniqueIdentifierVR:) public class func isUniqueIdentifierVR(_ vr: String?) -> Bool { isVR(vr, "UI") }
    @objc(isUnsignedLongVR:) public class func isUnsignedLongVR(_ vr: String?) -> Bool { isVR(vr, "UL") }
    @objc(isUnknownVR:) public class func isUnknownVR(_ vr: String?) -> Bool { isVR(vr, "UN") }
    @objc(isUnsignedShortVR:) public class func isUnsignedShortVR(_ vr: String?) -> Bool { isVR(vr, "US") }
    @objc(isUnspecifiedShortVR:) public class func isUnspecifiedShortVR(_ vr: String?) -> Bool { isVR(vr, "XS") }
    @objc(isUnspecifiedShortOrOtherWordVR:) public class func isUnspecifiedShortOrOtherWordVR(_ vr: String?) -> Bool { isVR(vr, "XO") }
    @objc(isUnlimitedTextVR:) public class func isUnlimitedTextVR(_ vr: String?) -> Bool { isVR(vr, "UT") }

    /// OB, OW or OX, the last one not a real representation but what the dictionary gives.
    @objc(isOtherByteOrWordVR:) public class func isOtherByteOrWordVR(_ vr: String?) -> Bool {
        isVR(vr, "OB") || isVR(vr, "OW") || isVR(vr, "OX")
    }

    /// The representations whose value length is written in two bytes in an explicit syntax.
    @objc(isShortValueLengthVR:) public class func isShortValueLengthVR(_ vr: String?) -> Bool {
        ["AE", "AS", "AT", "CS", "DA", "DS", "DT", "FD", "FL", "IS", "LO", "LT", "PN", "SH", "SL", "SS", "ST", "TM", "UI", "UL", "US"]
            .contains { (code: String) in letters(vr) == letters(code) }
    }

    @objc(isAffectedBySpecificCharacterSet:) public class func isAffectedBySpecificCharacterSet(_ vr: String?) -> Bool {
        isLongStringVR(vr) || isLongTextVR(vr) || isPersonNameVR(vr) || isShortStringVR(vr) || isShortTextVR(vr) || isUnlimitedTextVR(vr)
    }

    @objc(isValidVR:) public class func isValidVR(_ vr: String?) -> Bool {
        ["AE", "AS", "AT", "CS", "DA", "DT", "DS", "FD", "FL", "IS", "LO", "LT", "OB", "OF", "OW", "OX", "PN", "SH", "SL", "SQ", "SS", "ST",
         "TM", "UI", "UL", "UN", "US", "XS", "XO", "UT"].contains { (code: String) in letters(vr) == letters(code) }
    }

    /// The string of the C string `vr`, read as Latin-1.
    @objc(stringValue:) public class func stringValue(_ vr: UnsafeMutablePointer<CChar>?) -> String? {
        vr.flatMap { String(cString: $0, encoding: .isoLatin1) }
    }

    /// The bytes of a word of a value of `vr`, for a byte order to swap: 2, 4 or 8, and 1 for the others.
    @objc(getWordLengthOfValueAffectedByEndianness:) public class func wordLengthOfValueAffectedByEndianness(_ vr: String?) -> Int32 {
        if isFloatDoubleVR(vr) { return 8 }
        if isSignedLongVR(vr) || isUnsignedLongVR(vr) || isFloatSingleVR(vr) || isOtherFloatVR(vr) { return 4 }
        if isSignedShortVR(vr) || isUnsignedShortVR(vr) || isUnspecifiedShortVR(vr) || isOtherWordVR(vr) || isUnspecifiedShortOrOtherWordVR(vr) { return 2 }
        return 1
    }
}
