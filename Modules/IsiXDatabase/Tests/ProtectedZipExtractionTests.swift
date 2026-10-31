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

/// A folder of its own for one test, removed at the end, with synthetic files
/// and the archives /usr/bin/zip makes of them.
private final class ExtractionScratch {
    let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("zip-extraction-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ component: String) -> String {
        (root as NSString).appendingPathComponent(component)
    }

    func write(_ text: String, to name: String) throws {
        try text.write(toFile: path(name), atomically: true, encoding: .utf8)
    }

    func text(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Adds `names` to `archive` with zip, encrypted with -P when a password
    /// is given (Process passes it as the file-system representation, as the
    /// archives made before by the application).
    func zip(_ archive: String, _ names: [String], password: String? = nil) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ProtectedZipArchiver.systemZip)
        task.arguments = ["-q"] + (password.map { ["-P", $0] } ?? []) + [path(archive)] + names
        task.currentDirectoryURL = URL(fileURLWithPath: root)
        try task.run()
        task.waitUntilExit()
        #expect(task.terminationStatus == 0)
    }

    func extract(_ archive: String, password: String?, into folder: String, tool: String = ProtectedZipArchiver.systemUnzip,
                 continuing: () -> Bool = { true }) throws -> Int32 {
        try ProtectedZipArchiver.extract(path(archive), to: path(folder), password: password, in: root, tool: tool,
                                         continuing: continuing)
    }
}

@Suite struct ProtectedZipExtractionTests {

    @Test func theCommandCarriesNoPassword() {
        let arguments = ProtectedZipArchiver.extractionArguments(archive: "/in/a.zip", destination: "/out/folder")
        #expect(arguments == ["-qq", "-o", "-d", "/out/folder", "/in/a.zip"])
        #expect(!arguments.contains("-P"))
    }

    @Test func thePasswordIsTypedOnUnzipsTerminalNotGivenAsAnArgument() throws {
        let scratch = try ExtractionScratch()
        // A stand-in for unzip that records its arguments and what every
        // process shows in ps while it waits, then reads the answer from its
        // controlling terminal, as unzip does.
        let tool = scratch.path("unzip-stand-in.sh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(scratch.path("arguments"))'
        /bin/ps -axww -o args= > '\(scratch.path("ps"))'
        exec < /dev/tty
        printf '[a.zip] image.dcm password: ' >&2; stty -echo; IFS= read -r answer; stty echo; printf '\\n' >&2
        printf '%s\\n' "$answer" > '\(scratch.path("typed"))'
        """.write(toFile: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool)
        let password = "synthetic pass 'word\" ç"

        let status = try scratch.extract("a.zip", password: password, into: "out", tool: tool)
        #expect(status == 0)
        let arguments = scratch.text(scratch.path("arguments")) ?? ""
        #expect(arguments == ["-qq", "-o", "-d", scratch.path("out"), scratch.path("a.zip")].joined(separator: "\n") + "\n")
        let shown = scratch.text(scratch.path("ps")) ?? ""
        #expect(shown.contains("unzip-stand-in.sh"))
        #expect(!shown.contains("synthetic pass"))
        let decomposed = String(decoding: ZipPasswordTerminal.typed(password).dropLast(), as: UTF8.self)
        #expect(scratch.text(scratch.path("typed")) == decomposed + "\n")
    }

    @Test func anEncryptedArchiveOpensWithItsPasswordAndNotWithAnother() throws {
        let scratch = try ExtractionScratch()
        try scratch.write("first synthetic DICOM", to: "image.dcm")
        try scratch.write("second synthetic DICOM", to: "other.dcm")
        try scratch.zip("encrypted.zip", ["image.dcm", "other.dcm"], password: "synthetic-secret")

        #expect(try scratch.extract("encrypted.zip", password: "synthetic-secret", into: "right") == 0)
        #expect(scratch.text(scratch.path("right/image.dcm")) == "first synthetic DICOM")
        #expect(scratch.text(scratch.path("right/other.dcm")) == "second synthetic DICOM")

        // unzip -P answered 82 here: no file found because of a bad password.
        let started = ContinuousClock.now
        #expect(try scratch.extract("encrypted.zip", password: "wrong", into: "wrong") == 82)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: scratch.path("wrong"))) ?? []).isEmpty)
    }

    @Test func aWrongPasswordLeavesOnlyTheEncryptedEntriesOfAMixedArchive() throws {
        let scratch = try ExtractionScratch()
        try scratch.write("plain synthetic DICOM", to: "plain.dcm")
        try scratch.write("encrypted synthetic DICOM", to: "image.dcm")
        try scratch.zip("mixed.zip", ["plain.dcm"])
        try scratch.zip("mixed.zip", ["image.dcm"], password: "synthetic-secret")

        // 1, as with -P: the plain entry came out, the encrypted one was skipped.
        #expect(try scratch.extract("mixed.zip", password: "wrong", into: "wrong") == 1)
        #expect(scratch.text(scratch.path("wrong/plain.dcm")) == "plain synthetic DICOM")
        #expect(!FileManager.default.fileExists(atPath: scratch.path("wrong/image.dcm")))

        #expect(try scratch.extract("mixed.zip", password: "synthetic-secret", into: "right") == 0)
        #expect(scratch.text(scratch.path("right/image.dcm")) == "encrypted synthetic DICOM")
    }

    @Test func archivesMadeWithAccentsOrControlCharactersInThePasswordStillOpen() throws {
        let scratch = try ExtractionScratch()
        try scratch.write("synthetic DICOM", to: "image.dcm")
        for (index, password) in ["pässwörd çà", "tab\tand space", "a\u{3}b"].enumerated() {
            try scratch.zip("archive\(index).zip", ["image.dcm"], password: password)
            #expect(try scratch.extract("archive\(index).zip", password: password, into: "out\(index)") == 0)
            #expect(scratch.text(scratch.path("out\(index)/image.dcm")) == "synthetic DICOM")
        }
    }

    @Test func aPasswordOverUnzipsLimitIsRefused() throws {
        let scratch = try ExtractionScratch()
        try scratch.write("synthetic DICOM", to: "image.dcm")
        let password = String(repeating: "x", count: 100)
        try scratch.zip("long.zip", ["image.dcm"], password: password)
        let started = ContinuousClock.now
        #expect(try scratch.extract("long.zip", password: password, into: "out") == ZipPasswordTerminal.badPassword)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(!FileManager.default.fileExists(atPath: scratch.path("out/image.dcm")))
    }

    @Test func stoppingEndsUnzipWithOrWithoutAPassword() throws {
        let scratch = try ExtractionScratch()
        let tool = scratch.path("slow-unzip.sh")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(toFile: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool)
        for password in ["synthetic-secret", nil] {
            var calls = 0
            let started = ContinuousClock.now
            let status = try scratch.extract("a.zip", password: password, into: "out", tool: tool) {
                calls += 1
                return calls < 3
            }
            #expect(ContinuousClock.now - started < .seconds(10), "password: \(password ?? "none")")
            #expect(status != 0, "password: \(password ?? "none")")
        }
    }
}
