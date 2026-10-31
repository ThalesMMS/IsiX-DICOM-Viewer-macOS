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

/// The addition to the database that plugins built for Horos and OsiriX make
/// after writing their files: JPEG to DICOM, for one, writes each image with
/// DICOMExport into the database folder and then sends
/// +[BrowserController addFiles:toContext:toDatabase:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:generatedByOsiriX:].
/// Those plugins are not rebuilt and look the method up by that selector, which
/// BrowserController keeps as a forwarder to this type.
///
/// The files go through the single entry, as a plugin's, with the options the
/// caller passed and without marking them as imported, as the selector did:
/// into the database of the context, else of the browser, else of the folder.
@MainActor
enum LegacyPluginIngest {
    static func add(_ files: [Any]?, context: NSManagedObjectContext?, browser: BrowserController?, folder: String?,
                    onlyDICOM: Bool, notify: Bool, reread: Bool, generatedByOsiriX: Bool) -> [Any]? {
        guard let database = context.flatMap({ DicomDatabase(for: $0) }) ?? browser?.database
                ?? folder.flatMap({ DicomDatabase(atPath: $0) }) else { return nil }
        let options = IngestOptions(postNotifications: notify, dicomOnly: onlyDICOM ? .always : .never, rereadExistingItems: reread,
                                    generatedByOsiriX: generatedByOsiriX, importedFiles: false, returnArray: true)
        let preset = IngestPreset(name: "legacyPluginAddFiles", source: .plugin, options: options)
        return database.objects(withIDs: DatabaseIngest.process.index(files, preset: preset, in: database))
    }
}
