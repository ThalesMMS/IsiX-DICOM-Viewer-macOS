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

/// What a database-sharing peer answers to `GETDI`: the AE title, port and
/// transfer syntax of its DICOM listener, which the browser asks before it has
/// one shared database send images to another.
///
/// Every Horos and OsiriX server answers with `NSArchiver` data of a dictionary
/// of strings, and the client decoded it with `NSUnarchiver`, which instantiates
/// whatever classes the data names: any computer answering on the sharing port
/// chose them. `NSUnarchiver` has no secure mode, so the reply is read here
/// instead, by a reader of that format (a "typedstream") that knows a dictionary
/// and a string and nothing else, and builds the result itself: no class the
/// data names is looked up or instantiated. Any other class name, a value that
/// is no string, a reference to an object not yet complete, bytes that are not
/// UTF-8 or trailing bytes make the whole reply unreadable.
///
/// The server keeps sending the same bytes, which released clients still read
/// with `NSUnarchiver`.
@objc(HorosSharedDatabaseDestinationInfo)
public final class SharedDatabaseDestinationInfo: NSObject {

    /// The reply as a dictionary of strings, or nil when it is not one.
    @objc(dictionaryFromReply:)
    public class func dictionary(fromReply reply: Data) -> NSDictionary? {
        var reader = TypedStreamReader(reply)
        guard let dictionary = try? reader.readDictionaryOfStrings() else { return nil }
        return dictionary as NSDictionary
    }
}

/// `NSArchiver`'s format, as far as a dictionary of strings needs it.
///
/// A stream is a header - the streamer version, the signature and the system
/// version - followed by groups: a type encoding, as a shared string, and the
/// values it describes. An object is nil, a reference to an earlier one, or a
/// new one: its class, the groups its `-encodeWithCoder:` wrote, and an end tag.
/// A class is a reference or a new one: its name, as a shared string, its
/// version and its superclass. Objects and classes share one table of
/// references, class names and type encodings another. Integers are one signed
/// byte, or a tag followed by two or four bytes, little-endian under the
/// signature `streamtyped`.
private struct TypedStreamReader {
    private struct Invalid: Error {}

    private enum Kind { case dictionary, string }

    private enum Entry {
        case incomplete
        case string(String)
        /// A class; nil for `NSObject`, which only ends a superclass chain.
        case `class`(Kind?)
    }

    private static let integer2: Int8 = -127
    private static let integer4: Int8 = -126
    private static let new: Int8 = -124
    private static let null: Int8 = -123
    private static let endOfObject: Int8 = -122
    private static let lastTag = -111
    private static let firstReference = -110

    /// The only classes a reply may name. Anything else is refused on its name.
    private static let classes: [String: Kind?] = [
        "NSDictionary": .dictionary, "NSMutableDictionary": .dictionary,
        "NSString": .string, "NSMutableString": .string,
        "NSObject": Kind?.none,
    ]

    private let bytes: [UInt8]
    private var offset = 0
    private var sharedStrings: [String] = []
    private var entries: [Entry] = []

    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func readDictionaryOfStrings() throws -> [String: String] {
        guard try readInteger() == 4, try readBytes() == Array("streamtyped".utf8) else { throw Invalid() }
        _ = try readInteger() // the system version
        try expectType("@")
        let head = try readHead()
        guard head == Self.new else { throw Invalid() }
        let dictionary = try readNewObject(of: .dictionary)
        guard offset == bytes.count, case .dictionary(let result) = dictionary else { throw Invalid() }
        return result
    }

    private enum Value {
        case dictionary([String: String])
        case string(String)
    }

