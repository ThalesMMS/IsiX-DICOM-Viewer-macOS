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

/// Names image exports and identifies directories retained for their consumers.
@objc(HorosImageExportPath)
public final class ImageExportPath: NSObject {
    @objc(isPrivateExportDirectoryAtPath:)
    public static func isPrivateExportDirectory(atPath path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let isBatch = name.hasPrefix("EXPORT-") && UUID(uuidString: String(name.dropFirst(7))) != nil
        // EXPORT is the legacy shared directory; current batches have a UUID.
        // Match directories only so received files and unrelated folders still
        // participate in startup recovery. Do not follow symbolic links.
        guard name == "EXPORT" || isBatch,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    @objc(pathForSelection:index:extension:)
    public static func path(selection: String, index: Int, fileExtension: String) -> String {
        var base = (selection as NSString).deletingPathExtension
        // The save panel proposes "Series.0001.jpg" for a multi-image export.
        if (base as NSString).pathExtension == "0001" {
            base = (base as NSString).deletingPathExtension
        }
        return (base as NSString).appendingPathExtension(String(format: "%04ld.%@", index, fileExtension))!
    }
}
