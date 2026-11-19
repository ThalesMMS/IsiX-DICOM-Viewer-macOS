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
import IsiXPreferences
import Synchronization

/// How much one import may put on the disk out of ZIP archives.
///
/// An archive of a few kilobytes can expand to more than a disk holds, in one
/// go or through archives inside archives, each expanded in its turn. The
/// budget is of the operation: the archive that was given and every archive
/// found inside it draw from the same one.
public struct ArchiveExpansionBudget: Equatable, Sendable {
    /// The bytes the files expanded may add up to.
    public var bytes: Int64
    /// How many files may be expanded.
    public var files: Int
    /// How many archives an archive may be inside of and still be expanded:
    /// 0 expands none found inside another.
    public var nesting: Int

    public init(bytes: Int64, files: Int, nesting: Int) {
        self.bytes = bytes
        self.files = files
        self.nesting = nesting
    }

    /// An archive the user dropped or chose, one on a medium and one that
    /// reached the import folder: far above the largest export of a PACS, and
    /// below what fills a disk unnoticed.
    public static let imported = ArchiveExpansionBudget(bytes: 256 * 1024 * 1024 * 1024, files: 2_000_000, nesting: 4)
    /// An archive uploaded to the web portal, whose sender is not at this
    /// Mac: a study or a few, and no archive inside it is expanded.
    public static let uploaded = ArchiveExpansionBudget(bytes: 16 * 1024 * 1024 * 1024, files: 200_000, nesting: 0)

    /// `imported` as the preferences have it: megabytes, files and nesting,
    /// each the factory value when it is not a positive number (nesting: when
    /// negative).
    public static func imported(from preferences: any PreferenceStore) -> ArchiveExpansionBudget {
        var budget = imported
        let megabytes = preferences[DatabasePreferences.archiveExpansionLimitMegabytes]
        if megabytes > 0 { budget.bytes = Int64(megabytes) * 1024 * 1024 }
        let files = preferences[DatabasePreferences.archiveExpansionLimitFiles]
        if files > 0 { budget.files = files }
        let nesting = preferences[DatabasePreferences.archiveExpansionLimitNesting]
        if nesting >= 0 { budget.nesting = nesting }
        return budget
    }
}

/// Why an archive was not expanded, or was stopped while it was.
public enum ArchiveExpansionRefusal: Error, Equatable, Sendable {
    case bytes(limit: Int64)
    case files(limit: Int)
    case nesting(limit: Int)

    /// What stands for the refusal where unzip's termination status is
    /// reported: unzip's own end at 82.
    public var status: Int32 {
        switch self {
        case .bytes: 1001
        case .files: 1002
        case .nesting: 1003
        }
    }

    /// The refusal `status` stands for, with the limits of `budget`.
    public init?(status: Int32, budget: ArchiveExpansionBudget) {
        switch status {
        case 1001: self = .bytes(limit: budget.bytes)
        case 1002: self = .files(limit: budget.files)
        case 1003: self = .nesting(limit: budget.nesting)
        default: return nil
        }
    }

    /// For a log line, after the archive's name.
    public var logText: String {
        switch self {
        case .bytes(let limit): "would expand to more than \(limit) bytes, the limit of one import"
        case .files(let limit): "holds more than \(limit) files, the limit of one import"
        case .nesting(let limit): "is inside more than \(limit) other archives, the limit of one import"
        }
    }
}

/// What a ZIP archive says it holds.
public struct ArchiveListing: Equatable, Sendable {
    public var files: Int
    public var bytes: Int64

    /// Read with zipinfo; nil when the archive cannot be listed. What it says
    /// may be false: the expansion is measured as well.
    public static func read(_ archive: String) -> ArchiveListing? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        // One line an entry (-s), neither the header nor the totals (--h-t).
        task.arguments = ["-s", "--h-t", archive]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        // Read before waiting: a long listing fills the pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        // zipinfo warns with 1 about the same things unzip does.
        guard task.terminationStatus == 0 || task.terminationStatus == 1 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// The listing of `zipinfo -s --h-t`: permissions, version, system, size,
    /// flags, method, date, time and the name. A name that ends in `/` is a
    /// directory; a line that does not read as an entry counts as a file of
    /// no size.
    static func parse(_ text: String) -> ArchiveListing {
        var listing = ArchiveListing(files: 0, bytes: 0)
        for line in text.split(separator: "\n") where !line.hasSuffix("/") {
            listing.files += 1
            let fields = line.split(separator: " ", maxSplits: 8)
            if fields.count == 9, let size = Int64(fields[3]), size > 0 {
                let (sum, overflow) = listing.bytes.addingReportingOverflow(size)
                listing.bytes = overflow ? .max : sum
            }
        }
        return listing
    }
}

