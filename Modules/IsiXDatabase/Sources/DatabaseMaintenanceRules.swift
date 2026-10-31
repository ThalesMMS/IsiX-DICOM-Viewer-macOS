/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import SQLite3

/// The time the rebuild sheet announces: nine seconds per thousand files,
/// rounded down.
public enum RebuildEstimate {
    public static func seconds(forFileCount files: Int) -> Int {
        return files * 9 / 1000
    }
}

/// What a rebuild of the index reads from the folders of the database.
public enum RebuildScan {
    /// Whether the rebuild adds the item called `name`: hidden names stay out.
    public static func includes(_ name: String) -> Bool {
        return name.utf16.first != UInt16(UInt8(ascii: "."))
    }

    /// The paths the rebuild adds, in order: the items in each folder of the
    /// data folder, then those of the ROIs folder. `contents` lists a folder,
    /// nil for a folder that cannot be read.
    public static func files(dataFolder: String, roisFolder: String?, contents: (String) -> [String]?) -> [String] {
        func path(_ folder: String, _ name: String) -> String {
            return (folder as NSString).appendingPathComponent(name)
        }
        var files: [String] = []
        for name in contents(dataFolder) ?? [] {
            let folder = path(dataFolder, name)
            files += (contents(folder) ?? []).filter(includes).map { path(folder, $0) }
        }
        if let roisFolder {
            files += (contents(roisFolder) ?? []).filter(includes).map { path(roisFolder, $0) }
        }
        return files
    }
}

/// What a rebuild that keeps the index takes out of it, once the images whose
/// files are gone have left.
public enum KeptIndexCleanup {
    /// A series left without images goes. The one that keeps an empty study in
    /// its album never has any.
    public static func removesSeries(name: String?, id: Int32, imageCount: Int) -> Bool {
        return imageCount == 0 && !SelectionImages.isNoAutodeletionSeries(name: name, id: id)
    }

    /// A study goes when it has nothing left, and a study that goes takes its
    /// files with it: the images its series still have, hidden ones included,
    /// such as key objects, ROIs and annotations, and its report. So the images
    /// that are left decide, not noFiles or what the list shows, and a report
    /// that can be reached keeps its study. So does the "No Autodeletion" series,
    /// and a lock, which the person's own delete respects too.
    public static func removesStudy(imagesLeft: Int, hasNoAutodeletionSeries: Bool, hasReport: Bool, isLocked: Bool) -> Bool {
        return imagesLeft == 0 && !hasNoAutodeletionSeries && !hasReport && !isLocked
    }

    /// Whether an image whose file did not open has lost it. Only "nothing at
    /// this path" says so, and only with the place that holds the file there: on
    /// a volume that is out or with no data folder the file is out of reach, and
    /// its study, with what only the index holds, waits for it. Any other error
    /// says nothing about the file.
    public static func fileIsGone(openError: Int32, volumeIsThere: Bool, inDatabaseFolder: Bool, dataFolderIsThere: Bool) -> Bool {
        guard openError == ENOENT || openError == ENOTDIR else { return false }
        return volumeIsThere && (dataFolderIsThere || !inDatabaseFolder)
    }
}

/// What a rebuild that stopped has left, which is what it tells the person.
public enum RebuildStop: Equatable, Sendable {
    /// The index was copied, or set aside, in this folder.
    case recoveryFilesIn(String)
    /// A complete rebuild stopped before the copy existed: the index is as it was.
    case beforeTheIndexWasCopied
    /// A rebuild that was not complete, which never moves the index.
    case maintenance

    public init(recoveryFolder: String?, complete: Bool) {
        if let recoveryFolder {
            self = .recoveryFilesIn(recoveryFolder)
        } else {
            self = complete ? .beforeTheIndexWasCopied : .maintenance
        }
    }
}

