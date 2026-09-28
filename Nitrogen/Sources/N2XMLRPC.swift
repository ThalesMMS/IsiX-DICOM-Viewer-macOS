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

/// Converts between XML-RPC values and Foundation objects.
///
/// Implemented in Swift since #710; the Objective-C name, the selectors and
/// `<Horos/N2XMLRPC.h>` are those of the former class. N2XMLRPCConnection (the
/// application's XML-RPC server), XMLRPCMethods and N2XMLRPCWebServiceClient
/// call it, so what it writes is what goes on the wire: the strings are built
/// in UTF-16, as NSStrings, so that nothing is transcoded on the way. A failure
/// raises the NSException the Objective-C raised, which those callers catch.
@objc(N2XMLRPC)
public final class N2XMLRPC: NSObject {

    // MARK: Parsing

    @objc(ParseElement:)
    public static func parseElement(_ n: XMLNode?) -> NSObject? {
        if n?.kind == .text {
            return n?.stringValue as NSString?
        }

        let name = n?.name

        if name == "array" {
            let values = (try? n?.nodes(forXPath: "data/value")) ?? []
            let returnValues = NSMutableArray(capacity: values.count)
            for value in values {
                returnValues.add(nonNil(parseElement(value), inserting: "-[__NSArrayM insertObject:atIndex:]"))
            }
            return returnValues.copy() as! NSArray
        }

        if name == "base64" {
            return dataWithBase64(n?.child(at: 0)?.stringValue as NSString?)
        }

        if name == "boolean" {
            return NSNumber(value: (n?.stringValue as NSString?)?.boolValue ?? false)
        }

        if name == "dateTime.iso8601" {
            return iso8601Date(from: n?.stringValue) as NSDate
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
                let value = parseElement(firstNode(m, "value"))
                let key = firstNode(m, "name").stringValue
                guard let key else {
                    raise(.invalidArgumentException, "*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil")
                }
                guard let value else {
                    raise(.invalidArgumentException, "*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: \(key))")
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
                return parseElement(n.child(at: 0))
            }
            return n?.stringValue as NSString?
        }

        raise(.genericException, "unhandled XMLRPC data type: \(name ?? "(null)")")
    }

    // MARK: Formatting

    @objc(FormatElement:options:)
    public static func formatElement(_ o: Any?, options: UInt) -> NSString {
        guard let o else {
            return "<nil/>"
        }
        let object = o as AnyObject

        if isKind(object, of: NSDictionary.self) {
            let s = NSMutableString(capacity: 512)
            s.append("<struct>")
            for (k, v) in unsafeDowncast(object, to: NSDictionary.self) {
                s.append("<member><name>")
                s.append((xmlEscapedString(k) ?? "(null)") as String)
                s.append("</name><value>")
                s.append(formatElement(v, options: options) as String)
                s.append("</value></member>")
            }
            s.append("</struct>")
            return NSString(string: s)
        }

        if isKind(object, of: NSString.self) {
            let escaped = xmlEscapedString(object) ?? "(null)"
            if options & UInt(N2XMLRPCDontSpecifyStringTypeOptionMask.rawValue) != 0 {
                return escaped
            }
            return NSString(format: "<string>%@</string>", escaped)
        }

        if isKind(object, of: NSArray.self) {
            let s = NSMutableString(capacity: 512)
            s.append("<array><data>")
            for o2 in unsafeDowncast(object, to: NSArray.self) {
                s.append("<value>")
                s.append(formatElement(o2, options: options) as String)
                s.append("</value>")
            }
            s.append("</data></array>")
            return NSString(string: s)
        }

        if isKind(object, of: NSDate.self) {
            return NSString(format: "<dateTime.iso8601>%@</dateTime.iso8601>",
                            iso8601String(from: unsafeDowncast(object, to: NSDate.self) as Date))
        }

        if isKind(object, of: NSData.self) {
            let base64 = unsafeDowncast(object, to: NSData.self).perform(NSSelectorFromString("base64"))?
                .takeUnretainedValue() as? NSString
            return NSString(format: "<base64>%@</base64>", base64 ?? "(null)")
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
                raise(.genericException, "execution succeeded but return NSNumber of type \(Int32(type.rawValue)) unsupported")
            }
        }

