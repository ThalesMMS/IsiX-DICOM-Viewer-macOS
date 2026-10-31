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
import Testing
@testable import IsiXDatabase

@Suite struct IndexRepairRulesTests {

    private struct MoveFailed: Error {}

    private func scans(study: Int = 0, complete: Bool = true) -> [IndexTableScan] {
        return [IndexTableScan(table: "ZSTUDY", rows: study, isComplete: complete),
                IndexTableScan(table: "ZSERIES", rows: 0, isComplete: true),
                IndexTableScan(table: "ZIMAGE", rows: 0, isComplete: true)]
    }

    private func new(_ study: Int, series: Int = 0, image: Int = 0, passes: Bool = true) -> RepairedIndexState {
        return RepairedIndexState(passesQuickCheck: passes, rows: ["ZSTUDY": study, "ZSERIES": series, "ZIMAGE": image])
    }

    /// The swap, over a set of paths, with `failing` throwing at those steps.
    private func replace(_ files: inout Set<String>, failing: (String, String) -> Bool = { _, _ in false }) -> (IndexReplacement, [String]) {
        var steps: [String] = []
        var current = files
        let outcome = IndexRepairRules.replaceIndex(
            atPath: "/d/i", with: "/d/n", retiringTo: "/b", exists: { current.contains($0) },
            move: { from, to in
                if failing(from, to) { throw MoveFailed() }
                steps.append("move \(from) > \(to)")
                current.remove(from)
                current.insert(to)
            },
            keep: { index, retired in
                if failing(index, retired) { throw MoveFailed() }
                steps.append("keep \(index) > \(retired)")
                current.insert(retired)
            },
            replace: { index, new in
                if failing(new, index) { throw MoveFailed() }
                steps.append("replace \(index) < \(new)")
                current.remove(new)
            },
            remove: { path in
                steps.append("remove \(path)")
                current.remove(path)
            })
        files = current
        return (outcome, steps)
    }

    @Test func onlyTheHeaderOfASQLiteDatabaseGoesToSqlite3() {
        let header = Data("SQLite format 3\0".utf8)
        #expect(IndexRepairRules.isSQLite(header: header))
        #expect(IndexRepairRules.isSQLite(header: header + Data([0x10, 0x00, 1, 1])))
        #expect(!IndexRepairRules.isSQLite(header: Data("SQLite format 3".utf8)))
        #expect(!IndexRepairRules.isSQLite(header: Data("SQLite format 2\0".utf8)))
        #expect(!IndexRepairRules.isSQLite(header: Data(".shell touch x\n.dump\n".utf8)))
        #expect(!IndexRepairRules.isSQLite(header: Data()))
    }

    @Test func theModeOfTheFileIsInItsHeader() {
        let start = Data("SQLite format 3\0".utf8) + Data([0x10, 0x00])
        #expect(!IndexRepairRules.usesWriteAheadLog(header: start + Data([1, 1])))
        #expect(IndexRepairRules.usesWriteAheadLog(header: start + Data([2, 2])))
        #expect(!IndexRepairRules.usesWriteAheadLog(header: start))
    }

    @Test func theIndexIsReadReadOnlyAndAsAFileOnlyInLogModeWithNoLog() {
        let path = "/a b/c#d?e/Database.sql"
        #expect(IndexRepairRules.readingURI(forIndexAtPath: path, usesWriteAheadLog: false, logExists: false) == "file:///a%20b/c%23d%3Fe/Database.sql?mode=ro")
        #expect(IndexRepairRules.readingURI(forIndexAtPath: path, usesWriteAheadLog: false, logExists: true).hasSuffix("?mode=ro"))
        #expect(IndexRepairRules.readingURI(forIndexAtPath: path, usesWriteAheadLog: true, logExists: true).hasSuffix("?mode=ro"))
        #expect(IndexRepairRules.readingURI(forIndexAtPath: path, usesWriteAheadLog: true, logExists: false).hasSuffix("?immutable=1"))
    }

