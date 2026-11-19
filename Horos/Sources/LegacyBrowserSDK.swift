//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreData
import Foundation
import IsiXContracts
import IsiXPreferences

/// What the selectors of the former Horos/OsiriX plug-in SDK on the database
/// window do, for those that are more than a forward: the window's class
/// keeps the selector, and the work is here.
enum LegacyBrowserSDK {
    /// The first object of `entity` whose `key` is `uid` in `database`, or nil.
    nonisolated static func object(ofEntity entity: NSEntityDescription?, where key: String, is uid: String?, in database: DicomDatabase?) -> NSManagedObject? {
        guard let database, let entity, let uid else { return nil }
        let found = database.objects(forEntity: entity, predicate: NSPredicate(format: "%K == %@", key, uid))
        return found?.first as? NSManagedObject
    }

    /// -decompressArrayOfFiles:work: 'C' compresses and 'D' decompresses
    /// in place, 'X' and 'I' do the same into the database's incoming folder.
    nonisolated static func transcode(_ paths: [Any]?, work: NSNumber?, in database: DicomDatabase?) {
        guard let database, let work else { return }
        // What a conversion makes for the database goes to its incoming folder, which the single entry of the database names.
        let admission = DatabaseIngest.process.incomingFolderPath(of: database)
        let mode: FileConversionMode, destination: String?
        switch UInt8(truncatingIfNeeded: work.int8Value) {
        case UInt8(ascii: "C"): (mode, destination) = (.compress, nil)
        case UInt8(ascii: "X"): (mode, destination) = (.compress, admission)
        case UInt8(ascii: "D"): (mode, destination) = (.decompress, nil)
        case UInt8(ascii: "I"): (mode, destination) = (.decompress, admission)
        default: return
        }
        // In chunks under the lock of the database, as the selector did; it answers nothing, so a failed chunk is not reported.
        try? DatabaseIngest.process.fileConverting(of: database).convertInChunks((paths ?? []).map { "\($0)" }, mode: mode, into: destination)
    }

    /// -compressDICOMJPEG: and -decompressDICOMJPEG: convert the files where
    /// they are, on the calling thread, through the database's conversion.
    nonisolated static func convert(_ paths: [Any]?, mode: FileConversionMode, in database: DicomDatabase?) {
        _ = DatabaseIngest.process.fileConverting(of: database).convertNow((paths ?? []).map { "\($0)" }, mode: mode, into: nil)
    }

    /// The studies the DICOM nodes find for a smart album, asked on the
    /// calling thread: none on a read-only or remote database or when the
    /// smart albums do not ask the nodes, nil without an activated entry.
    nonisolated static func distantStudies(forSmartAlbum album: String?, in database: DicomDatabase?) -> [Any]? {
        let graph = PreferencesSource.process.processGraph, preferences = graph.preferences
        guard let database, !database.isReadOnly, database.isLocal(),
              preferences[NetworkPreferences.searchesComparativeStudiesOnDICOMNodes],
              preferences[NetworkPreferences.searchesSmartAlbumStudiesOnDICOMNodes] else { return [] }
        guard let filters = graph.pacsOnDemand.smartAlbumFilters(album) else { return nil }
        return QueryController.queryStudies(forFilters: filters.mapValues { $0.object }, servers: BrowserController.comparativeServers(), showErrors: false) as? [Any]
    }

    /// A value of an object of the database shown: through the remote
    /// database when it is one, which sends the change to its server.
    nonisolated static func set(_ value: Any?, forKey key: String?, of object: NSManagedObject?, in database: DicomDatabase?) {
        guard let object, let key else { return }
        if let remote = database as? RemoteDicomDatabase {
            remote.object(object, setValue: value, forKey: key)
        } else {
            object.setValue(value, forKey: key)
        }
    }
}