/// What one import has expanded so far, against its budget. The archive that
/// was given and the archives found inside it share it.
public final class ArchiveExpansionAccount: Sendable {
    public let budget: ArchiveExpansionBudget
    private let spent = Mutex<(bytes: Int64, files: Int)>((0, 0))

    public init(budget: ArchiveExpansionBudget) {
        self.budget = budget
    }

    public var used: (bytes: Int64, files: Int) { spent.withLock { $0 } }

    func charge(bytes: Int64, files: Int) {
        spent.withLock {
            $0.bytes += bytes
            $0.files += files
        }
    }

    /// Why `bytes` and `files` more do not fit, or nil when they do.
    public func refusal(adding bytes: Int64, files: Int) -> ArchiveExpansionRefusal? {
        let used = used
        if bytes > budget.bytes - min(used.bytes, budget.bytes) { return .bytes(limit: budget.bytes) }
        if files > budget.files - min(used.files, budget.files) { return .files(limit: budget.files) }
        return nil
    }
}

/// The part one archive takes in an import: the account it draws from and
/// how many archives it is inside of.
public struct ArchiveExpansionShare: Sendable {
    public let account: ArchiveExpansionAccount
    public let depth: Int

    public init(account: ArchiveExpansionAccount, depth: Int = 0) {
        self.account = account
        self.depth = depth
    }

    /// The share of an archive found in what this one expanded.
    public var inside: ArchiveExpansionShare { ArchiveExpansionShare(account: account, depth: depth + 1) }

    /// Why `archive` is not expanded at all: it is too deep, or what it says
    /// it holds does not fit what is left. Nothing was written.
    public func refusal(before archive: String) -> ArchiveExpansionRefusal? {
        if depth > account.budget.nesting { return .nesting(limit: account.budget.nesting) }
        guard let listing = ArchiveListing.read(archive) else { return nil }
        return account.refusal(adding: listing.bytes, files: listing.files)
    }
}

/// Measures a folder while unzip fills it, for an archive that holds more
/// than it says.
///
/// A measure reads every file's size, so it is taken at intervals that grow
/// with what it costs: twenty times the last one, from 0.2 s to 2 s. What
/// unzip writes between two measures is what the budget can be passed by.
public final class ArchiveExpansionWatch {
    private let share: ArchiveExpansionShare
    private let folder: String
    private var due = Date(timeIntervalSinceNow: 0.2)

    public init(share: ArchiveExpansionShare, folder: String) {
        self.share = share
        self.folder = folder
    }

    /// The files below `folder` that are not directories, and their sizes.
    static func measure(_ folder: String) -> (bytes: Int64, files: Int) {
        guard let items = FileManager.default.enumerator(
            at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return (0, 0) }
        var bytes: Int64 = 0, files = 0
        for case let item as URL in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { continue }
            files += 1
            bytes += Int64(values?.fileSize ?? 0)
        }
        return (bytes, files)
    }

    /// Why unzip must stop, when a measure is due and shows it.
    public func refusal(now: Date = Date()) -> ArchiveExpansionRefusal? {
        // Use the Date comparison available across supported macOS releases.
        guard !(now < due) else { return nil }
        let measured = Self.measure(folder)
        let cost = Date().timeIntervalSince(now)
        due = Date(timeIntervalSinceNow: min(max(cost * 20, 0.2), 2))
        return share.account.refusal(adding: measured.bytes, files: measured.files)
    }

    /// Once unzip ended: why what it left is too much, or nil after charging
    /// it to the account.
    public func settle() -> ArchiveExpansionRefusal? {
        let measured = Self.measure(folder)
        if let refusal = share.account.refusal(adding: measured.bytes, files: measured.files) { return refusal }
        share.account.charge(bytes: measured.bytes, files: measured.files)
        return nil
    }
}

