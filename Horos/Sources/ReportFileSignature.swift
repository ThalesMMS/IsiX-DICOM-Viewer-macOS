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

/// Identifies the on-disk state of report files without reading their contents.
///
/// The browser checks every report opened in the session against its archived
/// DICOM SR each time the app becomes active. Extracting the SR and comparing
/// the contents takes milliseconds per megabyte on the main thread, so it only
/// needs to run when this signature differs from the one recorded at the last
/// successful check.
///
/// A modification date alone is not enough: an editor can keep it, and a
/// document package such as a .pages report changes its inner files without
/// touching the date of the package directory. The signature therefore covers
/// every item of a package, and for each one its device, inode, size, mode,
/// modification time and status change time. The kernel updates the status
/// change time on every write, rename or date change, and no API sets it back.
enum ReportFileSignature {

    /// The signature of the given files or packages, in order, or nil when one
    /// of them cannot be examined. A nil signature never matches.
    static func signature(ofPaths paths: [String]) -> String? {
        var parts: [String] = []
        for path in paths {
            guard let item = entry(path, relative: "") else { return nil }
            parts.append(item)
            guard isDirectory(path) else { continue }
            guard let children = FileManager.default.enumerator(atPath: path) else { return nil }
            var inner: [String] = []
            while let child = children.nextObject() as? String {
                guard let item = entry((path as NSString).appendingPathComponent(child), relative: child) else { return nil }
                inner.append(item)
            }
            parts.append(contentsOf: inner.sorted())
        }
        return parts.joined(separator: "\n")
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func entry(_ path: String, relative: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return "\(relative)\u{0}\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):" +
            "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }
}
