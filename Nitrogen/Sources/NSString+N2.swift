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

// NSString (N2) and NSAttributedString (N2) are implemented in Swift since
// #710. The selectors and <Horos/NSString+N2.h> are those of the former
// categories. N2NonNullString, a C function exported with its C++ name, stays
// in NSString+N2+CAPI.mm.
//
// The former -stringByConditionallyResolvingSymlink and
// -stringByConditionallyResolvingAlias of this category are not here: the
// application also links NSString (SymlinksAndAliases) of LetsMoveAndDock,
// which defines both selectors and is the implementation the runtime used
// (the linker put its methods first in the merged NSString category). Callers,
// NSFileManager+N2 among them, keep getting that one.

/// The C conversion of a floating-point value to an unsigned integer as it
/// behaves on arm64: NaN and negative values are 0, values past the range
/// saturate.
fileprivate func cUnsigned<T: BinaryFloatingPoint, U: FixedWidthInteger & UnsignedInteger>(_ value: T, _: U.Type) -> U {
    if value.isNaN || value <= 0 { return 0 }
    if value >= T(U.max) { return U.max }
    return U(value)
}

public extension NSString {

    @objc(stringByTruncatingToLength:)
    func stringByTruncating(toLength theWidth: Int) -> NSString {
        let stringLength = length
        let stringMiddle = (theWidth - 3) / 2

        let retString = NSMutableString()

        if stringLength > theWidth {
            var i = 0
            while i <= stringMiddle {
                retString.append(substring(with: NSRange(location: i, length: 1)))
                i += 1
            }

            retString.append("...")

            i = stringLength - stringMiddle
            while i < stringLength {
                retString.append(substring(with: NSRange(location: i, length: 1)))
                i += 1
            }

            return retString
        }

        return self
    }

    // from http://snippets.dzone.com/posts/show/3038 with slight modifications
    @objc(sizeString:)
    static func sizeString(_ size: UInt64) -> NSString {
        if size < 1023 {
            return NSString(format: NSLocalizedString("%i bytes", comment: "") as NSString, size)
        }
        var floatSize = Float(size) / 1024
        if floatSize < 1023 {
            return NSString(format: NSLocalizedString("%1.2f KB", comment: "KB = kilo bytes") as NSString, Double(floatSize))
        }
        floatSize = floatSize / 1024
        if floatSize < 1023 {
            return NSString(format: NSLocalizedString("%1.2f MB", comment: "MB = mega bytes") as NSString, Double(floatSize))
        }
        floatSize = floatSize / 1024
        return NSString(format: NSLocalizedString("%1.2f GB", comment: "GB = giga bytes") as NSString, Double(floatSize))
    }

    @objc(timeString:)
    static func timeString(_ time: TimeInterval) -> NSString {
        timeString(time, maxUnits: 1)
    }

    @objc(timeString:maxUnits:)
    static func timeString(_ time: TimeInterval, maxUnits: Int) -> NSString {
        var time = time
        let rs = NSMutableArray()

        repeat {
            let unit: String, units: String, value: UInt32
            if time < 60 {
                unit = NSLocalizedString("second", comment: "")
                units = NSLocalizedString("seconds", comment: "")
                value = cUnsigned(floor(time), UInt32.self)
                time -= Double(value)
            } else if time < 3600 {
                unit = NSLocalizedString("minute", comment: "")
                units = NSLocalizedString("minutes", comment: "")
                value = cUnsigned(floor(time / 60), UInt32.self)
                time -= Double(value &* 60)
            } else {
                unit = NSLocalizedString("hour", comment: "")
                units = NSLocalizedString("hours", comment: "")
                value = cUnsigned(floor(time / 3600), UInt32.self)
                time -= Double(value &* 3600)
            }

            rs.add(NSString(format: "%d %@", value, (value == 1 ? unit : units) as NSString))
            // rs.count (NSUInteger) < maxUnits (NSInteger) compared as unsigned, as in C
        } while UInt(rs.count) < UInt(bitPattern: maxUnits) && time >= 1

        let s = NSMutableString()
        for i in 0..<rs.count {
            if i > 0 {
                if i == rs.count - 1 {
                    s.append(NSLocalizedString(" and ", comment: ""))
                } else {
                    s.append(", ")
                }
            }

            s.append(rs.object(at: i) as! String)
        }

        return s
    }

    @objc func stringByTrimmingStartAndEnd() -> NSString {
        let whitespaceAndNewline = CharacterSet.whitespacesAndNewlines as NSCharacterSet
        var i = 0
        while i < length && whitespaceAndNewline.characterIsMember(character(at: i)) { i += 1 }
        if i == length { return "" }
        let start = i
        i = length - 1
        while i > start && whitespaceAndNewline.characterIsMember(character(at: i)) { i -= 1 }
        return substring(with: NSRange(location: start, length: i - start + 1)) as NSString
    }

    /// &amp; is handled apart, first.
    private static let xmlEscapes: [(String, String)] = [
        ("<", "&lt;"),
        (">", "&gt;"),
        /* ("&", "&amp;"), */
        ("'", "&#39;"), // &#39; &apos;
        ("\"", "&quot;"),
    ]