/// Which import the folders archives were expanded into belong to, so that an
/// archive found in one draws from the same account, one level deeper.
///
/// By path: an archive is expanded by whoever meets it (the import of a
/// dropped archive, the scan of a medium, the import folder), and none of
/// them hands the next anything but a folder.
public final class ArchiveExpansionRegistry: Sendable {
    public static let shared = ArchiveExpansionRegistry()

    private struct Entry: Sendable {
        var share: ArchiveExpansionShare
        var serial: Int
    }
    private let entries = Mutex<(byPath: [String: Entry], serial: Int)>(([:], 0))
    /// How many paths are remembered; past it the older half is forgotten,
    /// and an archive found there later starts an import of its own.
    static let capacity = 4096

    public init() {}

    private static func key(_ path: String) -> String { (path as NSString).standardizingPath }

    private func set(_ share: ArchiveExpansionShare, for path: String) {
        entries.withLock {
            $0.serial += 1
            $0.byPath[Self.key(path)] = Entry(share: share, serial: $0.serial)
            if $0.byPath.count > Self.capacity {
                let oldest = $0.serial - Self.capacity / 2
                $0.byPath = $0.byPath.filter { $0.value.serial > oldest }
            }
        }
    }

    /// The share of the folder that holds `path`, the nearest remembered.
    private func shareOfFolder(holding path: String) -> ArchiveExpansionShare? {
        var folder = (Self.key(path) as NSString).deletingLastPathComponent
        return entries.withLock {
            while folder.count > 1 {
                if let entry = $0.byPath[folder] { return entry.share }
                folder = (folder as NSString).deletingLastPathComponent
            }
            return nil
        }
    }

    /// The share `archive` is expanded with: the one it was given when it
    /// was moved out of an expanded folder, else one inside the share of the
    /// folder that holds it, else the first of a new account of `budget`.
    public func share(ofArchive archive: String, budget: @autoclosure () -> ArchiveExpansionBudget) -> ArchiveExpansionShare {
        if let given = entries.withLock({ $0.byPath.removeValue(forKey: Self.key(archive)) }) { return given.share }
        if let holder = shareOfFolder(holding: archive) { return holder.inside }
        return ArchiveExpansionShare(account: ArchiveExpansionAccount(budget: budget()))
    }

    /// `folder` holds what an archive of `share` expanded to.
    public func record(_ share: ArchiveExpansionShare, expandedInto folder: String) {
        set(share, for: folder)
    }

    /// An archive found at `source`, inside an expanded folder or not, was
    /// moved to `destination` to be expanded from there.
    public func archive(at source: String, movedTo destination: String) {
        if let holder = shareOfFolder(holding: source) { set(holder.inside, for: destination) }
    }

    /// An expanded folder was moved.
    public func folder(_ source: String, movedTo destination: String) {
        if let entry = entries.withLock({ $0.byPath.removeValue(forKey: Self.key(source)) }) { set(entry.share, for: destination) }
    }

    /// `path` is gone.
    public func forget(_ path: String) {
        entries.withLock { _ = $0.byPath.removeValue(forKey: Self.key(path)) }
    }
}

extension ProtectedZipArchiver {
    /// Expands `archive` into `destination` as `extract` does, within
    /// `share`: an archive too deep, or that says it holds more than is
    /// left, is refused before unzip runs; one that turns out to hold more
    /// is stopped, and what it had written is removed from `destination`. An
    /// expansion unzip ended by itself is charged to the account whatever
    /// its status, as its files are there.
    public static func extract(_ archive: String, to destination: String, password: String?, in directory: String?,
                               share: ArchiveExpansionShare, tool: String = ProtectedZipArchiver.systemUnzip,
                               continuing: () -> Bool) throws -> Result<Int32, ArchiveExpansionRefusal> {
        if let refusal = share.refusal(before: archive) { return .failure(refusal) }
        let watch = ArchiveExpansionWatch(share: share, folder: destination)
        var refusal: ArchiveExpansionRefusal?
        let status = try extract(archive, to: destination, password: password, in: directory, tool: tool) {
            refusal = watch.refusal()
            return refusal == nil && continuing()
        }
        if refusal == nil { refusal = watch.settle() }
        guard let refusal else { return .success(status) }
        let files = FileManager.default
        for item in (try? files.contentsOfDirectory(atPath: destination)) ?? [] {
            try? files.removeItem(atPath: (destination as NSString).appendingPathComponent(item))
        }
        return .failure(refusal)
    }
}
