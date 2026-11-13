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

/// Whether a DICOM file is the image the database record that names it says
/// it is.
///
/// A record names its file by a number of the data folder. In a database
/// where a record came to name the file of another image, loading the record
/// showed that other image, of another study or another patient, under the
/// record's own names. The SOP Instance UID the record keeps and the one the
/// file states tell the two apart: a file that states another one is not
/// shown as the record's image.
///
/// Nothing is refused that cannot be told apart. A record that keeps no UID
/// and a file that states none are taken as they are, and so is every frame
/// of a multi-frame object, whose records name one file between them. A record
/// keeps its UID packed, digits and dots only: of a UID written with any other
/// character it keeps something else, so a file that states such a UID is
/// taken as it is too.
public enum RecordedInstance {
    /// Whether the file whose SOP Instance UID is `fileUID` may be loaded as
    /// the image of a record that keeps `recordUID` and counts
    /// `numberOfFrames` frames. The padding a UID may be written with (spaces,
    /// a trailing NUL) is no difference.
    public static func accepts(fileUID: String?, forRecordUID recordUID: String?, numberOfFrames: Int) -> Bool {
        if numberOfFrames > 1 { return true }
        guard let recorded = unpadded(recordUID), let stated = unpadded(fileUID) else { return true }
        guard isKeptAsWritten(stated) else { return true }
        return recorded == stated
    }

    /// `uid` without its padding; nil when nothing is left.
    private static func unpadded(_ uid: String?) -> String? {
        let padding = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))
        guard let trimmed = uid?.trimmingCharacters(in: padding), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Whether a record keeps `uid` as it is written: digits and dots only.
    private static func isKeptAsWritten(_ uid: String) -> Bool {
        uid.utf8.allSatisfy { $0 == UInt8(ascii: ".") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }
}
