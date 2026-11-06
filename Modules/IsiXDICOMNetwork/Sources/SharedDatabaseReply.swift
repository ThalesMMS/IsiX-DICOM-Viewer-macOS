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

/// The answers of the shared-database server, as released clients read them:
/// integers in big-endian order, strings with their terminator.
public enum SharedDatabaseReply {

    /// A 32-bit big-endian integer.
    public static func integer(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// `AUTHV`: the version of the authorization envelope.
    public static let authorizationVersion = integer(1)

    /// `ISPWD` and `PASWD`: 1 for yes, 0 for no.
    public static func answer(_ yes: Bool) -> Data {
        integer(yes ? 1 : 0)
    }

    /// `DBSIZ` answers in four bytes, which the client reads unsigned. An index
    /// of 4 GiB or more cannot be described in them: the answer is then
    /// `indexTooLargeForReply`, which the client refuses by name, instead of
    /// the size wrapped around.
    public static let indexTooLargeForReply = UInt32.max

    public static func indexSizeValue(_ size: UInt64) -> UInt32 {
        size >= UInt64(UInt32.max) ? indexTooLargeForReply : UInt32(size)
    }

    public static func indexSize(_ size: UInt64) -> Data {
        integer(indexSizeValue(size))
    }

    /// `VERSI`: the time of the index's last change, the eight bytes of the
    /// double in big-endian order.
    public static func modificationTime(_ time: TimeInterval) -> Data {
        withUnsafeBytes(of: time.bitPattern.bigEndian) { Data($0) }
    }

    /// `DBVER`: the model's version in ASCII; nil when there is none or it is
    /// not ASCII, and then nothing is sent.
    public static func databaseVersion(_ version: String?) -> Data? {
        (version as NSString?)?.data(using: String.Encoding.ascii.rawValue)
    }

    /// `GETDI`: the keys of the destination, in order, up to the first value
    /// missing (the dictionary was built by +dictionaryWithObjectsAndKeys:,
    /// which stops at the first nil).
    public static func destinationInfo(aeTitle: String?, port: String?, transferSyntax: Int32) -> [(key: String, value: String)] {
        var entries: [(key: String, value: String)] = []
        for (value, key) in [(aeTitle, "AETitle"), (port, "Port"), (String(format: "%d", transferSyntax), "TransferSyntax")] {
            guard let value else { break }
            entries.append((key, value))
        }
        return entries
    }

    /// `SENDD` and `SENDG`: how many images the upload added, and the path
    /// number of each.
    public static func upload(pathNumbers: [Int32]) -> Data {
        var data = integer(UInt32(truncatingIfNeeded: pathNumbers.count))
        for number in pathNumbers {
            data.append(integer(UInt32(bitPattern: number)))
        }
        return data
    }

    /// `DICOM`: how many files follow.
    public static func fetchCount(_ count: Int) -> Data {
        integer(UInt32(truncatingIfNeeded: count))
    }

    /// `DICOM`: the length of one file, which follows it.
    public static func fetchedFileLength(_ length: Int) -> Data {
        integer(UInt32(truncatingIfNeeded: length))
    }

    /// `DICOM`: the path the client keeps a file at, with its length and its
    /// terminator, after the file.
    public static func destinationPath(_ path: String) -> (length: Data, path: Data) {
        let string = path.utf8CString
        return (integer(UInt32(truncatingIfNeeded: string.count)), string.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// `MFILE`: the description of the file's modification date in UTF-16 with
    /// its byte order mark; nil when there is no date, and then nothing is sent.
    public static func fileDate(_ description: String?) -> Data? {
        (description as NSString?)?.data(using: String.Encoding.unicode.rawValue)
    }
}
