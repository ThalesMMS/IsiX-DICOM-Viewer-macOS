//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// Why an archive was not unarchived.
public enum RestrictedUnarchiverError: Error, CustomStringConvertible {
    /// The archive names a class outside the list its reader accepts.
    case disallowedClass(String)
    /// The data is not an NSArchiver typedstream this reader can walk, or
    /// NSUnarchiver raised while decoding it.
    case unreadable(String)

    public var description: String {
        switch self {
        case .disallowedClass(let name):
            return "the archive names the class \(name), which this archive does not hold"
        case .unreadable(let reason):
            return reason
        }
    }
}

/// Reads NSArchiver typedstreams - the ROI format of SRs, .roi and
/// .rois_series files and the ROI pasteboard, and the CLUT editor's pasteboard
/// types - without letting the archive choose which classes are instantiated.
///
/// NSUnarchiver has no secure coding and no hook before it resolves a class:
/// the archive names the classes, and each one's -initWithCoder: runs. So the
/// whole stream is walked first, as NSUnarchiver would read it, and every class
/// name in it - of objects, of their superclasses and of class values - must be
/// on the caller's list. Only then does NSUnarchiver decode it. The walk
/// follows the type string that precedes every value in the stream, and
/// NSUnarchiver raises when that string is not the type the decoder asks for,
/// so the two cannot read the bytes differently; anything the walk does not
/// understand is refused rather than skipped. The format itself is unchanged,
/// so the archives Horos and OsiriX have written stay readable.
@objc(HorosRestrictedUnarchiver)
public final class RestrictedUnarchiver: NSObject {

    /// An array of ROIs (an SR, a .roi file, the ROI pasteboard) or of arrays
    /// of them (a .rois_series file): the classes ROI and its subclass
    /// HorosVolumeLengthROI archive, MyPoint, and the Foundation and AppKit
    /// values they hold.
    @objc public static let roiClassNames: Set<String> = [
        "ROI", "HorosVolumeLengthROI", "MyPoint",
        "NSObject", "NSArray", "NSMutableArray", "NSDictionary", "NSMutableDictionary",
        "NSString", "NSMutableString", "NSNumber", "NSValue", "NSData", "NSMutableData", "NSColor",
    ]

    /// A curve of the CLUT and opacity editor: a dictionary of its points
    /// (NSValues) and their colours.
    @objc public static let clutCurveClassNames: Set<String> = [
        "NSObject", "NSArray", "NSMutableArray", "NSDictionary", "NSMutableDictionary",
        "NSString", "NSMutableString", "NSNumber", "NSValue", "NSColor",
    ]

    /// One colour of the CLUT and opacity editor. A named colour holds strings.
    @objc public static let colorClassNames: Set<String> = [
        "NSObject", "NSColor", "NSString", "NSMutableString",
    ]

    /// The class names `data` holds, in the order they appear, or an error
    /// when it is not a typedstream this reader can walk.
    public static func classNames(in data: Data) throws -> [String] {
        var walker = TypedStreamWalker(bytes: [UInt8](data))
        try walker.walkRootObject()
        return walker.classNames
    }

    /// The root object of `data`, decoded by NSUnarchiver only when every
    /// class the archive names is in `allowedClassNames`.
    public static func unarchiveObject(with data: Data, allowedClassNames: Set<String>) throws -> Any {
        for name in try classNames(in: data) {
            // A name must also reach NSUnarchiver as itself, not mapped to
            // another class by +decodeClassName:asClassName:.
            if !allowedClassNames.contains(name) || NSUnarchiver.classNameDecoded(forArchiveClassName: name) != name {
                throw RestrictedUnarchiverError.disallowedClass(name)
            }
        }
        var object: Any?
        do {
            try HorosObjCException.perform {
                object = NSUnarchiver.unarchiveObject(with: data)
            }
        } catch {
            let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            throw RestrictedUnarchiverError.unreadable(exception?.reason ?? exception?.name.rawValue ?? "NSUnarchiver raised")
        }
        guard let object else {
            throw RestrictedUnarchiverError.unreadable("the archive holds no object")
        }
        return object
    }

