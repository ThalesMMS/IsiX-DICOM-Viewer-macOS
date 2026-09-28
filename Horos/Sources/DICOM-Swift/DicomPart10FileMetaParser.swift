// Modified for Horos by Thales Matheus M Santos (ThalesMMS), 2026: reads its
// integers and the Transfer Syntax UID tag without the DicomData module, which
// is not vendored.
// Original: DICOM-Swift, DicomCore/DicomPart10FileMetaParser.swift, revision 1947fefa46e6.
// Licensed under the Apache License, Version 2.0; see LICENSE in this folder.

import Foundation

public enum DicomPart10FileMetaParser {
    public struct FileMeta: Equatable, Sendable {
        public var mediaStorageSOPClassUID: String?
        public var mediaStorageSOPInstanceUID: String?
        public var transferSyntaxUID: String?
        public var dataSetOffset: Int
    }

    public enum ParserError: Error, Equatable, Sendable {
        case invalid(String)
    }

    public static func hasPart10Prefix(_ data: Data) -> Bool {
        guard data.count >= 132 else {
            return false
        }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            bytes[128] == 0x44 &&
                bytes[129] == 0x49 &&
                bytes[130] == 0x43 &&
                bytes[131] == 0x4D
        }
    }

    public static func parse(_ data: Data) throws -> FileMeta {
        guard hasPart10Prefix(data) else {
            throw ParserError.invalid("missing DICM prefix")
        }

        var offset = 132
        var sopClassUID: String?
        var sopInstanceUID: String?
        var transferSyntaxUID: String?

        while offset < data.count {
            let remainingByteCount = data.count - offset
            guard remainingByteCount >= 8 else {
                if remainingByteCount >= 2,
                   try readUInt16(from: data, at: offset) == 0x0002 {
                    throw ParserError.invalid("truncated file meta element")
                }
                break
            }

            let elementOffset = offset
            let group = try readUInt16(from: data, at: offset)
            let element = try readUInt16(from: data, at: offset + 2)
            guard group == 0x0002 else {
                offset = elementOffset
                break
            }

            let vr = asciiString(from: data, at: offset + 4, length: 2) ?? ""
            guard let uses32BitLength = uses32BitLength(vr) else {
                throw ParserError.invalid("file meta element has an invalid explicit VR")
            }
            let valueOffset: Int
            let length: Int
            if uses32BitLength {
                guard remainingByteCount >= 12 else {
                    throw ParserError.invalid("truncated file meta element")
                }
                valueOffset = offset + 12
                guard let exactLength = Int(exactly: try readUInt32(from: data, at: offset + 8)) else {
                    throw ParserError.invalid("file meta element length is not addressable")
                }
                length = exactLength
            } else {
                valueOffset = offset + 8
                length = Int(try readUInt16(from: data, at: offset + 6))
            }

            guard length <= data.count - valueOffset else {
                throw ParserError.invalid("file meta element length exceeds file size")
            }

            let valueEnd = valueOffset + length
            let tag = (Int(group) << 16) | Int(element)
            switch tag {
            case 0x0002_0002:
                guard vr == "UI" else {
                    throw ParserError.invalid("Media Storage SOP Class UID has an invalid VR")
                }
                sopClassUID = try uidValue(from: data, at: valueOffset, length: length)
            case 0x0002_0003:
                guard vr == "UI" else {
                    throw ParserError.invalid("Media Storage SOP Instance UID has an invalid VR")
                }
                sopInstanceUID = try uidValue(from: data, at: valueOffset, length: length)
            case 0x0002_0010: // Transfer Syntax UID
                guard vr == "UI" else {
                    throw ParserError.invalid("Transfer Syntax UID has an invalid VR")
                }
                transferSyntaxUID = try uidValue(from: data, at: valueOffset, length: length)
            default:
                break
            }
            offset = valueEnd
        }

        return FileMeta(
            mediaStorageSOPClassUID: sopClassUID,
            mediaStorageSOPInstanceUID: sopInstanceUID,
            transferSyntaxUID: transferSyntaxUID,
            dataSetOffset: offset
        )
    }

    private static func uses32BitLength(_ vr: String) -> Bool? {
        switch vr {
        case "OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV":
            return true
        case "AE", "AS", "AT", "CS", "DA", "DS", "DT", "FD", "FL", "IS", "LO", "LT", "PN", "SH", "SL",
             "SS", "ST", "TM", "UI", "UL", "US":
            return false
        default:
            return nil
        }
    }

    private static func readUInt16(from data: Data, at offset: Int) throws -> UInt16 {
        guard let value = littleEndianInteger(from: data, at: offset, as: UInt16.self) else {
            throw ParserError.invalid("truncated UInt16 value")
        }
        return value
    }

    private static func readUInt32(from data: Data, at offset: Int) throws -> UInt32 {
        guard let value = littleEndianInteger(from: data, at: offset, as: UInt32.self) else {
            throw ParserError.invalid("truncated UInt32 value")
        }
        return value
    }

    private static func littleEndianInteger<T: FixedWidthInteger>(from data: Data, at offset: Int, as: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, size <= data.count - offset else { return nil }
        return data.withUnsafeBytes { bytes in
            (0..<size).reduce(T.zero) { $0 | T(bytes[offset + $1]) << (8 * $1) }
        }
    }

    private static func uidValue(from data: Data, at offset: Int, length: Int) throws -> String {
        guard length <= 64 else {
            throw ParserError.invalid("file meta UID exceeds 64 bytes")
        }
        return asciiString(from: data, at: offset, length: length)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? ""
    }

    private static func asciiString(from data: Data, at offset: Int, length: Int) -> String? {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            String(bytes: bytes[offset..<(offset + length)], encoding: .ascii)
        }
    }
}
