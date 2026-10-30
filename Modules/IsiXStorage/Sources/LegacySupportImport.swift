//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CryptoKit
import Darwin
import Foundation

/// Copies what earlier versions kept in `Application Support/Horos` into the
/// app's own folder, when the user asks for it.
///
/// Horos uses the same folder, so nothing in it is assumed to belong to this
/// app: the app offers the import and the user decides. The import only reads
/// the old folder. It never renames, moves or deletes anything in it, never
/// replaces anything already in the new folder, and never copies plugins.
///
/// Each item is copied into a staging folder inside the new folder, checked
/// against the original (every file's SHA-256, or SQLite's integrity check for
/// a database, copied with SQLite's backup so that its write-ahead log is
/// included), and only then renamed into place with a rename that fails when
/// the destination exists. Its state is written to `stateFileName` before and
/// after that rename, and the import is recorded complete only once every item
/// is either imported, absent or kept as the user already had it.
///
/// A run that stops at any point - the app quits, a file cannot be read, the
/// disk is full - leaves the originals as they were and at most a staging
/// folder of its own, which the next run discards before copying again.
/// Running again after success changes nothing.
public struct LegacySupportImport: Sendable {
    public enum Kind: String, Sendable, Codable {
        case folder
        case sqliteDatabase
    }

    /// Something to import, by its name in both folders.
    public struct Item: Sendable, Hashable {
        public let name: String
        public let kind: Kind

        public init(name: String, kind: Kind) {
            self.name = name
            self.kind = kind
        }

        /// The Web Portal's accounts and their settings.
        public static let webPortalAccounts = Item(name: "WebUsers.sql", kind: .sqliteDatabase)
        /// The user's customized Web Portal pages.
        public static let customWebPages = Item(name: "WebServicesHTML", kind: .folder)
        /// The user's Weasis customization.
        public static let weasis = Item(name: "Weasis", kind: .folder)

        /// What the app imports. The accounts only when the Web Portal reads
        /// them from the support folder, not from a configured path.
        public static func standard(includingAccounts: Bool) -> [Item] {
            (includingAccounts ? [webPortalAccounts] : []) + [customWebPages, weasis]
        }
    }

    public enum Status: Sendable, Equatable {
        /// Not in the old folder: nothing to import.
        case sourceAbsent
        /// In the old folder and not yet in the new one.
        case pending
        /// Copied by an import, or already the same in both folders.
        case imported
        /// In both folders with different contents. The new folder's is kept
        /// and the old one is not merged into it.
        case conflict
        /// A conflict the user has been told about; the new folder's is kept.
        case keptExisting
        /// This run could not copy it; the next one tries again.
        case failed(String)
    }

    public struct Entry: Sendable, Equatable {
        public let item: Item
        public let status: Status
        public let source: URL
        public let destination: URL
    }

    /// The import's own record, in the new folder.
    public static let stateFileName = ".ImportFromHoros.json"
    /// Where items are copied and checked before they are renamed into place.
    public static let stagingFolderName = ".ImportFromHoros-staging"

    public let source: URL
    public let destination: URL
    public let items: [Item]

    /// Where a test stops the run, as if the process had ended there.
    enum Moment: Sendable { case staged, renamed }
    var stopsAt: (@Sendable (Item, Moment) -> Bool)? = nil

    public init(source: URL, destination: URL, items: [Item]) {
        self.source = source.standardizedFileURL
        self.destination = destination.standardizedFileURL
        self.items = items
    }

    /// The import between the old and the new support folders of a domain.
    public init(userDomain: String, items: [Item]) {
        self.init(source: URL(fileURLWithPath: StorageLocations.legacySupportFolder(inDomain: userDomain), isDirectory: true),
                  destination: URL(fileURLWithPath: StorageLocations.supportFolder(for: .direct, inDomain: userDomain), isDirectory: true),
                  items: items)
    }

    // MARK: state

    struct State: Codable, Equatable {
        enum ItemState: String, Codable { case committing, imported, keptExisting }
        struct ItemRecord: Codable, Equatable {
            var state: ItemState
            var digest: String?
        }
        var items: [String: ItemRecord] = [:]
        var declined: Date?
        var completed: Date?
    }

    private var stateURL: URL { destination.appendingPathComponent(Self.stateFileName) }
    private var stagingURL: URL { destination.appendingPathComponent(Self.stagingFolderName, isDirectory: true) }

    func readState() -> State {
        guard let data = try? Data(contentsOf: stateURL) else { return State() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(State.self, from: data)) ?? State()
    }

    private func write(_ state: State) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    /// Whether the user declined the import or it is complete: either way the
    /// app does not offer it again.
    public var isSettled: Bool {
        let state = readState()
        return state.declined != nil || state.completed != nil
    }

    /// Whether the import completed.
    public var isComplete: Bool { readState().completed != nil }

    /// Records that the user does not want the import. Nothing is copied.
    public func decline() throws {
        var state = readState()
        state.declined = Date()
        try write(state)
    }

    // MARK: survey

    /// Where each item stands, without copying or writing anything.
    public func survey() -> [Entry] {
        let state = readState()
        return items.map { entry(for: $0, status: status(of: $0, state: state)) }
    }