    @Test func bothRunsOfSqlite3AreInSafeModeAndStopAtTheFirstError() {
        let dump = IndexRepairRules.dumpArguments(indexURI: "file:///i?mode=ro")
        let load = IndexRepairRules.loadArguments(newIndexPath: "/n")
        for arguments in [dump, load] {
            #expect(arguments.contains("-safe"))
            #expect(arguments.contains("-bail"))
            #expect(arguments.starts(with: IndexRepairRules.sqlite3Options))
        }
        #expect(dump.suffix(3) == ["-readonly", "file:///i?mode=ro", ".dump"])
        #expect(load.last == "/n")
        #expect(!load.contains("-readonly"))
    }

    @Test func aRunOfSqlite3StopsAtALimitAnHonestIndexDoesNotReach() {
        let small = IndexRepairRules.workLimit(indexBytes: 4096)
        #expect(small == IndexRepairWorkLimit(seconds: 300, bytes: 1_073_807_360))
        let large = IndexRepairRules.workLimit(indexBytes: 6_400_000_000)
        #expect(large.seconds == 300 + 60 * 95)
        #expect(large.bytes == 1_073_741_824 + 102_400_000_000)
        #expect(!small.isExceeded(seconds: 300, bytes: small.bytes))
        #expect(small.isExceeded(seconds: 300.1, bytes: 0))
        #expect(small.isExceeded(seconds: 0, bytes: small.bytes + 1))
    }

