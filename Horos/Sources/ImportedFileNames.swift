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
import Synchronization

/// The name a file arrived with, for the moment between copying it into the
/// database and reading it.
///
/// A file that is not DICOM has no identity of its own: `-[DicomFile
/// getImageFile]` makes one out of the file's **name**, and a trailing number is
/// what turns `scan001.jpg`, `scan002.jpg`, … into one series. The database
/// copies the file to a numbered name of its own first - `2173.tif` - so what
/// the reader saw was that number: every raster file, whatever it was called,
/// came out with the same empty stem and they all fell into a single series.
///
/// The database leaves the original name here on its way past, and the reader
/// takes it. Nothing else uses it, and an entry that is never taken is dropped
/// once the table grows past what an import can hold.
@objc(HorosImportedFileNames)
public final class ImportedFileNames: NSObject {
    /// The names by path, and the paths in the order they came.
    private static let table = Mutex<(names: [String: String], order: [String])>(([:], []))
    /// An import hands over its files in one batch, so the table only has to
    /// hold a batch; well past that, the oldest entries were never claimed.
    private static let limit = 20_000

    @objc(rememberName:forPath:)
    public static func remember(_ name: String?, forPath path: String?) {
        guard let name, !name.isEmpty, let path, !path.isEmpty else { return }
        table.withLock { table in
            if table.names.updateValue(name, forKey: path) == nil { table.order.append(path) }
            while table.order.count > limit {
                table.names.removeValue(forKey: table.order.removeFirst())
            }
        }
    }

    /// The name, and it is forgotten: a stored file is read once on the way in.
    @objc(nameForPath:)
    public static func name(forPath path: String?) -> String? {
        guard let path else { return nil }
        return table.withLock { table in
            guard let name = table.names.removeValue(forKey: path) else { return nil }
            if let position = table.order.firstIndex(of: path) { table.order.remove(at: position) }
            return name
        }
    }

    @objc public static func forgetAll() {
        table.withLock { table in
            table.names.removeAll()
            table.order.removeAll()
        }
    }

    @objc public static var count: Int {
        table.withLock { $0.names.count }
    }
}
