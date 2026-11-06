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

/// Where a DICOM comes in from.
public enum IngestSource: String, CaseIterable, Hashable, Sendable {
    /// What the scan of the incoming folder takes, whoever left it there.
    case incoming
    /// A C-STORE received by the listener.
    case listener
    /// What a C-MOVE or a C-GET brought.
    case retrieve
    case dicomweb
    case wado
    /// A medium: its scan, its DICOMDIR and the copy of its files.
    case media
    case dragAndDrop
    /// What the decompression helper could not hand back to the incoming folder.
    case decompress
    case url
    /// An upload to the web portal.
    case upload
    /// What a client of the shared database sent.
    case sharedDatabase
    /// A copy between two sources of the browser.
    case sourceCopy
    case plugin
    /// Objects the application made: exports, ROIs, reports, key images.
    case generated
    /// Files a change rewrote: anonymization and Modify DICOM.
    case modify
    case rebuild
}

/// Whether an import takes only DICOM files.
public enum IngestDicomOnly: Hashable, Sendable {
    case always
    case never
    /// As the "onlyDICOM" preference says when the import runs.
    case preference

    public func resolved(preference: Bool) -> Bool {
        switch self {
        case .always: return true
        case .never: return false
        case .preference: return preference
        }
    }
}

/// The six options of an addition to the index.
///
/// They decide what is stored and who hears of it: `importedFiles` and
/// `generatedByOsiriX` are stored in each image, `generatedByOsiriX` also keeps
/// the file's comments, state and key frames out of the database and silences
/// the notice of new images, `postNotifications` and `rereadExistingItems`
/// decide the notifications and the autorouting, and `returnArray` both.
public struct IngestOptions: Hashable, Sendable {
    public let postNotifications: Bool
    public let dicomOnly: IngestDicomOnly
    public let rereadExistingItems: Bool
    public let generatedByOsiriX: Bool
    public let importedFiles: Bool
    public let returnArray: Bool

    public init(postNotifications: Bool, dicomOnly: IngestDicomOnly, rereadExistingItems: Bool,
                generatedByOsiriX: Bool, importedFiles: Bool, returnArray: Bool) {
        self.postNotifications = postNotifications
        self.dicomOnly = dicomOnly
        self.rereadExistingItems = rereadExistingItems
        self.generatedByOsiriX = generatedByOsiriX
        self.importedFiles = importedFiles
        self.returnArray = returnArray
    }
}

/// The options of one way into the database, with its name.
///
/// Each preset says what its path does today, written out in full even when it
/// matches another: unifying two of them would change what is stored, or who is
/// told, for one of the paths. The transports that leave their files in the
/// incoming folder have a preset of their own because they name who published
/// a file; those files are indexed by the scan, with the scan's options.
public struct IngestPreset: Hashable, Sendable {
    public let name: String
    public let source: IngestSource
    public let options: IngestOptions

    public init(name: String, source: IngestSource, options: IngestOptions) {
        self.name = name
        self.source = source
        self.options = options
    }