    @Test func sqlite3StartsUnderTheKernelsLimitsOfTheRun() {
        let limit = IndexRepairWorkLimit(seconds: 300.5, bytes: 1_073_807_360)
        let launch = IndexRepairRules.boundedLaunch(of: IndexRepairRules.loadArguments(newIndexPath: "/d/i.sql"), limit: limit)
        #expect(launch.executable == "/bin/sh")
        #expect(launch.arguments == ["-c", "ulimit -f 2097281 && ulimit -t 302 && exec /usr/bin/sqlite3 \"$@\"", "sqlite3",
                                     "-safe", "-bail", "-batch", "-init", "/dev/null", "/d/i.sql"])
    }

    /// The crafted dump of an index that fills the disk, run as the repair runs
    /// it, with nothing watching: as after the app crashed or was killed while
    /// it repaired. The kernel ends sqlite3 at the limit of a file.
    @Test func anEndlessRunWithNoOneWatchingEndsAtItsLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("isix-repair-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("dump.sql")
        try Data("CREATE TABLE fill (a);\nWITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) INSERT INTO fill SELECT zeroblob(1048576) FROM n;\n".utf8)
            .write(to: script)
        let new = folder.appendingPathComponent("new.sql").path
        let limit = IndexRepairWorkLimit(seconds: 60, bytes: 4 * 1024 * 1024)
        let launch = IndexRepairRules.boundedLaunch(of: IndexRepairRules.loadArguments(newIndexPath: new), limit: limit)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launch.executable)
        task.arguments = launch.arguments
        task.standardInput = try FileHandle(forReadingFrom: script)
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        let deadline = Date().addingTimeInterval(30)
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let ended = !task.isRunning
        if !ended { task.terminate() }
        task.waitUntilExit()
        #expect(ended)
        #expect(task.terminationReason == .uncaughtSignal && task.terminationStatus == SIGXFSZ)
        let size = (try? FileManager.default.attributesOfItem(atPath: new))?[.size] as? Int ?? 0
        // One file at most twice the limit, for a shell that counts in 1024-byte blocks.
        #expect(size > 0 && size <= 2 * limit.bytes + 1024)
    }

    @Test func aFileWithoutTheTablesOfAnIndexIsRefusedBeforeTheDump() {
        #expect(IndexRepairRules.refusal(original: nil) == .unreadable)
        #expect(IndexRepairRules.refusal(original: [IndexTableScan(table: "notes", rows: 1, isComplete: true)]) == .unreadable)
        #expect(IndexRepairRules.refusal(original: Array(scans().dropLast())) == .unreadable)
        #expect(IndexRepairRules.refusal(original: scans()) == nil)
    }

    @Test func anyTableThatDoesNotReadToItsEndIsRefusedBeforeTheDump() {
        #expect(IndexRepairRules.refusal(original: scans(study: 2605, complete: false)) == .damagedTable("ZSTUDY"))
        let album = IndexTableScan(table: "ZALBUM", rows: 0, isComplete: false)
        #expect(IndexRepairRules.refusal(original: scans(study: 5000) + [album]) == .damagedTable("ZALBUM"))
        let links = IndexTableScan(table: "Z_1STUDIES", rows: 10094, isComplete: false)
        #expect(IndexRepairRules.refusal(original: scans(study: 5000) + [links]) == .damagedTable("Z_1STUDIES"))
    }

    @Test func aTableWhoseRowsWereDeletedIsNotDamage() {
        #expect(IndexRepairRules.refusal(original: scans()) == nil)
        #expect(IndexRepairRules.refusal(new: new(0), original: scans()) == nil)
    }

    @Test func theNewFileHoldsEveryRowOfEveryTable() {
        #expect(IndexRepairRules.refusal(new: new(10), original: scans(study: 10)) == nil)
        #expect(IndexRepairRules.refusal(new: new(11), original: scans(study: 10)) == nil)
        #expect(IndexRepairRules.refusal(new: new(9), original: scans(study: 10)) == .rowsLost(table: "ZSTUDY", kept: 9, readable: 10))
        let album = IndexTableScan(table: "ZALBUM", rows: 19, isComplete: true)
        var state = new(10)
        #expect(IndexRepairRules.refusal(new: state, original: scans(study: 10) + [album]) == .missingTable("ZALBUM"))
        state.rows["ZALBUM"] = 3
        #expect(IndexRepairRules.refusal(new: state, original: scans(study: 10) + [album]) == .rowsLost(table: "ZALBUM", kept: 3, readable: 19))
        state.rows["ZALBUM"] = 19
        #expect(IndexRepairRules.refusal(new: state, original: scans(study: 10) + [album]) == nil)
    }

    @Test func aNewFileThatFailsItsCheckOrLacksATableIsRefused() {
        #expect(IndexRepairRules.refusal(new: nil, original: scans()) == .newIndexDamaged)
        #expect(IndexRepairRules.refusal(new: new(1, passes: false), original: scans()) == .newIndexDamaged)
        for table in ["ZSTUDY", "ZSERIES", "ZIMAGE"] {
            var state = new(0)
            state.rows[table] = nil
            #expect(IndexRepairRules.refusal(new: state, original: scans()) == .missingTable(table))
        }
    }

    @Test func aSnapshotStopsARebuildUnlessItFoundTheIndexDamaged() {
        let domain = "HorosDatabaseIndexBackup"
        #expect(IndexRepairRules.snapshotFoundDamage(NSError(domain: domain, code: Int(SQLITE_CORRUPT))))
        #expect(IndexRepairRules.snapshotFoundDamage(NSError(domain: domain, code: Int(SQLITE_NOTADB))))
        // SQLITE_CORRUPT_INDEX: the extended codes keep the primary one in the low byte.
        #expect(IndexRepairRules.snapshotFoundDamage(NSError(domain: domain, code: 779)))
        for result in [SQLITE_FULL, SQLITE_BUSY, SQLITE_CANTOPEN, SQLITE_IOERR, SQLITE_READONLY] {
            #expect(!IndexRepairRules.snapshotFoundDamage(NSError(domain: domain, code: Int(result))))
        }
        #expect(!IndexRepairRules.snapshotFoundDamage(NSError(domain: NSCocoaErrorDomain, code: Int(SQLITE_CORRUPT))))
    }

    @Test func theTemporaryFilesAreTheDumpTheNewFileAndWhatIsBesideIt() {
        #expect(IndexRepairRules.temporaryFiles(forIndexAtPath: "/d/Database.sql") == [
            "/d/Database.sql.dump", "/d/Database.sql.dump.sql", "/d/Database.sql.dump.sql-wal", "/d/Database.sql.dump.sql-shm", "/d/Database.sql.dump.sql-journal"])
    }

    @Test func theCompanionsLeaveFirstAndTheNewFileTakesTheNameInOneStep() {
        var files: Set<String> = ["/d/i", "/d/i-wal", "/d/i-journal", "/d/n"]
        let (outcome, steps) = replace(&files)
        #expect(outcome == .replaced)
        #expect(steps == ["move /d/i-wal > /b/RetiredDatabase.sql-wal", "move /d/i-journal > /b/RetiredDatabase.sql-journal",
                          "keep /d/i > /b/RetiredDatabase.sql", "replace /d/i < /d/n"])
        #expect(files == ["/d/i", "/b/RetiredDatabase.sql", "/b/RetiredDatabase.sql-wal", "/b/RetiredDatabase.sql-journal"])
    }

    @Test func aStepThatFailsLeavesTheIndexAsItWas() {
        for failing in ["/d/i-wal", "/d/i", "/d/n"] {
            var files: Set<String> = ["/d/i", "/d/i-wal", "/d/n"]
            let start = files
            let (outcome, _) = replace(&files) { from, _ in from == failing }
            guard case .formerBack = outcome else {
                Issue.record("\(failing): \(outcome)")
                continue
            }
            #expect(files == start)
        }
    }

    @Test func aWayBackThatFailsLeavesWhatWasBesideTheIndexInTheFolderAndSaysSo() {
        var files: Set<String> = ["/d/i", "/d/i-wal", "/d/n"]
        let (outcome, _) = replace(&files) { from, to in from == "/d/n" || to == "/d/i-wal" }
        guard case .companionsInBackupFolder = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(files == ["/d/i", "/b/RetiredDatabase.sql-wal", "/d/n"])
    }
}

