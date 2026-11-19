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
import Testing
@testable import IsiXDatabase

/// A folder of its own for one test, removed at the end, with synthetic files
/// of a few kilobytes and the archives /usr/bin/zip makes of them. The limits
/// the tests give are of kilobytes: nothing large is written.
private final class BudgetScratch {
    let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("zip-budget-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ component: String) -> String {
        (root as NSString).appendingPathComponent(component)
    }

    /// A file of `kilobytes` of one byte, which zip packs into a few bytes.
    func file(_ name: String, kilobytes: Int) throws {
        try Data(repeating: 0x41, count: kilobytes * 1024).write(to: URL(fileURLWithPath: path(name)))
    }

    func zip(_ archive: String, _ names: [String], password: String? = nil) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ProtectedZipArchiver.systemZip)
        task.arguments = ["-q", "-r"] + (password.map { ["-P", $0] } ?? []) + [path(archive)] + names
        task.currentDirectoryURL = URL(fileURLWithPath: root)
        try task.run()
        task.waitUntilExit()
        #expect(task.terminationStatus == 0)
    }

    /// Makes `archive`, of one entry, say that entry is `bytes` long once
    /// expanded, in its local header and in its directory.
    func declare(_ archive: String, bytes: UInt32) throws {
        let url = URL(fileURLWithPath: path(archive))
        var data = try Data(contentsOf: url)
        let size = withUnsafeBytes(of: bytes.littleEndian) { Data($0) }
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        data.replaceSubrange(22 ..< 26, with: size)
        let directory = try #require(data.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        data.replaceSubrange(directory.lowerBound + 24 ..< directory.lowerBound + 28, with: size)
        try data.write(to: url)
    }

    func folder(_ name: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path(name), withIntermediateDirectories: true)
        return path(name)
    }

    func contents(_ folder: String) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: path(folder))) ?? []).sorted()
    }

    func extract(_ archive: String, into folder: String, share: ArchiveExpansionShare, password: String? = nil)
        throws -> Result<Int32, ArchiveExpansionRefusal> {
        try ProtectedZipArchiver.extract(path(archive), to: self.folder(folder), password: password, in: root, share: share,
                                         continuing: { true })
    }
}

private func share(kilobytes: Int64 = 1024, files: Int = 100, nesting: Int = 2) -> ArchiveExpansionShare {
    ArchiveExpansionShare(account: ArchiveExpansionAccount(budget: ArchiveExpansionBudget(bytes: kilobytes * 1024, files: files, nesting: nesting)))
}

@Suite struct ArchiveExpansionBudgetTests {

    @Test func aListingCountsTheFilesAndTheirBytesAndNoDirectory() {
        let listing = ArchiveListing.parse("""
        drwxr-xr-x  3.0 unx        0 bx stor 26-Nov-15 10:00 study/
        -rw-r--r--  3.0 unx   524288 bx defN 26-Nov-15 10:00 study/first image.dcm
        -rw-r--r--  3.0 unx     1024 bx defN 26-Nov-15 10:00 study/second.dcm
        -rw-a--     2.0 fat 5000000000 b- defN 26-Nov-15 10:00 large.dcm
        """)
        #expect(listing == ArchiveListing(files: 3, bytes: 524_288 + 1024 + 5_000_000_000))
    }

    @Test func anArchiveThatSaysItHoldsMoreThanTheBudgetIsRefusedBeforeAnythingIsWritten() throws {
        let scratch = try BudgetScratch()
        try scratch.file("large.dcm", kilobytes: 300)
        try scratch.zip("large.zip", ["large.dcm"])

        let small = share(kilobytes: 200)
        #expect(try scratch.extract("large.zip", into: "out", share: small) == .failure(.bytes(limit: 200 * 1024)))
        #expect(scratch.contents("out").isEmpty)
        #expect(small.account.used.bytes == 0)

        let enough = share(kilobytes: 400)
        #expect(try scratch.extract("large.zip", into: "fits", share: enough) == .success(0))
        #expect(scratch.contents("fits") == ["large.dcm"])
        #expect(enough.account.used.bytes == 300 * 1024 && enough.account.used.files == 1)
    }