/// Why "Rebuild SQL File" left the index as it was.
public enum IndexRepairRefusal: Equatable, Sendable {
    /// The file does not start as a SQLite database.
    case notSQLite
    /// The file cannot be read, or lacks a table every index has.
    case unreadable
    /// A read of this table stopped at a page, and its dump would stop there too.
    case damagedTable(String)
    /// sqlite3 could not write out the index.
    case dumpFailed
    /// sqlite3 stopped on what the index wrote out.
    case loadFailed
    /// The new file does not open or fails its check.
    case newIndexDamaged
    /// The new file does not have this table.
    case missingTable(String)
    /// The new file has fewer rows in this table than the index gave.
    case rowsLost(table: String, kept: Int, readable: Int)
    /// The new file could not be put in place, and the index came back.
    case notPutInPlace(String)
}

/// A table of an index, as a read of all its rows ended.
public struct IndexTableScan: Equatable, Sendable {
    public var table: String
    /// The rows read.
    public var rows: Int
    /// The read got past the last row, and did not stop at a page.
    public var isComplete: Bool

    public init(table: String, rows: Int, isComplete: Bool) {
        self.table = table
        self.rows = rows
        self.isComplete = isComplete
    }
}

/// The file sqlite3 made out of the index, before it replaces it.
public struct RepairedIndexState: Equatable, Sendable {
    /// `PRAGMA quick_check` answered ok.
    public var passesQuickCheck: Bool
    /// The rows of each table it has.
    public var rows: [String: Int]

    public init(passesQuickCheck: Bool, rows: [String: Int]) {
        self.passesQuickCheck = passesQuickCheck
        self.rows = rows
    }
}

/// Where a run of sqlite3 is stopped: what the dump of a crafted index holds is
/// plain SQL, which can run for ever or fill the disk with the import lock held.
public struct IndexRepairWorkLimit: Equatable, Sendable {
    public var seconds: Double
    /// The temporary files of the repair, together.
    public var bytes: Int

    public init(seconds: Double, bytes: Int) {
        self.seconds = seconds
        self.bytes = bytes
    }

    public func isExceeded(seconds elapsed: Double, bytes written: Int) -> Bool {
        return elapsed > seconds || written > bytes
    }
}

/// How the swap of the index with the file made out of it ended.
public enum IndexReplacement: Equatable, Sendable {
    case replaced
    /// A step failed, with this reason, and the index is as it was.
    case formerBack(reason: String)
    /// A step failed, and the way back too: the index is in its place, and what
    /// was beside it stays in the folder.
    case companionsInBackupFolder(reason: String)
}

/// What "Rebuild SQL File" decides. It remakes the index from what the
/// `/usr/bin/sqlite3` tool gets out of it, and neither its exit code nor the end
/// of its output says how much that was: `.dump` stops a table at the first page
/// it cannot read, in any table, says 0 and still ends with COMMIT. So a table
/// that a read does not get to the end of is not dumped: the repair is for what
/// the dump leaves behind, the indexes of the tables and the free pages.
public enum IndexRepairRules {
    /// The tables every index has.
    public static let requiredTables = ["ZSTUDY", "ZSERIES", "ZIMAGE"]

    /// The bytes of a database header that are read before anything else: up
    /// to the two that tell the journal mode.
    public static let headerLength = 20

    /// Any other file is not given to sqlite3, which takes it for a script.
    public static func isSQLite(header: Data) -> Bool {
        return header.prefix(16).elementsEqual(Array("SQLite format 3\0".utf8))
    }

    /// Whether the database of this header keeps its last changes in a log.
    public static func usesWriteAheadLog(header: Data) -> Bool {
        let bytes = [UInt8](header.prefix(headerLength))
        return bytes.count == headerLength && (bytes[18] == 2 || bytes[19] == 2)
    }

    /// The name sqlite3 and the probe read the index by, read-only, which leaves
    /// its bytes alone: a log is read and not checkpointed, and a journal that
    /// would have to roll back fails the read. A database in log mode with no
    /// log cannot be opened that way, since it would have to make one; with no
    /// log nobody is writing to it, and it is read as a file that does not change.
    public static func readingURI(forIndexAtPath path: String, usesWriteAheadLog: Bool, logExists: Bool) -> String {
        return URL(fileURLWithPath: path).absoluteString + (usesWriteAheadLog && !logExists ? "?immutable=1" : "?mode=ro")
    }