        let className = (object as? NSObject)?.className ?? NSStringFromClass(type(of: object))
        raise(.genericException, "execution succeeded but return class \(className) unsupported")
    }

    @objc(FormatElement:)
    public static func formatElement(_ o: Any?) -> NSString {
        formatElement(o, options: 0)
    }

    // MARK: Messages

    @objc(requestWithMethodName:arguments:)
    public static func request(withMethodName methodName: NSString?, arguments args: [Any]?) -> NSString {
        let escapedName: NSString = methodName.flatMap { xmlEscapedString($0) } ?? "(null)"
        let request = NSMutableString(format: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><methodCall><methodName>%@</methodName><params>", escapedName)
        for arg in args ?? [] {
            request.appendFormat("<param><value>%@</value></param>", formatElement(arg))
        }
        request.append("</params></methodCall>")
        return request
    }

    @objc(responseWithValue:)
    public static func response(withValue value: Any?) -> NSString {
        response(withValue: value, options: 0)
    }

    @objc(responseWithValue:options:)
    public static func response(withValue value: Any?, options: UInt) -> NSString {
        NSString(format: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><methodResponse><params><param><value>%@</value></param></params></methodResponse>",
                 formatElement(value, options: options))
    }

    // MARK: dateTime.iso8601

    // The vendored ISO8601DateFormatter (Peter Hosey) wrote and read these
    // until #710; Foundation's ISO8601DateFormatter does now, configured to
    // give the same results.

    /// The vendored formatter's defaults: the calendar date only, yyyy-MM-dd,
    /// in the default time zone.
    private static func iso8601String(from date: Date) -> NSString {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = NSTimeZone.default
        return formatter.string(from: date) as NSString
    }

    /// The layouts tried in turn, the most complete first: Foundation's
    /// formatter reads a prefix of the string, so a shorter layout would take a
    /// longer string and drop its time.
    private static let iso8601ReadingLayouts: [ISO8601DateFormatter.Options] = [
        [.withInternetDateTime, .withFractionalSeconds],                 // 2026-09-26T12:34:56.789Z
        [.withInternetDateTime],                                         // 2026-09-26T12:34:56+02:00, +0200, Z
        [.withFullDate, .withSpaceBetweenDateAndTime, .withFullTime],    // 2026-09-26 12:34:56Z
        [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime, .withTimeZone], // 20260926T12:34:56Z
        [.withFullDate, .withTime, .withColonSeparatorInTime],           // 2026-09-26T12:34:56, local time
        [.withFullDate, .withSpaceBetweenDateAndTime, .withTime, .withColonSeparatorInTime], // 2026-09-26 12:34:56
        [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime], // 20260926T12:34:56, XML-RPC's own
        [.withFullDate],                                                 // 2026-09-26, what N2XMLRPC writes
        [.withYear, .withMonth, .withDashSeparatorInDate],               // 2026-09
        [.withYear, .withMonth, .withDay],                               // 20260926
    ]

    /// The vendored formatter's -dateFromString:, not strict: leading
    /// whitespace and what follows the date are ignored, a string without a
    /// time zone is in the default time zone, and seconds are whole (the
    /// vendored parser dropped a fraction).
    private static func iso8601Date(from string: String?) -> Date {
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
            for layout in iso8601ReadingLayouts {
                formatter.formatOptions = layout
                if let date = formatter.date(from: trimmed) {
                    return Date(timeIntervalSince1970: (date.timeIntervalSince1970).rounded(.down))
                }
            }
        }
        // For a string it could not read, the vendored formatter returned the
        // date of empty components, 1 January of year 1 in the default time
        // zone, never nil; N2XMLRPC passed it on.
        let calendar = NSCalendar(calendarIdentifier: .gregorian)!
        calendar.firstWeekday = 2
        return calendar.date(from: DateComponents())!
    }

    // MARK: Helpers

    private static func isKind(_ object: AnyObject, of type: AnyClass) -> Bool {
        (object as? NSObjectProtocol)?.isKind(of: type) ?? false
    }

    /// -[NSString xmlEscapedString] of NSString+N2, sent by selector as the
    /// Objective-C did: a key that is not a string raises there, as before.
    private static func xmlEscapedString(_ string: Any) -> NSString? {
        (string as AnyObject).perform(NSSelectorFromString("xmlEscapedString"))?.takeUnretainedValue() as? NSString
    }

    /// +[NSData dataWithBase64:] of NSData+N2.
    private static func dataWithBase64(_ base64: NSString?) -> NSData? {
        (NSData.self as AnyObject).perform(NSSelectorFromString("dataWithBase64:"), with: base64)?
            .takeUnretainedValue() as? NSData
    }

    /// The first node of an XPath, where the Objective-C sent -objectAtIndex:0
    /// to the result and so raised NSRangeException when there was none.
    private static func firstNode(_ node: XMLNode, _ xpath: String) -> XMLNode {
        guard let first = (try? node.nodes(forXPath: xpath))?.first else {
            raise(.rangeException, "*** -[__NSArray0 objectAtIndex:]: index 0 beyond bounds for empty array")
        }
        return first
    }

    private static func nonNil(_ object: NSObject?, inserting method: String) -> NSObject {
        guard let object else {
            raise(.invalidArgumentException, "*** \(method): object cannot be nil")
        }
        return object
    }

    private static func raise(_ name: NSExceptionName, _ reason: String) -> Never {
        NSException(name: name, reason: reason, userInfo: nil).raise()
        fatalError(reason)
    }
}
