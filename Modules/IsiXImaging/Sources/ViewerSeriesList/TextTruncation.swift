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

/// The truncation of a text to a length with an ellipsis, as the series list
/// and the series menu shorten the comments of the studies. Lengths count
/// UTF-16 units, as NSString does, and the arithmetic is the unsigned one of
/// the former Objective-C: a length too short for the ellipsis gives an
/// index out of range, and NSString raises its NSRangeException.
public enum TextTruncation {
    /// Where the text is cut.
    public enum Direction: UInt32 {
        /// The ellipsis replaces the end of the first `length` units.
        case start = 0
        /// The ellipsis joins the first and the last halves.
        case middle = 1
        /// The ellipsis replaces the start of the last `length` units.
        case end = 2
    }

    /// `text` cut to `length` units with `ellipsis`; `text` itself when it is
    /// not longer than `length`; an empty text for a direction other than
    /// start, middle or end.
    public static func truncate(_ text: NSString, toLength length: UInt32, direction: UInt32, ellipsis: NSString) -> NSString {
        let result = text.mutableCopy() as! NSMutableString
        if UInt(result.length) <= UInt(length) {
            return text // no truncation
        }

        let charactersEachSide = UInt(length / 2)
        let ellipsisLength = UInt(ellipsis.length)

        switch Direction(rawValue: direction) {
        case .start:
            result.insert(ellipsis as String, at: index(UInt(length) &- ellipsisLength))
            return result.substring(to: Int(length)) as NSString
        case .middle:
            let first = result.substring(to: index(charactersEachSide &- ellipsisLength &+ 1))
            let last = result.substring(from: index(UInt(result.length) &- charactersEachSide))
            return ([first, last] as NSArray).componentsJoined(by: ellipsis as String) as NSString
        case .end:
            result.insert(ellipsis as String, at: index(UInt(result.length) &- UInt(length) &+ ellipsisLength))
            return result.substring(from: index(UInt(result.length) &- UInt(length))) as NSString
        case nil:
            return ""
        }
    }

    /// The NSUInteger `value` as the Int an NSString index takes (a value
    /// that wrapped around stays out of range).
    private static func index(_ value: UInt) -> Int {
        Int(bitPattern: value)
    }
}
