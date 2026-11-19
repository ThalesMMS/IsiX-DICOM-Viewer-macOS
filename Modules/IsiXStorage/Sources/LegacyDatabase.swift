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
import SQLite3

/// The data folder of an earlier application ("Horos Data", "OsiriX Data"),
/// read to import its studies.
///
/// Nothing in the folder is opened for writing, renamed, moved or deleted. Its
/// database is read through SQLite as a read-only file: as immutable when no
/// write-ahead log lies beside it, which creates no file and takes no lock,
/// and through the log when the earlier application has it open.
public struct LegacyDatabase: Sendable, Equatable {
    /// The names earlier applications gave their data folder.
    public static let folderNames = ["Horos Data", "OsiriX Data"]
    public static let storeName = "Database.sql"
    public static let imagesFolderName = "DATABASE.noindex"

    /// The data folder.
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public var store: URL { folder.appendingPathComponent(Self.storeName) }
    public var imagesFolder: URL { folder.appendingPathComponent(Self.imagesFolderName, isDirectory: true) }

    /// The data folder whose image folder is `imagesFolder`: the folder that
    /// holds it, when a database lies there beside it.
    public static func holding(imagesFolder: URL, fileManager: FileManager = .default) -> LegacyDatabase? {
        guard imagesFolder.lastPathComponent == imagesFolderName else { return nil }
        let database = LegacyDatabase(folder: imagesFolder.deletingLastPathComponent())
        return fileManager.fileExists(atPath: database.store.path) ? database : nil
    }

    /// The data folders of earlier applications in a documents folder.
    public static func found(inDocuments documents: URL, fileManager: FileManager = .default) -> [LegacyDatabase] {
        folderNames.map { LegacyDatabase(folder: documents.appendingPathComponent($0, isDirectory: true)) }
            .filter { fileManager.fileExists(atPath: $0.store.path) }
    }

    /// The data folder a chosen folder stands for: the folder itself when it
    /// holds a database, or the data folder of an earlier application inside
    /// it (the folder chosen as "database location" in its settings).
    public static func resolving(_ chosen: URL, fileManager: FileManager = .default) -> LegacyDatabase? {
        let direct = LegacyDatabase(folder: chosen)
        if fileManager.fileExists(atPath: direct.store.path) { return direct }
        return found(inDocuments: chosen, fileManager: fileManager).first
    }

    // MARK: - What the database lists

    /// What the earlier application recorded about a study, apart from what
    /// its files say.
    public struct Study: Sendable, Equatable {
        public let uid: String
        /// The four comment fields, empty when not written.
        public let comments: [String]
        /// The state chosen in the list; 0 when none.
        public let state: Int
        /// The names of the albums the study was put in.
        public let albums: [String]

        public init(uid: String, comments: [String] = ["", "", "", ""], state: Int = 0, albums: [String] = []) {
            self.uid = uid
            self.comments = comments
            self.state = state
            self.albums = albums
        }

        /// Whether there is anything to carry over.
        public var hasNotes: Bool { state != 0 || !albums.isEmpty || comments.contains { !$0.isEmpty } }

        /// The notes a study with these comments, this state and these albums lacks.
        public func notesMissing(comments current: [String], state currentState: Int, albums currentAlbums: Set<String>) -> MissingNotes {
            var fill: [Int: String] = [:]
            for (place, comment) in comments.enumerated() where !comment.isEmpty && (place >= current.count || current[place].isEmpty) {
                fill[place] = comment
            }
            return MissingNotes(comments: fill, state: state != 0 && currentState == 0 ? state : nil,
                                albums: albums.filter { !currentAlbums.contains($0) })
        }
    }

    public struct Album: Sendable, Equatable {
        public let name: String
        /// The rule of a smart album; nil for an album studies are put in.
        public let predicate: String?

        public init(name: String, predicate: String? = nil) {
            self.name = name
            self.predicate = predicate
        }
    }

