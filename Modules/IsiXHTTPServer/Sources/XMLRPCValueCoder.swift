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

import CoreFoundation
import Foundation

/// A value or document that XML-RPC cannot carry, or that is not XML-RPC: the
/// name and reason of the NSException the former Objective-C coder raised, so
/// the app can still raise it for its Objective-C callers and the server can
/// still answer it as the reason of a fault.
public struct XMLRPCCodingError: Error, Equatable, Sendable {
    public let name: String
    public let reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }

    static func generic(_ reason: String) -> XMLRPCCodingError {
        XMLRPCCodingError(name: NSExceptionName.genericException.rawValue, reason: reason)
    }

    static func invalidArgument(_ reason: String) -> XMLRPCCodingError {
        XMLRPCCodingError(name: NSExceptionName.invalidArgumentException.rawValue, reason: reason)
    }

    static func range(_ reason: String) -> XMLRPCCodingError {
        XMLRPCCodingError(name: NSExceptionName.rangeException.rawValue, reason: reason)
    }
}

/// How values are written.
public struct XMLRPCFormatOptions: OptionSet, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// A string goes out as bare text in its value, without `<string>`, which
    /// the XML-RPC interface's clients have always received.
    public static let dontSpecifyStringType = XMLRPCFormatOptions(rawValue: 1 << 0)
}

/// Converts between XML-RPC values and Foundation objects: what the XML-RPC
/// interface reads from a request and writes in its answer, and what the
/// web-service client sends and reads.
///
/// What it writes is what goes on the wire: the strings are built in UTF-16,
/// as NSStrings, so that nothing is transcoded on the way, and a struct's
/// members are written in the order NSDictionary enumerates them.
public enum XMLRPCValueCoder {

    // MARK: Parsing

    /// The Foundation value of an XML-RPC element (`<value>`, or the element
    /// inside it), or nil for `<nil/>`. A text node is its string.
    public static func parse(_ n: XMLNode?) throws -> NSObject? {
        if n?.kind == .text {
            return n?.stringValue as NSString?
        }

        let name = n?.name

        if name == "array" {
            let values = (try? n?.nodes(forXPath: "data/value")) ?? []
            let returnValues = NSMutableArray(capacity: values.count)
            for value in values {
                returnValues.add(try nonNil(parse(value), inserting: "-[__NSArrayM insertObject:atIndex:]"))
            }
            return returnValues.copy() as! NSArray
        }

        if name == "base64" {
            return XMLRPCBase64.decode(n?.child(at: 0)?.stringValue as NSString?)
        }

        if name == "boolean" {
            return NSNumber(value: (n?.stringValue as NSString?)?.boolValue ?? false)
        }

        if name == "dateTime.iso8601" {
            return XMLRPCDate.date(from: n?.stringValue) as NSDate
        }

        if name == "double" {
            return NSNumber(value: (n?.stringValue as NSString?)?.doubleValue ?? 0)
        }

        if name == "i4" || name == "int" {
            return NSNumber(value: (n?.stringValue as NSString?)?.intValue ?? 0)
        }

        if name == "string" {
            // NSXMLDocument already decoded entities. A second pass corrupts
            // literal strings such as "&amp;" received from standard clients.
            return n?.stringValue as NSString?
        }

        if name == "struct" {
            let members = (try? n?.nodes(forXPath: "member")) ?? []
            let returnMembers = NSMutableDictionary(capacity: members.count)
            for m in members {
                // The value is read before the name, as the Objective-C
                // evaluated the arguments of -setObject:forKey:.
                let value = try parse(firstNode(m, "value"))
                let key = try firstNode(m, "name").stringValue
                guard let key else {
                    throw XMLRPCCodingError.invalidArgument("*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil")
                }
                guard let value else {
                    throw XMLRPCCodingError.invalidArgument("*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: \(key))")
                }
                returnMembers.setObject(value, forKey: key as NSString)
            }
            return returnMembers.copy() as! NSDictionary
        }

        if name == "nil" {
            return nil
        }

        if name == "value" {
            if let n, n.childCount > 0 {
                return try parse(n.child(at: 0))
            }
            return n?.stringValue as NSString?
        }

        throw XMLRPCCodingError.generic("unhandled XMLRPC data type: \(name ?? "(null)")")
    }

