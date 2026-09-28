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

// NSObject (NSObject_SBJSON) is implemented in Swift since #710; the selectors
// and <Horos/NSObject+SBJSON.h> are those of the category the vendored SBJson
// framework added. The vendored parser and writer classes left the repository
// with it.
//
// The web portal sends [x JSONRepresentation] to browsers, so the output keeps
// the bytes SBJsonWriter wrote with its defaults. JSONSerialization cannot give
// them: it escapes '/', writes numbers its own way and raises on NaN, where
// SBJsonWriter wrote -[NSNumber stringValue]. SBJsonCompatibleWriter below
// follows SBJsonWriter.m rule by rule.

public extension NSObject {

    /// A string containing the receiver encoded as a JSON fragment: an
    /// NSDictionary, NSArray, NSString, NSNumber (also used for booleans) or
    /// NSNull. Nil, and a log line, when the receiver cannot be written.
    @objc(JSONFragment)
    func jsonFragment() -> NSString? {
        let writer = SBJsonCompatibleWriter()
        let json = writer.string(withFragment: self)
        if json == nil {
            NSLog("-JSONFragment failed. Error trace is: %@", writer.errorTraceDescription)
        }
        return json
    }

    /// A string containing the receiver encoded in JSON; only an NSDictionary
    /// or an NSArray is. Nil, and a log line, otherwise.
    @objc(JSONRepresentation)
    func jsonRepresentation() -> NSString? {
        let writer = SBJsonCompatibleWriter()
        let json = writer.string(withObject: self)
        if json == nil {
            NSLog("-JSONRepresentation failed. Error trace is: %@", writer.errorTraceDescription)
        }
        return json
    }
}

/// SBJsonWriter with its defaults: no whitespace, keys in the order
/// -[NSDictionary allKeys] gives them (not sorted), a nesting limit of 512.
/// It works on the Objective-C objects themselves, in UTF-16, so that nothing
/// is reordered or transcoded on the way.
fileprivate final class SBJsonCompatibleWriter {

    /// SBJSONErrorDomain and the error codes of the former SBJsonBase.h.
    private static let errorDomain = "org.brautaset.JSON.ErrorDomain"
    private static let unsupported = 1 // EUNSUPPORTED
    private static let fragment = 4    // EFRAGMENT
    private static let tooDeep = 7     // EDEPTH

    private static let maxDepth = 512

    private static let escapeCharacters: CharacterSet = {
        var characters = CharacterSet(charactersIn: Unicode.Scalar(UInt8(0))...Unicode.Scalar(UInt8(31)))
        characters.insert(charactersIn: "\"\\")
        return characters
    }()

    private var depth = 0
    private var errorTrace: NSMutableArray?

    /// What SBJsonWriter's -errorTrace printed in the log line of a failure.
    var errorTraceDescription: NSObject {
        errorTrace ?? ("(null)" as NSString)
    }

    private func addError(code: Int, description: String) {
        let userInfo: [String: Any]
        if let trace = errorTrace, let last = trace.lastObject {
            userInfo = [NSLocalizedDescriptionKey: description, NSUnderlyingErrorKey: last]
        } else {
            errorTrace = NSMutableArray()
            userInfo = [NSLocalizedDescriptionKey: description]
        }
        errorTrace?.add(NSError(domain: Self.errorDomain, code: code, userInfo: userInfo))
    }

    private func clearErrorTrace() {
        errorTrace = nil
    }

    private static func isKind(_ object: AnyObject?, of type: AnyClass) -> Bool {
        (object as? NSObjectProtocol)?.isKind(of: type) ?? false
    }

    /// -stringWithFragment: of SBJsonWriter.
    func string(withFragment value: Any?) -> NSString? {
        clearErrorTrace()
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
        clearErrorTrace()
        addError(code: Self.fragment, description: "Not valid type for JSON")
        return nil
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
        depth += 1
        if depth > Self.maxDepth {
            addError(code: Self.tooDeep, description: "Nested too deep")
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

            if !append(value, into: json) {
                return false
            }
        }

        depth -= 1
        json.append("]")
        return true
    }

    private func append(dictionary fragment: NSDictionary, into json: NSMutableString) -> Bool {
        depth += 1
        if depth > Self.maxDepth {
            addError(code: Self.tooDeep, description: "Nested too deep")
            return false
        }
        json.append("{")

        var addComma = false
        for key in fragment.allKeys {
            if addComma {
                json.append(",")
            } else {
                addComma = true
            }

            let keyObject = key as AnyObject
            if !Self.isKind(keyObject, of: NSString.self) {
                addError(code: Self.unsupported, description: "JSON object key must be string")
                return false
            }

            if !append(string: unsafeDowncast(keyObject, to: NSString.self), into: json) {
                return false
            }

            json.append(":")
            if !append(fragment.object(forKey: key), into: json) {
                addError(code: Self.unsupported, description: "Unsupported value for key \(keyObject) in object")
                return false
            }
        }

        depth -= 1
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
