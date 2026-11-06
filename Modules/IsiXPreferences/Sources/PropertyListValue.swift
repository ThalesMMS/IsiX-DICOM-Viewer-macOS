//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreFoundation
import Foundation

/// One value of a property list, as the preferences store it, with its kind
/// kept: a Boolean stays a Boolean, an integer an integer and a number written
/// as text stays text. A node read and written back through these values is
/// stored exactly as it was.
public enum PropertyListValue: Sendable, Hashable {
    case string(String)
    case integer(Int)
    case real(Double)
    case boolean(Bool)
    case date(Date)
    case data(Data)
    case array([PropertyListValue])
    case dictionary([String: PropertyListValue])

    /// The value of a property-list object, as Foundation hands it out; nil for
    /// an object a property list cannot hold, or a dictionary with a key that
    /// is not text.
    public init?(_ object: Any) {
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .boolean(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .real(number.doubleValue)
            } else {
                self = .integer(number.intValue)
            }
        } else if let text = object as? String {
            self = .string(text)
        } else if let date = object as? Date {
            self = .date(date)
        } else if let data = object as? Data {
            self = .data(data)
        } else if let list = object as? [Any] {
            var values: [PropertyListValue] = []
            values.reserveCapacity(list.count)
            for element in list {
                guard let value = PropertyListValue(element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        } else if let entry = object as? [String: Any] {
            guard let values = PropertyListValue.dictionary(entry) else { return nil }
            self = .dictionary(values)
        } else {
            return nil
        }
    }

    /// The values of a dictionary of property-list objects; nil when one of
    /// them is not a property-list value.
    public static func dictionary(_ entry: [String: Any]) -> [String: PropertyListValue]? {
        var values: [String: PropertyListValue] = [:]
        values.reserveCapacity(entry.count)
        for (key, object) in entry {
            guard let value = PropertyListValue(object) else { return nil }
            values[key] = value
        }
        return values
    }

    /// The Foundation object the preferences store for this value.
    public var object: Any {
        switch self {
        case .string(let text): return text
        case .integer(let number): return number
        case .real(let number): return number
        case .boolean(let flag): return flag
        case .date(let date): return date
        case .data(let data): return data
        case .array(let values): return values.map(\.object)
        case .dictionary(let values): return values.mapValues(\.object)
        }
    }

    /// The value as `-boolValue` of a number or of a string read it: text that
    /// starts with Y, y, T, t or a non-zero digit is true; anything else, false.
    public var boolValue: Bool {
        switch self {
        case .boolean(let flag): return flag
        case .integer(let number): return number != 0
        case .real(let number): return number != 0
        case .string(let text): return (text as NSString).boolValue
        default: return false
        }
    }

    /// The value as `-integerValue` of a number or of a string read it: the
    /// leading integer of text, 0 when there is none.
    public var intValue: Int {
        switch self {
        case .boolean(let flag): return flag ? 1 : 0
        case .integer(let number): return number
        case .real(let number): return NSNumber(value: number).intValue
        case .string(let text): return (text as NSString).integerValue
        default: return 0
        }
    }

    /// The text of a string value; nil for every other kind.
    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// Whether the value is a number, Boolean included, as NSNumber holds one.
    public var isNumber: Bool {
        switch self {
        case .boolean, .integer, .real: return true
        default: return false
        }
    }

    /// The value as `%@` prints it: text as it is, a number as NSNumber
    /// describes it (a Boolean as 1 or 0).
    public var text: String {
        switch self {
        case .string(let text): return text
        case .boolean(let flag): return flag ? "1" : "0"
        case .integer(let number): return String(number)
        case .real(let number): return NSNumber(value: number).description
        default: return String(describing: object as AnyObject)
        }
    }
}

/// Encoded as the property-list value itself, with no tag: a node encoded with
/// PropertyListEncoder is the dictionary the preferences hold. Decoding tries
/// the kinds in an order that keeps each one through a property list; a real
/// number with no fraction comes back as an integer, which no node stores.
extension PropertyListValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .boolean(flag)
        } else if let number = try? container.decode(Int.self) {
            self = .integer(number)
        } else if let number = try? container.decode(Double.self) {
            self = .real(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let date = try? container.decode(Date.self) {
            self = .date(date)
        } else if let data = try? container.decode(Data.self) {
            self = .data(data)
        } else if let values = try? container.decode([PropertyListValue].self) {
            self = .array(values)
        } else {
            self = .dictionary(try container.decode([String: PropertyListValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text): try container.encode(text)
        case .integer(let number): try container.encode(number)
        case .real(let number): try container.encode(number)
        case .boolean(let flag): try container.encode(flag)
        case .date(let date): try container.encode(date)
        case .data(let data): try container.encode(data)
        case .array(let values): try container.encode(values)
        case .dictionary(let values): try container.encode(values)
        }
    }
}
