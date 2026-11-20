//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Compression
import CryptoKit
import Foundation
import zlib

// Selectors that later headers of the plugin SDK add to classes of Foundation.
// A plugin built with those headers sends them by name, from any thread, and
// an absent one raises «unrecognized selector» in the middle of the plugin's
// work. The headers give each a name and its types; what each answers follows
// its name and the conventions of Cocoa, and is said at each one. An argument
// that is nil or zero answers nil, false or nothing, never an exception.

// MARK: - NSString

extension NSString {
    /// What follows the first occurrence of `marker`; nil when the string does not have it.
    @objc(stringAfterString:) func laterSDKString(after marker: String?) -> String? {
        guard let marker, !marker.isEmpty else { return nil }
        let found = range(of: marker, options: .literal)
        return found.location == NSNotFound ? nil : substring(from: NSMaxRange(found))
    }

    /// What lies between the first occurrence of `start` and the next one of `end`; nil without both.
    @objc(stringBetweenString:andString:) func laterSDKString(between start: String?, and end: String?) -> String? {
        laterSDKStrings(between: start, and: end, limit: 1).first
    }

    /// Every piece that lies between an occurrence of `start` and the next one of `end`, in order.
    @objc(stringsBetweenString:andString:) func laterSDKStrings(between start: String?, and end: String?) -> [String] {
        laterSDKStrings(between: start, and: end, limit: .max)
    }

    private func laterSDKStrings(between start: String?, and end: String?, limit: Int) -> [String] {
        guard let start, let end, !start.isEmpty, !end.isEmpty else { return [] }
        var pieces: [String] = []
        var location = 0
        while location < length, pieces.count < limit {
            let opening = range(of: start, options: .literal, range: NSRange(location: location, length: length - location))
            guard opening.location != NSNotFound else { break }
            let from = NSMaxRange(opening)
            let closing = range(of: end, options: .literal, range: NSRange(location: from, length: length - from))
            guard closing.location != NSNotFound else { break }
            pieces.append(substring(with: NSRange(location: from, length: closing.location - from)))
            location = NSMaxRange(closing)
        }
        return pieces
    }

    /// The string without `prefix` at its start; the string itself when it does not start with it.
    @objc(stringByDeletingPrefix:) func laterSDKDeletingPrefix(_ prefix: String?) -> String {
        guard let prefix, hasPrefix(prefix) else { return self as String }
        return substring(from: (prefix as NSString).length)
    }

    /// The string without `suffix` at its end; the string itself when it does not end with it.
    @objc(stringByDeletingSuffix:) func laterSDKDeletingSuffix(_ suffix: String?) -> String {
        guard let suffix, hasSuffix(suffix) else { return self as String }
        return substring(to: length - (suffix as NSString).length)
    }

    /// The string with its accents and other combining marks taken off: «é» is «e».
    @objc(stringByRemovingCombiningMarks) func laterSDKRemovingCombiningMarks() -> String {
        applyingTransform(.stripCombiningMarks, reverse: false) ?? (self as String)
    }

    /// The string with each run of spaces, tabs and line breaks made one space.
    @objc(withoutWhitespaceSequences) func laterSDKWithoutWhitespaceSequences() -> String {
        var collapsed = "", inRun = false
        for scalar in (self as String).unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !inRun { collapsed.append(" ") }
                inRun = true
            } else {
                collapsed.unicodeScalars.append(scalar)
                inRun = false
            }
        }
        return collapsed
    }

    /// The string as the name of a file: each character a name cannot hold on
    /// the usual file systems (/ \ : * ? " < > | and the control characters)
    /// becomes «_», and so does a name that is empty, «.» or «..».
    @objc(sanitizeFileName) func laterSDKSanitizedFileName() -> String {
        let refused = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var name = ""
        for scalar in (self as String).unicodeScalars {
            if refused.contains(scalar) { name.append("_") } else { name.unicodeScalars.append(scalar) }
        }
        return name.isEmpty || name == "." || name == ".." ? "_" : name
    }

    /// The SHA-1 digest of the UTF-8 bytes of the string, in lowercase hexadecimal.
    @objc(sha1) func laterSDKSHA1() -> String {
        hexadecimal(Insecure.SHA1.hash(data: Data((self as String).utf8)))
    }

    /// The string with its percent escapes read; the string itself when they do not make UTF-8.
    @objc(urlDecodedString) func laterSDKURLDecodedString() -> String {
        removingPercentEncoding ?? (self as String)
    }

    /// Whether the string is a URL as written, with a scheme and a host, or a path for the file scheme.
    @objc(validURL) func laterSDKIsValidURL() -> Bool {
        guard let components = URLComponents(string: self as String, encodingInvalidCharacters: false),
              let scheme = components.scheme, !scheme.isEmpty else { return false }
        if scheme.lowercased() == "file" { return !components.path.isEmpty }
        return !(components.host ?? "").isEmpty
    }

    /// The UTF-8 bytes of the string in the quoted-printable encoding of
    /// MIME: lines of at most 76 characters that end in CRLF, a soft break
    /// «=» where a longer line is cut.
    @objc(quotedPrintableString) func laterSDKQuotedPrintableString() -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        let bytes = Array((self as String).utf8)
        var encoded: [UInt8] = [], lineLength = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0D || byte == 0x0A {
                if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 1 }
                encoded += [0x0D, 0x0A]
                lineLength = 0
                index += 1
                continue
            }
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0x0A
            let endsLine = next == 0x0D || next == 0x0A
            let literal = (byte >= 33 && byte <= 126 && byte != 0x3D) || ((byte == 0x20 || byte == 0x09) && !endsLine)
            let piece: [UInt8] = literal ? [byte] : [0x3D, digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
            if lineLength + piece.count > 75 {
                encoded += [0x3D, 0x0D, 0x0A]
                lineLength = 0
            }
            encoded += piece
            lineLength += piece.count
            index += 1
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    /// The string with its digits and its plus and minus signs as superscripts: «-12» is «⁻¹²».
    @objc(numberToSuperscript) func laterSDKNumberToSuperscript() -> String {
        let superscripts: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷",
                                                    "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻"]
        return String((self as String).map { superscripts[$0] ?? $0 })
    }

    /// `length` letters and digits drawn at random; the empty string for a length of 0 or less.
    @objc(randomStringWithLength:) class func laterSDKRandomString(length: Int32) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<max(0, Int(length))).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    /// The text of `data`: as UTF-8, or as Latin-1 when its bytes are not UTF-8.
    @objc(stringWithData:) class func laterSDKString(data: Data?) -> NSString? {
        guard let data else { return nil }
        return NSString(data: data, encoding: String.Encoding.utf8.rawValue) ?? NSString(data: data, encoding: String.Encoding.isoLatin1.rawValue)
    }

    /// A duration of `interval` seconds in days, hours, minutes and seconds,
    /// as «1 hour, 2 minutes» or, abbreviated, «1h 2m»: at most `maxUnits`
    /// units from the largest that is not zero, all of them for 0 or less.
    @objc(timeString:maxUnits:abbreviated:) class func laterSDKTimeString(_ interval: TimeInterval, maxUnits: Int, abbreviated: Bool) -> String? {
        guard interval.isFinite else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = abbreviated ? .abbreviated : .full
        formatter.maximumUnitCount = max(0, min(maxUnits, 4))
        return formatter.string(from: interval)
    }
}

