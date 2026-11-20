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

/// What Settings > Locations asks of the open panel for a local database, and
/// the folder a choice stands for.
///
/// In the sandbox the choice is a folder and nothing else: the panel grants
/// access to what was chosen and to what is inside it, and an index file
/// would open nothing of the folder it is in. The panel is told of no type
/// of file there.
///
/// Out of the sandbox the index file may be chosen as well, and stands for
/// the database folder it is in. Whoever sets up the panel gives it the types
/// before saying that folders can be chosen: a panel given its types of file
/// stops taking folders (seen on macOS 27), and its Open button then stays
/// off on every folder.
public struct LocalDatabasePathChoice: Sendable, Equatable {
    public let sandboxed: Bool

    public init(sandboxed: Bool) {
        self.sandboxed = sandboxed
    }

    public var canChooseDirectories: Bool { true }
    public var canChooseFiles: Bool { !sandboxed }
    /// The extensions of the files the panel takes; none when it takes
    /// folders only, and the panel is then given no type at all.
    public var fileExtensions: [String] { sandboxed ? [] : ["sql"] }

    /// The database folder that what was chosen at `path` stands for; nil for
    /// a file that is no index. `isDataDirectoryName` says whether a folder's
    /// name is that of the data directory of a database.
    ///
    /// Out of the sandbox an index file stands for the folder it is in, and
    /// the data directory, or the folder of images inside it, for the folder
    /// that holds the data directory. In the sandbox the folder chosen is the
    /// only one the application may read, and stands for itself.
    public func folder(forChosenPath path: String, isDirectory: Bool, isDataDirectoryName: (String) -> Bool) -> String? {
        if sandboxed { return isDirectory ? path : nil }
        var location = path as NSString
        if !isDirectory {
            guard fileExtensions.contains(location.pathExtension.lowercased()) else { return nil }
            location = location.deletingLastPathComponent as NSString
        }
        if isDataDirectoryName(location.lastPathComponent) {
            return location.deletingLastPathComponent
        }
        let parent = location.deletingLastPathComponent as NSString
        if ["DATABASE", "DATABASE.noindex"].contains(location.lastPathComponent), isDataDirectoryName(parent.lastPathComponent) {
            return parent.deletingLastPathComponent
        }
        return location as String
    }
}
