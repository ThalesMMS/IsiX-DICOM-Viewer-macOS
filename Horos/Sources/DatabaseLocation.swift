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
///
/// A `Horos Data` directory is a database of Horos, which is another
/// application. Opening it here upgrades it to this application's model, which
/// Horos may then refuse or rebuild, and the two applications working on one
/// database can damage it. Found in a folder, it is therefore opened only by an
/// installation that already used it or by a user who chose it and confirmed;
/// anywhere else a new database is created beside it and it is left as it was.
@objc(HorosDatabaseLocation)
public final class DatabaseLocation: NSObject {

    /// The directory a database's files live in, inside the chosen folder.
    /// This is the name a new database gets.
    @objc public static let dataDirectoryName = "IsiX Data"
    /// The names a new database's directory got in earlier versions of this
    /// application, newest first. A database made then keeps its name: it is
    /// opened where it is, never renamed or copied.
    @objc public static let previousDataDirectoryNames = [
        "IsiX DICOM Viewer Data", "Isis DICOM Viewer Data",
    ]
    /// The data directory Horos gives its database.
    @objc public static let horosDataDirectoryName = "Horos Data"
    /// The `Horos Data` directories this installation opens as its own: the
    /// ones it was already using when it stopped opening them by name, and the
    /// ones the user chose and confirmed since. The key's presence also says
    /// that the first of those was recorded.
    @objc public static let adoptedHorosDirectoriesKey = "AdoptedHorosDataDirectories"

    /// Whether `name` is a database directory's: this application's, current or
    /// previous, or Horos's. Recognising one is not opening it.
    @objc(isDataDirectoryName:)
    public class func isDataDirectoryName(_ name: String?) -> Bool {
        guard let name = name else { return false }
        return isOwnDataDirectoryName(name) || name == horosDataDirectoryName
    }

    /// Whether `name` is this application's data directory, current or previous.
    @objc(isOwnDataDirectoryName:)
    public class func isOwnDataDirectoryName(_ name: String?) -> Bool {
        guard let name = name else { return false }
        return name == dataDirectoryName || previousDataDirectoryNames.contains(name)
    }

    /// The data directory `folder` holds, under any of its names, or `nil`.
    /// With several there, the first with an index is the database, in the
    /// order current name, then earlier names from newest to oldest, then
    /// `Horos Data` if this installation adopted it; with no index in any, that
    /// order alone decides.
    @objc(existingDataDirectoryInFolder:)
    public class func existingDataDirectory(inFolder folder: String?) -> String? {
        let adopted = adoptedHorosDirectories()
        return existingDataDirectory(inFolder: folder, horosDataAdopted: { isAdopted($0, in: adopted) })
    }

    class func existingDataDirectory(inFolder folder: String?, horosDataAdopted: (String) -> Bool) -> String? {
        guard let folder = folder else { return nil }
        let horos = (folder as NSString).appendingPathComponent(horosDataDirectoryName)
        let candidates = ([dataDirectoryName] + previousDataDirectoryNames)
            .map { (folder as NSString).appendingPathComponent($0) }
            .filter { isDirectory($0) }
            + (isDirectory(horos) && horosDataAdopted(horos) ? [horos] : [])
        return candidates.first { pathHoldsExistingDatabase($0) } ?? candidates.first
    }

    // MARK: Horos databases

    /// The adopted `Horos Data` directories, as recorded in `defaults`.
    class func adoptedHorosDirectories(_ defaults: UserDefaults = .standard) -> [String] {
        return defaults.stringArray(forKey: adoptedHorosDirectoriesKey) ?? []
    }

    class func isAdopted(_ path: String, in adopted: [String]) -> Bool {
        let standard = standardized(path)
        return adopted.contains { standardized($0) == standard }
    }

    /// From now on, `directory` is opened as this installation's database.
    @objc(adoptHorosDirectory:)
    public class func adoptHorosDirectory(_ directory: String) {
        adoptHorosDirectory(directory, defaults: .standard)
    }

    class func adoptHorosDirectory(_ directory: String, defaults: UserDefaults) {
        var adopted = adoptedHorosDirectories(defaults)
        guard !isAdopted(directory, in: adopted) else { return }
        adopted.append(standardized(directory))
        defaults.set(adopted, forKey: adoptedHorosDirectoriesKey)
        NSLog("Database: %@ is opened as this installation's database, as the user confirmed", directory)
    }

    /// The Horos database a path the user chose would open, when this
    /// installation has not adopted it, or `nil`. The caller asks before opening.
    @objc(horosDataDirectoryForChosenPath:)
    public class func horosDataDirectory(forChosenPath path: String?) -> String? {
        return horosDataDirectory(forChosenPath: path, adopted: adoptedHorosDirectories())
    }