    /// An object whose new tag was just read, of the kind the caller expects.
    private mutating func readNewObject(of expected: Kind) throws -> Value {
        let index = entries.count
        entries.append(.incomplete)
        guard try readClass() == expected else { throw Invalid() }
        let value: Value
        switch expected {
        case .string:
            try expectType("+")
            guard let string = String(bytes: try readBytes(), encoding: .utf8) else { throw Invalid() }
            entries[index] = .string(string)
            value = .string(string)
        case .dictionary:
            try expectType("i")
            let count = try readInteger()
            guard count >= 0 else { throw Invalid() }
            var dictionary: [String: String] = [:]
            for _ in 0..<count {
                try expectType("@")
                let key = try readString()
                try expectType("@")
                dictionary[key] = try readString()
            }
            value = .dictionary(dictionary)
        }
        guard try readHead() == Self.endOfObject else { throw Invalid() }
        return value
    }

    /// A key or a value: a new string, or a reference to a complete one.
    private mutating func readString() throws -> String {
        let head = try readHead()
        if head == Self.new {
            guard case .string(let string) = try readNewObject(of: .string) else { throw Invalid() }
            return string
        }
        guard case .string(let string) = try entry(forReferenceHead: head) else { throw Invalid() }
        return string
    }

    /// An object's class and its superclass chain: every name is checked
    /// against the list as it is read, before anything that follows it.
    private mutating func readClass() throws -> Kind {
        let head = try readHead()
        let kind: Kind?
        if head == Self.new {
            kind = try readNewClass()
            while true { // the superclass chain: new classes, then nil or a known class
                let next = try readHead()
                if next == Self.null { break }
                if next == Self.new { _ = try readNewClass(); continue }
                guard case .class = try entry(forReferenceHead: next) else { throw Invalid() }
                break
            }
        } else {
            guard case .class(let known) = try entry(forReferenceHead: head) else { throw Invalid() }
            kind = known
        }
        guard let kind else { throw Invalid() } // an NSObject
        return kind
    }

    private mutating func readNewClass() throws -> Kind? {
        guard let known = Self.classes[try readSharedString()] else { throw Invalid() }
        _ = try readInteger() // the class version
        entries.append(.class(known))
        return known
    }

    private mutating func expectType(_ type: String) throws {
        guard try readSharedString() == type else { throw Invalid() }
    }

    private mutating func readSharedString() throws -> String {
        let head = try readHead()
        if head == Self.new {
            guard let string = String(bytes: try readBytes(), encoding: .utf8) else { throw Invalid() }
            sharedStrings.append(string)
            return string
        }
        let index = try reference(head)
        guard index < sharedStrings.count else { throw Invalid() }
        return sharedStrings[index]
    }

    private mutating func entry(forReferenceHead head: Int8) throws -> Entry {
        let index = try reference(head)
        guard index < entries.count else { throw Invalid() }
        return entries[index]
    }

    private mutating func reference(_ head: Int8) throws -> Int {
        let index = try integer(afterHead: head) - Self.firstReference
        guard index >= 0 else { throw Invalid() }
        return index
    }

    /// A length and as many bytes.
    private mutating func readBytes() throws -> [UInt8] {
        let length = try readInteger()
        guard length >= 0, length <= bytes.count - offset else { throw Invalid() }
        defer { offset += length }
        return Array(bytes[offset..<offset + length])
    }

    private mutating func readInteger() throws -> Int {
        try integer(afterHead: try readHead())
    }

    private mutating func integer(afterHead head: Int8) throws -> Int {
        switch head {
        case Self.integer2:
            return Int(Int16(bitPattern: UInt16(try readByte()) | UInt16(try readByte()) << 8))
        case Self.integer4:
            var value: UInt32 = 0
            for shift in stride(from: 0, to: 32, by: 8) { value |= UInt32(try readByte()) << UInt32(shift) }
            return Int(Int32(bitPattern: value))
        default:
            guard Int(head) > Self.lastTag else { throw Invalid() } // a tag where a value belongs
            return Int(head)
        }
    }

    private mutating func readHead() throws -> Int8 { Int8(bitPattern: try readByte()) }

    private mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw Invalid() }
        defer { offset += 1 }
        return bytes[offset]
    }
}