    public struct Contents: Sendable, Equatable {
        public let studies: [Study]
        public let albums: [Album]
        public let imageCount: Int
        /// The files the database lists outside its own folder, which it
        /// referenced where they were.
        public let linkedFiles: [String]
        /// The files of its own folder the database lists; nil when its table
        /// of images does not record where they are.
        public let listedFiles: LegacyFileIndex?

        public init(studies: [Study], albums: [Album], imageCount: Int, linkedFiles: [String], listedFiles: LegacyFileIndex? = nil) {
            self.studies = studies
            self.albums = albums
            self.imageCount = imageCount
            self.linkedFiles = linkedFiles
            self.listedFiles = listedFiles
        }
    }

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String

        public init(description: String) {
            self.description = description
        }
    }

    /// What of a study's earlier notes the study in this database still
    /// lacks. A comment or a state already written here is kept: the notes
    /// only fill what is empty.
    public struct MissingNotes: Sendable, Equatable {
        /// The comment fields to fill, by their place (0 to 3).
        public let comments: [Int: String]
        public let state: Int?
        public let albums: [String]

        public var isEmpty: Bool { comments.isEmpty && state == nil && albums.isEmpty }
    }

    /// Reads the studies, the albums and the files listed outside the folder.
    /// A database without a table of studies is not one of these applications.
    public func contents() throws -> Contents {
        let handle = try Self.open(store)
        defer { sqlite3_close_v2(handle) }
        guard try !Self.rows(handle, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ZSTUDY'").isEmpty else {
            throw Failure(description: "\(store.lastPathComponent) has no studies table")
        }
        let studyColumns = try Self.columns(handle, of: "ZSTUDY")
        guard studyColumns.contains("ZSTUDYINSTANCEUID") else {
            throw Failure(description: "\(store.lastPathComponent) has no study identifiers")
        }

        // Albums, and the studies put in each. Core Data names the join table
        // and its columns after the entities' numbers, which differ by version.
        var albums: [Album] = [], names: [Int64: String] = [:], membership: [Int64: [String]] = [:]
        if try !Self.rows(handle, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ZALBUM'").isEmpty {
            let albumColumns = try Self.columns(handle, of: "ZALBUM")
            let smart = albumColumns.contains("ZSMARTALBUM") ? "ZSMARTALBUM" : "0"
            let predicate = albumColumns.contains("ZPREDICATESTRING") ? "ZPREDICATESTRING" : "NULL"
            let order = albumColumns.contains("ZINDEX") ? "ZINDEX, Z_PK" : "Z_PK"
            for row in try Self.rows(handle, "SELECT Z_PK, ZNAME, \(smart), \(predicate) FROM ZALBUM WHERE ZNAME IS NOT NULL ORDER BY \(order)") {
                guard let key = row[0].integer, let name = row[1].text, !name.isEmpty else { continue }
                let isSmart = (row[2].integer ?? 0) != 0
                albums.append(Album(name: name, predicate: isSmart ? (row[3].text ?? "") : nil))
                if !isSmart { names[key] = name }
            }
            let joins = try Self.rows(handle, "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z\\_%STUDIES' ESCAPE '\\'")
            if let join = joins.first?[0].text {
                let joinColumns = try Self.columns(handle, of: join)
                if let album = joinColumns.first(where: { $0.hasSuffix("ALBUMS") }), let study = joinColumns.first(where: { $0.hasSuffix("STUDIES") }) {
                    for row in try Self.rows(handle, "SELECT \(Self.quoted(study)), \(Self.quoted(album)) FROM \(Self.quoted(join))") {
                        guard let studyKey = row[0].integer, let albumKey = row[1].integer, let name = names[albumKey] else { continue }
                        membership[studyKey, default: []].append(name)
                    }
                }
            }
        }

        let comments = ["ZCOMMENT", "ZCOMMENT2", "ZCOMMENT3", "ZCOMMENT4"].map { studyColumns.contains($0) ? $0 : "NULL" }
        let state = studyColumns.contains("ZSTATETEXT") ? "ZSTATETEXT" : "0"
        var studies: [Study] = [], seen = Set<String>()
        for row in try Self.rows(handle, "SELECT Z_PK, ZSTUDYINSTANCEUID, \(state), \(comments.joined(separator: ", ")) FROM ZSTUDY ORDER BY Z_PK") {
            guard let key = row[0].integer, let uid = row[1].text, !uid.isEmpty, seen.insert(uid).inserted else { continue }
            studies.append(Study(uid: uid, comments: (3...6).map { row[$0].text ?? "" }, state: Int(row[2].integer ?? 0),
                                 albums: membership[key] ?? []))
        }

        var imageCount = 0, linked: [String] = [], listed: LegacyFileIndex?
        if try !Self.rows(handle, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ZIMAGE'").isEmpty {
            imageCount = Int(try Self.rows(handle, "SELECT COUNT(*) FROM ZIMAGE").first?[0].integer ?? 0)
            let imageColumns = try Self.columns(handle, of: "ZIMAGE")
            if imageColumns.contains("ZPATHSTRING") {
                // A file of the database's own folder is recorded by its number
                // or by a bare name; a path from the root is a file left where
                // it was. A multiframe file is listed once per frame.
                linked = try Self.rows(handle, "SELECT DISTINCT ZPATHSTRING FROM ZIMAGE WHERE ZPATHSTRING LIKE '/%' ORDER BY ZPATHSTRING")
                    .compactMap { $0[0].text }
                    .filter { !$0.hasPrefix(imagesFolder.path + "/") }
            }
            // Which files of the folder the rows record, one row at a time:
            // there is a row per image, and a database holds millions. A row
            // with both a number and a name records both files.
            let number = imageColumns.contains("ZPATHNUMBER") ? "ZPATHNUMBER" : nil
            let name = imageColumns.contains("ZPATHSTRING") ? "ZPATHSTRING" : nil
            if number != nil || name != nil {
                var index = LegacyFileIndex()
                let folders = Array(Set([imagesFolder.path, imagesFolder.resolvingSymlinksInPath().path]))
                try Self.each(handle, "SELECT \(number ?? "NULL"), \(name ?? "NULL") FROM ZIMAGE") { row in
                    if let value = row[0].integer { index.list(number: value) }
                    if let value = row[1].text { index.list(path: value, imagesFolders: folders) }
                }
                listed = index
            }
        }
        return Contents(studies: studies, albums: albums, imageCount: imageCount, linkedFiles: linked, listedFiles: listed)
    }

    // MARK: - Files

    /// The files to import and the bytes they take on disk, and the files of
    /// the image folder the database no longer lists, which are left out
    /// unless asked for. Each file is in one of the two lists.
    public struct Files: Sendable, Equatable {
        public let paths: [String]
        public let bytes: Int64
        public let unlisted: [String]
        public let unlistedBytes: Int64

        public init(paths: [String], bytes: Int64, unlisted: [String] = [], unlistedBytes: Int64 = 0) {
            self.paths = paths
            self.bytes = bytes
            self.unlisted = unlisted
            self.unlistedBytes = unlistedBytes
        }
    }

    /// The files of the database's image folder, hidden ones left out, and
    /// the files it lists elsewhere that are still there. With `listed`, the
    /// files of the folder it does not list are set apart; without it, which
    /// is when the database does not say, every file of the folder is to
    /// import. Nil when `isCancelled` answers true.
    public func files(linked: [String], listed: LegacyFileIndex? = nil, fileManager: FileManager = .default,
                      isCancelled: () -> Bool = { false }) -> Files? {
        var paths: [String] = [], bytes: Int64 = 0, unlisted: [String] = [], unlistedBytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        if let enumerator = fileManager.enumerator(at: imagesFolder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                                                   errorHandler: { _, _ in true }) {
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited % 512 == 0 && isCancelled() { return nil }
                guard let size = Self.size(of: url, keys: keys) else { continue }
                let path = url.path
                // A file is set apart only when the list is there and does
                // not have it. Its place in the folder is told by how deep the
                // walk is, whichever way the folder's own path is written.
                if let listed, !listed.lists(relativePath: url.pathComponents.suffix(enumerator.level).joined(separator: "/")) {
                    unlisted.append(path)
                    unlistedBytes += size
                } else {
                    paths.append(path)
                    bytes += size
                }
            }
        }
        for (index, path) in linked.enumerated() {
            if index % 512 == 0 && isCancelled() { return nil }
            guard let size = Self.size(of: URL(fileURLWithPath: path), keys: keys) else { continue }
            paths.append(path)
            bytes += size
        }
        return Files(paths: paths, bytes: bytes, unlisted: unlisted, unlistedBytes: unlistedBytes)
    }

    // MARK: - What to import

    /// What was read of a data folder, to import it.
    public struct Survey: Sendable, Equatable {
        /// Whether the database said which files of its folder it lists.
        public enum Listing: Sendable, Equatable {
            /// It did: the files it does not list are set apart.
            case read
            /// The database could not be read at all: nothing of it is
            /// known, and every file of the folder is to import.
            case unreadable(Failure)
            /// Its table of images does not record where the files are:
            /// every file of the folder is to import.
            case unknown
        }

        public let contents: Contents
        public let files: Files
        public let listing: Listing

        public init(contents: Contents, files: Files, listing: Listing) {
            self.contents = contents
            self.files = files
            self.listing = listing
        }
    }

    /// Reads the database and the image folder. A database that cannot be
    /// read, or that does not say where its files are, leaves no file out:
    /// a file is only set apart on the word of a list that was read. Nil
    /// when `isCancelled` answers true.
    public func survey(fileManager: FileManager = .default, isCancelled: () -> Bool = { false }) -> Survey? {
        var contents = Contents(studies: [], albums: [], imageCount: 0, linkedFiles: [])
        var listing = Survey.Listing.read
        do {
            contents = try self.contents()
            if contents.listedFiles == nil { listing = .unknown }
        } catch let failure as Failure {
            listing = .unreadable(failure)
        } catch {
            listing = .unreadable(Failure(description: error.localizedDescription))
        }
        guard let files = files(linked: contents.linkedFiles, listed: contents.listedFiles, fileManager: fileManager, isCancelled: isCancelled) else { return nil }
        return Survey(contents: contents, files: files, listing: listing)
    }

    /// The bytes free for the user's files on the volume of `folder`.
    public static func freeSpace(at folder: URL) -> Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// The bytes of a regular file on disk; nil for anything else.
    private static func size(of url: URL, keys: [URLResourceKey]) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }

    // MARK: - SQLite

    private enum Value {
        case null
        case integer(Int64)
        case text(String)

        var integer: Int64? {
            switch self {
            case .integer(let value): return value
            case .text(let value): return Int64(value)
            case .null: return nil
            }
        }

        var text: String? {
            switch self {
            case .text(let value): return value
            case .integer(let value): return String(value)
            case .null: return nil
            }
        }
    }

    private static func open(_ url: URL) throws -> OpaquePointer {
        let log = url.path + "-wal"
        let uri = url.absoluteString + (FileManager.default.fileExists(atPath: log) ? "?mode=ro" : "?immutable=1")
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard result == SQLITE_OK, let handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(result))
            sqlite3_close_v2(handle)
            throw Failure(description: "cannot open \(url.lastPathComponent): \(reason)")
        }
        sqlite3_busy_timeout(handle, 5000)
        return handle
    }

    private static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func columns(_ handle: OpaquePointer, of table: String) throws -> Set<String> {
        Set(try rows(handle, "PRAGMA table_info(\(quoted(table)))").compactMap { $0.count > 1 ? $0[1].text : nil })
    }

    private static func rows(_ handle: OpaquePointer, _ sql: String) throws -> [[Value]] {
        var rows: [[Value]] = []
        try each(handle, sql) { rows.append($0) }
        return rows
    }

    /// Hands each row of a query to `body` as it is read, none of them kept.
    private static func each(_ handle: OpaquePointer, _ sql: String, _ body: ([Value]) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(description: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure(description: String(cString: sqlite3_errmsg(handle))) }
            body((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL: return .null
                case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
                default: return sqlite3_column_text(statement, column).map { .text(String(cString: $0)) } ?? .null
                }
            })
        }
    }
}