    /// Not in the header; kept under its former selector.
    @objc(xmlEscapedString:)
    func xmlEscapedString(_ unescape: Bool) -> NSString {
        let temp = mutableCopy() as! NSMutableString
        // amp first!!
        if !unescape {
            temp.n2ReplaceOccurrences(of: "&", with: "&amp;")
        } else {
            temp.n2ReplaceOccurrences(of: "&amp;", with: "&")
        }
        // other chars
        for (k, v) in NSString.xmlEscapes {
            if !unescape {
                temp.n2ReplaceOccurrences(of: k as NSString, with: v as NSString)
            } else {
                temp.n2ReplaceOccurrences(of: v as NSString, with: k as NSString)
            }
        }

        return NSString(string: temp)
    }

    @objc func xmlEscapedString() -> NSString {
        xmlEscapedString(false)
    }

    @objc func ASCIIString() -> NSString? {
        guard let data = data(using: String.Encoding.ascii.rawValue, allowLossyConversion: true) else { return nil }
        return NSString(data: data, encoding: String.Encoding.ascii.rawValue)
    }

    @objc(contains:)
    func n2Contains(_ str: NSString) -> Bool {
        range(of: str as String, options: .literal).location != NSNotFound
    }

    @objc(stringByPrefixingLinesWithString:)
    func stringByPrefixingLines(with prefix: NSString) -> NSString {
        let lines = (components(separatedBy: CharacterSet.newlines) as NSArray).mutableCopy() as! NSMutableArray
        if (lines.lastObject as? NSString)?.isEqual(to: "") == true { lines.removeLastObject() }
        return NSString(format: "%@%@\n", prefix, lines.componentsJoined(by: NSString(format: "\n%@", prefix) as String) as NSString)
    }

    @objc(stringByRepeatingString:times:)
    static func stringByRepeating(_ string: NSString, times: UInt) -> NSString {
        let ret = NSMutableString(capacity: string.length &* Int(bitPattern: times))
        var i: UInt = 0
        while i < times {
            ret.append(string as String)
            i += 1
        }
        return ret
    }

    @objc func suspendedString() -> NSString {
        var dotsCount: UInt = 0
        var i = length - 1
        while i >= 0 {
            if character(at: i) == 0x2E /* '.' */ {
                dotsCount += 1
            } else {
                break
            }
            i -= 1
        }
        if dotsCount >= 3 { return self }
        return appending(NSString.stringByRepeating(".", times: 3 - dotsCount) as String) as NSString
    }

    @objc(range)
    func n2Range() -> NSRange {
        NSRange(location: 0, length: length)
    }

    @objc(stringByComposingPathWithString:)
    func stringByComposingPath(with rel: NSString) -> NSString? {
        let baseurl = NSURL(string: character(at: 0) == 0x2F /* '/' */ ? self as String : NSString(format: "/%@", self) as String)
        let url = NSURL(string: rel as String, relativeTo: baseurl as URL?)
        guard let path = url?.path as NSString? else { return nil }
        return character(at: 0) == 0x2F ? path : path.substring(from: 1) as NSString
    }

    @objc(componentsWithLength:)
    func components(withLength len: UInt) -> NSArray {
        let nf = CGFloat(length) / CGFloat(len)
        let n = cUnsigned(ceilf(Float(nf)), UInt.self)

        let r = NSMutableArray(capacity: Int(bitPattern: n))
        var i: UInt = 0
        while i < n {
            let location = Int(bitPattern: i &* len)
            r.add(substring(with: NSRange(location: location, length: i != n - 1 ? Int(bitPattern: len) : length - location)))
            i += 1
        }
        return r
    }

    // from DHValidation
    @objc func isEmail() -> Bool {
        NSPredicate(format: "SELF MATCHES %@", "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,6}").evaluate(with: self)
    }

    @objc(splitStringAtCharacterFromSet:intoChunks::separator:)
    func splitString(atCharacterFrom charset: NSCharacterSet,
                     intoChunks part1: AutoreleasingUnsafeMutablePointer<NSString?>?,
                     _ part2: AutoreleasingUnsafeMutablePointer<NSString?>?,
                     separator: UnsafeMutablePointer<unichar>?) {
        let i = rangeOfCharacter(from: charset as CharacterSet).location
        if i != NSNotFound {
            part1?.pointee = substring(to: i) as NSString
            separator?.pointee = character(at: i)
            part2?.pointee = substring(from: i + 1) as NSString
        } else {
            part1?.pointee = self
            separator?.pointee = 0
            part2?.pointee = nil
        }
    }

    @objc func md5() -> NSString {
        // NSData (N2)'s -md5 and -hex, by their Objective-C selectors.
        let utf8 = utf8String!
        let data = NSData(bytesNoCopy: UnsafeMutableRawPointer(mutating: utf8), length: strlen(utf8), freeWhenDone: false)
        let hash = data.perform(NSSelectorFromString("md5"))!.takeUnretainedValue() as! NSObject
        return hash.perform(NSSelectorFromString("hex"))!.takeUnretainedValue() as! NSString
    }
}

public extension NSAttributedString {

    @objc(range)
    func n2Range() -> NSRange {
        NSRange(location: 0, length: length)
    }
}
