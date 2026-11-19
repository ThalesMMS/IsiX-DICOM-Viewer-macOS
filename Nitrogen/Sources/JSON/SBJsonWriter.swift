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

/// The implementation of SBJsonWriter, declared in SBJsonWriter.h: the JSON
/// writer of the plugin SDK of Horos and OsiriX. It holds the options and the
/// error trace; SBJsonCompatibleWriter, below, writes.
@objc @implementation extension SBJsonWriter {
    var humanReadable: Bool = false
    var sortKeys: Bool = false

    override init() {
        super.init()
    }

    /// The JSON of any value JSON has, a string or a number alone included.
    @objc(stringWithFragment:)
    func string(withFragment value: Any!) -> String! {
        write { $0.string(withFragment: value) }
    }

    /// The JSON of a dictionary or an array; nil, and EFRAGMENT in the trace,
    /// for anything else.
    @objc(stringWithObject:)
    func string(with value: Any!) -> String! {
        write { $0.string(withObject: value) }
    }

    private final func write(_ body: (SBJsonCompatibleWriter) -> NSString?) -> String? {
        let writer = SBJsonCompatibleWriter(maxDepth: maxDepth, humanReadable: humanReadable, sortKeys: sortKeys)
        let json = body(writer)
        clearErrorTrace()
        addErrors(writer.errors)
        return json as String?
    }
}

/// SBJsonWriter's rules, one by one, as SBJsonWriter.m had them. With its
/// defaults: no whitespace, keys in the order -[NSDictionary allKeys] gives
/// them (not sorted), a nesting limit of 512. It works on the Objective-C
/// objects themselves, in UTF-16, so that nothing is reordered or transcoded
/// on the way.
///
/// The web portal sends [x JSONRepresentation] to browsers, so the output keeps
/// the bytes SBJsonWriter wrote. JSONSerialization cannot give them: it
/// escapes '/', writes numbers its own way and raises on NaN, where
/// SBJsonWriter wrote -[NSNumber stringValue].
final class SBJsonCompatibleWriter {

    /// SBJSONErrorDomain and the error codes of SBJsonBase.h.
    static let errorDomain = "org.brautaset.JSON.ErrorDomain"
    private static let unsupported = 1 // EUNSUPPORTED
    private static let fragment = 4    // EFRAGMENT
    private static let tooDeep = 7     // EDEPTH

    private static let escapeCharacters: CharacterSet = {
        var characters = CharacterSet(charactersIn: Unicode.Scalar(UInt8(0))...Unicode.Scalar(UInt8(31)))
        characters.insert(charactersIn: "\"\\")
        return characters
    }()

    /// 0 for no limit.
    private let maxDepth: UInt
    /// A line and two spaces per level for each value, « : » after a key.
    private let humanReadable: Bool
    /// The keys of each dictionary in the order of -compare:.
    private let sortKeys: Bool

    private var depth: UInt = 0
    /// The errors of the last call, the first one first, each with the one
    /// before it as its underlying error.
    private(set) var errors: [NSError] = []

    init(maxDepth: UInt = 512, humanReadable: Bool = false, sortKeys: Bool = false) {
        self.maxDepth = maxDepth
        self.humanReadable = humanReadable
        self.sortKeys = sortKeys
    }

    /// What SBJsonWriter's -errorTrace printed in the log line of a failure.
    var errorTraceDescription: NSObject {
        errors.isEmpty ? ("(null)" as NSString) : (errors as NSArray)
    }

    private func addError(code: Int, description: String) {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
        if let last = errors.last {
            userInfo[NSUnderlyingErrorKey] = last
        }
        errors.append(NSError(domain: Self.errorDomain, code: code, userInfo: userInfo))
    }

    private static func isKind(_ object: AnyObject?, of type: AnyClass) -> Bool {
        (object as? NSObjectProtocol)?.isKind(of: type) ?? false
    }

    /// -stringWithFragment: of SBJsonWriter.
    func string(withFragment value: Any?) -> NSString? {
        errors = []
        depth = 0
        let json = NSMutableString(capacity: 128)
        if append(value, into: json) {
            return json
        }
        return nil
    }

    /// -stringWithObject: of SBJsonWriter: only a dictionary or an array.
    func string(withObject value: Any?) -> NSString? {
        let object = value.map { $0 as AnyObject }
        if Self.isKind(object, of: NSDictionary.self) || Self.isKind(object, of: NSArray.self) {
            return string(withFragment: value)
        }
        errors = []
        addError(code: Self.fragment, description: "Not valid type for JSON")
        return nil
    }

    /// A line feed and two spaces for each level of nesting.
    private func appendIndent(into json: NSMutableString) {
        json.append("\n" + String(repeating: " ", count: 2 * Int(depth)))
    }