    /// The scan of the incoming folder.
    public static let incoming = preset("incoming", .incoming, post: true, dicomOnly: .preference, reread: false, generated: false, imported: false, returned: true)
    public static let listener = preset("listener", .listener, post: true, dicomOnly: .preference, reread: false, generated: false, imported: false, returned: true)
    public static let retrieve = preset("retrieve", .retrieve, post: true, dicomOnly: .preference, reread: false, generated: false, imported: false, returned: true)
    public static let dicomweb = preset("dicomweb", .dicomweb, post: true, dicomOnly: .preference, reread: false, generated: false, imported: false, returned: true)
    public static let wado = preset("wado", .wado, post: true, dicomOnly: .preference, reread: false, generated: false, imported: false, returned: true)
    /// The files a medium's scan finds, indexed where they are.
    public static let mediaScan = preset("mediaScan", .media, post: false, dicomOnly: .never, reread: false, generated: false, imported: true, returned: true)
    /// The files a medium's DICOMDIR describes; they are not read, so `dicomOnly` decides nothing.
    public static let mediaDicomdir = preset("mediaDicomdir", .media, post: false, dicomOnly: .never, reread: false, generated: false, imported: false, returned: true)
    /// The files of a medium or a folder copied into the database, of a request that takes only DICOM.
    public static let mediaCopyDICOM = preset("mediaCopyDICOM", .media, post: true, dicomOnly: .always, reread: true, generated: false, imported: true, returned: true)
    /// The same copy, of a request that takes what the database can read.
    public static let mediaCopyAnything = preset("mediaCopyAnything", .media, post: true, dicomOnly: .never, reread: true, generated: false, imported: true, returned: true)
    /// What is dropped on the database or opened: the copy above, told what to take by the preference at the drop.
    public static let dragAndDropDICOM = preset("dragAndDropDICOM", .dragAndDrop, post: true, dicomOnly: .always, reread: true, generated: false, imported: true, returned: true)
    public static let dragAndDropAnything = preset("dragAndDropAnything", .dragAndDrop, post: true, dicomOnly: .never, reread: true, generated: false, imported: true, returned: true)
    /// What conversion could not put back in the incoming folder.
    public static let decompress = preset("decompress", .decompress, post: true, dicomOnly: .always, reread: false, generated: false, imported: false, returned: true)
    public static let url = preset("url", .url, post: true, dicomOnly: .preference, reread: false, generated: false, imported: false, returned: true)
    public static let upload = preset("upload", .upload, post: true, dicomOnly: .always, reread: true, generated: true, imported: true, returned: false)
    /// SEND of the shared database: what a client received.
    public static let sharedDatabaseReceived = preset("sharedDatabaseReceived", .sharedDatabase, post: true, dicomOnly: .never, reread: true, generated: false, imported: false, returned: true)
    /// SENDG of the shared database: what a client's viewer made.
    public static let sharedDatabaseGenerated = preset("sharedDatabaseGenerated", .sharedDatabase, post: true, dicomOnly: .never, reread: true, generated: true, imported: false, returned: true)
    /// The batches of a long copy between sources.
    public static let sourceCopyBatch = preset("sourceCopyBatch", .sourceCopy, post: true, dicomOnly: .preference, reread: false, generated: false, imported: true, returned: false)
    /// The last batch of that copy, and the copy to a local source, which mark nothing as imported.
    public static let sourceCopy = preset("sourceCopy", .sourceCopy, post: true, dicomOnly: .preference, reread: false, generated: false, imported: false, returned: true)
    public static let plugin = preset("plugin", .plugin, post: true, dicomOnly: .always, reread: true, generated: true, imported: true, returned: true)
    /// Objects the application made, with their notifications.
    public static let generated = preset("generated", .generated, post: true, dicomOnly: .always, reread: true, generated: true, imported: false, returned: true)
    /// The same objects when more follow, or when nobody is to hear of them.
    public static let generatedQuiet = preset("generatedQuiet", .generated, post: false, dicomOnly: .always, reread: true, generated: true, imported: false, returned: true)
    /// The records of a surgical procedure, which keep the comments of their files.
    public static let surgicalRecords = preset("surgicalRecords", .generated, post: true, dicomOnly: .always, reread: true, generated: false, imported: false, returned: true)
    public static let anonymization = preset("anonymization", .modify, post: true, dicomOnly: .always, reread: true, generated: true, imported: false, returned: true)
    /// Files rewritten by Modify DICOM, which stay the patient's own.
    public static let modify = preset("modify", .modify, post: true, dicomOnly: .always, reread: true, generated: false, imported: false, returned: true)
    public static let rebuild = preset("rebuild", .rebuild, post: false, dicomOnly: .preference, reread: false, generated: false, imported: false, returned: false)