/// The bytes of a digest or of a data in lowercase hexadecimal, two digits a byte.
private func hexadecimal(_ bytes: some Sequence<UInt8>) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var text: [UInt8] = []
    for byte in bytes { text += [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]] }
    return String(decoding: text, as: UTF8.self)
}

// MARK: - Property lists and JSON

/// A property list as the text of an XML property list; nil for an object that is not one.
private func propertyListText(_ object: Any) -> String? {
    guard PropertyListSerialization.propertyList(object, isValidFor: .xml),
          let data = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// The property list a text holds, in XML or in the old text format.
private func propertyList(fromText text: String?) -> Any? {
    guard let text, !text.isEmpty else { return nil }
    return try? PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil)
}

/// An object as JSON text; nil for an object JSON cannot hold.
private func jsonText(_ object: Any, options: UInt) -> String? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: JSONSerialization.WritingOptions(rawValue: options)) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// The object a JSON text holds.
private func jsonObject(fromText text: String?, options: UInt) -> Any? {
    guard let text, !text.isEmpty else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(text.utf8), options: JSONSerialization.ReadingOptions(rawValue: options))
}

// MARK: - NSArray

extension NSArray {
    /// The array without the objects equal to one before them.
    @objc(arrayByRemovingDuplicates) func laterSDKRemovingDuplicates() -> [Any] { NSOrderedSet(array: Array(self)).array }

    /// The array without its first object.
    @objc(arrayByRemovingFirstObject) func laterSDKRemovingFirstObject() -> [Any] { Array(dropFirst()) }

    /// The array without its last object.
    @objc(arrayByRemovingLastObject) func laterSDKRemovingLastObject() -> [Any] { Array(dropLast()) }

    /// The array without any object equal to `object`.
    @objc(arrayByRemovingObject:) func laterSDKRemoving(_ object: Any?) -> [Any] {
        guard let object else { return Array(self) }
        return filter { !($0 as AnyObject).isEqual(object) }
    }

    /// The array without the object at `index`; the whole array for an index past its end.
    @objc(arrayByRemovingObjectAtIndex:) func laterSDKRemovingObject(at index: UInt) -> [Any] {
        var objects = Array(self)
        if index < UInt(objects.count) { objects.remove(at: Int(index)) }
        return objects
    }

    /// The array without the first object equal to `object`.
    @objc(arrayByRemovingObjectFirstOccurenceOf:) func laterSDKRemovingFirstOccurrence(of object: Any?) -> [Any] {
        var objects = Array(self)
        if let object, case let found = index(of: object), found != NSNotFound { objects.remove(at: found) }
        return objects
    }

    /// The array without any object equal to one of `others`.
    @objc(arrayByRemovingObjectsFromArray:) func laterSDKRemovingObjects(in others: NSArray?) -> [Any] {
        guard let others else { return Array(self) }
        return filter { !others.contains($0) }
    }

    /// The index of the smallest of the numbers of the array; NSNotFound when it has none.
    @objc(indexOfSmallestValue) func laterSDKIndexOfSmallestValue() -> UInt {
        var smallest: (index: Int, value: NSNumber)?
        for (index, object) in enumerated() {
            guard let number = object as? NSNumber else { continue }
            if let current = smallest, current.value.compare(number) != .orderedDescending { continue }
            smallest = (index, number)
        }
        return UInt(smallest?.index ?? NSNotFound)
    }

    /// Whether the array and `other` have an object in common.
    @objc(intersectArray:) func laterSDKIntersects(_ other: NSArray?) -> Bool {
        guard let other else { return false }
        return contains { other.contains($0) }
    }