    /// What every run of sqlite3 starts with. Its safe mode ends the process at
    /// a dot-command that reaches outside and refuses ATTACH, VACUUM INTO and the
    /// functions that touch files; -bail stops at the first failed statement; and
    /// it reads no file of settings of the person. All of them exist in the
    /// sqlite3 of macOS 15. Safe mode runs no command, and it is not a sandbox: a
    /// crafted index can still make sqlite3 work without end, which `workLimit`
    /// stops (and `boundedLaunch` when nothing watches any more), and leave an
    /// empty lock file at a path it names with a PRAGMA.
    public static let sqlite3Options = ["-safe", "-bail", "-batch", "-init", "/dev/null"]

    /// How a run of sqlite3 with `arguments` is started: a shell gives it the
    /// kernel's limits of `limit`, the size of any file it writes and its
    /// processor time, and becomes sqlite3 (same process, same arguments). The
    /// repair stops a run that goes past `limit` while it watches it; sqlite3 runs
    /// in a process group of its own, though, and outlives the process that
    /// started it, crashed or killed, with no one watching. Past these limits the
    /// kernel ends it (SIGXFSZ, SIGXCPU), so a crafted index cannot fill the disk.
    /// Each file is held to the whole `limit.bytes`, counted in 512-byte blocks
    /// rounded up (a shell that counts in 1024 allows twice that), and processor
    /// time runs no faster than the clock: neither ends a run the watch lets go on.
    public static func boundedLaunch(of arguments: [String], limit: IndexRepairWorkLimit) -> (executable: String, arguments: [String]) {
        let blocks = limit.bytes / 512 + 1
        let seconds = Int(limit.seconds.rounded(.up)) + 1
        return ("/bin/sh", ["-c", "ulimit -f \(blocks) && ulimit -t \(seconds) && exec /usr/bin/sqlite3 \"$@\"", "sqlite3"] + arguments)
    }

    /// The run that writes out the index, on its standard output. A file a
    /// writable connection opens could be checkpointed or rolled back.
    public static func dumpArguments(indexURI: String) -> [String] {
        return sqlite3Options + ["-readonly", indexURI, ".dump"]
    }

    /// The run that reads the dump from its standard input into a new file. The
    /// dump is not data: the text of a crafted schema goes in it as it is, with
    /// its line breaks, and comes back as commands.
    public static func loadArguments(newIndexPath: String) -> [String] {
        return sqlite3Options + [newIndexPath]
    }

    /// How much a run of sqlite3 gets for an index of this size. The text of a
    /// row with many empty columns takes several times its size, so an honest
    /// index stays far below this, even on a slow disk.
    public static func workLimit(indexBytes: Int) -> IndexRepairWorkLimit {
        return IndexRepairWorkLimit(seconds: 300 + 60 * Double(indexBytes / (64 * 1024 * 1024)),
                                    bytes: 1024 * 1024 * 1024 + indexBytes.multipliedReportingOverflow(by: 16).partialValue)
    }

    /// Why the index is not worth dumping, from how the reads of its tables
    /// ended, or from there being no tables to read, which is nil.
    public static func refusal(original: [IndexTableScan]?) -> IndexRepairRefusal? {
        guard let original, requiredTables.allSatisfy({ name in original.contains { $0.table == name } }) else { return .unreadable }
        return original.first { !$0.isComplete }.map { .damagedTable($0.table) }
    }

    /// Why the new file does not replace the index: every table of the index
    /// has to be there, with the rows that were read from it.
    public static func refusal(new: RepairedIndexState?, original: [IndexTableScan]) -> IndexRepairRefusal? {
        guard let new, new.passesQuickCheck else { return .newIndexDamaged }
        for table in original {
            guard let kept = new.rows[table.table] else { return .missingTable(table.table) }
            if kept < table.rows {
                return .rowsLost(table: table.table, kept: kept, readable: table.rows)
            }
        }
        return nil
    }