    private func entry(for item: Item, status: Status) -> Entry {
        Entry(item: item, status: status, source: source.appendingPathComponent(item.name),
              destination: destination.appendingPathComponent(item.name))
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func status(of item: Item, state: State) -> Status {
        let from = source.appendingPathComponent(item.name), to = destination.appendingPathComponent(item.name)
        if let record = state.items[item.name] {
            switch record.state {
            case .imported: return .imported
            case .keptExisting: return .keptExisting
            case .committing:
                // Stopped between the rename and its record: the destination is
                // the checked copy if it still has the digest written before.
                if exists(to), let digest = record.digest, (try? Self.digest(of: to)) == digest { return .imported }
            }
        }
        guard exists(from) else { return .sourceAbsent }
        guard exists(to) else { return .pending }
        if let left = try? Self.digest(of: from), let right = try? Self.digest(of: to), left == right,
           !(item.kind == .sqliteDatabase && exists(URL(fileURLWithPath: from.path + "-wal"))) {
            return .imported
        }
        return .conflict
    }

    // MARK: run

    /// Copies every pending item and records what became of each.
    @discardableResult
    public func run() -> [Entry] {
        var state = readState()
        var results: [Entry] = []
        // What an earlier run left in staging is its own unfinished copy.
        if exists(stagingURL) { try? FileManager.default.removeItem(at: stagingURL) }
        for item in items {
            let current = status(of: item, state: state)
            switch current {
            case .imported:
                if state.items[item.name]?.state != .imported {
                    state.items[item.name] = .init(state: .imported, digest: state.items[item.name]?.digest)
                    try? write(state)
                }
                results.append(entry(for: item, status: .imported))
            case .pending:
                switch copy(item, state: &state) {
                case .stopped: return results
                case .finished(let status): results.append(entry(for: item, status: status))
                }
            default:
                results.append(entry(for: item, status: current))
            }
        }
        complete(&state, results)
        return results
    }

    /// Records the conflicts the user has been shown: the new folder's items
    /// are kept, and the import does not offer them again.
    public func keepExisting(_ conflicts: [Entry]) throws {
        var state = readState()
        for entry in conflicts where entry.status == .conflict {
            state.items[entry.item.name] = .init(state: .keptExisting, digest: nil)
        }
        try write(state)
        complete(&state, survey())
    }

    private func complete(_ state: inout State, _ entries: [Entry]) {
        let settled = entries.count == items.count && entries.allSatisfy {
            [.sourceAbsent, .imported, .keptExisting].contains($0.status)
        }
        guard settled, state.completed == nil else { return }
        // With nothing anywhere, the new folder is not made just to say so.
        if entries.allSatisfy({ $0.status == .sourceAbsent }) && !exists(destination) { return }
        state.completed = Date()
        try? write(state)
    }

    private enum Outcome { case finished(Status), stopped }

    private func copy(_ item: Item, state: inout State) -> Outcome {
        let from = source.appendingPathComponent(item.name), to = destination.appendingPathComponent(item.name)
        let staged = stagingURL.appendingPathComponent(item.name)
        let files = FileManager.default
        do {
            try files.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            switch item.kind {
            case .folder:
                try files.copyItem(at: from, to: staged)
                guard try Self.digest(of: staged) == Self.digest(of: from) else {
                    throw SQLiteSnapshot.Failure(description: "the copy differs from the original, which may have changed while it was copied")
                }
            case .sqliteDatabase:
                try SQLiteSnapshot.copy(from: from, to: staged)
                try SQLiteSnapshot.validate(staged, against: from)
            }
            if stopsAt?(item, .staged) == true { return .stopped }
            state.items[item.name] = .init(state: .committing, digest: try Self.digest(of: staged))
            try write(state)
            guard renamex_np(staged.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
                let error = errno
                try? files.removeItem(at: staged)
                state.items[item.name] = nil
                try? write(state)
                if error == EEXIST { return .finished(.conflict) }
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
            if stopsAt?(item, .renamed) == true { return .stopped }
            state.items[item.name]?.state = .imported
            try write(state)
            try? files.removeItem(at: stagingURL)
            return .finished(.imported)
        } catch {
            try? files.removeItem(at: staged)
            try? files.removeItem(at: stagingURL)
            return .finished(.failed(Self.describe(error)))
        }
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? SQLiteSnapshot.Failure { return failure.description }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.localizedDescription ?? error.localizedDescription
    }

    // MARK: digests

    /// A SHA-256 of a file, or of a folder: every entry's relative path and
    /// kind, and each file's contents or link's target, in order of path.
    static func digest(of url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var hash = SHA256()
        if (info.st_mode & S_IFMT) == S_IFDIR {
            for relative in try entries(in: url.path, prefix: "").sorted() {
                hash.update(data: Data(relative.utf8))
                try update(&hash, with: url.appendingPathComponent(relative))
            }
        } else {
            try update(&hash, with: url)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Every entry under a folder, relative to it. A folder that cannot be
    /// read is an error, not an empty folder.
    private static func entries(in folder: String, prefix: String) throws -> [String] {
        var found: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder) {
            let relative = prefix + name, path = (folder as NSString).appendingPathComponent(name)
            found.append(relative)
            var info = stat()
            if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
                found += try entries(in: path, prefix: relative + "/")
            }
        }
        return found
    }

    private static func update(_ hash: inout SHA256, with url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            hash.update(data: Data("d".utf8))
        case S_IFLNK:
            hash.update(data: Data(("l" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))).utf8))
        default:
            hash.update(data: Data("f".utf8))
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hash.update(data: chunk)
            }
        }
    }
}
