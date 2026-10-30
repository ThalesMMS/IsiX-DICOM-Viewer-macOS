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

/// A Specific Character Set (0008,0005) and the string encodings it names.
///
/// The table is the one the app has always read text with: the DICOM terms,
/// written with spaces, hyphens or underscores and in any case, and the
/// Windows code page names some equipment writes instead. A value with several
/// terms gives one encoding per term, ten at most, the first being the one the
/// text starts in.
@objc(IsiXDICOMCharacterSet)
public final class DICOMCharacterSet: NSObject, NSCopying {
    /// The value as the file states it.
    @objc public let characterSet: String
    /// The encoding of the first term.
    @objc public let encoding: UInt
    private let storage: UnsafeMutablePointer<UInt>

    /// The encodings of the terms, in order, ten slots, zero after the last.
    @objc public var encodings: UnsafeMutablePointer<UInt> { storage }

    @objc(initWithCode:)
    public init(code characterSet: String) {
        self.characterSet = characterSet
        storage = .allocate(capacity: 10)
        storage.initialize(repeating: 0, count: 10)
        storage[0] = String.Encoding.isoLatin1.rawValue
        for (index, term) in characterSet.components(separatedBy: "\\").enumerated() {
            if index < 10 {
                storage[index] = Self.encoding(forDICOMCharacterSet: term)
            } else {
                NSLog("Encoding number >= 10 ???")
            }
        }
        encoding = storage[0]
        super.init()
    }

    deinit { storage.deallocate() }

    public func copy(with zone: NSZone? = nil) -> Any { DICOMCharacterSet(code: characterSet) }

    public override var description: String { characterSet }

    /// What to read a file's text as when it does not say.
    ///
    /// The standard's default is the ASCII repertoire, which this reads as
    /// Latin-1; equipment that predates Specific Character Set writes the bytes
    /// of whatever code page the operating system had, and in Russia that is
    /// Windows-1251. Nothing in such a file tells one from the other, so the
    /// choice is the reader's, made once in the preferences:
    /// `DefaultCharacterSetWhenAbsent` holds a DICOM term or a code page name and
    /// is empty by default. It applies only when the attribute is absent.
    @objc public static func characterSetWhenAbsent() -> String? {
        let chosen = UserDefaults.standard.string(forKey: "DefaultCharacterSetWhenAbsent") ?? ""
        return chosen.isEmpty ? nil : chosen
    }

    private static func cf(_ encoding: CFStringEncodings) -> UInt {
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
    }

    /// The ten encodings a text value is decoded with (stringWithBytes:...),
    /// for a Specific Character Set (0008,0005) as stated, nil when absent:
    /// one per term, the slots after the last term in the last term's
    /// encoding; without a value, or with ten terms or more, the encoding of
    /// an absent character set first and nothing after it.
    public static func encodings(forSpecificCharacterSet value: String?) -> [UInt] {
        var encodings = [UInt](repeating: 0, count: 10)
        encodings[0] = encoding(forDICOMCharacterSet: nil)
        guard let value else { return encodings }
        let terms = value.components(separatedBy: "\\")
        if terms.count >= 10 {
            NSLog("Encoding number >= 10 ???")
            return encodings
        }
        for (index, term) in terms.enumerated() { encodings[index] = encoding(forDICOMCharacterSet: term) }
        for index in terms.count..<10 { encodings[index] = encoding(forDICOMCharacterSet: terms.last) }
        return encodings
    }

