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

/// The bytes of a DICOM text value read into a string, as dcmtk 3.6's
/// convertString reads them and as +[DicomFile stringWithBytes:encodings:]
/// always did: in the value's first character set, switching at each ISO 2022
/// escape sequence, and back to the first one at each delimiter (a line break,
/// a form feed, and, in a person name, `^` and `=`).
public enum DICOMTextDecoding {

    /// `bytes`, NUL-terminated, read starting in `encodings[0]`.
    /// `encodingForTerm` answers the encoding of an ISO 2022 term
    /// ("ISO 2022 IR 100"); it is asked only at an escape sequence.
    public static func decode(_ bytes: UnsafePointer<CChar>, encodings: UnsafePointer<UInt>,
                              encodingForTerm: (String) -> UInt) -> NSMutableString {
        let fromLength = strlen(bytes)
        let result = NSMutableString()
        var checkPNDelimiters = true
        var currentEncoding = encodings[0]
        var position = 0
        var first = 0        // where the characters not yet converted start
        var current = 0      // the next byte
        var escapeLength = 0

        func append(from start: Int, length: Int) {
            if let text = NSString(bytes: bytes + start, length: length, encoding: currentEncoding) {
                result.append(text as String)
            }
        }

        while position < fromLength {
            let c0 = UInt8(bitPattern: bytes[current])
            current += 1
            let isEscape = c0 == 0x1B
            let isDelimiter = c0 == 0x0A || c0 == 0x0C || c0 == 0x0D
                || ((c0 == 0x5E || c0 == 0x3D) && checkPNDelimiters)

            if isEscape || isDelimiter {
                let convertLength = current - first - 1
                if convertLength - (escapeLength + 1) >= 0 {
                    append(from: first, length: convertLength)
                }
            }

            if isEscape {
                // At least two more characters name the new character set.
                escapeLength = 2
                if position + escapeLength < fromLength {
                    var term: String?
                    let c1 = UInt8(bitPattern: bytes[current])
                    let c2 = UInt8(bitPattern: bytes[current + 1])
                    current += 2
                    switch (c1, c2) {
                    case (0x28, 0x42): term = "ISO 2022 IR 6"       // ASCII
                    case (0x2D, 0x41): term = "ISO 2022 IR 100"     // Latin alphabet No. 1
                    case (0x2D, 0x42): term = "ISO 2022 IR 101"     // Latin alphabet No. 2
                    case (0x2D, 0x43): term = "ISO 2022 IR 109"     // Latin alphabet No. 3
                    case (0x2D, 0x44): term = "ISO 2022 IR 110"     // Latin alphabet No. 4
                    case (0x2D, 0x4C): term = "ISO 2022 IR 144"     // Cyrillic
                    case (0x2D, 0x47): term = "ISO 2022 IR 127"     // Arabic
                    case (0x2D, 0x46): term = "ISO 2022 IR 126"     // Greek
                    case (0x2D, 0x48): term = "ISO 2022 IR 138"     // Hebrew
                    case (0x2D, 0x4D): term = "ISO 2022 IR 148"     // Latin alphabet No. 5
                    case (0x29, 0x49): term = "ISO 2022 IR 13"      // Japanese
                    case (0x28, 0x4A): term = "ISO 2022 IR 13"      // Japanese, as dcmtk reads it
                    case (0x2D, 0x54): term = "ISO 2022 IR 166"     // Thai
                    case (0x24, 0x42): term = "ISO 2022 IR 87"      // Japanese, multi-byte
                    case (0x24, 0x28):                              // Japanese, multi-byte
                        escapeLength = 3
                        if position + escapeLength < fromLength {
                            let c3 = UInt8(bitPattern: bytes[current])
                            current += 1
                            if c3 == 0x44 { term = "ISO 2022 IR 159" }
                        }
                    case (0x24, 0x29):                              // Korean or simplified Chinese, multi-byte
                        escapeLength = 3
                        if position + escapeLength < fromLength {
                            let c3 = UInt8(bitPattern: bytes[current])
                            current += 1
                            if c3 == 0x43 { term = "ISO 2022 IR 149" } else if c3 == 0x41 { term = "ISO 2022 IR 58" }
                        }
                    default: break
                    }

                    if let term {
                        currentEncoding = encodingForTerm(term)
                        checkPNDelimiters = term != "ISO 2022 IR 87" && term != "ISO 2022 IR 159"
                        // The multi-byte Japanese sets keep their escape sequence in the bytes converted.
                        first = checkPNDelimiters ? current : current - (escapeLength + 1)
                    } else {
                        NSLog("*** key == nil")
                    }
                    position += escapeLength
                    if checkPNDelimiters { escapeLength = 0 }
                }
                if position >= fromLength { NSLog("incomplete sequence") }
            } else if isDelimiter {
                result.append(delimiter(c0))
                if currentEncoding != encodings[0] {
                    currentEncoding = encodings[0]
                    checkPNDelimiters = true
                }
                first = current
            }
            position += 1
        }

        // What is left after the last delimiter or escape sequence.
        let convertLength = current - first
        if convertLength > 0 && first + convertLength <= fromLength && convertLength - (escapeLength + 1) >= 0 {
            append(from: first, length: convertLength)
        }
        return result
    }

    private static func delimiter(_ c: UInt8) -> String {
        switch c {
        case 0x0A: return "\n"
        case 0x0C: return "\u{0C}"
        case 0x0D: return "\r"
        case 0x5E: return "^"
        default: return "="
        }
    }
}
