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
import Testing
@testable import IsiXDatabase

/// A folder of its own for one test, removed at the end.
private final class Scratch {
    let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("zip-archiver-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ component: String) -> String {
        (root as NSString).appendingPathComponent(component)
    }

    /// A folder holding image.txt.
    func folder(_ name: String, text: String = "synthetic archive bytes") throws -> String {
        let folder = path(name)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try text.write(toFile: (folder as NSString).appendingPathComponent("image.txt"), atomically: true, encoding: .utf8)
        return folder
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func text(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Nothing left of the private folders zip wrote in.
    var stagingLeft: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).contains { $0.hasPrefix(".horos-zip-") }
    }
}

/// What /usr/bin/zipinfo lists of an archive: one line per entry, its
/// encryption flag first (an uppercase letter when encrypted) and its name last.
private func entries(of archive: String) throws -> [(name: String, encrypted: Bool)] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
    task.arguments = ["-l", archive]
    let output = Pipe()
    task.standardOutput = output
    try task.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    return lines.compactMap { line in
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 10, let mode = fields.first, mode.hasPrefix("-") || mode.hasPrefix("d") else { return nil }
        // Field 5 is the text/binary and encryption flag pair, e.g. "TX" or "tx".
        let flags = fields[4]
        return (String(fields[fields.count - 1]), flags.first?.isUppercase ?? false)
    }
}

/// What /usr/bin/unzip prints of one entry, with the password if given.
private func extracted(_ entry: String, from archive: String, password: String? = nil) throws -> String? {
    try extractedData(entry, from: archive, password: password).map { String(decoding: $0, as: UTF8.self) }
}

private func extractedData(_ entry: String, from archive: String, password: String? = nil) throws -> Data? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    task.arguments = (password.map { ["-P", $0] } ?? []) + ["-p", archive, entry]
    let output = Pipe()
    task.standardOutput = output
    task.standardError = Pipe()
    try task.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return task.terminationStatus == 0 ? data : nil
}

@Suite struct ProtectedZipArchiverTests {

    private let archiver = ProtectedZipArchiver()

    @Test func theFoldersOfOneExportGoIntoOneEncryptedArchiveUnderTheirNames() throws {
        let scratch = try Scratch()
        let folders = [try scratch.folder("SMITH"), try scratch.folder("SMITH_2")]
        let archive = scratch.path("SMITH.zip")
        try archiver.archive(items: folders, to: archive, password: "synthetic-password", deletingSources: true)

        let listed = try entries(of: archive).filter { !$0.name.hasSuffix("/") }
        #expect(listed.map(\.name).sorted() == ["SMITH/image.txt", "SMITH_2/image.txt"])
        #expect(listed.filter { !$0.encrypted }.isEmpty)
        #expect(try extracted("SMITH/image.txt", from: archive, password: "synthetic-password") == "synthetic archive bytes")
        #expect(try extracted("SMITH/image.txt", from: archive) == nil)
        #expect(folders.filter { scratch.exists($0) }.isEmpty)
        #expect(!scratch.stagingLeft)
    }

    @Test func withoutAPasswordTheArchiveIsPlainAndTheSourcesStayUnlessAsked() throws {
        let scratch = try Scratch()
        let folder = try scratch.folder("source")
        let archive = scratch.path("plain.zip")
        try "old archive bytes".write(toFile: archive, atomically: true, encoding: .utf8)
        try archiver.archive(items: [folder], to: archive, password: "", deletingSources: false)

        let listed = try entries(of: archive).filter { !$0.name.hasSuffix("/") }
        #expect(listed.map(\.name) == ["source/image.txt"])
        #expect(listed.filter { $0.encrypted }.isEmpty)
        #expect(try extracted("source/image.txt", from: archive) == "synthetic archive bytes")
        #expect(scratch.exists(folder))
    }