    /// The object of an archive, or nil - logged - when it is refused or
    /// unreadable. What NSUnarchiver would raise for is answered with nil too.
    /// No data, or none at all (an image without ROIs), is nil without a word.
    @objc(unarchiveObjectWithData:allowedClassNames:)
    public static func unarchiveObjectOrNil(with data: Data?, allowedClassNames: Set<String>) -> Any? {
        guard let data, !data.isEmpty else { return nil }
        do {
            return try unarchiveObject(with: data, allowedClassNames: allowedClassNames)
        } catch {
            NSLog("Refused to unarchive %lu bytes: %@", data.count, "\(error)")
            return nil
        }
    }

    /// The ROIs of an SR or of the ROI pasteboard: the array the archive
    /// holds, or nil when it is refused, unreadable or holds no array.
    @objc(unarchiveROIsWithData:)
    public static func unarchiveROIs(with data: Data?) -> NSArray? {
        return unarchiveObjectOrNil(with: data, allowedClassNames: roiClassNames) as? NSArray
    }

    /// The ROIs of a .roi or .rois_series file, as `unarchiveROIs(with:)`.
    @objc(unarchiveROIsWithFile:)
    public static func unarchiveROIs(withFile path: String?) -> NSArray? {
        guard let path, let data = FileManager.default.contents(atPath: path) else { return nil }
        return unarchiveROIs(with: data)
    }
}

/// A walk over a typedstream - NSArchiver's format, unchanged since NeXTSTEP -
/// that records every class name in it and reads nothing into objects.
///
/// The stream: a version byte (4), the signature "streamtyped" (little-endian
/// numbers) or "typedstream" (big-endian), the system version (1000), then
/// groups. A group is a type string, shared, followed by one value per type in
/// it. Integers are one signed byte, or a tag followed by 2, 4 or 8 bytes;
/// reals are a tag followed by a float or double, or an integer. Strings and
/// objects are new (a tag), nil (a tag) or a reference to an earlier one. An
/// object is its class, then its groups, then an end tag; a class is its name
/// (a shared string), its version and its superclass, down to nil.
struct TypedStreamWalker {
    private static let tagInteger2: UInt8 = 0x81
    private static let tagInteger4: UInt8 = 0x82
    private static let tagFloatingPoint: UInt8 = 0x83
    private static let tagNew: UInt8 = 0x84
    private static let tagNil: UInt8 = 0x85
    private static let tagEndOfObject: UInt8 = 0x86
    private static let tagInteger8: UInt8 = 0x87
    /// Reference numbers start after the tags, at -110.
    private static let firstReference: Int64 = -110
    /// Deeper than any archive Horos writes (an array of arrays of ROIs whose
    /// dictionaries hold arrays of numbers), and shallow enough that neither
    /// this walk nor NSUnarchiver runs out of stack.
    private static let maximumDepth = 64

    private enum Entry {
        case object
        case classDefinition
        case cString
    }

    private indirect enum TypeCode {
        case char           // c C: one raw byte
        case integer        // s S i I l L q Q
        case float, double
        case object         // @
        case classValue     // #
        case selector       // :
        case cString        // *
        case bytes          // +: a length and that many bytes
        case array(Int, TypeCode)
        case structure([TypeCode])
    }

    private let bytes: [UInt8]
    private var position = 0
    private var bigEndian = false
    private var sharedStrings: [[UInt8]] = []
    private var entries: [Entry] = []
    private var depth = 0
    private(set) var classNames: [String] = []

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private func failure(_ reason: String) -> RestrictedUnarchiverError {
        return .unreadable("not a typedstream this reader accepts: \(reason) at byte \(position)")
    }

    /// The header and the root object that +unarchiveObjectWithData: reads.
    /// NSUnarchiver reads nothing after it; the padding a DICOM value may add
    /// (zero bytes) is the only thing allowed there.
    mutating func walkRootObject() throws {
        guard try readByte() == 4 else { throw failure("unknown stream version") }
        let signature = try readUnsharedBytes()
        if signature == Array("streamtyped".utf8) {
            bigEndian = false
        } else if signature == Array("typedstream".utf8) {
            bigEndian = true
        } else {
            throw failure("unknown signature")
        }
        guard try readInteger() == 1000 else { throw failure("unknown system version") }
        let types = try readTypeString()
        guard types.count == 1, case .object = types[0] else { throw failure("the root is not an object") }
        try walkObject()
        if bytes[position...].contains(where: { $0 != 0 }) {
            throw failure("data after the root object")
        }
    }

