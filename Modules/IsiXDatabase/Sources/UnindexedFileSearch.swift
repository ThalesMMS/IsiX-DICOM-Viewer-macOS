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
import Darwin
import Foundation

/// Why a file of the data folder that the index does not have is not offered
/// for indexing. Each is counted and told, so that nothing is left out in
/// silence.
public enum UnindexedFileExclusion: String, CaseIterable, Hashable, Sendable {
    /// Changed within the quiet period: something may still be writing it,
    /// or an import has just moved it in and not saved the index yet.
    case recentlyChanged
    /// Open in a process: being written, or read by something that would
    /// see it change under it.
    case open
    /// Neither a DICOM Part 10 file nor a dataset that starts with a DICOM
    /// group. Indexing it would move it to the errors folder.
    case notDICOM
    /// Not where the index, given only its name, would find it: in a folder
    /// other than the one its number goes to, directly in the data folder, or
    /// a `.dcm` name that is not a number. Indexed in place, its image would
    /// point to a file that is not there.
    case misplaced
}

/// What the search makes of one file of a folder of the data folder.
public enum UnindexedFileVerdict: Equatable, Sendable {
    /// The index has it.
    case indexed
    /// Not in the index, and it can be indexed where it is.
    case unindexed
    /// Not in the index, and left alone for that reason.
    case excluded(UnindexedFileExclusion)
    /// Not a file the search considers: a hidden name, a folder, a link.
    case ignored
}

/// The rules of the search for files of the data folder that the index does
/// not have.
///
/// The data folder (`DATABASE.noindex`) holds numbered folders, and each holds
/// the files of the database. The index keeps the name of such a file only: a
/// `.dcm` file as the number of its name, any other as its name, and finds the
/// folder from that number, as `DataFileNumbering` places new files. So only
/// a file whose name says the folder it is in can be indexed there.
public enum UnindexedFileRules {
    /// How long a file must have been left unchanged before it is offered:
    /// the time after which the incoming folder takes an empty transfer as
    /// stopped. A rename does not change the modification date, so the change
    /// of the file's status, which a rename does change, counts too.
    public static let quietPeriod: TimeInterval = IncomingScanRules.stalledEmptyFileAge

    /// The folders of a database that are never searched, whatever folder
    /// holds them: the incoming folder, whose files the import takes, and the
    /// folder where the listener writes a file until it is complete.
    public static let skippedFolderNames: Set<String> = ["INCOMING.noindex", "TEMP.noindex"]

    /// Whether the search looks at the item called `name`. Hidden names, such
    /// as `.DS_Store` and the drafts of a publication, stay out, as in a rebuild.
    public static func considers(_ name: String) -> Bool {
        RebuildScan.includes(name) && !name.isEmpty
    }

    /// Whether the search goes into the folder called `name` of the data folder.
    public static func searchesFolder(named name: String) -> Bool {
        considers(name) && !skippedFolderNames.contains(name)
    }

    /// The path the index stores for a file called `name` of the data folder,
    /// as an image's path is set: a `.dcm` name becomes its number.
    public static func storedName(ofFileNamed name: String) -> String {
        if (name as NSString).pathExtension == "dcm" {
            return "\(((name as NSString).deletingPathExtension as NSString).intValue).dcm"
        }
        return name
    }

    /// The name of the folder of the data folder where the index looks for
    /// the file it stores as `storedName`: the next multiple of the folder
    /// size above the name's number. A folder size of 0 counts as 1.
    public static func folderName(forStoredName storedName: String, folderSize: Int) -> String {
        let size = max(folderSize, 1)
        let number = Int(((storedName as NSString).deletingPathExtension as NSString).intValue)
        return String((number / size + 1) * size)
    }

    /// Whether the file called `name`, in the folder called `folder` of the
    /// data folder, is where the index would find it.
    public static func isWhereTheIndexLooks(name: String, folder: String, folderSize: Int) -> Bool {
        let stored = storedName(ofFileNamed: name)
        return stored == name && folderName(forStoredName: stored, folderSize: folderSize) == folder
    }

    /// How many bytes of a file `looksLikeDICOM` reads.
    public static let headLength = 132

    /// Whether the first bytes of a file are DICOM: "DICM" after the 128-byte
    /// preamble, or, for a dataset written without one, the tag of an element
    /// of the file meta information (0002) or of the identification group
    /// (0008), little endian, at the start.
    public static func looksLikeDICOM(_ head: Data) -> Bool {
        let bytes = [UInt8](head.prefix(headLength))
        if bytes.count >= 132, bytes[128...131].elementsEqual(Array("DICM".utf8)) {
            return true
        }
        guard bytes.count >= 8 else { return false }
        return (bytes[0] == 0x02 || bytes[0] == 0x08) && bytes[1] == 0x00
    }

    /// Whether a file last changed at `lastChange` is still within the quiet
    /// period at `now`. A change dated after `now` counts as recent.
    public static func isRecentlyChanged(lastChange: Date, now: Date, quietPeriod: TimeInterval = quietPeriod) -> Bool {
        lastChange > now.addingTimeInterval(-quietPeriod)
    }

