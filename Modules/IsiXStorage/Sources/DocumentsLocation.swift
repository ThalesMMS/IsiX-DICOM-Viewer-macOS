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

/// The folders of a local database: its documents directory (the folder the
/// user chose, which holds the index), and the folders inside its data folder,
/// such as the incoming folder the listener and the imports fill and the
/// temporary folder. The database and the former plugin API ask them here.
///
/// The data folder is usually the documents directory itself; a database
/// whose data was moved keeps it elsewhere. A user may have replaced a folder
/// of the data folder by a symbolic link or a Finder alias to another disk:
/// the paths given here follow them, as the database's own always did. The
/// value is computed from the two folders and may be made on any thread.
public struct DocumentsLocation: Sendable, Equatable {
    /// The folders of the data folder, by the names databases have on disk.
    public enum DataFolder: String, Sendable, CaseIterable {
        /// The images the database indexes.
        case images = "DATABASE.noindex"
        /// What the listener and the imports write into.
        case incoming = "INCOMING.noindex"
        case decompression = "DECOMPRESSION.noindex"
        case toBeIndexed = "TOBEINDEXED.noindex"
        /// The files of an operation in progress.
        case temporary = "TEMP.noindex"
        case dump = "DUMP"
        /// The files the import could not read, kept for inspection.
        case unreadable = "NOT READABLE"
        case reports = "REPORTS"
        case pages = "PAGES"
        case rois = "ROIs"
        case htmlTemplates = "HTML_TEMPLATES"
        case states3D = "3DSTATE"
        case colourTables = "CLUTs"
        case presets3D = "3DPRESETS"
    }

    /// The folder of the data folder the listener and the imports write into.
    public static let incomingFolderName = DataFolder.incoming.rawValue
    /// The folder of the data folder for the files of an operation in progress.
    public static let temporaryFolderName = DataFolder.temporary.rawValue

    /// The documents directory; nil when there is no database.
    public let documentsDirectory: String?
    /// The folder that holds the database's folders.
    public let dataDirectory: String?

    public init(documentsDirectory: String?, dataDirectory: String?) {
        self.documentsDirectory = documentsDirectory
        self.dataDirectory = dataDirectory
    }

    /// The incoming folder, through its links and aliases; nil without a
    /// data folder, for a relative one, or when a link cannot be followed.
    public var incomingDirectory: String? { path(of: .incoming) }

    /// The temporary folder, through its links and aliases; nil as for the
    /// incoming folder.
    public var temporaryDirectory: String? { path(of: .temporary) }

    /// `folder` of the data folder, through its links and aliases; nil as for
    /// the incoming folder.
    public func path(of folder: DataFolder) -> String? {
        guard let dataDirectory else { return nil }
        return ((dataDirectory as NSString).appendingPathComponent(folder.rawValue) as NSString).resolvingSymlinksAndAliases()
    }
}