    // MARK: Primitive values

    private mutating func readByte() throws -> UInt8 {
        guard position < bytes.count else { throw failure("unexpected end") }
        defer { position += 1 }
        return bytes[position]
    }

    private mutating func peekByte() throws -> UInt8 {
        guard position < bytes.count else { throw failure("unexpected end") }
        return bytes[position]
    }

    private mutating func readRaw(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= bytes.count - position else { throw failure("a length past the end") }
        defer { position += count }
        return Array(bytes[position..<position + count])
    }

    private mutating func readFixed(_ count: Int) throws -> UInt64 {
        let raw = try readRaw(count)
        var value: UInt64 = 0
        for byte in (bigEndian ? raw : raw.reversed()) {
            value = value << 8 | UInt64(byte)
        }
        return value
    }

    private mutating func readInteger() throws -> Int64 {
        return try readInteger(head: try readByte())
    }

    private mutating func readInteger(head: UInt8) throws -> Int64 {
        switch head {
        case Self.tagInteger2: return Int64(Int16(truncatingIfNeeded: try readFixed(2)))
        case Self.tagInteger4: return Int64(Int32(truncatingIfNeeded: try readFixed(4)))
        case Self.tagInteger8: return Int64(bitPattern: try readFixed(8))
        case 0x80...0x91: throw failure("tag \(head) where an integer belongs")
        default: return Int64(Int8(bitPattern: head))
        }
    }

    private mutating func readReal(size: Int) throws {
        let head = try readByte()
        if head == Self.tagFloatingPoint {
            _ = try readRaw(size)
        } else {
            _ = try readInteger(head: head)
        }
    }

    private mutating func readUnsharedBytes() throws -> [UInt8] {
        let length = try readInteger()
        guard length >= 0, length <= Int64(bytes.count - position) else { throw failure("a length past the end") }
        return try readRaw(Int(length))
    }

    /// A reference number, as an index into a table of `count` entries.
    private mutating func readReference(head: UInt8, count: Int) throws -> Int {
        let index = try readInteger(head: head) - Self.firstReference
        guard index >= 0, index < Int64(count) else { throw failure("a reference to nothing") }
        return Int(index)
    }

    private mutating func readSharedString() throws -> [UInt8]? {
        let head = try readByte()
        switch head {
        case Self.tagNil:
            return nil
        case Self.tagNew:
            let string = try readUnsharedBytes()
            sharedStrings.append(string)
            return string
        default:
            return sharedStrings[try readReference(head: head, count: sharedStrings.count)]
        }
    }

    // MARK: Objects and classes

    private mutating func enter() throws {
        depth += 1
        guard depth <= Self.maximumDepth else { throw failure("nesting deeper than \(Self.maximumDepth)") }
    }

    private mutating func walkObject() throws {
        let head = try readByte()
        switch head {
        case Self.tagNil:
            return
        case Self.tagNew:
            try enter()
            defer { depth -= 1 }
            entries.append(.object)
            guard try walkClass() else { throw failure("an object without a class") }
            while try peekByte() != Self.tagEndOfObject {
                try walkGroup()
            }
            position += 1
        default:
            guard case .object = entries[try readReference(head: head, count: entries.count)] else {
                throw failure("an object reference to something else")
            }
        }
    }

    /// False for nil, the end of a superclass chain.
    private mutating func walkClass() throws -> Bool {
        let head = try readByte()
        switch head {
        case Self.tagNil:
            return false
        case Self.tagNew:
            try enter()
            defer { depth -= 1 }
            guard let nameBytes = try readSharedString(), !nameBytes.isEmpty, !nameBytes.contains(0),
                  let name = String(bytes: nameBytes, encoding: .utf8) else {
                throw failure("a class without a readable name")
            }
            classNames.append(name)
            _ = try readInteger() // version
            entries.append(.classDefinition)
            _ = try walkClass() // superclass
            return true
        default:
            guard case .classDefinition = entries[try readReference(head: head, count: entries.count)] else {
                throw failure("a class reference to something else")
            }
            return true
        }
    }