    // MARK: Formatting

    /// The XML-RPC element of a Foundation value: a dictionary, string, array,
    /// date, data, number or nil.
    public static func format(_ o: Any?, options: XMLRPCFormatOptions = []) throws -> NSString {
        guard let o else {
            return "<nil/>"
        }
        let object = o as AnyObject

        if isKind(object, of: NSDictionary.self) {
            let s = NSMutableString(capacity: 512)
            s.append("<struct>")
            for (k, v) in unsafeDowncast(object, to: NSDictionary.self) {
                s.append("<member><name>")
                s.append(try escapedKey(k) as String)
                s.append("</name><value>")
                s.append(try format(v, options: options) as String)
                s.append("</value></member>")
            }
            s.append("</struct>")
            return NSString(string: s)
        }

        if isKind(object, of: NSString.self) {
            let escaped = XMLRPCEscaping.escaped(unsafeDowncast(object, to: NSString.self))
            if options.contains(.dontSpecifyStringType) {
                return escaped
            }
            return NSString(format: "<string>%@</string>", escaped)
        }

        if isKind(object, of: NSArray.self) {
            let s = NSMutableString(capacity: 512)
            s.append("<array><data>")
            for o2 in unsafeDowncast(object, to: NSArray.self) {
                s.append("<value>")
                s.append(try format(o2, options: options) as String)
                s.append("</value>")
            }
            s.append("</data></array>")
            return NSString(string: s)
        }

        if isKind(object, of: NSDate.self) {
            return NSString(format: "<dateTime.iso8601>%@</dateTime.iso8601>",
                            XMLRPCDate.string(from: unsafeDowncast(object, to: NSDate.self) as Date))
        }

        if isKind(object, of: NSData.self) {
            return NSString(format: "<base64>%@</base64>", XMLRPCBase64.encode(unsafeDowncast(object, to: NSData.self)))
        }

        if isKind(object, of: NSNumber.self) {
            let number = unsafeDowncast(object, to: NSNumber.self)
            let type = CFNumberGetType(number as CFNumber)
            switch type {
            case .charType:
                return NSString(format: "<boolean>%d</boolean>", Int32(number.boolValue ? 1 : 0))
            case .sInt8Type, .sInt16Type, .sInt32Type, .sInt64Type, .shortType, .intType, .longType,
                 .longLongType, .cfIndexType, .nsIntegerType:
                return NSString(format: "<int>%d</int>", number.int32Value)
            case .floatType, .float32Type, .float64Type, .doubleType, .cgFloatType:
                return NSString(format: "<double>%f</double>", number.doubleValue)
            default:
                throw XMLRPCCodingError.generic("execution succeeded but return NSNumber of type \(Int32(type.rawValue)) unsupported")
            }
        }

        throw XMLRPCCodingError.generic("execution succeeded but return class \(className(of: object)) unsupported")
    }

    // MARK: Messages