    /// The complete path of the file of an image of the index, from its
    /// stored attributes, or nil for an image with no path. An image in the
    /// database folder, which is what an image without the flag is, keeps a
    /// name, resolved as the data folder resolves it; an absolute path is
    /// where the file is, wherever that is.
    public static func indexedPath(pathNumber: Int?, pathString: String?, inDatabaseFolder: Bool?,
                                   dataFolder: String, folderSize: Int) -> String? {
        let stored: String
        if let pathNumber {
            stored = "\(Int32(truncatingIfNeeded: pathNumber)).dcm"
        } else if let pathString, !pathString.isEmpty {
            stored = pathString
        } else {
            return nil
        }
        if stored.hasPrefix("/") { return stored }
        guard inDatabaseFolder ?? true else { return stored }
        return ((dataFolder as NSString).appendingPathComponent(folderName(forStoredName: stored, folderSize: folderSize)) as NSString)
            .appendingPathComponent(stored)
    }

    /// The complete paths of the files of the images of an index, read from
    /// the stored attributes of its Image entity. On the queue of `context`.
    public static func indexedPaths(in context: NSManagedObjectContext, dataFolder: String, folderSize: Int) throws -> Set<String> {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Image")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["pathNumber", "pathString", "storedInDatabaseFolder"]
        var paths = Set<String>()
        for case let row as [String: Any] in try context.fetch(request) {
            let path = indexedPath(pathNumber: (row["pathNumber"] as? NSNumber)?.intValue, pathString: row["pathString"] as? String,
                                   inDatabaseFolder: (row["storedInDatabaseFolder"] as? NSNumber)?.boolValue,
                                   dataFolder: dataFolder, folderSize: folderSize)
            if let path { paths.insert(path) }
        }
        return paths
    }

    /// The files of `candidates` the index does not have, in their order.
    public static func unindexed(_ candidates: [String], indexed: Set<String>) -> [String] {
        candidates.filter { !indexed.contains($0) }
    }

    /// What the search makes of a file, from what it knows of it. `isFile` is
    /// false for a folder or a link; `lastChange` is the later of the file's
    /// modification and status change; `head` reads the file's first bytes,
    /// and is only called once nothing else has left the file out.
    public static func verdict(name: String, folder: String?, path: String, isFile: Bool, lastChange: Date,
                               isOpen: Bool, indexed: Set<String>, now: Date, folderSize: Int,
                               head: () -> Data?) -> UnindexedFileVerdict {
        guard considers(name), isFile else { return .ignored }
        if indexed.contains(path) { return .indexed }
        if isRecentlyChanged(lastChange: lastChange, now: now) { return .excluded(.recentlyChanged) }
        if isOpen { return .excluded(.open) }
        guard let head = head(), looksLikeDICOM(head) else { return .excluded(.notDICOM) }
        guard let folder, isWhereTheIndexLooks(name: name, folder: folder, folderSize: folderSize) else {
            return .excluded(.misplaced)
        }
        return .unindexed
    }
}

/// What a search of the data folder found.
public struct UnindexedFileReport: Equatable, Sendable {
    /// The files to offer, in the order of their folders and names.
    public var unindexed: [String] = []
    /// The files left alone, by reason.
    public var excluded: [UnindexedFileExclusion: Int] = [:]
    /// The files the index has.
    public var indexedCount = 0
    /// The search was cancelled before its end: what it found is partial.
    public var cancelled = false

    public init() {}

    public func count(_ exclusion: UnindexedFileExclusion) -> Int {
        excluded[exclusion] ?? 0
    }
}

/// The search of a data folder for files its index does not have. Changes
/// nothing: it lists folders, reads the state of files and the first bytes of
/// those it would offer.
public struct UnindexedFileSearch: Sendable {
    public let dataFolder: String
    public let folderSize: Int
    /// Folders, by path, that are never searched even when the data folder
    /// holds them: the incoming, temporary, errors and decompression folders.
    public let skippedFolders: [String]

    public init(dataFolder: String, folderSize: Int, skippedFolders: [String] = []) {
        self.dataFolder = dataFolder
        self.folderSize = folderSize
        self.skippedFolders = skippedFolders.map { ($0 as NSString).standardizingPath }
    }