    /// Whether the failure of a recovery snapshot says that the index itself is
    /// damaged, and not that the copy could not be made: a folder that cannot be
    /// written, a full disk or a busy database still stop a complete rebuild, and
    /// a damaged index, which no verified copy can be made of, does not.
    public static func snapshotFoundDamage(_ error: NSError) -> Bool {
        let result = Int32(truncatingIfNeeded: error.code) & 0xff
        return error.domain == "HorosDatabaseIndexBackup" && (result == SQLITE_CORRUPT || result == SQLITE_NOTADB)
    }

    /// The temporary files of a repair: the dump, the new index and what SQLite
    /// may have left beside it.
    public static func temporaryFiles(forIndexAtPath path: String) -> [String] {
        let dump = path + ".dump"
        let new = dump + ".sql"
        return [dump, new] + companionSuffixes.map { new + $0 }
    }

    /// The name of a former index in a recovery folder, as a complete rebuild
    /// leaves it.
    public static let retiredName = "RetiredDatabase.sql"

    /// The files that belong to an index: SQLite applies a log or a journal it
    /// finds beside a database to whichever database is there, so they leave
    /// with the index, and keep it whole in the folder it goes to.
    public static let companionSuffixes = ["-wal", "-shm", "-journal"]

    /// Puts the new file in the place of the index, and leaves the index and its
    /// companions in `folder`, each step checked. The companions go first: left
    /// beside the new file, they would be applied to it. The index never leaves
    /// its place: it gets a second name in the folder, and the new file then
    /// takes the name in a single step, so that no failure and no crash finds the
    /// place empty. If a step fails, what moved goes back, in reverse order.
    public static func replaceIndex(atPath index: String, with new: String, retiringTo folder: String,
                                    exists: (String) -> Bool, move: (String, String) throws -> Void,
                                    keep: (String, String) throws -> Void, replace: (String, String) throws -> Void,
                                    remove: (String) -> Void) -> IndexReplacement {
        let retired = (folder as NSString).appendingPathComponent(retiredName)
        let companions: [(from: String, to: String)] = companionSuffixes.map { (index + $0, retired + $0) }.filter { exists($0.0) }
        var moved: [(from: String, to: String)] = []
        do {
            for step in companions {
                try move(step.from, step.to)
                moved.append(step)
            }
            try keep(index, retired)
            do {
                try replace(index, new)
            } catch {
                remove(retired)
                throw error
            }
            return .replaced
        } catch {
            var allBack = true
            for step in moved.reversed() {
                do {
                    try move(step.to, step.from)
                } catch {
                    allBack = false
                }
            }
            return allBack ? .formerBack(reason: error.localizedDescription) : .companionsInBackupFolder(reason: error.localizedDescription)
        }
    }
}

/// What an upgrade from a former model of the index decides.
public enum ModelUpgradeRules {
    /// The file of the model of an index of `version`, in the app's resources.
    public static func modelFileName(forVersion version: String?, current: String) -> String {
        if let version, (version as NSString).isEqual(to: current) {
            return "OsiriXDB_DataModel.mom"
        }
        return "OsiriXDB_Previous_DataModel\(version ?? "(null)").mom"
    }

    /// The model the database has on record for its index: its version file or,
    /// without one, the preference, which the last database saved wrote.
    public static func recordedVersion(file: String?, preference: String?) -> String? {
        return file ?? preference
    }

    /// Whether the record names another model than `current`. An empty one
    /// names none.
    public static func namesAnotherModel(_ version: String?, current: String) -> Bool {
        guard let version, (version as NSString).length != 0 else { return false }
        return !(version as NSString).isEqual(to: current)
    }

