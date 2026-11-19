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

/// The files of its image folder that the database of an earlier application
/// still lists, as its table of images records them.
///
/// An image of the folder is recorded by a number, which is the file
/// `<number>.dcm`, or by a bare name; either lies in the subfolder named after
/// the next multiple of ten thousand above the number the name starts with
/// (`10000/1.dcm`, `10000/9999.dcm`, `20000/10000.dcm`; a name that starts
/// with no number counts as 0). A path from the root is a file left where it
/// was, which is not of the folder unless it leads into it.
///
/// A file of the folder that no row records is what the earlier application
/// took out of its list and left on disk: a deletion still waiting or refused,
/// what remained of an import that did not finish.
public struct LegacyFileIndex: Sendable, Equatable {
    /// How many numbers a subfolder of the image folder takes.
    public static let folderSize = 10000

    /// The numbers recorded, each the file `<number>.dcm`.
    private var numbers = IndexSet()
    /// The other files recorded, by their path inside the image folder.
    private var names = Set<String>()

    public init() {}

    public var isEmpty: Bool { numbers.isEmpty && names.isEmpty }

    /// The path inside the image folder of the file recorded by a bare name.
    public static func relativePath(ofName name: String) -> String {
        let number = Int(((name as NSString).deletingPathExtension as NSString).intValue)
        return "\((number / folderSize + 1) * folderSize)/\(name)"
    }

    /// Records the file `<number>.dcm`. A row may repeat another's file, as
    /// the frames of a multiframe file do.
    public mutating func list(number: Int64) {
        guard number >= 0, number <= Int64(Int32.max) else { return }
        numbers.insert(Int(number))
    }

    /// Records the file of a row that names it. False for a path from the
    /// root that leads outside `imagesFolders`, the paths the image folder is
    /// known by: that file is not of the folder.
    @discardableResult
    public mutating func list(path: String, imagesFolders: [String]) -> Bool {
        guard !path.isEmpty else { return true }
        guard path.hasPrefix("/") else {
            names.insert(Self.relativePath(ofName: path))
            return true
        }
        for folder in imagesFolders where path.hasPrefix(folder + "/") {
            names.insert(String(path.dropFirst(folder.count + 1)))
            return true
        }
        return false
    }

    /// Whether a row records the file at `relativePath` of the image folder.
    /// The image half of a header and image pair is recorded by its header.
    public func lists(relativePath: String) -> Bool {
        if names.contains(relativePath) { return true }
        let name = (relativePath as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        switch (name as NSString).pathExtension {
        case "dcm":
            guard let number = Int(stem), number >= 0, String(number) == stem, numbers.contains(number) else { return false }
            return relativePath == Self.relativePath(ofName: name)
        case "img":
            return names.contains(((relativePath as NSString).deletingPathExtension as NSString).appendingPathExtension("hdr") ?? "")
        default:
            return false
        }
    }
}