    private mutating func walkCString() throws {
        let head = try readByte()
        switch head {
        case Self.tagNil:
            return
        case Self.tagNew:
            entries.append(.cString)
            guard try readSharedString() != nil else { throw failure("a C string without characters") }
        default:
            guard case .cString = entries[try readReference(head: head, count: entries.count)] else {
                throw failure("a C string reference to something else")
            }
        }
    }

    // MARK: Groups and type strings

    private mutating func walkGroup() throws {
        for type in try readTypeString() {
            try walkValue(type)
        }
    }

    private mutating func walkValue(_ type: TypeCode) throws {
        switch type {
        case .char: _ = try readByte()
        case .integer: _ = try readInteger()
        case .float: try readReal(size: 4)
        case .double: try readReal(size: 8)
        case .object: try walkObject()
        case .classValue: _ = try walkClass()
        case .selector: _ = try readSharedString()
        case .cString: try walkCString()
        case .bytes: _ = try readUnsharedBytes()
        case .array(let count, .char):
            _ = try readRaw(count)
        case .array(let count, let element):
            // Each element takes at least a byte, so a count past the end is
            // not an archive; it would only make the walk long.
            guard count <= bytes.count - position else { throw failure("an array past the end") }
            try enter()
            defer { depth -= 1 }
            for _ in 0..<count {
                try walkValue(element)
            }
        case .structure(let fields):
            try enter()
            defer { depth -= 1 }
            for field in fields {
                try walkValue(field)
            }
        }
    }

    private mutating func readTypeString() throws -> [TypeCode] {
        guard let string = try readSharedString(), !string.isEmpty else { throw failure("a group without a type") }
        var index = 0
        var types: [TypeCode] = []
        while index < string.count {
            types.append(try parseType(string, &index, nesting: 0))
        }
        return types
    }

    private func parseType(_ string: [UInt8], _ index: inout Int, nesting: Int) throws -> TypeCode {
        guard nesting < 16 else { throw failure("a type nested too deep") }
        guard index < string.count else { throw failure("a truncated type") }
        let code = string[index]
        index += 1
        switch code {
        case UInt8(ascii: "c"), UInt8(ascii: "C"):
            return .char
        case UInt8(ascii: "s"), UInt8(ascii: "S"), UInt8(ascii: "i"), UInt8(ascii: "I"),
             UInt8(ascii: "l"), UInt8(ascii: "L"), UInt8(ascii: "q"), UInt8(ascii: "Q"):
            return .integer
        case UInt8(ascii: "f"): return .float
        case UInt8(ascii: "d"): return .double
        case UInt8(ascii: "@"): return .object
        case UInt8(ascii: "#"): return .classValue
        case UInt8(ascii: ":"): return .selector
        case UInt8(ascii: "*"): return .cString
        case UInt8(ascii: "+"): return .bytes
        case UInt8(ascii: "["):
            var count = 0
            var digits = 0
            while index < string.count, string[index] >= UInt8(ascii: "0"), string[index] <= UInt8(ascii: "9") {
                count = count * 10 + Int(string[index] - UInt8(ascii: "0"))
                digits += 1
                index += 1
                guard digits <= 9 else { throw failure("an array too long") }
            }
            guard digits > 0 else { throw failure("an array without a count") }
            let element = try parseType(string, &index, nesting: nesting + 1)
            guard index < string.count, string[index] == UInt8(ascii: "]") else { throw failure("an unterminated array type") }
            index += 1
            if case .char = element {
                return .array(count, element)
            }
            guard count > 0 else { throw failure("an empty array type") }
            return .array(count, element)
        case UInt8(ascii: "{"):
            // The name, up to '=', then the fields up to '}'.
            while index < string.count, string[index] != UInt8(ascii: "=") {
                guard !"{}[]\"".utf8.contains(string[index]) else { throw failure("a malformed structure type") }
                index += 1
            }
            guard index < string.count else { throw failure("a structure type without fields") }
            index += 1
            var fields: [TypeCode] = []
            while index < string.count, string[index] != UInt8(ascii: "}") {
                fields.append(try parseType(string, &index, nesting: nesting + 1))
            }
            guard index < string.count, !fields.isEmpty else { throw failure("a malformed structure type") }
            index += 1
            return .structure(fields)
        default:
            throw failure("the unsupported type '\(Character(Unicode.Scalar(code)))'")
        }
    }
}
