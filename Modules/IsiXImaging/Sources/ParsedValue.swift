//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// An exception the Objective-C reading raised, carried out of Swift as an
/// error. The reading stops where it would have raised, and the caller raises
/// it again once the values read up to that point are in place, so a file that
/// made the old reading fail still fails the same way and leaves the same state.
public struct AttributeReadException: Error, Equatable, Sendable {
    public let name: String
    public let reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }

    static func unrecognizedSelector(_ selector: String, sentTo object: AnyObject) -> AttributeReadException {
        let address = UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())
        return AttributeReadException(
            name: NSExceptionName.invalidArgumentException.rawValue,
            reason: "-[\(NSStringFromClass(type(of: object))) \(selector)]: unrecognized selector sent to instance 0x\(String(address, radix: 16))")
    }

    static func beyondBounds(index: Int, count: Int) -> AttributeReadException {
        AttributeReadException(
            name: NSExceptionName.rangeException.rawValue,
            reason: count == 0
                ? "*** -[NSArray objectAtIndex:]: index \(UInt(bitPattern: index)) beyond bounds for empty array"
                : "*** -[NSArray objectAtIndex:]: index \(UInt(bitPattern: index)) beyond bounds [0 .. \(count - 1)]")
    }

    /// The same exception as an `NSException`, for Objective-C to raise or log.
    public var exception: NSException {
        NSException(name: NSExceptionName(name), reason: reason, userInfo: nil)
    }
}

/// A parsed value asked for something the way an Objective-C message asked it:
/// nil answers zero, nil or NO; a number or a string answers; anything else
/// does not understand the message and raises.
enum ParsedValue {
    static func object(_ value: Any?) -> AnyObject? {
        guard let value else { return nil }
        return value as AnyObject
    }

    static func float(_ value: Any?, _ selector: String = "floatValue") throws -> Float {
        guard let object = object(value) else { return 0 }
        if let number = object as? NSNumber { return number.floatValue }
        if let string = object as? NSString { return string.floatValue }
        throw AttributeReadException.unrecognizedSelector(selector, sentTo: object)
    }

    static func double(_ value: Any?) throws -> Double {
        guard let object = object(value) else { return 0 }
        if let number = object as? NSNumber { return number.doubleValue }
        if let string = object as? NSString { return string.doubleValue }
        throw AttributeReadException.unrecognizedSelector("doubleValue", sentTo: object)
    }

    static func int(_ value: Any?) throws -> Int32 {
        guard let object = object(value) else { return 0 }
        if let number = object as? NSNumber { return number.int32Value }
        if let string = object as? NSString { return string.intValue }
        throw AttributeReadException.unrecognizedSelector("intValue", sentTo: object)
    }

    static func isEqual(_ value: Any?, toString string: String) throws -> Bool {
        guard let object = object(value) else { return false }
        if let text = object as? NSString { return text.isEqual(to: string) }
        throw AttributeReadException.unrecognizedSelector("isEqualToString:", sentTo: object)
    }

    /// `-count` of a value that was declared an array.
    static func count(_ value: Any?) throws -> Int {
        guard let object = object(value) else { return 0 }
        if let array = object as? NSArray { return array.count }
        throw AttributeReadException.unrecognizedSelector("count", sentTo: object)
    }

    /// `-objectAtIndex:` of a value that was declared an array.
    static func element(_ index: Int, of value: Any?) throws -> Any? {
        guard let object = object(value) else { return nil }
        guard let array = object as? NSArray else {
            throw AttributeReadException.unrecognizedSelector("objectAtIndex:", sentTo: object)
        }
        guard index >= 0 && index < array.count else { throw AttributeReadException.beyondBounds(index: index, count: array.count) }
        return array.object(at: index)
    }

    /// `-characterAtIndex:0`.
    static func firstCharacter(_ value: Any?) throws -> Int32 {
        guard let object = object(value) else { return 0 }
        guard let string = object as? NSString else {
            throw AttributeReadException.unrecognizedSelector("characterAtIndex:", sentTo: object)
        }
        guard string.length > 0 else {
            // Foundation raises an invalid argument here, not a range exception.
            throw AttributeReadException(
                name: NSExceptionName.invalidArgumentException.rawValue,
                reason: "-[\(NSStringFromClass(type(of: string))) characterAtIndex:]: Range or index out of bounds")
        }
        return Int32(string.character(at: 0))
    }

    /// `-dateString` or `-timeString` of a DA or TM value. The parser's date
    /// class answers both; a value of another class raised.
    static func dicomString(_ selectorName: String, of value: Any?) throws -> String? {
        guard let object = object(value) else { return nil }
        let selector = NSSelectorFromString(selectorName)
        guard let target = object as? NSObject, target.responds(to: selector) else {
            throw AttributeReadException.unrecognizedSelector(selectorName, sentTo: object)
        }
        return target.perform(selector)?.takeUnretainedValue() as? String
    }

    /// A float converted to a C `long` the way arm64 converts it: truncated,
    /// saturated at the ends of the range, and zero for NaN, where Swift's own
    /// conversion would trap.
    static func cLong(_ value: Float) -> Int {
        if value.isNaN { return 0 }
        if value >= Float(Int.max) { return Int.max }
        if value <= Float(Int.min) { return Int.min }
        return Int(value)
    }
}
