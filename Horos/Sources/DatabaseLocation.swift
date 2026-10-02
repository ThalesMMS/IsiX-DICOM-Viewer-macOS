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

/// Which directory a database lives in, for whatever the user pointed at.
///
/// Four things get chosen in practice and all four mean the same database: the
/// folder that contains `Horos Data`, that folder itself, a folder that *was*
/// it and has since been renamed - which is what happens to every backup copied
/// somewhere with a name that says what it is - and the index file inside any of
/// them.
///
/// Only the first two used to be recognised. Anything else had `Horos Data`
/// appended to it, so choosing a renamed data folder built an **empty new
/// database nested inside the real one** and showed nothing, while choosing the
/// index file inside one asked the file system to create a directory where a
/// file already was and threw before the application finished starting.
@objc(HorosDatabaseLocation)
public final class DatabaseLocation: NSObject {

    /// The directory a database's files live in, inside the chosen folder.
    /// This is the name a new database gets.
    @objc public static let dataDirectoryName = "Isis DICOM Viewer Data"
    /// The name that directory had before the application was renamed. A
    /// database made then keeps it: it is opened where it is, never renamed.
    @objc public static let previousDataDirectoryName = "Horos Data"

    /// Whether `name` is a data directory's, current or previous.
    @objc(isDataDirectoryName:)
    public class func isDataDirectoryName(_ name: String?) -> Bool {
        return name == dataDirectoryName || name == previousDataDirectoryName
    }

    /// The data directory `folder` holds, under either name, or `nil`. With
    /// both there, the one with an index is the database; the current name
    /// wins a tie.
    @objc(existingDataDirectoryInFolder:)
    public class func existingDataDirectory(inFolder folder: String?) -> String? {
        guard let folder = folder else { return nil }
        let candidates = [dataDirectoryName, previousDataDirectoryName]
            .map { (folder as NSString).appendingPathComponent($0) }
            .filter { isDirectory($0) }
        return candidates.first { pathHoldsExistingDatabase($0) } ?? candidates.first
    }
    /// The index, which is what makes a directory recognisable as a database.
    @objc public static let indexFileName = "Database.sql"

    /// `nil` in, `nil` out: the caller asks with the location it has, and it has
    /// none when the volume that location names is not mounted.
    @objc(baseDirectoryForPath:)
    public class func baseDirectory(forPath path: String?) -> String? {
        guard var path = path else { return nil }

        // A path inside a data directory belongs to that directory. This is
        // what resolves the index file, and any file below it, when the
        // directory still carries its name.
        let components = (path as NSString).pathComponents
        if let index = components.lastIndex(where: { isDataDirectoryName($0) }) {
            return NSString.path(withComponents: Array(components[0...index]))
        }

        // The index file of a directory that no longer carries the name.
        if (path as NSString).lastPathComponent == indexFileName, isFile(path) {
            path = (path as NSString).deletingLastPathComponent
        }

        // A folder holding a data directory: that directory is the database,
        // even when the folder also holds an index of its own.
        if let existing = existingDataDirectory(inFolder: path) {
            return existing
        }

        // A folder holding an index is the database, whatever it is called.
        if isFile((path as NSString).appendingPathComponent(indexFileName)) {
            return path
        }

        // Nothing there yet: this is where a new database goes.
        return (path as NSString).appendingPathComponent(dataDirectoryName)
    }

    /// Whether the chosen path names an existing database rather than a place to
    /// make one. The caller says something different in each case: reopening a
    /// database that moved is not the same event as creating one.
    @objc(pathHoldsExistingDatabase:)
    public class func pathHoldsExistingDatabase(_ path: String?) -> Bool {
        guard let path = path else { return false }
        return isFile((path as NSString).appendingPathComponent(indexFileName))
    }

    private class func isFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        return exists && !directory.boolValue
    }

    private class func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        return exists && directory.boolValue
    }
}
