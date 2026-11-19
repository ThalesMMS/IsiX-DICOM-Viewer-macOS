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
/*
 Copyright (C) 2009 Stig Brautaset. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
 
 * Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
 
 * Neither the name of the author nor the names of its contributors may be used
   to endorse or promote products derived from this software without specific
   prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
 FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Foundation

/// The implementation of SBJsonParser, declared in SBJsonParser.h: the JSON
/// parser of the plugin SDK of Horos and OsiriX. It holds the error trace and
/// the nesting limit; SBJsonCompatibleParser, below, reads.
@objc @implementation extension SBJsonParser {
    /// c of the header of an older SDK, which a plugin built with it binds by
    /// name when it loads: where its parser stood in the UTF-8 text it was
    /// reading. The text is read by JSONSerialization, which shows no place
    /// in it: nil.
    final var c: UnsafePointer<CChar>?

    override init() {
        super.init()
    }

    /// The object the JSON text stands for, a string or a number alone
    /// included; nil, and the reason in the trace, for a text that is not JSON.
    @objc(fragmentWithString:)
    func fragment(withString repr: Any!) -> Any! {
        parse(repr, allowFragments: true)
    }

    /// The dictionary or the array the JSON text stands for; nil, and the
    /// reason in the trace, for anything else.
    @objc(objectWithString:)
    func object(with repr: String!) -> Any! {
        parse(repr, allowFragments: false)
    }

    private final func parse(_ repr: Any?, allowFragments: Bool) -> Any? {
        clearErrorTrace()
        guard let text = repr as? NSString else {
            addError(withCode: UInt(SBJsonCompatibleParser.input), description: "Input was 'nil'")
            return nil
        }
        switch SBJsonCompatibleParser.object(with: text, allowFragments: allowFragments, maxDepth: maxDepth, parserValues: true) {
        case .success(let object):
            return object
        case .failure(let error):
            addError(withCode: UInt(bitPattern: error.code), description: SBJsonCompatibleParser.reason(of: error))
            return nil
        }
    }
}

/// What SBJsonParser did, over Foundation's JSONSerialization: the containers
/// it returns are mutable, as SBJsonParser's were, booleans are the NSNumber
/// booleans in both, and the errors carry SBJsonParser's domain and codes.
/// SBJsonParser made every number an NSDecimalNumber and every string an
/// NSMutableString; with `parserValues` what JSONSerialization read is replaced
/// by one each, otherwise the numbers stay the NSNumber it gave (an integer, or
/// a double for a fraction or an exponent) and the strings what it gave.
enum SBJsonCompatibleParser {

    /// SBJSONErrorDomain and the error codes of SBJsonBase.h.
    private static let errorDomain = "org.brautaset.JSON.ErrorDomain"
    private static let parse = 3      // EPARSE
    private static let fragment = 4   // EFRAGMENT
    private static let tooDeep = 7    // EDEPTH
    static let input = 12             // EINPUT

    static func object(with string: NSString, allowFragments: Bool, maxDepth: UInt = 512,
                       parserValues: Bool = false) -> Result<Any, NSError> {
        // SBJsonParser read -UTF8String.
        guard let data = string.data(using: String.Encoding.utf8.rawValue) else {
            return .failure(error(input, "Input is not UTF-8"))
        }
        // SBJsonParser counted the arrays and objects open at once and gave up
        // past its limit; JSONSerialization has a limit of its own and says
        // nothing of which it was.
        if maxDepth != 0 && nesting(of: data) > maxDepth {
            return .failure(error(tooDeep, "Nested too deep"))
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.mutableContainers, .mutableLeaves, .fragmentsAllowed])
        } catch let underlying {
            return .failure(error(parse, "Parse error", underlying: underlying))
        }
        if !allowFragments && !(object is NSDictionary) && !(object is NSArray) {
            return .failure(error(fragment, "Valid fragment, but not JSON"))
        }
        return .success(parserValues ? withParserValues(object) : object)
    }

    /// The description of a failure with what Foundation said of the text,
    /// for a trace that keeps descriptions only.
    static func reason(of error: NSError) -> String {
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
              let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String else {
            return error.localizedDescription
        }
        return error.localizedDescription + ": " + detail
    }

    private static func error(_ code: Int, _ description: String, underlying: Error? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
        if let underlying {
            userInfo[NSUnderlyingErrorKey] = underlying
        }
        return NSError(domain: errorDomain, code: code, userInfo: userInfo)
    }

    /// The most arrays and objects open at once in the text, strings skipped.
    private static func nesting(of data: Data) -> UInt {
        var depth: UInt = 0
        var deepest: UInt = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                deepest = max(deepest, depth)
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                if depth > 0 { depth -= 1 }
            default:
                break
            }
        }
        return deepest
    }

    /// `object` with each number that is not a boolean replaced by the
    /// NSDecimalNumber of its text and each string by a mutable one; the
    /// containers are changed in place.
    private static func withParserValues(_ object: Any) -> Any {
        let value = object as AnyObject
        if let dictionary = value as? NSMutableDictionary {
            for key in dictionary.allKeys {
                if let item = dictionary.object(forKey: key) {
                    dictionary.setObject(withParserValues(item), forKey: key as! NSCopying)
                }
            }
            return dictionary
        }
        if let array = value as? NSMutableArray {
            for index in 0..<array.count {
                array.replaceObject(at: index, with: withParserValues(array.object(at: index)))
            }
            return array
        }
        if let number = value as? NSNumber, !(number is NSDecimalNumber), CFGetTypeID(number) != CFBooleanGetTypeID() {
            let decimal = NSDecimalNumber(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
            return decimal == NSDecimalNumber.notANumber ? number : decimal
        }
        if let string = value as? NSString, !(string is NSMutableString) {
            return NSMutableString(string: string)
        }
        return object
    }
}