    @Test func aFailedArchiveKeepsTheSourcesAndThePreviousArchive() throws {
        let scratch = try Scratch()
        let folder = try scratch.folder("kept")
        let elsewhere = try scratch.folder("elsewhere/DOE")
        let archive = scratch.path("previous.zip")
        try "old archive bytes".write(toFile: archive, atomically: true, encoding: .utf8)

        // Items of different folders, and a missing item, are refused.
        for items in [[folder, elsewhere], [scratch.path("missing")]] {
            #expect {
                try archiver.archive(items: items, to: archive, password: "", deletingSources: true)
            } throws: { error in
                let error = error as NSError
                return error.domain == NSCocoaErrorDomain && error.code == NSFileWriteUnknownError
                    && error.userInfo[NSFilePathErrorKey] as? String == archive && !error.localizedDescription.isEmpty
            }
        }
        #expect(scratch.text(archive) == "old archive bytes")
        #expect(scratch.exists(folder) && scratch.exists(elsewhere))
        #expect(!scratch.stagingLeft)
    }

    @Test func aSourceAndADestinationAreRequired() throws {
        let scratch = try Scratch()
        for (items, destination) in [([String](), scratch.path("a.zip")), ([""], scratch.path("a.zip")), ([try scratch.folder("x")], "")] {
            #expect {
                try archiver.archive(items: items, to: destination, password: nil, deletingSources: true)
            } throws: { error in
                (error as NSError).code == NSFileWriteInvalidFileNameError
            }
        }
        #expect(scratch.exists(scratch.path("x")))
    }

    @Test func aDestinationThatCannotBeStagedFailsWithItsOwnError() throws {
        let scratch = try Scratch()
        let folder = try scratch.folder("source")
        // The destination's parent is a file: no private folder can be made beside it.
        let destination = (scratch.path("source/image.txt") as NSString).appendingPathComponent("invalid.zip")
        #expect(throws: (any Error).self) {
            try archiver.archive(items: [folder], to: destination, password: nil, deletingSources: true)
        }
        #expect(scratch.exists(folder))
    }

    @Test func flatArchivesHoldTheFilesAtTheirRoot() throws {
        let scratch = try Scratch()
        let first = (try scratch.folder("a") as NSString).appendingPathComponent("image.txt")
        let second = scratch.path("b.txt")
        try "second bytes".write(toFile: second, atomically: true, encoding: .utf8)
        let archive = scratch.path("flat.zip")
        try "old archive bytes".write(toFile: archive, atomically: true, encoding: .utf8)
        archiver.archiveFlat(files: [first, second], to: archive, password: "synthetic-password")

        let listed = try entries(of: archive)
        #expect(listed.map(\.name).sorted() == ["b.txt", "image.txt"])
        #expect(listed.filter { !$0.encrypted }.isEmpty)
        #expect(try extracted("b.txt", from: archive, password: "synthetic-password") == "second bytes")
    }

    @Test func thePasswordIsTypedOnZipsTerminalNotGivenAsAnArgument() throws {
        let scratch = try Scratch()
        // A stand-in for zip that records its arguments and reads the two
        // answers from its controlling terminal, as zip -e does.
        let tool = scratch.path("zip-stand-in.sh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(scratch.path("arguments"))'
        exec < /dev/tty
        printf 'Enter password: ' >&2; stty -echo; IFS= read -r first; stty echo; printf '\\n' >&2
        printf 'Verify password: ' >&2; stty -echo; IFS= read -r second; stty echo; printf '\\n' >&2
        printf '%s\\n%s\\n' "$first" "$second" > '\(scratch.path("typed"))'
        """.write(toFile: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool)
        let file = scratch.path("image.txt")
        try "synthetic".write(toFile: file, atomically: true, encoding: .utf8)

        ProtectedZipArchiver(tool: tool).archiveFlat(files: [file], to: scratch.path("flat.zip"), password: "synthetic pass phrase")

        let arguments = try #require(scratch.text(scratch.path("arguments"))).split(separator: "\n").map(String.init)
        #expect(arguments == ["-q", "-j", "-e", scratch.path("flat.zip"), file])
        #expect(scratch.text(scratch.path("typed")) == "synthetic pass phrase\nsynthetic pass phrase\n")
    }

    @Test func protectedArchivesOpenWithTheSamePasswordGivenToUnzip() throws {
        let scratch = try Scratch()
        // Spaces, a quote, non-ASCII letters and a control character reach zip unchanged.
        let password = "Synthetic pä\"ss \u{15}wörd 9"
        let folder = try scratch.folder("STUDY", text: "synthetic study bytes")
        let original = scratch.path("export.zip")
        try archiver.archive(items: [folder], to: original, password: password, deletingSources: false)
        #expect(try extracted("STUDY/image.txt", from: original, password: password) == "synthetic study bytes")
        #expect(try extracted("STUDY/image.txt", from: original, password: "wrong password") == nil)

        let attachment = scratch.path("Images-attachment.zip")
        try archiver.protectedAttachment(from: original, to: attachment, password: password)
        let inner = scratch.path("inner.zip")
        let payload = try #require(try extractedData("Images.zip", from: attachment, password: password))
        try payload.write(to: URL(fileURLWithPath: inner))
        #expect(try extracted("STUDY/image.txt", from: inner, password: password) == "synthetic study bytes")
        #expect(try extractedData("Images.zip", from: attachment, password: "wrong password") == nil)
        #expect(!scratch.stagingLeft)
    }

    @Test func theEmailAttachmentShowsOnlyAGenericEncryptedEntry() throws {
        let scratch = try Scratch()
        let folder = try scratch.folder("PATIENT NAME")
        let original = scratch.path("export.zip")
        try archiver.archive(items: [folder], to: original, password: "synthetic-password", deletingSources: false)
        let attachment = scratch.path("Images-attachment.zip")
        try archiver.protectedAttachment(from: original, to: attachment, password: "synthetic-password")

        let listed = try entries(of: attachment)
        #expect(listed.map(\.name) == ["Images.zip"])
        #expect(listed.filter { !$0.encrypted }.isEmpty)
        #expect(scratch.exists(original))

        // No password, or a missing source: refused, and the attachment made before stays.
        let saved = try Data(contentsOf: URL(fileURLWithPath: attachment))
        #expect(throws: (any Error).self) { try archiver.protectedAttachment(from: original, to: attachment, password: "") }
        #expect(throws: (any Error).self) { try archiver.protectedAttachment(from: original, to: attachment, password: nil) }
        #expect(throws: (any Error).self) {
            try archiver.protectedAttachment(from: scratch.path("missing"), to: attachment, password: "synthetic-password")
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: attachment)) == saved)
        #expect(!scratch.stagingLeft)
    }
}