    /// The objects of the array that `other` has too, in the order of the array.
    @objc(intersectionArray:) func laterSDKIntersection(_ other: NSArray?) -> [Any] {
        guard let other else { return [] }
        return filter { other.contains($0) }
    }

    /// The median of the numbers of the array, the mean of the two in the
    /// middle for an even count; nil when it has none.
    @objc(medianNumberFromNumbersArray) func laterSDKMedianNumber() -> NSNumber? {
        let values = compactMap { ($0 as? NSNumber)?.doubleValue }.sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        return NSNumber(value: values.count % 2 == 1 ? values[middle] : (values[middle - 1] + values[middle]) / 2)
    }

    /// One object of the array drawn at random; nil for an empty array.
    @objc(randomObject) func laterSDKRandomObject() -> Any? { count > 0 ? object(at: Int.random(in: 0..<count)) : nil }

    /// The objects of the array in a random order.
    @objc(randomizedArray) func laterSDKRandomized() -> [Any] { shuffled() }

    /// The array as the text of an XML property list, which +arrayFromString:
    /// reads back; nil when it holds an object a property list cannot.
    @objc(arrayAsString) func laterSDKAsString() -> String? { propertyListText(self) }

    /// The array a property list text holds; nil when the text is not one or holds something else.
    @objc(arrayFromString:) class func laterSDKArray(fromString text: String?) -> NSArray? { propertyList(fromText: text) as? NSArray }

    /// The array as JSON text; nil when it holds an object JSON cannot.
    @objc(arrayAsJSONwithOptions:) func laterSDKAsJSON(options: UInt) -> String? { jsonText(self, options: options) }

    /// The array a JSON text holds; nil when the text is not JSON or holds something else.
    @objc(arrayFromJSON:withOptions:) class func laterSDKArray(fromJSON text: String?, options: UInt) -> NSArray? {
        jsonObject(fromText: text, options: options) as? NSArray
    }
}

extension NSMutableArray {
    /// Adds `object`, unless it is nil.
    @objc(addObjectIfNotNil:) func laterSDKAddIfNotNil(_ object: Any?) {
        if let object { add(object) }
    }

    /// Adds `string`, unless it is nil.
    @objc(addString:) func laterSDKAddString(_ string: String?) {
        if let string { add(string) }
    }

    /// Puts `object` in the place of the last object; in an empty array, adds it.
    @objc(replaceLasObjectWith:) func laterSDKReplaceLastObject(with object: Any?) {
        guard let object else { return }
        if count > 0 { replaceObject(at: count - 1, with: object) } else { add(object) }
    }
}

// MARK: - NSDictionary

extension NSDictionary {
    /// The dictionary with the entries of `other`, which replace those of the same key.
    @objc(dictionaryByAddingDictionary:) func laterSDKAdding(_ other: NSDictionary?) -> NSDictionary {
        let sum = NSMutableDictionary(dictionary: self)
        if let other { sum.addEntries(from: other as? [AnyHashable: Any] ?? [:]) }
        return sum
    }

    /// The dictionary with `object` for `key`.
    @objc(dictionaryByAddingObject:forKey:) func laterSDKAdding(_ object: Any?, forKey key: Any?) -> NSDictionary {
        let sum = NSMutableDictionary(dictionary: self)
        if let object, let key = key as? NSCopying { sum.setObject(object, forKey: key) }
        return sum
    }

    /// The dictionary without `key`.
    @objc(dictionaryByRemovingKey:) func laterSDKRemovingKey(_ key: Any?) -> NSDictionary {
        let rest = NSMutableDictionary(dictionary: self)
        if let key { rest.removeObject(forKey: key) }
        return rest
    }

    /// The dictionary without the keys that are strings starting with `prefix`.
    @objc(dictionaryByRemovingKeysWithPrefix:) func laterSDKRemovingKeys(withPrefix prefix: String?) -> NSDictionary {
        let rest = NSMutableDictionary(dictionary: self)
        guard let prefix, !prefix.isEmpty else { return rest }
        for key in allKeys {
            if let name = key as? String, name.hasPrefix(prefix) { rest.removeObject(forKey: key) }
        }
        return rest
    }

    /// The object of `key`, or of a key that differs from it only in the case of its letters.
    @objc(objectForCaseInsensitiveKey:) func laterSDKObject(forCaseInsensitiveKey key: String?) -> Any? {
        guard let key else { return nil }
        if let exact = object(forKey: key) { return exact }
        for candidate in allKeys {
            if let name = candidate as? String, name.caseInsensitiveCompare(key) == .orderedSame { return object(forKey: candidate) }
        }
        return nil
    }

    /// The dictionary as the text of an XML property list, which
    /// +dictionaryFromString: reads back; nil when a property list cannot hold it.
    @objc(dictionaryAsString) func laterSDKAsString() -> String? { propertyListText(self) }

    /// The dictionary a property list text holds; nil when the text is not one or holds something else.
    @objc(dictionaryFromString:) class func laterSDKDictionary(fromString text: String?) -> NSDictionary? {
        propertyList(fromText: text) as? NSDictionary
    }

    /// The dictionary as JSON text; nil when it holds an object or a key JSON cannot.
    @objc(dictionaryAsJSONwithOptions:) func laterSDKAsJSON(options: UInt) -> String? { jsonText(self, options: options) }

    /// The dictionary a JSON text holds; nil when the text is not JSON or holds something else.
    @objc(dictionaryFromJSON:withOptions:) class func laterSDKDictionary(fromJSON text: String?, options: UInt) -> NSDictionary? {
        jsonObject(fromText: text, options: options) as? NSDictionary
    }
}