    /// The version to upgrade the index from as it opens, nil when no upgrade is
    /// due. With no index there is nothing to upgrade, whatever the record says:
    /// the opening makes one in the current model. A complete rebuild opens its
    /// new index this way, so a preference of a model the application does not
    /// know cannot send it back to the upgrade that started it.
    public static func versionToUpgrade(file: String?, preference: String?, current: String, indexExists: Bool) -> String? {
        let recorded = recordedVersion(file: file, preference: preference)
        return indexExists && namesAnotherModel(recorded, current: current) ? recorded : nil
    }

    /// Whether an index that will not open is one waiting for its upgrade: the
    /// record still names another model, as an upgrade whose rebuild stopped
    /// leaves it. Core Data refuses such an index as it refuses a damaged one,
    /// and it has to stay in its place for the next opening.
    public static func indexAwaitsUpgrade(file: String?, preference: String?, current: String) -> Bool {
        return namesAnotherModel(recordedVersion(file: file, preference: preference), current: current)
    }

    /// The attributes copied as primitive values, past the setters of the
    /// objects, at every level of the index.
    public static let primitiveKeys: Set<String> = ["isKeyImage", "comment", "comment2", "comment3", "comment4", "reportURL", "stateText"]
    /// The display state of a series, which the upgrade does not copy.
    public static let seriesKeysLeftOut: Set<String> = ["xOffset", "yOffset", "scale", "rotationAngle", "displayStyle", "windowLevel", "windowWidth", "yFlipped", "xFlipped"]
    /// The display state of an image, which the upgrade does not copy, under
    /// its names of today and the wl and ww of model 2.2.
    public static let imageKeysLeftOut: Set<String> = ["xOffset", "yOffset", "scale", "rotationAngle", "windowLevel", "windowWidth", "yFlipped", "xFlipped", "wl", "ww"]

    /// The attributes that have another name in the current model, by entity. An
    /// object takes an unknown key without a word, so an attribute left under its
    /// former name is lost in silence. The other attributes of an image that left
    /// the model, such as path or height, keep their names: the setters of the
    /// image store them where the current model has them.
    public static let renamedKeys: [String: [String: String]] = [
        "Study": ["locked": "lockedStudy"],
        "Image": ["frameNo": "frameID", "isKeyImage": "storedIsKeyImage", "mountedVolume": "storedMountedVolume"],
    ]

    /// The attributes of former models that have no value in the current one, by
    /// entity: the objects compute dicomTime from their date and answer type
    /// themselves, an image has no name, and nothing reads iPod.
    public static let retiredKeys: [String: Set<String>] = [
        "Study": ["dicomTime", "type"],
        "Series": ["dicomTime", "type"],
        "Image": ["dicomTime", "iPod", "name", "type"],
    ]

    /// The name of an attribute of `entity` in the current model.
    public static func currentKey(_ key: String, ofEntity entity: String) -> String {
        return renamedKeys[entity]?[key] ?? key
    }

    /// Whether the attribute of `entity` is one the current model keeps no value of.
    public static func isRetired(_ key: String, ofEntity entity: String) -> Bool {
        return retiredKeys[entity]?.contains(key) ?? false
    }

    /// The value an attribute of a former model takes in the current one. The
    /// windowsState of a study was text up to model 2.3, and whoever reads it
    /// now takes it as the data of a property list. An image that is not a key
    /// image has no stored value, which is how its setter leaves it, and the
    /// archive of a study lists the images that have one. Anything else, and a
    /// value that already has the current type, stays as it is.
    public static func upgradedValue(_ value: Any?, ofKey key: String, entity: String) -> Any? {
        if entity == "Study", key == "windowsState", let text = value as? String {
            return Data(text.utf8)
        }
        if entity == "Image", key == "isKeyImage", (value as? NSNumber)?.boolValue != true {
            return nil
        }
        return value
    }
}

/// The report of a study, as the database finds it.
public enum ReportAttachment {
    /// The extensions a report file of a study may have, in the order they are
    /// looked for.
    public static let fileExtensions = ["pages", "odt", "doc", "docx", "rtf"]