    /// A `methodCall` document; a nil name is written "(null)", as before.
    public static func request(methodName: NSString?, arguments args: [Any]?) throws -> NSString {
        let escapedName: NSString = methodName.map { XMLRPCEscaping.escaped($0) } ?? "(null)"
        let request = NSMutableString(format: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><methodCall><methodName>%@</methodName><params>", escapedName)
        for arg in args ?? [] {
            request.appendFormat("<param><value>%@</value></param>", try format(arg))
        }
        request.append("</params></methodCall>")
        return request
    }

    /// A `methodResponse` document carrying `value`.
    public static func response(value: Any?, options: XMLRPCFormatOptions = []) throws -> NSString {
        NSString(format: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><methodResponse><params><param><value>%@</value></param></params></methodResponse>",
                 try format(value, options: options))
    }

    // MARK: Helpers

    private static func isKind(_ object: AnyObject, of type: AnyClass) -> Bool {
        (object as? NSObjectProtocol)?.isKind(of: type) ?? false
    }

    private static func className(of object: AnyObject) -> String {
        (object as? NSObject)?.className ?? NSStringFromClass(type(of: object))
    }

    /// A member name, escaped as a string is. The former coder sent
    /// -xmlEscapedString to the key, which a key that is not a string does not
    /// answer: the call failed there, with the runtime's reason.
    private static func escapedKey(_ key: Any) throws -> NSString {
        let object = key as AnyObject
        guard isKind(object, of: NSString.self) else {
            let address = String(format: "%p", unsafeBitCast(object, to: Int.self))
            throw XMLRPCCodingError.invalidArgument("-[\(className(of: object)) xmlEscapedString]: unrecognized selector sent to instance \(address)")
        }
        return XMLRPCEscaping.escaped(unsafeDowncast(object, to: NSString.self))
    }

    /// The first node of an XPath, where the Objective-C sent -objectAtIndex:0
    /// to the result and so failed with NSRangeException when there was none.
    private static func firstNode(_ node: XMLNode, _ xpath: String) throws -> XMLNode {
        guard let first = (try? node.nodes(forXPath: xpath))?.first else {
            throw XMLRPCCodingError.range("*** -[__NSArray0 objectAtIndex:]: index 0 beyond bounds for empty array")
        }
        return first
    }

    private static func nonNil(_ object: NSObject?, inserting method: String) throws -> NSObject {
        guard let object else {
            throw XMLRPCCodingError.invalidArgument("*** \(method): object cannot be nil")
        }
        return object
    }
}

/// The escaping of text in XML-RPC documents: `&` first, then `<`, `>`, `'`
/// and `"`, on the UTF-16 of the string, so that nothing else in it changes.
public enum XMLRPCEscaping {
    private static let escapes: [(String, String)] = [
        ("&", "&amp;"),
        ("<", "&lt;"),
        (">", "&gt;"),
        ("'", "&#39;"),
        ("\"", "&quot;"),
    ]

    public static func escaped(_ string: NSString) -> NSString {
        let temp = string.mutableCopy() as! NSMutableString
        for (character, entity) in escapes {
            temp.replaceOccurrences(of: character, with: entity, options: .literal,
                                    range: NSRange(location: 0, length: temp.length))
        }
        return NSString(string: temp)
    }
}

/// `<base64>` values. Written without line breaks; read leniently, as the
/// former NSData category read them: white space and `=` are skipped anywhere,
/// and any other character outside the alphabet makes the value unreadable.
public enum XMLRPCBase64 {
    private static let encodingTable: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    /// 0xFF for a character that is not in the table.
    private static let decodingTable: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (index, character) in encodingTable.enumerated() {
            table[Int(character)] = UInt8(index)
        }
        return table
    }()

    public static func encode(_ data: NSData) -> NSString {
        let source = [UInt8](data as Data)
        var characters: [UInt8] = []
        characters.reserveCapacity(((source.count + 2) / 3) * 4)
        var i = 0
        while i < source.count {
            let count = min(3, source.count - i)
            let b0 = source[i], b1 = count > 1 ? source[i + 1] : 0, b2 = count > 2 ? source[i + 2] : 0
            characters.append(encodingTable[Int((b0 & 0xFC) >> 2)])
            characters.append(encodingTable[Int(((b0 & 0x03) << 4) | ((b1 & 0xF0) >> 4))])
            characters.append(count > 1 ? encodingTable[Int(((b1 & 0x0F) << 2) | ((b2 & 0xC0) >> 6))] : 0x3D)
            characters.append(count > 2 ? encodingTable[Int(b2 & 0x3F)] : 0x3D)
            i += count
        }
        return NSString(bytes: characters, length: characters.count, encoding: String.Encoding.ascii.rawValue) ?? ""
    }

