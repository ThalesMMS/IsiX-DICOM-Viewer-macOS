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

/// Writes the released typedstream contracts (.roi, SR and CLUT pasteboards).
/// A keyed archive is a different wire format and cannot replace this writer.
public enum HistoricalArchive {
    public enum Failure: Error {
        case writerUnavailable
        case invalidArchiveResult
    }

    public nonisolated static func archivedData(withRootObject object: Any) throws -> Data {
        let selector = NSSelectorFromString("archivedDataWithRootObject:")
        guard let writer = NSClassFromString("NSArchiver") as? NSObject.Type,
              writer.responds(to: selector) else {
            throw Failure.writerUnavailable
        }
        var result: Data?
        // The historical selector returns an autoreleased NSData object.
        // Keep Objective-C coder exceptions in the existing NSError boundary.
        try HorosObjCException.perform {
            result = writer.perform(selector, with: object)?.takeUnretainedValue() as? Data
        }
        guard let result else { throw Failure.invalidArchiveResult }
        return result
    }

    public nonisolated static func archiveRootObject(_ object: Any, toFile path: String) throws -> Bool {
        let data = try archivedData(withRootObject: object)
        return (data as NSData).write(toFile: path, atomically: true)
    }
}
