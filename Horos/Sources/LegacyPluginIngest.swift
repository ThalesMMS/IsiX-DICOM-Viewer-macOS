//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXContracts

/// What plugins built for Horos and OsiriX ask of the browser about the
/// database after writing their files: a path for a new file, the addition of
/// files to the index, and a pass over the incoming folder. JPEG to DICOM, for
/// one, writes each image with DICOMExport into the database folder and then
/// sends
/// +[BrowserController addFiles:toContext:toDatabase:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:generatedByOsiriX:].
/// Those plugins are not rebuilt and look the methods up by their selectors,
/// which BrowserController keeps as forwarders to this type.
///
/// A plugin sends them from any thread, so nothing here is of the main actor:
/// the database of a browser, the single entry and the allocator of data files
/// are asked from any thread. Without a database, as while the plugins load
/// before the browser has opened one, the answer is nil.
enum LegacyPluginIngest {
    /// The database a selector names: of the context, else, in the order the
    /// selector had, of the browser and of the folder.
    static func database(context: NSManagedObjectContext?, browser: BrowserController?, folder: String?,
                         browserFirst: Bool = true) -> DicomDatabase? {
        let ofFolder = { folder.flatMap { DicomDatabase(atPath: $0) } }
        if let database = context.flatMap({ DicomDatabase(for: $0) }) { return database }
        return browserFirst ? browser?.database ?? ofFolder() : ofFolder() ?? browser?.database
    }

    /// The files go through the single entry, as a plugin's, with the options
    /// the caller passed and without marking them as imported, as the
    /// selectors did; the objects of the images added are answered.
    static func add(_ files: [Any]?, to database: DicomDatabase?, dicomOnly: IngestDicomOnly, notify: Bool, reread: Bool,
                    generatedByOsiriX: Bool) -> [Any]? {
        guard let database else {
            NSLog("A plugin added files and no database was open to take them")
            return nil
        }
        let options = IngestOptions(postNotifications: notify, dicomOnly: dicomOnly, rereadExistingItems: reread,
                                    generatedByOsiriX: generatedByOsiriX, importedFiles: false, returnArray: true)
        let preset = IngestPreset(name: "legacyPluginAddFiles", source: .plugin, options: options)
        return database.objects(withIDs: DatabaseIngest.process.index(files, preset: preset, in: database))
    }

    /// A path in the data folder of `database` for a new file, which no other caller gets.
    static func newFilePath(extension fileExtension: String?, in database: DicomDatabase?) -> String? {
        database?.uniquePathForNewDataFile(withExtension: fileExtension)
    }

    /// A pass over the incoming folder of the local database in use: asked
    /// for, unless one is under way, or run before returning.
    static func checkIncoming(waiting: Bool) {
        guard let database = DicomDatabase.activeLocal() else { return }
        if waiting {
            DatabaseIngest.process.runPass(over: database)
        } else {
            DatabaseIngest.process.schedulePass(over: database)
        }
    }
}