extension NSMutableDictionary {
    /// Moves the object of the key `old` to the key `new`; nothing without such an object.
    @objc(changeKeyFrom:to:) func laterSDKChangeKey(from old: String?, to new: String?) {
        guard let old, let new, old != new, let object = object(forKey: old) else { return }
        removeObject(forKey: old)
        setObject(object, forKey: new as NSString)
    }

    /// Sets `object` for `key`, unless either is nil.
    @objc(setObjectIfNonNil:forKey:) func laterSDKSetIfNonNil(_ object: Any?, forKey key: String?) {
        if let object, let key { setObject(object, forKey: key as NSString) }
    }
}

// MARK: - NSSet and NSOrderedSet

extension NSSet {
    /// The objects of the set, in no particular order.
    @objc(array) func laterSDKArray() -> [Any] { allObjects }
}

extension NSOrderedSet {
    /// One object of the set, its first; nil for an empty set.
    @objc(anyObject) func laterSDKAnyObject() -> Any? { firstObject }
}

// MARK: - NSData

extension NSData {
    /// The bytes in Base64, on one line.
    @objc(base64Encoded) func laterSDKBase64Encoded() -> String { base64EncodedString() }

    /// The bytes the data holds as Base64 text; nil when it is not Base64.
    @objc(base64Decoded) func laterSDKBase64Decoded() -> Data? { Data(base64Encoded: self as Data, options: .ignoreUnknownCharacters) }

    /// The bytes in Base64, in lines of 64 characters.
    @objc(encodeBase64) func laterSDKEncodeBase64() -> String { laterSDKEncodeBase64(newlines: true) }

    /// The bytes in Base64: in lines of 64 characters separated by a line feed, or on one line.
    @objc(encodeBase64WithNewlines:) func laterSDKEncodeBase64(newlines: Bool) -> String {
        base64EncodedString(options: newlines ? [.lineLength64Characters, .endLineWithLineFeed] : [])
    }

    /// The bytes the data holds as Base64 text, in lines or not; nil when it is not Base64.
    @objc(decodeBase64) func laterSDKDecodeBase64() -> Data? { laterSDKDecodeBase64(newlines: true) }

    /// The bytes the data holds as Base64 text: in lines, where line breaks
    /// and spaces are skipped, or on one line, where they are refused.
    @objc(decodeBase64WithNewLines:) func laterSDKDecodeBase64(newlines: Bool) -> Data? {
        Data(base64Encoded: self as Data, options: newlines ? .ignoreUnknownCharacters : [])
    }

    /// The bytes in lowercase hexadecimal, two digits a byte.
    @objc(hexStringValue) func laterSDKHexStringValue() -> String { hexadecimal(self as Data) }

    /// The same.
    @objc(hexval) func laterSDKHexval() -> String { hexadecimal(self as Data) }

    /// The bytes sixteen a line: the offset, the bytes in hexadecimal and, between bars, as text.
    @objc(hexdump) func laterSDKHexdump() -> String {
        let bytes = self as Data
        var dump = ""
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let line = bytes[bytes.startIndex + offset..<bytes.startIndex + Swift.min(offset + 16, bytes.count)]
            let offsetDigits = String(offset, radix: 16)
            dump += String(repeating: "0", count: Swift.max(0, 8 - offsetDigits.count)) + offsetDigits + " "
            for (column, byte) in line.enumerated() {
                dump += (column == 8 ? "  " : " ") + hexadecimal(CollectionOfOne(byte))
            }
            dump += String(repeating: " ", count: (16 - line.count) * 3 + (line.count <= 8 ? 1 : 0))
            dump += "  |" + String(decoding: line.map { $0 >= 0x20 && $0 < 0x7F ? $0 : 0x2E }, as: UTF8.self) + "|\n"
        }
        return dump
    }

    /// The 16 bytes of the MD5 digest of the data.
    @objc(md5Digest) func laterSDKMD5Digest() -> Data { Data(Insecure.MD5.hash(data: self as Data)) }

    /// The 20 bytes of the SHA-1 digest of the data.
    @objc(sha1Digest) func laterSDKSHA1Digest() -> Data { Data(Insecure.SHA1.hash(data: self as Data)) }

    /// The text the bytes make in `encoding`; nil when they make none.
    @objc(dataAsStringWithEncoding:) func laterSDKString(encoding: UInt) -> NSString? {
        encoding == 0 ? nil : NSString(data: self as Data, encoding: encoding)
    }

    /// The data compressed by an algorithm of the Compression framework; nil
    /// when the algorithm is not one of its, or for an empty data.
    @objc(compressDataWithAlgorithm:) func laterSDKCompressed(algorithm code: Int32) -> Data? {
        // The algorithm by its number: the type of the Compression framework
        // is not one every Objective-C file of the application knows.
        let algorithm = compression_algorithm(rawValue: UInt32(bitPattern: code))
        let source = self as Data
        guard !source.isEmpty else { return nil }
        // What cannot be compressed grows by the framing of the algorithm; the
        // second size is for a data so small that the framing is most of it.
        for capacity in [source.count + source.count / 8 + 1024, source.count * 2 + 65_536] {
            var compressed = Data(count: capacity)
            let written = compressed.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) -> Int in
                source.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                    guard let to = output.bindMemory(to: UInt8.self).baseAddress, let from = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_encode_buffer(to, capacity, from, source.count, nil, algorithm)
                }
            }
            if written > 0 { return compressed.prefix(written) }
        }
        return nil
    }

    /// The data decompressed into a buffer of `destinationSize` bytes, which
    /// the caller frees with free(); the bytes past the decompressed ones are
    /// 0. NULL when nothing could be decompressed.
    @objc(decompressDataWithDestinationSize:algorithm:)
    func laterSDKDecompressed(destinationSize: UInt, algorithm code: Int32) -> UnsafeMutableRawPointer? {
        let algorithm = compression_algorithm(rawValue: UInt32(bitPattern: code))
        let source = self as Data
        guard !source.isEmpty, destinationSize > 0, destinationSize <= UInt(Int.max), let buffer = calloc(Int(destinationSize), 1) else { return nil }
        let written = source.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
            guard let from = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(buffer.assumingMemoryBound(to: UInt8.self), Int(destinationSize), from, source.count, nil, algorithm)
        }
        guard written > 0 else {
            free(buffer)
            return nil
        }
        return buffer
    }

    /// The first `count` bytes of the file at `path`, fewer when the file is shorter; nil when it cannot be read.
    @objc(dataWithFirstBytes:ofFile:) class func laterSDKData(firstBytes count: UInt, ofFile path: String?) -> Data? {
        guard let path, let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard count > 0 else { return Data() }
        return (try? file.read(upToCount: Int(Swift.min(count, UInt(Int.max))))) ?? Data()
    }

    /// The 8 bytes of `value`, in the byte order of the machine.
    @objc(dataWithLong:) class func laterSDKData(long value: UInt) -> Data { withUnsafeBytes(of: value) { Data($0) } }

    /// The 2 bytes of `value`, in the byte order of the machine.
    @objc(dataWithShort:) class func laterSDKData(short value: UInt16) -> Data { withUnsafeBytes(of: value) { Data($0) } }

    /// The fields of a header written as «Name: value» lines, as those of
    /// HTTP or of MIME, up to the first empty line: a line that starts with a
    /// space continues the value before it, a name that comes again adds its
    /// value after a comma, and a line without a colon is skipped.
    @objc(headerValuesFromString:) class func laterSDKHeaderValues(from text: String?) -> [String: String] {
        var values: [String: String] = [:]
        var last: String?
        for line in (text ?? "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty {
                if values.isEmpty { continue }
                break
            }
            if let first = line.first, first == " " || first == "\t" {
                if let last, let value = values[last] { values[last] = value + " " + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            values[name] = values[name].map { $0 + ", " + value } ?? value
            last = name
        }
        return values
    }
}