    /// Whether the study's own report is reachable: on a web address, or in a
    /// file that exists. Then no file is looked for.
    public static func isReachable(_ attached: String?, fileExists: (String) -> Bool) -> Bool {
        guard let attached, (attached as NSString).length != 0 else { return false }
        return attached.hasPrefix("http://") || attached.hasPrefix("https://") || fileExists(attached)
    }

    /// The same for a report as the index stores it, where a file inside the
    /// database has a path relative to it. A report on a volume that is out counts
    /// as reachable, as KeptIndexCleanup.fileIsGone does for an image: nothing says
    /// it is gone, and a study that lost it could leave the index with its files.
    public static func isReachable(stored: String?, inDatabaseAt baseFolder: String?, fileExists: (String) -> Bool) -> Bool {
        guard let stored, !stored.hasPrefix("/"), !stored.hasPrefix("http://"), !stored.hasPrefix("https://"), let baseFolder, !stored.isEmpty else {
            return isReachable(stored, fileExists: fileExists) || isOnVolumeThatIsOut(stored, fileExists: fileExists)
        }
        return isReachable((baseFolder as NSString).appendingPathComponent(stored), fileExists: fileExists)
    }

    /// Whether `path` lives on a `/Volumes/<name>` that is not mounted.
    public static func isOnVolumeThatIsOut(_ path: String?, fileExists: (String) -> Bool) -> Bool {
        volume(of: path).map { !fileExists($0) } ?? false
    }

    /// What the index stores for a report file: its path relative to the database
    /// when it is inside, so that the database can move; any other path as it is.
    public static func storedPath(_ path: String, inDatabaseAt baseFolder: String?) -> String {
        guard let baseFolder, !baseFolder.isEmpty else { return path }
        let inside = baseFolder.hasSuffix("/") ? baseFolder : baseFolder + "/"
        return path.hasPrefix(inside) ? String(path.dropFirst(inside.count)) : path
    }

    /// The `/Volumes/<name>` a path lives on, or nil when it is not on one.
    private static func volume(of path: String?) -> String? {
        guard let parts = (path as NSString?)?.pathComponents, parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        return "/Volumes/" + parts[2]
    }
}

/// The comment "Regenerate Auto Comments" leaves on a study when comments are
/// filled at study level only: the text read from the study's first image
/// series replaces the study's comment when it is longer, and otherwise the
/// comment is cleared.
public enum AutoCommentRule {
    public static func studyComment(read candidate: String?, current: String?) -> String? {
        let candidateLength = (candidate as NSString?)?.length ?? 0
        let currentLength = (current as NSString?)?.length ?? 0
        return candidateLength > currentLength ? candidate : nil
    }
}

/// The lookups of an album made from a list of patients.
public enum PatientListLookup {
    /// The identifier as matched against Patient ID: without the spaces and
    /// line breaks around it; nil when nothing is left.
    public static func identifier(_ identifier: String?) -> String? {
        let trimmed = (identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed as NSString).length > 0 ? trimmed : nil
    }

    /// The name search for the words of a listed name: every word anywhere in
    /// the stored name, in any order, which a leading `*` asks of the
    /// browser's name predicate. Nil without words.
    public static func nameQuery(words: [String]) -> String? {
        return words.isEmpty ? nil : "*" + words.joined(separator: " ")
    }
}

/// The series whose files make the surgical procedure timeline.
public enum SurgicalTimelineQuery {
    /// The series with exactly this Series Description that belong to a study,
    /// compared code unit by code unit (`==` in a fetch is that comparison, case
    /// and accents included). The index keeps that tag in `name`: its
    /// `seriesDescription` attribute holds the Protocol Name, which these
    /// reports do not have. Every refresh of the study list asks for the
    /// timeline; one fetch of the series replaces fetching every study and
    /// faulting in all of their series.
    public static func seriesPredicate(description: String) -> NSPredicate {
        return NSPredicate(format: "name == %@ AND study != nil", description)
    }
}