    @Test func anArchiveOfMoreFilesThanTheBudgetIsRefused() throws {
        let scratch = try BudgetScratch()
        for index in 0 ..< 6 { try scratch.file("image\(index).dcm", kilobytes: 1) }
        try scratch.zip("many.zip", (0 ..< 6).map { "image\($0).dcm" })
        #expect(try scratch.extract("many.zip", into: "out", share: share(files: 5)) == .failure(.files(limit: 5)))
        #expect(scratch.contents("out").isEmpty)
        #expect(try scratch.extract("many.zip", into: "fits", share: share(files: 6)) == .success(0))
    }

    @Test func anArchiveThatHoldsMoreThanItSaysIsStoppedAndWhatItWroteIsRemoved() throws {
        let scratch = try BudgetScratch()
        try scratch.file("bomb.dcm", kilobytes: 3000)
        try scratch.zip("bomb.zip", ["bomb.dcm"])
        try scratch.declare("bomb.zip", bytes: 10)
        #expect(ArchiveListing.read(scratch.path("bomb.zip")) == ArchiveListing(files: 1, bytes: 10))

        let small = share(kilobytes: 500)
        #expect(try scratch.extract("bomb.zip", into: "out", share: small) == .failure(.bytes(limit: 500 * 1024)))
        #expect(scratch.contents("out").isEmpty)
        #expect(small.account.used.bytes == 0)
    }

    @Test func aFolderIsMeasuredWhileItFillsOnlyWhenAMeasureIsDue() throws {
        let scratch = try BudgetScratch()
        _ = try scratch.folder("filling/series")
        try scratch.file("filling/series/a.dcm", kilobytes: 300)
        let small = share(kilobytes: 200)
        let watch = ArchiveExpansionWatch(share: small, folder: scratch.path("filling"))
        // The first measure is due 0.2 s after unzip starts.
        #expect(watch.refusal() == nil)
        #expect(watch.refusal(now: Date(timeIntervalSinceNow: 1)) == .bytes(limit: 200 * 1024))
        #expect(watch.refusal() == nil)
        #expect(watch.settle() == .bytes(limit: 200 * 1024))
        #expect(small.account.used.bytes == 0)

        let files = share(files: 1)
        try scratch.file("filling/b.dcm", kilobytes: 1)
        #expect(ArchiveExpansionWatch(share: files, folder: scratch.path("filling")).settle() == .files(limit: 1))
    }

    @Test func theArchivesOfOneImportDrawFromOneBudgetAndAnotherImportHasItsOwn() throws {
        let scratch = try BudgetScratch()
        try scratch.file("a.dcm", kilobytes: 300)
        try scratch.file("b.dcm", kilobytes: 300)
        try scratch.zip("a.zip", ["a.dcm"])
        try scratch.zip("b.zip", ["b.dcm"])

        let first = share(kilobytes: 500)
        #expect(try scratch.extract("a.zip", into: "a", share: first) == .success(0))
        #expect(try scratch.extract("b.zip", into: "b", share: first.inside) == .failure(.bytes(limit: 500 * 1024)))
        #expect(scratch.contents("a") == ["a.dcm"])
        #expect(scratch.contents("b").isEmpty)
        // What another import brings is not held against by the first.
        #expect(try scratch.extract("b.zip", into: "independent", share: share(kilobytes: 500)) == .success(0))
        #expect(scratch.contents("independent") == ["b.dcm"])
    }