// MARK: - NSDate

/// A formatter of fixed formats: the Gregorian calendar and the names of
/// en_US_POSIX, in the time zone of the user or in `timeZone`.
private func fixedDateFormatter(_ format: String, timeZone: TimeZone? = nil) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    if let timeZone { formatter.timeZone = timeZone }
    formatter.dateFormat = format
    return formatter
}

/// The format of a date formatter for a calendar format, whose fields are the
/// % specifiers the calendar dates of Cocoa took (%Y-%m-%d %H:%M:%S %z); a
/// format without a % is taken as the format of a date formatter already.
private func dateFormat(forCalendarFormat format: String?) -> String {
    guard let format, !format.isEmpty else { return "yyyy-MM-dd HH:mm:ss Z" }
    guard format.contains("%") else { return format }
    let fields: [Character: String] = ["Y": "yyyy", "y": "yy", "m": "MM", "d": "dd", "e": "d", "H": "HH", "I": "hh", "M": "mm", "S": "ss",
                                       "F": "SSS", "p": "a", "B": "MMMM", "b": "MMM", "A": "EEEE", "a": "EEE", "j": "DDD", "Z": "zzz", "z": "Z"]
    var converted = "", literal = ""
    var characters = format.makeIterator()
    while let character = characters.next() {
        guard character == "%", let field = characters.next() else {
            literal.append(character)
            continue
        }
        if let pattern = fields[field] {
            if !literal.isEmpty { converted += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'" }
            literal = ""
            converted += pattern
        } else {
            literal += field == "%" ? "%" : "%\(field)"
        }
    }
    if !literal.isEmpty { converted += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'" }
    return converted
}

extension NSDate {
    /// The day of the date in the time zone of the user, as a date field of a web page takes it: 2020-12-31.
    @objc(javaScriptDate) func laterSDKJavaScriptDate() -> String { fixedDateFormatter("yyyy-MM-dd").string(from: self as Date) }

    /// The date and time as JavaScript writes them, ISO 8601 in UTC with milliseconds: 2020-12-31T23:59:59.000Z.
    @objc(javaScriptDateTime) func laterSDKJavaScriptDateTime() -> String {
        fixedDateFormatter("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", timeZone: TimeZone(identifier: "UTC")).string(from: self as Date)
    }

    /// The start, in the time zone of the user, of a day written as 2020-12-31; a date and time is read as such.
    @objc(dateWithJavaScriptDate:) class func laterSDKDate(javaScriptDate text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return fixedDateFormatter("yyyy-MM-dd").date(from: text) ?? laterSDKDate(javaScriptDateTime: text)
    }

    /// The date of an ISO 8601 date and time, with or without fractions of a
    /// second; one without a time zone is in the time zone of the user.
    @objc(dateWithJavaScriptDateTime:) class func laterSDKDate(javaScriptDateTime text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        for format in ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            if let date = fixedDateFormatter(format).date(from: text) { return date }
        }
        return nil
    }

    /// The date as a header of HTTP writes it: Thu, 31 Dec 2020 23:59:59 GMT.
    @objc(rfc1123String) func laterSDKRFC1123String() -> String {
        fixedDateFormatter("EEE, dd MMM yyyy HH:mm:ss 'GMT'", timeZone: TimeZone(identifier: "GMT")).string(from: self as Date)
    }

    /// The years, months, days, hours, minutes and seconds from `date` to the
    /// receiver, negative when the receiver is the earlier; nil without a date.
    @objc(differenceWithDate:) func laterSDKDifference(with date: Date?) -> DateComponents? {
        guard let date else { return nil }
        return Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date, to: self as Date)
    }

    /// The date written by a calendar format, %Y-%m-%d %H:%M:%S %z without one.
    @objc(dateAsStringWithCalendarFormat:) func laterSDKString(calendarFormat format: String?) -> String {
        fixedDateFormatter(dateFormat(forCalendarFormat: format)).string(from: self as Date)
    }

    /// The date a text holds in a calendar format; nil when the text is not in that format.
    @objc(dateWithString:calendarFormat:) class func laterSDKDate(string text: String?, calendarFormat format: String?) -> NSDate? {
        laterSDKDate(string: text, calendarFormat: format, error: nil)
    }

    /// The same, with `error` set to whether the text could not be read.
    @objc(dateWithString:calendarFormat:error:)
    class func laterSDKDate(string text: String?, calendarFormat format: String?, error: UnsafeMutablePointer<ObjCBool>?) -> NSDate? {
        let date = text.flatMap { fixedDateFormatter(dateFormat(forCalendarFormat: format)).date(from: $0) }
        error?.pointee = ObjCBool(date == nil)
        return date as NSDate?
    }
}