    /// The bytes of `base64`: empty for an empty string; nil for nil, for a
    /// string that is not ASCII, that holds a character outside the alphabet,
    /// or that leaves a single character for its last byte.
    public static func decode(_ base64: NSString?) -> NSData? {
        guard let base64 else { return nil }
        guard base64.length != 0 else { return NSData() }
        guard let ascii = base64.cString(using: String.Encoding.ascii.rawValue) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(((base64.length + 3) / 4) * 3)
        var quad: [UInt8] = []
        // The C string ends at its first NUL, as the former reader's did.
        for character in UnsafeBufferPointer(start: ascii, count: strlen(ascii)) {
            let byte = UInt8(bitPattern: character)
            if isspace(Int32(character)) != 0 || byte == 0x3D { // '='
                continue
            }
            let decoded = decodingTable[Int(byte)]
            if decoded == 0xFF { // a character outside the alphabet
                return nil
            }
            quad.append(decoded)
            if quad.count == 4 {
                append(quad, to: &bytes)
                quad.removeAll(keepingCapacity: true)
            }
        }
        if quad.count == 1 { // at least two characters are needed to produce one byte
            return nil
        }
        if !quad.isEmpty {
            append(quad, to: &bytes)
        }
        return NSData(bytes: bytes, length: bytes.count)
    }

    private static func append(_ quad: [UInt8], to bytes: inout [UInt8]) {
        bytes.append((quad[0] << 2) | (quad[1] >> 4))
        if quad.count > 2 {
            bytes.append((quad[1] << 4) | (quad[2] >> 2))
        }
        if quad.count > 3 {
            bytes.append((quad[2] << 6) | quad[3])
        }
    }
}

/// `<dateTime.iso8601>` values.
///
/// The vendored ISO8601DateFormatter (Peter Hosey) wrote and read these before
/// the Swift migration; Foundation's ISO8601DateFormatter does now, configured
/// to give the same results.
public enum XMLRPCDate {
    /// The vendored formatter's defaults: the calendar date only, yyyy-MM-dd,
    /// in the default time zone.
    public static func string(from date: Date) -> NSString {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = NSTimeZone.default
        return formatter.string(from: date) as NSString
    }

    /// The layouts tried in turn, the most complete first: Foundation's
    /// formatter reads a prefix of the string, so a shorter layout would take a
    /// longer string and drop its time.
    private static let readingLayouts: [ISO8601DateFormatter.Options] = [
        [.withInternetDateTime, .withFractionalSeconds],                 // 2026-09-26T12:34:56.789Z
        [.withInternetDateTime],                                         // 2026-09-26T12:34:56+02:00, +0200, Z
        [.withFullDate, .withSpaceBetweenDateAndTime, .withFullTime],    // 2026-09-26 12:34:56Z
        [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime, .withTimeZone], // 20260926T12:34:56Z
        [.withFullDate, .withTime, .withColonSeparatorInTime],           // 2026-09-26T12:34:56, local time
        [.withFullDate, .withSpaceBetweenDateAndTime, .withTime, .withColonSeparatorInTime], // 2026-09-26 12:34:56
        [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime], // 20260926T12:34:56, XML-RPC's own
        [.withFullDate],                                                 // 2026-09-26, what the coder writes
        [.withYear, .withMonth, .withDashSeparatorInDate],               // 2026-09
        [.withYear, .withMonth, .withDay],                               // 20260926
    ]

    /// The vendored formatter's -dateFromString:, not strict: leading
    /// whitespace and what follows the date are ignored, a string without a
    /// time zone is in the default time zone, and seconds are whole (the
    /// vendored parser dropped a fraction).
    public static func date(from string: String?) -> Date {
        // Leading whitespace, as isspace() saw it on the UTF-8 bytes.
        let whole = (string ?? "") as NSString
        var start = 0
        while start < whole.length, (0x09...0x0D).contains(whole.character(at: start)) || whole.character(at: start) == 0x20 {
            start += 1
        }
        let trimmed = whole.substring(from: start)
        // Foundation's formatter reads odd dates out of words; the vendored
        // parser needed a digit here for any layout above.
        if let first = trimmed.utf16.first, (0x30...0x39).contains(first) {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = NSTimeZone.default
            for layout in readingLayouts {
                formatter.formatOptions = layout
                if let date = formatter.date(from: trimmed) {
                    return Date(timeIntervalSince1970: (date.timeIntervalSince1970).rounded(.down))
                }
            }
        }
        // For a string it could not read, the vendored formatter returned the
        // date of empty components, 1 January of year 1 in the default time
        // zone, never nil; the coder passed it on.
        let calendar = NSCalendar(calendarIdentifier: .gregorian)!
        calendar.firstWeekday = 2
        return calendar.date(from: DateComponents())!
    }
}
