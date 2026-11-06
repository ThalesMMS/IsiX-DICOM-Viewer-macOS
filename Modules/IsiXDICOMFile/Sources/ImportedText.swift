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

/// The text the import keeps of a name, a description or an identifier, cleaned
/// as +[DicomFile NSreplaceBadCharacter:] always cleaned it: the person-name
/// separators and the characters a path cannot hold replaced, line breaks
/// dropped, double quotes made single, runs of spaces folded and the trailing
/// spaces cut, the first character excepted.
///
/// The import runs this on every name and description of every file, so the
/// usual case - plain ASCII - is one pass over the characters, without a
/// search per rule; any other text goes through the same Foundation searches as
/// before, in the same order, since a search that is not literal treats a
/// character followed by a combining mark as a different character.
public enum ImportedText {

    /// The replacements, in the order they were made.
    private static let rules: [(of: String, with: String)] = [
        (",", " "), ("^", " "), ("/", "-"), ("\r", ""), ("\n", ""), ("\"", "'"),
        ("   ", " "),   // three spaces, one
        ("  ", " "),    // two spaces, one
    ]

    /// `string` cleaned, as a new string; nil for nil.
    public static func cleaned(_ string: NSString?) -> NSMutableString? {
        guard let string else { return nil }
        let result = NSMutableString(string: string)
        clean(result)
        return result
    }

    /// Cleans `string` in place.
    public static func clean(_ string: NSMutableString) {
        let length = string.length
        guard length > 0 else { return }
        let done = withUnsafeTemporaryAllocation(of: unichar.self, capacity: length * 2) { buffer -> Bool in
            let input = buffer.baseAddress!
            let output = input + length
            string.getCharacters(input, range: NSRange(location: 0, length: length))
            for index in 0..<length where input[index] >= 0x80 { return false }
            let count = cleanASCII(input, length, into: output)
            if count != length || memcmp(input, output, count * MemoryLayout<unichar>.size) != 0 {
                CFStringReplaceAll(string as CFMutableString,
                                   CFStringCreateWithCharacters(nil, output, count))
            }
            return true
        }
        if !done { cleanWithSearches(string) }
    }

    /// The rules on ASCII characters, in one pass: the six single-character
    /// rules map each character; a run of n spaces then becomes what the two
    /// folding searches leave of it, (n / 3 + n % 3) halved upwards; the
    /// trailing spaces go, except the first character.
    private static func cleanASCII(_ input: UnsafePointer<unichar>, _ length: Int,
                                   into output: UnsafeMutablePointer<unichar>) -> Int {
        let space: unichar = 0x20
        var count = 0, run = 0
        func flushRun() {
            guard run > 0 else { return }
            let afterThrees = run / 3 + run % 3
            for _ in 0..<(afterThrees / 2 + afterThrees % 2) {
                output[count] = space
                count += 1
            }
            run = 0
        }
        for index in 0..<length {
            var character = input[index]
            switch character {
            case 0x2C, 0x5E: character = space          // , ^
            case 0x2F: character = 0x2D                  // / -
            case 0x0D, 0x0A: continue                    // \r \n
            case 0x22: character = 0x27                  // " '
            default: break
            }
            if character == space {
                run += 1
            } else {
                flushRun()
                output[count] = character
                count += 1
            }
        }
        flushRun()
        while count > 1 && output[count - 1] == space { count -= 1 }
        return count
    }

    /// The rules as Foundation searches, as the Objective-C made them.
    private static func cleanWithSearches(_ string: NSMutableString) {
        for rule in rules {
            string.replaceOccurrences(of: rule.of, with: rule.with, options: [],
                                      range: NSRange(location: 0, length: string.length))
        }
        var index = string.length - 1
        while index > 0 && string.character(at: index) == 0x20 {
            string.deleteCharacters(in: NSRange(location: index, length: 1))
            index -= 1
        }
    }

    /// The C string `bytes`, cleaned in place as replaceBadCharacter() did for
    /// Latin-1 text: `/` becomes `-`, `^` a space, and the trailing spaces are
    /// cut, the first character excepted. Other encodings are left as they are.
    @discardableResult
    public static func cleanCString(_ bytes: UnsafeMutablePointer<CChar>, encoding: UInt) -> UnsafeMutablePointer<CChar> {
        guard encoding == String.Encoding.isoLatin1.rawValue else { return bytes }
        var index = strlen(bytes)
        while index > 0 {
            index -= 1
            if bytes[index] == 0x2F { bytes[index] = 0x2D }
            if bytes[index] == 0x5E { bytes[index] = 0x20 }
        }
        var last = strlen(bytes)
        if last > 0 {
            last -= 1
            while last > 0 && bytes[last] == 0x20 {
                bytes[last] = 0
                last -= 1
            }
        }
        return bytes
    }
}