    @Test func anArchiveInsideTooManyOthersIsNotExpanded() throws {
        let scratch = try BudgetScratch()
        try scratch.file("image.dcm", kilobytes: 1)
        try scratch.zip("inner.zip", ["image.dcm"])
        let root = share(nesting: 2)
        #expect(try scratch.extract("inner.zip", into: "two", share: root.inside.inside) == .success(0))
        #expect(try scratch.extract("inner.zip", into: "three", share: root.inside.inside.inside) == .failure(.nesting(limit: 2)))
        #expect(scratch.contents("three").isEmpty)
    }

    @Test func anArchiveFoundInAnExpandedFolderSharesItsImport() {
        let registry = ArchiveExpansionRegistry()
        let budget = ArchiveExpansionBudget(bytes: 1000, files: 10, nesting: 4)
        let root = registry.share(ofArchive: "/incoming/study.zip", budget: budget)
        #expect(root.depth == 0)
        registry.record(root, expandedInto: "/incoming/unzip-1")

        let inside = registry.share(ofArchive: "/incoming/unzip-1/series/inner.zip", budget: budget)
        #expect(inside.depth == 1 && inside.account === root.account)

        // Moved out to be expanded elsewhere, and its folder moved again.
        registry.archive(at: "/incoming/unzip-1/series/inner.zip", movedTo: "/decompress/inner.zip")
        let moved = registry.share(ofArchive: "/decompress/inner.zip", budget: budget)
        #expect(moved.depth == 1 && moved.account === root.account)
        registry.record(moved, expandedInto: "/incoming/.staging")
        registry.folder("/incoming/.staging", movedTo: "/incoming/inner.zip")
        let deeper = registry.share(ofArchive: "/incoming/inner.zip/deeper.zip", budget: budget)
        #expect(deeper.depth == 2 && deeper.account === root.account)

        // One that is in no expanded folder, and one whose folder is gone.
        let other = registry.share(ofArchive: "/incoming/other.zip", budget: budget)
        #expect(other.depth == 0 && other.account !== root.account)
        registry.archive(at: "/incoming/loose.zip", movedTo: "/decompress/loose.zip")
        #expect(registry.share(ofArchive: "/decompress/loose.zip", budget: budget).depth == 0)
        registry.forget("/incoming/unzip-1")
        #expect(registry.share(ofArchive: "/incoming/unzip-1/series/inner.zip", budget: budget).depth == 0)
    }

    @Test func theRegistryForgetsTheOlderFoldersPastItsCapacity() {
        let registry = ArchiveExpansionRegistry()
        let budget = ArchiveExpansionBudget.imported
        for index in 0 ... ArchiveExpansionRegistry.capacity {
            registry.record(ArchiveExpansionShare(account: ArchiveExpansionAccount(budget: budget)), expandedInto: "/expanded/\(index)")
        }
        #expect(registry.share(ofArchive: "/expanded/0/a.zip", budget: budget).depth == 0)
        #expect(registry.share(ofArchive: "/expanded/\(ArchiveExpansionRegistry.capacity)/a.zip", budget: budget).depth == 1)
    }

    @Test func anArchiveOverTheBudgetInTheImportFolderLeavesTheOthersOfTheListToBeExpanded() throws {
        let scratch = try BudgetScratch()
        try scratch.file("bomb.dcm", kilobytes: 3000)
        try scratch.zip("bomb.zip", ["bomb.dcm"])
        try scratch.declare("bomb.zip", bytes: 10)
        try scratch.file("large.dcm", kilobytes: 800)
        try scratch.zip("large.zip", ["large.dcm"])
        try scratch.file("good.dcm", kilobytes: 20)
        try scratch.zip("good.zip", ["good.dcm"])
        let incoming = try scratch.folder("incoming")

        let summary = DecompressConversion.run([scratch.path("bomb.zip"), scratch.path("large.zip"), scratch.path("good.zip")],
                                               mode: .decompressList, destination: incoming, settings: [:], moveIfUnreadable: false,
                                               converter: DecompressConversionTests.Converter(),
                                               archiveBudget: ArchiveExpansionBudget(bytes: 500 * 1024, files: 100, nesting: 2))
        #expect(!summary.succeeded)
        // The two over the budget are handed back whole, under a name the
        // import folder does not expand again, with nothing of theirs
        // beside them; the third is expanded.
        #expect(scratch.contents("incoming") == ["bomb.zip.horos-unexpanded", "good.zip", "good.zip/good.dcm", "large.zip.horos-unexpanded"])
        ArchiveExpansionRegistry.shared.forget((incoming as NSString).appendingPathComponent("good.zip"))
    }