    /// The encoding of one term; Latin-1 for an empty one (or the preference's
    /// choice) and for a term this does not know. Of a value with several
    /// terms, the first.
    @objc(encodingForDICOMCharacterSet:)
    public static func encoding(forDICOMCharacterSet value: String?) -> UInt {
        let latin1 = String.Encoding.isoLatin1.rawValue
        var term = value ?? ""
        if term.isEmpty {
            guard let chosen = characterSetWhenAbsent() else { return latin1 }
            term = chosen
        }
        term = term.replacingOccurrences(of: "-", with: " ")
        term = term.replacingOccurrences(of: "_", with: " ")
        term = term.replacingOccurrences(of: "ISO 2022", with: "ISO")
        // Every term below is written in capitals; a file that writes its own in
        // lower case is naming the same thing.
        term = term.uppercased()
        switch term {
        case "ISO IR 100", "ISO IR 6": return latin1
        case "ISO IR 127": return cf(.isoLatinArabic)
        case "ISO IR 148": return cf(.isoLatin5)
        case "ISO IR 101": return String.Encoding.isoLatin2.rawValue
        case "ISO IR 109": return cf(.isoLatin3)
        case "ISO IR 110": return cf(.isoLatin4)
        case "ISO IR 144": return cf(.isoLatinCyrillic)
        case "ISO IR 126": return cf(.isoLatinGreek)
        case "ISO IR 138": return cf(.isoLatinHebrew)
        case "ISO IR 166": return cf(.isoLatinThai)
        case "GB18030": return cf(.GB_18030_2000)
        case "ISO IR 192", "UTF 8": return String.Encoding.utf8.rawValue
        case "ISO IR 13": return cf(.macJapanese)
        case "ISO IR 58": return cf(.ISO_2022_CN)
        case "ISO IR 87": return String.Encoding.iso2022JP.rawValue
        case "ISO IR 149": return cf(.EUC_KR)
        // Not DICOM terms. Equipment writes them anyway, and a file that names
        // its code page is telling the truth about its bytes even when it names
        // it in the wrong vocabulary.
        case "WINDOWS 1250", "CP1250": return cf(.windowsLatin2)
        case "WINDOWS 1251", "CP1251": return cf(.windowsCyrillic)
        case "WINDOWS 1252", "CP1252": return CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringBuiltInEncodings.windowsLatin1.rawValue))
        case "WINDOWS 1253", "CP1253": return cf(.windowsGreek)
        case "WINDOWS 1254", "CP1254": return cf(.windowsLatin5)
        case "WINDOWS 1255", "CP1255": return cf(.windowsHebrew)
        case "WINDOWS 1256", "CP1256": return cf(.windowsArabic)
        case "WINDOWS 1257", "CP1257": return cf(.windowsBalticRim)
        case "WINDOWS 1258", "CP1258": return cf(.windowsVietnamese)
        default:
            NSLog("** DICOMTONSString encoding not found: %@", term)
            if (term as NSString).length < 50 {
                let terms = term.components(separatedBy: "\\")
                if terms.count > 1 {
                    NSLog("**** error: multiple encoding in +[IsiXDICOMCharacterSet encodingForDICOMCharacterSet:] : %@", term)
                    return encoding(forDICOMCharacterSet: terms[0])
                }
            }
            return latin1
        }
    }

    /// Text of `length` bytes in the encodings of a value's terms, switching at
    /// ISO 2022 escape sequences and back to the first at a delimiter, as
    /// DCMTK 3.6's convertString does. Person name component delimiters are
    /// delimiters except inside the multi-byte Japanese sets.
    @objc(stringWithBytes:length:encodings:)
    public static func string(withBytes bytes: UnsafePointer<CChar>?, length: UInt32,
                              encodings: UnsafePointer<UInt>) -> String? {
        guard let bytes else { return nil }
        let fromLength: Int
        if length > 0 {
            fromLength = Int(length)
        } else {
            NSLog("***** warning IsiXDICOMCharacterSet stringWithBytes, length == 0, use C String length")
            fromLength = strlen(bytes)
        }
        let result = NSMutableString()
        var checkPNDelimiters = true
        var currentEncoding = encodings[0]
        var position = 0
        var first = 0
        var current = 0
        var escapeLength = 0

        func append(from start: Int, count: Int) {
            if let text = NSString(bytes: bytes + start, length: count, encoding: currentEncoding) {
                result.append(text as String)
            }
        }

        while position < fromLength {
            let c0 = UInt8(bitPattern: bytes[current]); current += 1
            let isEscape = c0 == 0x1B
            let isDelimiter = c0 == 0x0A || c0 == 0x0C || c0 == 0x0D || ((c0 == 0x5E || c0 == 0x3D) && checkPNDelimiters)
            if isEscape || isDelimiter {
                let convertLength = current - first - 1
                if convertLength - (escapeLength + 1) >= 0 {
                    append(from: first, count: convertLength)
                }
            }
            if isEscape {
                escapeLength = 2
                if position + escapeLength < fromLength {
                    var key: String?
                    let c1 = UInt8(bitPattern: bytes[current]); current += 1
                    let c2 = UInt8(bitPattern: bytes[current]); current += 1
                    switch (c1, c2) {
                    case (0x28, 0x42): key = "ISO 2022 IR 6"
                    case (0x2d, 0x41): key = "ISO 2022 IR 100"
                    case (0x2d, 0x42): key = "ISO 2022 IR 101"
                    case (0x2d, 0x43): key = "ISO 2022 IR 109"
                    case (0x2d, 0x44): key = "ISO 2022 IR 110"
                    case (0x2d, 0x4c): key = "ISO 2022 IR 144"
                    case (0x2d, 0x47): key = "ISO 2022 IR 127"
                    case (0x2d, 0x46): key = "ISO 2022 IR 126"
                    case (0x2d, 0x48): key = "ISO 2022 IR 138"
                    case (0x2d, 0x4d): key = "ISO 2022 IR 148"
                    case (0x29, 0x49), (0x28, 0x4a): key = "ISO 2022 IR 13"
                    case (0x2d, 0x54): key = "ISO 2022 IR 166"
                    case (0x24, 0x42): key = "ISO 2022 IR 87"
                    case (0x24, 0x28):
                        escapeLength = 3
                        if position + escapeLength < fromLength {
                            let c3 = UInt8(bitPattern: bytes[current]); current += 1
                            if c3 == 0x44 { key = "ISO 2022 IR 159" }
                        }
                    case (0x24, 0x29):
                        escapeLength = 3
                        if position + escapeLength < fromLength {
                            let c3 = UInt8(bitPattern: bytes[current]); current += 1
                            if c3 == 0x43 { key = "ISO 2022 IR 149" } else if c3 == 0x41 { key = "ISO 2022 IR 58" }
                        }
                    default: break
                    }
                    if let key {
                        currentEncoding = encoding(forDICOMCharacterSet: key)
                        if !(0..<10).contains(where: { encodings[$0] == currentEncoding }) {
                            NSLog("*** encoding not found in declared SpecificCharacterSet (0008,0005)")
                        }
                        checkPNDelimiters = key != "ISO 2022 IR 87" && key != "ISO 2022 IR 159"
                        first = checkPNDelimiters ? current : current - (escapeLength + 1)
                    } else {
                        NSLog("*** key == nil")
                    }
                    position += escapeLength
                    if checkPNDelimiters { escapeLength = 0 }
                }
                if position >= fromLength { NSLog("incomplete sequence") }
            } else if isDelimiter {
                result.append(String(UnicodeScalar(c0)))
                if currentEncoding != encodings[0] {
                    currentEncoding = encodings[0]
                    checkPNDelimiters = true
                }
                first = current
            }
            position += 1
        }
        let convertLength = current - first
        if convertLength > 0 && first + convertLength <= fromLength && convertLength - (escapeLength + 1) >= 0 {
            append(from: first, count: convertLength)
        }
        return result as String
    }
}