@Suite struct IndexFileSwapTests {

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("index swap \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theIndexKeepsItsPlaceUntilTheNewFileTakesItsName() throws {
        let base = try folder()
        let index = base.appendingPathComponent("Database.sql"), retired = base.appendingPathComponent("Retired.sql"), new = base.appendingPathComponent("new.sql")
        try Data("former".utf8).write(to: index)
        try Data("rebuilt".utf8).write(to: new)
        try IndexFileSwap.keep(index.path, as: retired.path)
        #expect(try Data(contentsOf: index) == Data("former".utf8))
        try IndexFileSwap.replace(index.path, with: new.path)
        #expect(try Data(contentsOf: index) == Data("rebuilt".utf8))
        #expect(try Data(contentsOf: retired) == Data("former".utf8))
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    @Test func aReplaceThatFailsLeavesTheIndex() throws {
        let base = try folder()
        let index = base.appendingPathComponent("Database.sql")
        try Data("former".utf8).write(to: index)
        #expect(throws: (any Error).self) { try IndexFileSwap.replace(index.path, with: base.appendingPathComponent("nothing").path) }
        #expect(try Data(contentsOf: index) == Data("former".utf8))
    }

    @Test func aKeepThatFailsSaysSo() throws {
        let base = try folder()
        let index = base.appendingPathComponent("Database.sql")
        try Data("former".utf8).write(to: index)
        // No folder there: neither a link nor a copy.
        #expect(throws: (any Error).self) { try IndexFileSwap.keep(index.path, as: base.appendingPathComponent("no/folder").path) }
    }
}

@Suite struct IndexFileProbeTests {

    private let pageSize = 4096

    /// An index in a folder of its own, in a path that takes escaping.
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("index probe #\(UUID().uuidString)?")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func uri(_ url: URL) -> String {
        return IndexRepairRules.readingURI(forIndexAtPath: url.path, usesWriteAheadLog: false, logExists: false)
    }

    private func exec(_ handle: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "IndexFileProbeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }

    /// An index of `rows` studies, and `links` rows in a join table of albums,
    /// which has no key of its own to ask for.
    private func makeIndex(at url: URL, rows: Int, links: Int = 0) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(handle) }
        try exec(handle, "PRAGMA page_size = \(pageSize); BEGIN")
        for table in ["ZSTUDY", "ZSERIES", "ZIMAGE"] {
            try exec(handle, "CREATE TABLE \(table) (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT)")
        }
        try exec(handle, "CREATE TABLE Z_1STUDIES (Z_1ALBUMS INTEGER, Z_5STUDIES INTEGER, PRIMARY KEY (Z_1ALBUMS, Z_5STUDIES))")
        if rows > 0 {
            for key in 1...rows {
                try exec(handle, "INSERT INTO ZSTUDY VALUES (\(key), '\(String(repeating: "x", count: 100))')")
            }
        }
        if links > 0 {
            for key in 1...links {
                try exec(handle, "INSERT INTO Z_1STUDIES VALUES (\(key % 7), \(key))")
            }
        }
        try exec(handle, "COMMIT")
    }