    /// One level deeper; false, with EDEPTH, past the limit.
    private func descend() -> Bool {
        depth += 1
        if maxDepth != 0 && depth > maxDepth {
            addError(code: Self.tooDeep, description: "Nested too deep")
            return false
        }
        return true
    }

    private func append(_ value: Any?, into json: NSMutableString) -> Bool {
        let fragment = value.map { $0 as AnyObject }
        if Self.isKind(fragment, of: NSDictionary.self) {
            if !append(dictionary: unsafeDowncast(fragment!, to: NSDictionary.self), into: json) {
                return false
            }
        } else if Self.isKind(fragment, of: NSArray.self) {
            if !append(array: unsafeDowncast(fragment!, to: NSArray.self), into: json) {
                return false
            }
        } else if Self.isKind(fragment, of: NSString.self) {
            if !append(string: unsafeDowncast(fragment!, to: NSString.self), into: json) {
                return false
            }
        } else if Self.isKind(fragment, of: NSNumber.self) {
            let number = unsafeDowncast(fragment!, to: NSNumber.self)
            if number.objCType.pointee == CChar(UInt8(ascii: "c")) {
                json.append(number.boolValue ? "true" : "false")
            } else {
                json.append(number.stringValue)
            }
        } else if Self.isKind(fragment, of: NSNull.self) {
            json.append("null")
        } else if let object = fragment as? NSObjectProtocol,
                  object.responds(to: NSSelectorFromString("proxyForJson")) {
            // As SBJsonWriter did, a proxy that cannot be written leaves an
            // error in the trace but does not fail the whole value.
            let proxy = object.perform(NSSelectorFromString("proxyForJson"))?.takeUnretainedValue()
            _ = append(proxy, into: json)
        } else {
            let className = fragment.map { NSStringFromClass(type(of: $0)) } ?? "(null)"
            addError(code: Self.unsupported, description: "JSON serialisation not supported for \(className)")
            return false
        }
        return true
    }

    private func append(array fragment: NSArray, into json: NSMutableString) -> Bool {
        if !descend() {
            return false
        }
        json.append("[")

        var addComma = false
        for value in fragment {
            if addComma {
                json.append(",")
            } else {
                addComma = true
            }

            if humanReadable {
                appendIndent(into: json)
            }

            if !append(value, into: json) {
                return false
            }
        }

        depth -= 1
        if humanReadable && fragment.count > 0 {
            appendIndent(into: json)
        }
        json.append("]")
        return true
    }

    private func append(dictionary fragment: NSDictionary, into json: NSMutableString) -> Bool {
        if !descend() {
            return false
        }
        json.append("{")

        let colon = humanReadable ? " : " : ":"
        var addComma = false
        var keys = fragment.allKeys
        if sortKeys {
            keys = (keys as NSArray).sortedArray(using: NSSelectorFromString("compare:"))
        }

        for key in keys {
            if addComma {
                json.append(",")
            } else {
                addComma = true
            }

            if humanReadable {
                appendIndent(into: json)
            }

            let keyObject = key as AnyObject
            if !Self.isKind(keyObject, of: NSString.self) {
                addError(code: Self.unsupported, description: "JSON object key must be string")
                return false
            }

            if !append(string: unsafeDowncast(keyObject, to: NSString.self), into: json) {
                return false
            }

            json.append(colon)
            if !append(fragment.object(forKey: key), into: json) {
                addError(code: Self.unsupported, description: "Unsupported value for key \(keyObject) in object")
                return false
            }
        }

        depth -= 1
        if humanReadable && fragment.count > 0 {
            appendIndent(into: json)
        }
        json.append("}")
        return true
    }

    private func append(string fragment: NSString, into json: NSMutableString) -> Bool {
        json.append("\"")

        if fragment.rangeOfCharacter(from: Self.escapeCharacters).length == 0 {
            // No special chars -- can just add the raw string:
            CFStringAppend(json as CFMutableString, fragment as CFString)
        } else {
            for i in 0..<fragment.length {
                var uc = fragment.character(at: i)
                switch uc {
                case 0x22: json.append("\\\"")
                case 0x5C: json.append("\\\\")
                case 0x09: json.append("\\t")
                case 0x0A: json.append("\\n")
                case 0x0D: json.append("\\r")
                case 0x08: json.append("\\b")
                case 0x0C: json.append("\\f")
                default:
                    if uc < 0x20 {
                        json.append(String(format: "\\u%04x", UInt32(uc)))
                    } else {
                        CFStringAppendCharacters(json as CFMutableString, &uc, 1)
                    }
                }
            }
        }

        json.append("\"")
        return true
    }
}