    @Test func aProtectedArchiveIsHeldToTheBudgetAsAnother() throws {
        let scratch = try BudgetScratch()
        try scratch.file("secret.dcm", kilobytes: 300)
        try scratch.zip("protected.zip", ["secret.dcm"], password: "synthetic-secret")

        #expect(try scratch.extract("protected.zip", into: "small", share: share(kilobytes: 200), password: "synthetic-secret")
                == .failure(.bytes(limit: 200 * 1024)))
        #expect(scratch.contents("small").isEmpty)

        // A wrong password is no refusal: unzip ends with 82, or with 2 when
        // the password passes the one byte ZIP checks it by.
        let enough = share(kilobytes: 1024)
        let wrong = try scratch.extract("protected.zip", into: "wrong", share: enough, password: "wrong")
        #expect(wrong == .success(82) || wrong == .success(2))
        #expect(try scratch.extract("protected.zip", into: "right", share: enough, password: "synthetic-secret") == .success(0))
        #expect(scratch.contents("right") == ["secret.dcm"])
    }

    @Test func thePreferencesGiveTheBudgetOfAnImportAndTheFactoryOneWhenTheyHoldNoNumber() {
        // The application registers the factory values; a store with none reads 0.
        #expect(ArchiveExpansionBudget.imported(from: MemoryPreferences()).bytes == ArchiveExpansionBudget.imported.bytes)
        let preferences = MemoryPreferences(registered: ["ArchiveExpansionLimitMegabytes": "262144", "ArchiveExpansionLimitFiles": "2000000",
                                                         "ArchiveExpansionLimitNesting": "4"])
        #expect(ArchiveExpansionBudget.imported(from: preferences) == .imported)
        #expect(ArchiveExpansionBudget.imported == ArchiveExpansionBudget(bytes: 256 * 1024 * 1024 * 1024, files: 2_000_000, nesting: 4))
        preferences.set(2, for: DatabasePreferences.archiveExpansionLimitMegabytes)
        preferences.set(50, for: DatabasePreferences.archiveExpansionLimitFiles)
        preferences.set(0, for: DatabasePreferences.archiveExpansionLimitNesting)
        #expect(ArchiveExpansionBudget.imported(from: preferences) == ArchiveExpansionBudget(bytes: 2 * 1024 * 1024, files: 50, nesting: 0))
        preferences.set(0, for: DatabasePreferences.archiveExpansionLimitMegabytes)
        preferences.set(-1, for: DatabasePreferences.archiveExpansionLimitNesting)
        #expect(ArchiveExpansionBudget.imported(from: preferences).bytes == ArchiveExpansionBudget.imported.bytes)
        #expect(ArchiveExpansionBudget.imported(from: preferences).nesting == 4)
    }

    @Test func aRefusalStandsForItselfWhereUnzipsStatusIsReported() {
        let budget = ArchiveExpansionBudget(bytes: 1, files: 2, nesting: 3)
        for refusal in [ArchiveExpansionRefusal.bytes(limit: 1), .files(limit: 2), .nesting(limit: 3)] {
            #expect(ArchiveExpansionRefusal(status: refusal.status, budget: budget) == refusal)
            #expect(!ArchivePasswordRule.needsPassword(afterStatus: refusal.status))
            #expect(!ArchivePasswordRule.needsPasswordAgain(afterStatus: refusal.status))
        }
        #expect(ArchiveExpansionRefusal(status: 82, budget: budget) == nil)
    }
}