    private func rootPage(of table: String, at url: URL) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, "SELECT rootpage FROM sqlite_master WHERE name = '\(table)'", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func damagePage(_ page: Int, at url: URL, with byte: UInt8 = 0xFF) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64((page - 1) * pageSize))
        try file.write(contentsOf: Data(repeating: byte, count: pageSize))
    }

    private func pages(at url: URL) throws -> Int {
        return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0) / pageSize
    }

    private func scan(_ table: String, at url: URL) -> IndexTableScan? {
        return IndexFileProbe.tableScans(ofIndexAt: uri(url))?.first { $0.table == table }
    }

    @Test func anIntactIndexReadsToTheEndOfEveryTable() throws {
        let index = try folder().appendingPathComponent("Database.sql")
        try makeIndex(at: index, rows: 500, links: 300)
        #expect(IndexFileProbe.tableScans(ofIndexAt: uri(index)) == [
            IndexTableScan(table: "ZSTUDY", rows: 500, isComplete: true), IndexTableScan(table: "ZSERIES", rows: 0, isComplete: true),
            IndexTableScan(table: "ZIMAGE", rows: 0, isComplete: true), IndexTableScan(table: "Z_1STUDIES", rows: 300, isComplete: true)])
        #expect(IndexFileProbe.header(ofFileAtPath: index.path).map(IndexRepairRules.isSQLite(header:)) == true)
    }

    @Test func aDamagedLeafStopsTheRead() throws {
        let index = try folder().appendingPathComponent("Database.sql")
        try makeIndex(at: index, rows: 2000)
        // The root's first pages are its leaves, in the order they filled.
        try damagePage(try rootPage(of: "ZSTUDY", at: index) + 10, at: index)
        let study = try #require(scan("ZSTUDY", at: index))
        #expect(!study.isComplete)
        #expect(study.rows < 2000)
    }

    @Test func aDamagedRootStopsTheReadAtItsFirstRow() throws {
        let index = try folder().appendingPathComponent("Database.sql")
        try makeIndex(at: index, rows: 2000)
        try damagePage(try rootPage(of: "ZSTUDY", at: index), at: index)
        #expect(scan("ZSTUDY", at: index) == IndexTableScan(table: "ZSTUDY", rows: 0, isComplete: false))
        #expect(IndexRepairRules.refusal(original: IndexFileProbe.tableScans(ofIndexAt: uri(index))) == .damagedTable("ZSTUDY"))
    }

    // The last page of the file, whose rows nothing can read, and that a
    // comparison with what can still be read would let go.
    @Test func damageAtTheEndOfATableStopsTheReadToo() throws {
        for byte: UInt8 in [0xFF, 0x00] {
            let index = try folder().appendingPathComponent("Database.sql")
            try makeIndex(at: index, rows: 2000)
            try damagePage(try pages(at: index), at: index, with: byte)
            let study = try #require(scan("ZSTUDY", at: index))
            #expect(!study.isComplete)
            #expect(study.rows > 1900)
        }
    }

    @Test func aTableWithNoKeyOfItsOwnIsReadToo() throws {
        let index = try folder().appendingPathComponent("Database.sql")
        try makeIndex(at: index, rows: 10, links: 4000)
        try damagePage(try rootPage(of: "Z_1STUDIES", at: index), at: index)
        #expect(IndexRepairRules.refusal(original: IndexFileProbe.tableScans(ofIndexAt: uri(index))) == .damagedTable("Z_1STUDIES"))
    }

    // Its rows are all in the table, and that is what a repair is for. The index
    // of the primary key has every column of this table, and the read stays out.
    @Test func aDamagedIndexOfATableDoesNotStopTheRead() throws {
        let index = try folder().appendingPathComponent("Database.sql")
        try makeIndex(at: index, rows: 10, links: 4000)
        try damagePage(try rootPage(of: "sqlite_autoindex_Z_1STUDIES_1", at: index), at: index)
        #expect(scan("Z_1STUDIES", at: index) == IndexTableScan(table: "Z_1STUDIES", rows: 4000, isComplete: true))
    }

    // A row whose text goes on in other pages, as the dump would read it.
    @Test func aDamagedPageOfALongRowStopsTheRead() throws {
        let index = try folder().appendingPathComponent("Database.sql")
        try makeIndex(at: index, rows: 0)
        var handle: OpaquePointer?
        #expect(sqlite3_open(index.path, &handle) == SQLITE_OK)
        try exec(handle, "INSERT INTO ZIMAGE VALUES (1, '\(String(repeating: "x", count: pageSize * 5))'), (2, 'next')")
        sqlite3_close(handle)
        try damagePage(try pages(at: index) - 1, at: index)
        #expect(scan("ZIMAGE", at: index)?.isComplete == false)
    }

    @Test func aFileThatDoesNotReadAnswersNothing() throws {
        let base = try folder()
        // A database, but not an index.
        let other = base.appendingPathComponent("other.sql")
        var handle: OpaquePointer?
        #expect(sqlite3_open(other.path, &handle) == SQLITE_OK)
        try exec(handle, "CREATE TABLE t (a)")
        sqlite3_close(handle)
        #expect(IndexRepairRules.refusal(original: IndexFileProbe.tableScans(ofIndexAt: uri(other))) == .unreadable)

        // Half of an index.
        let truncated = base.appendingPathComponent("truncated.sql")
        try makeIndex(at: truncated, rows: 500)
        let bytes = try FileManager.default.attributesOfItem(atPath: truncated.path)[.size] as? Int64 ?? 0
        #expect(truncate(truncated.path, off_t(bytes / 2)) == 0)
        #expect(IndexFileProbe.tableScans(ofIndexAt: uri(truncated)) == nil)

        // Nothing there.
        #expect(IndexFileProbe.header(ofFileAtPath: base.appendingPathComponent("nothing").path) == nil)
        #expect(IndexFileProbe.tableScans(ofIndexAt: uri(base.appendingPathComponent("nothing"))) == nil)
    }

    @Test func theNewFileSaysWhatItHas() throws {
        let base = try folder()
        let index = base.appendingPathComponent("Database.sql")
        try makeIndex(at: index, rows: 30, links: 5)
        #expect(IndexFileProbe.state(ofRepairedIndexAtPath: index.path) == RepairedIndexState(passesQuickCheck: true, rows: ["ZSTUDY": 30, "ZSERIES": 0, "ZIMAGE": 0, "Z_1STUDIES": 5]))
        #expect(IndexFileProbe.state(ofRepairedIndexAtPath: base.appendingPathComponent("nothing").path) == nil)

        // A view of the name is not the table.
        let other = base.appendingPathComponent("other.sql")
        var handle: OpaquePointer?
        #expect(sqlite3_open(other.path, &handle) == SQLITE_OK)
        try exec(handle, "CREATE TABLE ZSTUDY (Z_PK INTEGER PRIMARY KEY); CREATE VIEW ZIMAGE AS SELECT * FROM ZSTUDY")
        sqlite3_close(handle)
        #expect(IndexFileProbe.state(ofRepairedIndexAtPath: other.path) == RepairedIndexState(passesQuickCheck: true, rows: ["ZSTUDY": 0]))

        // A page of the index broken: quick_check reads the whole tree.
        try damagePage(try rootPage(of: "ZSTUDY", at: index), at: index)
        #expect(IndexFileProbe.state(ofRepairedIndexAtPath: index.path)?.passesQuickCheck == false)
    }

    @Test func aReadLeavesTheFileAndNothingBesideIt() throws {
        let base = try folder()
        let index = base.appendingPathComponent("Database.sql")
        try makeIndex(at: index, rows: 30)
        let before = try Data(contentsOf: index)
        _ = IndexFileProbe.tableScans(ofIndexAt: uri(index))
        _ = IndexFileProbe.state(ofRepairedIndexAtPath: index.path)
        #expect(try Data(contentsOf: index) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == ["Database.sql"])
    }
}