// MARK: - NSNumber

/// A whole number written in decimal, with nothing around it but spaces.
private func parsed<Value: FixedWidthInteger>(_ text: String?, into value: UnsafeMutablePointer<Value>?) -> Bool {
    guard let text, let number = Value(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    value?.pointee = number
    return true
}

extension NSNumber {
    /// Reads `string` as a whole decimal number into `value`; false, with
    /// `value` left as it was, when the string is not one or does not fit.
    @objc(parseString:intoNSInteger:) class func laterSDKParse(_ string: String?, intoNSInteger value: UnsafeMutablePointer<Int>?) -> Bool {
        parsed(string, into: value)
    }

    /// The same for an unsigned number.
    @objc(parseString:intoNSUInteger:) class func laterSDKParse(_ string: String?, intoNSUInteger value: UnsafeMutablePointer<UInt>?) -> Bool {
        parsed(string, into: value)
    }

    /// The same for a number of 64 bits.
    @objc(parseString:intoSInt64:) class func laterSDKParse(_ string: String?, intoSInt64 value: UnsafeMutablePointer<Int64>?) -> Bool {
        parsed(string, into: value)
    }

    /// The same for an unsigned number of 64 bits.
    @objc(parseString:intoUInt64:) class func laterSDKParse(_ string: String?, intoUInt64 value: UnsafeMutablePointer<UInt64>?) -> Bool {
        parsed(string, into: value)
    }
}

// MARK: - NSURL

extension NSURL {
    /// The parameters of the query of the URL, each name with its value, the
    /// empty string for a name without one; the last value of a name that comes again.
    @objc(queryItems) func laterSDKQueryItems() -> [String: String] {
        var items: [String: String] = [:]
        for item in URLComponents(url: self as URL, resolvingAgainstBaseURL: true)?.queryItems ?? [] { items[item.name] = item.value ?? "" }
        return items
    }

    /// The URL with each entry of `parameters` added to its query, in the order of the names.
    @objc(URLByAppendingQueryParameters:) func laterSDKAppendingQueryParameters(_ parameters: NSDictionary?) -> URL? {
        guard let parameters, parameters.count > 0, var components = URLComponents(url: self as URL, resolvingAgainstBaseURL: true) else { return self as URL }
        var added: [URLQueryItem] = []
        for (name, value) in parameters { added.append(URLQueryItem(name: "\(name)", value: value is NSNull ? nil : "\(value)")) }
        components.queryItems = (components.queryItems ?? []) + added.sorted { $0.name < $1.name }
        return components.url
    }

    /// The URL without the parameters of its query whose name is one of `names`.
    @objc(URLByRemovingQueryParameters:) func laterSDKRemovingQueryParameters(_ names: NSArray?) -> URL? {
        guard let names, var components = URLComponents(url: self as URL, resolvingAgainstBaseURL: true), let items = components.queryItems else { return self as URL }
        let kept = items.filter { !names.contains($0.name) }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url
    }
}

// MARK: - NSNotificationCenter and NSThread

extension NotificationCenter {
    /// Registers `observer` for a notification once: what it had registered
    /// for that name and that object is removed first, so that asking again
    /// does not have it told twice.
    @objc(addUniqueObserver:selector:name:object:)
    func laterSDKAddUniqueObserver(_ observer: Any?, selector: Selector?, name: NSNotification.Name?, object: Any?) {
        guard let observer, let selector else { return }
        removeObserver(observer, name: name, object: object)
        addObserver(observer, selector: selector, name: name, object: object)
    }
}

extension Thread {
    /// The number the thread shows in its description and in the debugger, 1
    /// for the main thread; 0 when the description has none.
    @objc(getThreadNum) func laterSDKThreadNumber() -> Int {
        let text = description as NSString
        let label = text.range(of: "number = ")
        guard label.location != NSNotFound else { return isMainThread ? 1 : 0 }
        return text.substring(from: NSMaxRange(label)).prefix { $0.isASCII && $0.isNumber }.reduce(0) { $0 &* 10 &+ ($1.wholeNumberValue ?? 0) }
    }
}

// MARK: - NSObject

extension NSObject {
    /// Sends `selector` to the receiver with `object` on the main thread, and
    /// waits for it to return when `wait`; at once when already there and waiting.
    @objc(OsiriXPerformSelectorOnMainThread:withObject:waitUntilDone:)
    func laterSDKPerformOnMainThread(_ selector: Selector?, with object: Any?, waitUntilDone wait: Bool) {
        guard let selector else { return }
        perform(selector, on: .main, with: object, waitUntilDone: wait)
    }

    /// Sends `selector` to the receiver with `object` on the main thread at
    /// the next turn of its run loop, without waiting, also when sent from
    /// the main thread. The flag has nothing to choose here: every such call
    /// starts from the run loop, never from inside the one that asks.
    @objc(OsiriXPerformSelectorOnMainThread:withObject:rootCallStack:)
    func laterSDKPerformOnMainThread(_ selector: Selector?, with object: Any?, rootCallStack: Bool) {
        laterSDKPerformOnMainThread(selector, with: object, waitUntilDone: false)
    }

    /// Sends `selector` to the receiver with `object` on the main thread
    /// `delay` seconds from now, without waiting: a timer of the main run
    /// loop in its common modes, which keeps the receiver and the object
    /// until it fires. A delay of 0 or less is the next turn of the run loop.
    @objc(OsiriXPerformSelectorOnMainThread:withObject:afterDelay:)
    func laterSDKPerformOnMainThread(_ selector: Selector?, with object: Any?, afterDelay delay: Float) {
        guard let selector else { return }
        guard delay.isFinite, delay > 0 else {
            perform(selector, on: .main, with: object, waitUntilDone: false)
            return
        }
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + CFTimeInterval(delay), 0, 0, 0) { _ in
            _ = self.perform(selector, with: object)
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// The same; the flag changes nothing, as without a delay.
    @objc(OsiriXPerformSelectorOnMainThread:withObject:rootCallStack:afterDelay:)
    func laterSDKPerformOnMainThread(_ selector: Selector?, with object: Any?, rootCallStack: Bool, afterDelay delay: Float) {
        laterSDKPerformOnMainThread(selector, with: object, afterDelay: delay)
    }
}

// MARK: - NSFileManager

extension FileManager {
    private func laterSDKIsDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `path` once a directory is there: one that is missing is made, with
    /// the directories above it when `intermediates`. nil when it could not
    /// be made or the path is of something else.
    @objc(confirmDirectoryAtPath:createIntermediateDirectories:)
    func laterSDKConfirmDirectory(atPath path: String?, createIntermediateDirectories intermediates: Bool) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if !fileExists(atPath: path) { try? createDirectory(atPath: path, withIntermediateDirectories: intermediates) }
        return laterSDKIsDirectory(path) ? path : nil
    }

    /// The size of the file at `path` in bytes; 0 when there is none.
    @objc(fileSize:) func laterSDKFileSize(_ path: String?) -> UInt64 {
        guard let path, let size = (try? attributesOfItem(atPath: path))?[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }

    /// The sum of the sizes of the files in the folder at `path` and in the folders inside it, in bytes.
    @objc(folderSize:) func laterSDKFolderSize(_ path: String?) -> UInt64 {
        guard let path, laterSDKIsDirectory(path),
              let files = enumerator(at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            total &+= UInt64(max(0, values.fileSize ?? 0))
        }
        return total
    }

    /// How many items the folder at `path` holds itself, hidden ones included, not those of the folders inside it.
    @objc(countFolderItemsForPath:) func laterSDKCountFolderItems(forPath path: String?) -> UInt {
        guard let path else { return 0 }
        return UInt((try? contentsOfDirectory(atPath: path))?.count ?? 0)
    }

    /// The CRC-32 of the content of the file at `path`, as zlib computes it; 0 when it cannot be read.
    @objc(crc32ForPath:) func laterSDKCRC32(forPath path: String?) -> UInt {
        guard let path, let file = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? file.close() }
        var checksum = crc32(0, nil, 0), atEnd = false
        while !atEnd {
            // A megabyte at a time, each let go before the next: the file may be larger than the memory.
            autoreleasepool {
                guard let chunk = try? file.read(upToCount: 1 << 20), !chunk.isEmpty else {
                    atEnd = true
                    return
                }
                checksum = chunk.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            }
        }
        return UInt(checksum)
    }

    /// The paths of the files of the folder at `directory` whose extension is
    /// `fileExtension`, whatever the case of its letters, in the order of their names.
    @objc(filesWithExtension:inDirectory:) func laterSDKFiles(withExtension fileExtension: String?, inDirectory directory: String?) -> [String] {
        guard let fileExtension else { return [] }
        return laterSDKFiles(withExtensions: [fileExtension], inDirectory: directory)
    }

    /// The same for any of several extensions.
    @objc(filesWithExtensions:inDirectory:) func laterSDKFiles(withExtensions extensions: NSArray?, inDirectory directory: String?) -> [String] {
        guard let extensions, let directory, let names = try? contentsOfDirectory(atPath: directory) else { return [] }
        let wanted = Set(extensions.compactMap { ($0 as? String)?.lowercased() }.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 })
        return names.sorted().filter { wanted.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { (directory as NSString).appendingPathComponent($0) }
            .filter { !laterSDKIsDirectory($0) }
    }

    /// Removes everything the folder at `path` holds and keeps the folder; whether all of it went.
    @objc(removeContentOfDirectoryAtPath:) func laterSDKRemoveContentOfDirectory(atPath path: String?) -> Bool {
        guard let path, laterSDKIsDirectory(path), let names = try? contentsOfDirectory(atPath: path) else { return false }
        var removedAll = true
        for name in names where (try? removeItem(atPath: (path as NSString).appendingPathComponent(name))) == nil { removedAll = false }
        return removedAll
    }

    /// Removes the items whose path starts with `prefix`: those of its folder
    /// whose name starts with what follows the last «/». A prefix without a
    /// name after the folder removes nothing and answers false.
    @objc(removeItemsWithPrefix:error:) func laterSDKRemoveItems(withPrefix prefix: String?, error: NSErrorPointer) -> Bool {
        guard let prefix, let slash = prefix.lastIndex(of: "/"), case let namePrefix = String(prefix[prefix.index(after: slash)...]), !namePrefix.isEmpty else {
            error?.pointee = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
            return false
        }
        let folder = slash == prefix.startIndex ? "/" : String(prefix[..<slash])
        do {
            for name in try contentsOfDirectory(atPath: folder) where name.hasPrefix(namePrefix) {
                try removeItem(atPath: (folder as NSString).appendingPathComponent(name))
            }
            return true
        } catch let failure {
            error?.pointee = failure as NSError
            return false
        }
    }

    /// Whether `path` can be written: a folder by writing a file in it and
    /// removing it, a file by opening it for writing, without changing it.
    @objc(testWritingPermission:error:) func laterSDKTestWritingPermission(_ path: String?, error: NSErrorPointer) -> Bool {
        guard let path, fileExists(atPath: path) else {
            error?.pointee = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
            return false
        }
        do {
            if laterSDKIsDirectory(path) {
                let probe = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".write-test-" + UUID().uuidString)
                try Data().write(to: probe)
                try removeItem(at: probe)
            } else {
                try FileHandle(forWritingTo: URL(fileURLWithPath: path)).close()
            }
            return true
        } catch let failure {
            error?.pointee = failure as NSError
            return false
        }
    }

    /// Gives the owner of `path` the permissions `added` when it lacks one of them.
    private func laterSDKAddPermissions(_ added: Int, toItemAtPath path: String) throws {
        guard let permissions = try attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber else { return }
        if permissions.intValue & added != added {
            try setAttributes([.posixPermissions: NSNumber(value: permissions.intValue | added)], ofItemAtPath: path)
        }
    }

    /// Gives its owner the permission to read, write and enter the folder at
    /// `directory`, the folder alone and not what it holds.
    @objc(correctWritingPermissionForDirectory:error:) func laterSDKCorrectWritingPermission(forDirectory directory: String?, error: NSErrorPointer) {
        guard let directory, laterSDKIsDirectory(directory) else {
            error?.pointee = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
            return
        }
        do { try laterSDKAddPermissions(0o700, toItemAtPath: directory) } catch let failure { error?.pointee = failure as NSError }
    }

    /// Gives its owner the permission to read and write the file at `path`; whether it can be written after that.
    @objc(correctWritingPermissionForFile:) func laterSDKCorrectWritingPermission(forFile path: String?) -> Bool {
        guard let path, fileExists(atPath: path) else { return false }
        try? laterSDKAddPermissions(0o600, toItemAtPath: path)
        return isWritableFile(atPath: path)
    }

    /// The size and the free space of the volume of `path`, in bytes; false, with both left as they were, when it has none.
    @objc(getTotalSize:andFreeSize:forPath:)
    func laterSDKGetTotalSize(_ total: UnsafeMutablePointer<UInt64>?, andFreeSize free: UnsafeMutablePointer<UInt64>?, forPath path: String?) -> Bool {
        guard let path, let attributes = try? attributesOfFileSystem(forPath: path),
              let size = attributes[.systemSize] as? NSNumber, let freeSize = attributes[.systemFreeSize] as? NSNumber else { return false }
        total?.pointee = size.uint64Value
        free?.pointee = freeSize.uint64Value
        return true
    }

    /// A path in the folder `directory`, the temporary folder without one,
    /// that no file has: a new name each time, with `fileExtension`. Nothing is made there.
    @objc(tmpFilePathInDir:withExtension:) func laterSDKTemporaryFilePath(inDirectory directory: String?, withExtension fileExtension: String?) -> String {
        var name = UUID().uuidString
        if let fileExtension = fileExtension.map({ $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }), !fileExtension.isEmpty { name += "." + fileExtension }
        let folder = directory.flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return (folder as NSString).appendingPathComponent(name)
    }

    /// The same in the temporary folder.
    @objc(tmpFilePathInTmpWithExtension:) func laterSDKTemporaryFilePath(withExtension fileExtension: String?) -> String {
        laterSDKTemporaryFilePath(inDirectory: nil, withExtension: fileExtension)
    }

    /// The path of the name `name` in the temporary folder, the same each time; nil without a name.
    @objc(tmpFilePathInTmpWithName:) func laterSDKTemporaryFilePath(withName name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    /// The folder `app` inside the Application Support folder of the user,
    /// made when it is missing; the Application Support folder itself without a name.
    @objc(userApplicationSupportFolderForApp:) func laterSDKUserApplicationSupportFolder(forApp app: String?) -> String? {
        guard let support = try? url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        guard let app, !app.isEmpty else { return support.path }
        return laterSDKConfirmDirectory(atPath: support.appendingPathComponent(app, isDirectory: true).path, createIntermediateDirectories: true)
    }
}