    /// The folders of the data folder the search goes into, by name, sorted.
    public func folders() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dataFolder)) ?? []
        return names.filter { name in
            guard UnindexedFileRules.searchesFolder(named: name) else { return false }
            let path = (dataFolder as NSString).appendingPathComponent(name)
            guard !skippedFolders.contains((path as NSString).standardizingPath) else { return false }
            return Self.status(of: path).map { ($0.st_mode & S_IFMT) == S_IFDIR } ?? false
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Searches the data folder: its files, which can only be misplaced, then
    /// each of its folders. `openFiles` are the real paths of the files open
    /// in some process (`OpenFileList`). `progress` hears the folders done of
    /// the folders to do; `isCancelled` is asked before each folder.
    public func search(indexed: Set<String>, openFiles: Set<String>, now: Date = Date(),
                       isCancelled: () -> Bool = { false }, progress: (Int, Int) -> Void = { _, _ in }) -> UnindexedFileReport {
        var report = UnindexedFileReport()
        let folders = folders()
        let realDataFolder = Self.realPath(dataFolder) ?? dataFolder

        func record(_ verdict: UnindexedFileVerdict, _ path: String) {
            switch verdict {
            case .indexed: report.indexedCount += 1
            case .unindexed: report.unindexed.append(path)
            case .excluded(let exclusion): report.excluded[exclusion, default: 0] += 1
            case .ignored: break
            }
        }

        let loose = ((try? FileManager.default.contentsOfDirectory(atPath: dataFolder)) ?? []).sorted()
        for name in loose {
            let path = (dataFolder as NSString).appendingPathComponent(name)
            let real = (realDataFolder as NSString).appendingPathComponent(name)
            record(verdict(name: name, folder: nil, path: path, realPath: real, indexed: indexed, openFiles: openFiles, now: now), path)
        }

        for (done, folder) in folders.enumerated() {
            if isCancelled() {
                report.cancelled = true
                break
            }
            progress(done, folders.count)
            let folderPath = (dataFolder as NSString).appendingPathComponent(folder)
            let realFolder = (realDataFolder as NSString).appendingPathComponent(folder)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folderPath)) ?? []).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            for name in names {
                let path = (folderPath as NSString).appendingPathComponent(name)
                let real = (realFolder as NSString).appendingPathComponent(name)
                record(verdict(name: name, folder: folder, path: path, realPath: real, indexed: indexed, openFiles: openFiles, now: now), path)
            }
        }
        if !report.cancelled { progress(folders.count, folders.count) }
        return report
    }

    /// The files of `paths`, found earlier by `search`, that may still be
    /// indexed now: those the index still does not have and that nothing has
    /// changed, opened or moved since. For the moment the import starts.
    public func stillUnindexed(_ paths: [String], indexed: Set<String>, openFiles: Set<String>, now: Date = Date()) -> [String] {
        let realDataFolder = Self.realPath(dataFolder) ?? dataFolder
        let prefix = (dataFolder as NSString).standardizingPath + "/"
        return paths.filter { path in
            let standardized = (path as NSString).standardizingPath
            guard standardized.hasPrefix(prefix) else { return false }
            let relative = String(standardized.dropFirst(prefix.count))
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, UnindexedFileRules.searchesFolder(named: parts[0]),
                  !skippedFolders.contains(((dataFolder as NSString).appendingPathComponent(parts[0]) as NSString).standardizingPath) else { return false }
            let real = ((realDataFolder as NSString).appendingPathComponent(parts[0]) as NSString).appendingPathComponent(parts[1])
            return verdict(name: parts[1], folder: parts[0], path: path, realPath: real, indexed: indexed, openFiles: openFiles, now: now) == .unindexed
        }
    }

    private func verdict(name: String, folder: String?, path: String, realPath: String, indexed: Set<String>,
                         openFiles: Set<String>, now: Date) -> UnindexedFileVerdict {
        let state = Self.status(of: path)
        let isFile = state.map { ($0.st_mode & S_IFMT) == S_IFREG } ?? false
        let lastChange = state.map { Self.lastChange(of: $0) } ?? now
        return UnindexedFileRules.verdict(name: name, folder: folder, path: path, isFile: isFile, lastChange: lastChange,
                                          isOpen: openFiles.contains(realPath), indexed: indexed, now: now,
                                          folderSize: folderSize, head: { Self.head(of: path) })
    }

    /// The state of the item at `path` itself, a link not followed.
    private static func status(of path: String) -> stat? {
        var state = stat()
        return lstat(path, &state) == 0 ? state : nil
    }

    /// The later of the modification and the status change of a file.
    private static func lastChange(of state: stat) -> Date {
        func date(_ time: timespec) -> Date {
            Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
        }
        return max(date(state.st_mtimespec), date(state.st_ctimespec))
    }

    /// The first bytes of a file, or nil when it cannot be read.
    private static func head(of path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: UnindexedFileRules.headLength)
    }

    /// `path` with its links resolved, as the system names an open file.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// The files open in the processes this one may inspect: its own and those
/// of the same user, which are the ones that write into a database folder.
public enum OpenFileList {
    /// The real paths of the regular files open under `folder` (its links
    /// resolved), read once from every process.
    public static func paths(under folder: String) -> Set<String> {
        let root = (UnindexedFileSearch.realPath(folder) ?? folder) + "/"
        var paths = Set<String>()

        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return paths }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard listed > 0 else { return paths }

        for pid in pids.prefix(Int(listed)) where pid > 0 {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16)
            let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * MemoryLayout<proc_fdinfo>.stride))
            guard filled > 0 else { continue }
            for descriptor in descriptors.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
            where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
                let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                if path.hasPrefix(root) { paths.insert(path) }
            }
        }
        return paths
    }
}