    public static let all: [IngestPreset] = [
        incoming, listener, retrieve, dicomweb, wado, mediaScan, mediaDicomdir, mediaCopyDICOM, mediaCopyAnything,
        dragAndDropDICOM, dragAndDropAnything, decompress, url, upload, sharedDatabaseReceived, sharedDatabaseGenerated,
        sourceCopyBatch, sourceCopy, plugin, generated, generatedQuiet, surgicalRecords, anonymization, modify, rebuild,
    ]

    private static func preset(_ name: String, _ source: IngestSource, post: Bool, dicomOnly: IngestDicomOnly, reread: Bool,
                               generated: Bool, imported: Bool, returned: Bool) -> IngestPreset {
        IngestPreset(name: name, source: source,
                     options: IngestOptions(postNotifications: post, dicomOnly: dicomOnly, rereadExistingItems: reread,
                                            generatedByOsiriX: generated, importedFiles: imported, returnArray: returned))
    }
}

/// The folder a database admits files from, read once: a retrieve keeps
/// publishing into the database it started with, whatever the browser shows.
public struct IngestFolder: Hashable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// A path inside the folder that the scan does not take: it skips what
    /// starts with a dot, and everything inside such a folder.
    public func hiddenPath(named name: String) -> String {
        (path as NSString).appendingPathComponent("." + name)
    }

    public func path(named name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }
}

/// A file being written into the folder under a hidden name, which publishing
/// takes away: until then the scan does not see it, and it can be checked or
/// discarded.
public struct IngestDraft: Hashable, Sendable {
    public let folder: IngestFolder
    /// The name it will have once published.
    public let name: String

    public init(folder: IngestFolder, name: String) {
        self.folder = folder
        self.name = name
    }

    /// Where the file is written.
    public var path: String { folder.hiddenPath(named: name) }
}

/// What publishing a file came to.
public struct IngestPublication: Hashable, Sendable {
    /// 0 when the file is in the folder, or the errno of the rename.
    public let errorNumber: Int32
    public let folder: IngestFolder

    public init(errorNumber: Int32, folder: IngestFolder) {
        self.errorNumber = errorNumber
        self.folder = folder
    }

    public var succeeded: Bool { errorNumber == 0 }
}

/// The single entry of every DICOM that comes in.
///
/// Three capabilities: publish a file, so that the import takes it; index
/// files now, on the calling thread and in the caller's context; and ask for
/// the import of what is queued in the folder, or say whether one is under way.
public protocol DICOMIngesting: Sendable {
    /// The folder of the database files are published to now.
    func admissionFolder() -> IngestFolder

    /// Moves a complete file into `folder` in one step of the volume: it is
    /// there under `name`, whole, or it is not there, before this returns.
    func publish(fileAt path: String, named name: String, into folder: IngestFolder, preset: IngestPreset) -> IngestPublication

    /// Publishes a file written as a draft.
    func publish(_ draft: IngestDraft, preset: IngestPreset) -> IngestPublication

    /// Throws away a draft that turned out not to be what was expected.
    func discard(_ draft: IngestDraft)

    /// Indexes `paths` now and returns how many images they added, or nil when
    /// the addition could not run.
    func index(_ paths: [String], preset: IngestPreset) -> Int?

    /// Asks for a pass over the queue and returns without waiting for it.
    func requestImport()

    /// Imports what is queued now, on the calling thread, and returns how many images it added.
    func importQueueNow() -> Int

    /// Whether files are being imported or converted now. Never waits.
    var isImporting: Bool { get }
}

/// One database's passes over its queue, as `IngestScheduler` asks for them.
///
/// Sent from the scheduler's actor: nothing here but `runPass` may wait, and a
/// pass runs on a thread of its own, never on the actor.
public protocol IngestPassRunning: Sendable {
    /// What names the database. A database and its independent databases share it.
    var ingestIdentifier: String { get }

    /// Whether a pass may start now. Never waits.
    func isReadyForPass() -> Bool

    /// One pass over the queue. Returns when it has ended; cancelling the
    /// calling task cancels the pass.
    func runPass() async
}
