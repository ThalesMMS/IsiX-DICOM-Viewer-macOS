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
import ObjectiveC

// Selectors the plug-in SDK of Horos and OsiriX added to classes of Foundation
// and that the application itself no longer sends. A plug-in built for that
// SDK sends them without being rebuilt, from any thread.

extension NSString {
    /// The date `interval` seconds after the reference date, as «le 31.12.2020 à 23h59».
    @objc(dateString:) class func legacyDateString(_ interval: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "'le' dd.MM.yyyy 'à' HH'h'mm"
        return formatter.string(from: Date(timeIntervalSinceReferenceDate: interval))
    }

    /// The string with its line feeds, carriage returns and tabs written as \n, \r and \t.
    @objc(markedString) func legacyMarkedString() -> String {
        replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t")
    }

    /// The string with the reserved characters of a URL percent-escaped, and
    /// nothing else: a % already there stays as it is.
    @objc(urlEncodedString) func legacyURLEncodedString() -> String {
        let escapes: [(String, String)] = [(";", "%3B"), ("/", "%2F"), ("?", "%3F"), (":", "%3A"), ("@", "%40"), ("&", "%26"), ("=", "%3D"),
                                           ("+", "%2B"), ("$", "%24"), (",", "%2C"), ("[", "%5B"), ("]", "%5D"), ("#", "%23"), ("!", "%21"),
                                           ("'", "%27"), ("(", "%28"), (")", "%29"), ("*", "%2A")]
        var encoded = self as String
        for (character, escape) in escapes {
            encoded = encoded.replacingOccurrences(of: character, with: escape, options: .literal)
        }
        return encoded
    }

    @objc(xmlUnescapedString) func legacyXMLUnescapedString() -> NSString { xmlEscapedString(true) }
}

/// A mutable copy of an array or a dictionary whose arrays and dictionaries,
/// at any depth, are mutable copies too; any other object is copied.
private func deepMutableCopy(_ object: Any) -> AnyObject {
    switch object {
    case let array as [Any]:
        return NSMutableArray(array: array.map { deepMutableCopy($0) })
    case let dictionary as [AnyHashable: Any]:
        let copy = NSMutableDictionary(capacity: dictionary.count)
        for (key, value) in dictionary { copy[key] = deepMutableCopy(value) }
        return copy
    case let copying as NSCopying:
        return copying.copy(with: nil) as AnyObject
    default:
        return object as AnyObject
    }
}

extension NSArray {
    /// The caller owns the copy, as it did: the method of the SDK answered a
    /// retained object though its name is not one of a copy.
    @objc(deepMutableCopy) func legacyDeepMutableCopy() -> Unmanaged<AnyObject> { .passRetained(deepMutableCopy(self)) }
}

extension NSDictionary {
    @objc(deepMutableCopy) func legacyDeepMutableCopy() -> Unmanaged<AnyObject> { .passRetained(deepMutableCopy(self)) }

    /// The object of `key`, which must be of the class `expected`: another raises, as it did.
    @objc(objectForKey:ofClass:) func legacyObject(forKey key: Any, ofClass expected: AnyClass) -> Any? {
        guard let object = object(forKey: key) else { return nil }
        if !(object as AnyObject).isKind(of: expected) {
            NSException(name: .genericException, reason: "\(NSStringFromClass(expected)) expected, actually \(type(of: object as AnyObject))", userInfo: nil).raise()
        }
        return object
    }
}

extension NSMutableDictionary {
    /// Removes every key whose object is `object` itself.
    @objc(removeObject:) func legacyRemoveObject(_ object: AnyObject?) {
        while let key = key(forObject: object) { removeObject(forKey: key) }
    }

    @objc(setBool:forKey:) func legacySetBool(_ value: Bool, forKey key: String) { self[key] = NSNumber(value: value) }
}

extension NSObject {
    /// JRSwizzle: exchanges the implementations of two instance methods of
    /// the class, each first given to the class itself when it inherits it,
    /// so that the exchange does not reach the superclass.
    @objc(jr_swizzleMethod:withMethod:error:) class func legacySwizzleMethod(_ original: Selector, withMethod alternate: Selector, error: NSErrorPointer) -> Bool {
        swizzle(self, original, alternate, error)
    }

    /// The same for two class methods.
    @objc(jr_swizzleClassMethod:withClassMethod:error:) class func legacySwizzleClassMethod(_ original: Selector, withClassMethod alternate: Selector, error: NSErrorPointer) -> Bool {
        guard let metaclass = object_getClass(self) else { return false }
        return swizzle(metaclass, original, alternate, error)
    }

    private class func swizzle(_ target: AnyClass, _ original: Selector, _ alternate: Selector, _ error: NSErrorPointer) -> Bool {
        func fail(_ which: String, _ selector: Selector) -> Bool {
            error?.pointee = NSError(domain: "NSCocoaErrorDomain", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "+[NSObject(JRSwizzle) jr_swizzleMethod:withMethod:error:]: \(which) method \(NSStringFromSelector(selector)) not found for class \(NSStringFromClass(self))"])
            return false
        }
        guard let originalMethod = class_getInstanceMethod(target, original) else { return fail("original", original) }
        guard let alternateMethod = class_getInstanceMethod(target, alternate) else { return fail("alternate", alternate) }
        class_addMethod(target, original, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod))
        class_addMethod(target, alternate, method_getImplementation(alternateMethod), method_getTypeEncoding(alternateMethod))
        guard let first = class_getInstanceMethod(target, original), let second = class_getInstanceMethod(target, alternate) else { return false }
        method_exchangeImplementations(first, second)
        return true
    }
}