    class func horosDataDirectory(forChosenPath path: String?, adopted: [String]) -> String? {
        guard let resolved = baseDirectory(forPath: path, horosDataAdopted: { _ in true }),
              (resolved as NSString).lastPathComponent == horosDataDirectoryName,
              isDirectory(resolved), !isAdopted(resolved, in: adopted) else { return nil }
        return resolved
    }

    /// The `Horos Data` directories an installation that was already running
    /// opens today: its database location and its local sources, resolved the
    /// way earlier versions resolved them.
    static func horosDirectoriesInUse(locationMode: Int, locationURL: String?,
                                      sourcePaths: [String], documents: String) -> [String] {
        let location = locationMode == 1 ? locationURL : documents
        var found: [String] = []
        for path in [location] + sourcePaths.map({ Optional($0) }) {
            guard let path, !path.isEmpty,
                  let resolved = baseDirectory(forPath: path, horosDataAdopted: { _ in true }),
                  (resolved as NSString).lastPathComponent == horosDataDirectoryName,
                  !isAdopted(resolved, in: found) else { continue }
            found.append(standardized(resolved))
        }
        return found
    }

    /// Records, once, which `Horos Data` directories this installation keeps
    /// opening. An installation that existed before - its preferences were not
    /// empty when this version first started - keeps the database it was using,
    /// even one in `Horos Data`. A new installation adopts none, so it creates
    /// a database of its own beside any it finds.
    @objc(recordHorosDirectoriesInUseForExistingInstallation:)
    public class func recordHorosDirectoriesInUse(existingInstallation: Bool) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        recordHorosDirectoriesInUse(existingInstallation: existingInstallation, defaults: .standard, documents: documents)
    }

    static func recordHorosDirectoriesInUse(existingInstallation: Bool, defaults: UserDefaults, documents: String) {
        guard defaults.object(forKey: adoptedHorosDirectoriesKey) == nil else { return }
        var inUse: [String] = []
        if existingInstallation {
            let sources = (defaults.array(forKey: "localDatabasePaths") ?? [])
                .compactMap { ($0 as? [String: Any])?["Path"] as? String }
            inUse = horosDirectoriesInUse(locationMode: defaults.integer(forKey: "DEFAULT_DATABASELOCATION"),
                                          locationURL: defaults.string(forKey: "DEFAULT_DATABASELOCATIONURL"),
                                          sourcePaths: sources, documents: documents)
        }
        defaults.set(inUse, forKey: adoptedHorosDirectoriesKey)
        NSLog("Database: %@ installation; Horos databases kept in use: %@",
              existingInstallation ? "existing" : "new", inUse.isEmpty ? "none" : inUse.joined(separator: ", "))
    }

    /// Whether `path`, as a database location or a local source, names a
    /// database of this application: a folder holding one of its data
    /// directories, or one of those directories. Anything else Horos listed is
    /// a place where Horos keeps, or would create, a database of its own.
    static func namesOwnDatabase(_ path: String) -> Bool {
        guard let resolved = baseDirectory(forPath: path, horosDataAdopted: { _ in false }) else { return false }
        return isOwnDataDirectoryName((resolved as NSString).lastPathComponent) && isDirectory(resolved)
    }

    /// The folder File > Import takes to bring the studies of the database in
    /// `directory` over: its `DATABASE.noindex`, where `DBFOLDER_LOCATION` says
    /// the images are when they are kept elsewhere.
    @objc(importFolderForDataDirectory:)
    public class func importFolder(forDataDirectory directory: String) -> String {
        let pointer = (directory as NSString).appendingPathComponent("DBFOLDER_LOCATION")
        let elsewhere = (try? String(contentsOfFile: pointer, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (elsewhere?.isEmpty == false ? elsewhere! : directory)
        return (base as NSString).appendingPathComponent("DATABASE.noindex")
    }
    /// The index, which is what makes a directory recognisable as a database.
    @objc public static let indexFileName = "Database.sql"

    /// `nil` in, `nil` out: the caller asks with the location it has, and it has
    /// none when the volume that location names is not mounted.
    @objc(baseDirectoryForPath:)
    public class func baseDirectory(forPath path: String?) -> String? {
        let adopted = adoptedHorosDirectories()
        return baseDirectory(forPath: path, horosDataAdopted: { isAdopted($0, in: adopted) })
    }

    class func baseDirectory(forPath path: String?, horosDataAdopted: (String) -> Bool) -> String? {
        guard var path = path else { return nil }

        // A path inside a data directory belongs to that directory. This is
        // what resolves the index file, and any file below it, when the
        // directory still carries its name. A path that names `Horos Data`
        // itself was chosen as it is, so it is not a folder holding one.
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
        if let existing = existingDataDirectory(inFolder: path, horosDataAdopted: horosDataAdopted) {
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

    private class func standardized(_ path: String) -> String {
        return ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
    }

    private class func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        return exists && directory.boolValue
    }
}
