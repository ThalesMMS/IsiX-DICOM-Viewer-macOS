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

/// A type a preference is read as. The conversion from what the store holds is
/// the one of the UserDefaults accessor of that type, so a key read through the
/// catalog gives what `bool(forKey:)`, `integer(forKey:)`, `float(forKey:)`,
/// `double(forKey:)`, `string(forKey:)`, `stringArray(forKey:)`,
/// `array(forKey:)`, `dictionary(forKey:)` or `data(forKey:)` gave: a switch
/// stored as the text "1" is on, "120" is the integer 120, and a key with no
/// value is false, 0 or nil.
public protocol PreferenceValue: Hashable, Sendable {
    /// The value of the property list `object`, nil when the key has none.
    static func reading(_ object: Any?) -> Self
    /// The property list written for the value; nil removes the key.
    var preferenceObject: Any? { get }
}

/// A value that is either there or not: read as an optional, the key's
/// absence being nil, as the UserDefaults accessors of objects read it.
public protocol PreferenceObject: Hashable, Sendable {
    /// The value of a property list that is there; nil when it is not of this type.
    static func reading(present object: Any) -> Self?
    /// The property list written for the value.
    var preferenceObject: Any { get }
    /// The value of an element of a list or a table; as `reading(present:)`
    /// unless the type reads its elements more strictly.
    static func reading(element object: Any) -> Self?
}

extension PreferenceObject {
    public static func reading(element object: Any) -> Self? {
        return reading(present: object)
    }
}

extension Bool: PreferenceValue {
    /// As `bool(forKey:)`: a number is true when not zero; text is true when it
    /// is "1", or "YES" or "true" in any case, and false otherwise ("2", " 1").
    public static func reading(_ object: Any?) -> Self {
        if let text = object as? String {
            return text == "1" || text.caseInsensitiveCompare("YES") == .orderedSame
                || text.caseInsensitiveCompare("true") == .orderedSame
        } else if let number = object as? NSNumber {
            return number.boolValue
        } else {
            return false
        }
    }

    public var preferenceObject: Any? { self as NSNumber }
}

extension Int: PreferenceValue {
    /// As `integer(forKey:)`: a number's integer part; text that is an integer
    /// from end to end after leading white space ("120", " -3"), limited to the
    /// 32-bit range; anything else is 0 ("3.5", "12abc").
    public static func reading(_ object: Any?) -> Self {
        if let text = object as? String {
            return Self.integer(parsing: text)
        } else if let number = object as? NSNumber {
            return number.intValue
        } else {
            return 0
        }
    }

    public var preferenceObject: Any? { self as NSNumber }

    static func integer(parsing text: String) -> Int {
        var scalars = Substring(text).unicodeScalars[...]
        while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
        var negative = false
        if let sign = scalars.first, sign == "+" || sign == "-" {
            negative = sign == "-"
            scalars.removeFirst()
        }
        guard !scalars.isEmpty else { return 0 }
        var magnitude: Int64 = 0
        let limit = Int64(Int32.max) + 1
        for scalar in scalars {
            guard ("0"..."9").contains(scalar) else { return 0 }
            magnitude = Swift.min(magnitude * 10 + Int64(scalar.value - 48), limit)
        }
        let value = negative ? -magnitude : magnitude
        return Int(Swift.min(Swift.max(value, Int64(Int32.min)), Int64(Int32.max)))
    }
}

extension Float: PreferenceValue {
    /// As `float(forKey:)`: a number's value; the leading number of text, as
    /// `floatValue` of the text reads it; anything else is 0.
    public static func reading(_ object: Any?) -> Self {
        if let text = object as? String {
            return (text as NSString).floatValue
        } else if let number = object as? NSNumber {
            return number.floatValue
        } else {
            return 0
        }
    }

    public var preferenceObject: Any? { self as NSNumber }
}

extension Double: PreferenceValue {
    /// As `double(forKey:)`: a number's value; the leading number of text, as
    /// `doubleValue` of the text reads it; anything else is 0.
    public static func reading(_ object: Any?) -> Self {
        if let text = object as? String {
            return (text as NSString).doubleValue
        } else if let number = object as? NSNumber {
            return number.doubleValue
        } else {
            return 0
        }
    }

    public var preferenceObject: Any? { self as NSNumber }
}

extension Optional: PreferenceValue where Wrapped: PreferenceObject {
    public static func reading(_ object: Any?) -> Self {
        return object.flatMap(Wrapped.reading(present:))
    }

    public var preferenceObject: Any? { self?.preferenceObject }
}

extension String: PreferenceObject {
    /// As `string(forKey:)`: text as it is, a number as its `stringValue`
    /// ("1" for true); anything else is not text.
    public static func reading(present object: Any) -> Self? {
        if let text = object as? String {
            return text
        } else if let number = object as? NSNumber {
            return number.stringValue
        } else {
            return nil
        }
    }

    public var preferenceObject: Any { self }

    /// As `stringArray(forKey:)`: an element is text, never a number.
    public static func reading(element object: Any) -> Self? {
        guard let text = object as? String else { return nil }
        return text
    }
}

extension Data: PreferenceObject {
    public static func reading(present object: Any) -> Self? {
        guard let data = object as? Data else { return nil }
        return data
    }

    public var preferenceObject: Any { self }
}

extension PropertyListValue: PreferenceObject {
    public static func reading(present object: Any) -> Self? {
        return PropertyListValue(object)
    }

    public var preferenceObject: Any { object }
}

/// A list: as `array(forKey:)` with `[PropertyListValue]`, as
/// `stringArray(forKey:)` with `[String]`, which is nil unless every element
/// is text.
extension Array: PreferenceObject where Element: PreferenceObject {
    public static func reading(present object: Any) -> Self? {
        guard let list = object as? [Any] else { return nil }
        var elements: [Element] = []
        elements.reserveCapacity(list.count)
        for item in list {
            guard let element = Element.reading(element: item) else { return nil }
            elements.append(element)
        }
        return elements
    }

    public var preferenceObject: Any { map(\.preferenceObject) }
}

/// A table by name: as `dictionary(forKey:)` with `[String: PropertyListValue]`.
extension Dictionary: PreferenceObject where Key == String, Value: PreferenceObject {
    public static func reading(present object: Any) -> Self? {
        guard let table = object as? [String: Any] else { return nil }
        var values: [String: Value] = [:]
        values.reserveCapacity(table.count)
        for (key, item) in table {
            guard let value = Value.reading(element: item) else { return nil }
            values[key] = value
        }
        return values
    }

    public var preferenceObject: Any { mapValues(\.preferenceObject) }
}
