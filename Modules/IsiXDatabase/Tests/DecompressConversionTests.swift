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

@Suite struct DecompressConversionTests {

    /// A stand-in for the Decompress service, by the name of the file: "bad"
    /// cannot be read, "keep" stays as it is, "crash" ends the service, and
    /// anything else is converted to "converted:" and its contents.
    private final class Converter: DecompressConverting, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []

        var files: [String] {
            lock.lock()
            defer { lock.unlock() }
            return asked
        }

        func convertFile(atPath path: String, output: FileHandle, compress: Bool, settings: NSDictionary)
            -> Result<DecompressConversionOutcome, DecompressServiceError> {
            lock.lock()
            asked.append((path as NSString).lastPathComponent)
            lock.unlock()
            let name = (path as NSString).lastPathComponent
            if name.contains("crash") { return .failure(.crashed) }
            if name.contains("bad") { return .success(.unreadable) }
            if name.contains("keep") { return .success(.unchanged) }
            guard let contents = FileManager.default.contents(atPath: path) else { return .success(.unreadable) }
            output.write(Data("converted:".utf8) + contents)
            return .success(.written)
        }
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("decompress-conversion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func text(_ url: URL) -> String? {
        FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) }
    }

    private func leftovers(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { $0.hasPrefix(".horos-") } ?? []
    }

    @Test func aFileOfTheSameNameGoesBesideTheOneAlreadyThere() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("INCOMING")
        let first = root.appendingPathComponent("a/1.dcm"), second = root.appendingPathComponent("b/1.dcm")
        try write("first", first)
        try write("second", second)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for mode in [DecompressConversion.Mode.compress, .decompressList] {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try write("first", first)
            try write("second", second)
            let summary = DecompressConversion.run([first.path, second.path], mode: mode, destination: destination.path,
                                                   settings: [:], moveIfUnreadable: false, converter: Converter())
            #expect(summary.succeeded && !summary.crashed)
            #expect(text(destination.appendingPathComponent("1.dcm")) == "converted:first")
            #expect(text(destination.appendingPathComponent("1-1.dcm")) == "converted:second")
            #expect(!FileManager.default.fileExists(atPath: first.path) && !FileManager.default.fileExists(atPath: second.path))
            #expect(leftovers(destination).isEmpty)
        }
    }

    @Test func aConversionInPlaceReplacesItsSource() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.dcm")
        try write("pixels", file)
        let summary = DecompressConversion.run([file.path], mode: .compress, destination: nil, settings: [:],
                                               moveIfUnreadable: false, converter: Converter())
        #expect(summary.succeeded)
        #expect(text(file) == "converted:pixels")
        #expect(leftovers(root).isEmpty)
    }

    @Test func aFileThatStaysAsItIsIsMovedWithoutReplacing() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("out")
        let file = root.appendingPathComponent("keep.dcm")
        try write("original", file)
        try write("already there", destination.appendingPathComponent("keep.dcm"))
        let summary = DecompressConversion.run([file.path], mode: .compress, destination: destination.path, settings: [:],
                                               moveIfUnreadable: false, converter: Converter())
        #expect(summary.succeeded)
        #expect(text(destination.appendingPathComponent("keep.dcm")) == "already there")
        #expect(text(destination.appendingPathComponent("keep-1.dcm")) == "original")
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // In place, nothing moves and nothing is written.
        try write("in place", file)
        #expect(DecompressConversion.run([file.path], mode: .compress, destination: nil, settings: [:],
                                         moveIfUnreadable: false, converter: Converter()).succeeded)
        #expect(text(file) == "in place")
    }

    @Test func aFileTheServiceCannotReadFailsAndMovesOnlyWhenAsked() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("bad.dcm")
        try write("garbage", file)

        var summary = DecompressConversion.run([file.path], mode: .compress, destination: destination.path, settings: [:],
                                               moveIfUnreadable: false, converter: Converter())
        #expect(!summary.succeeded && !summary.crashed)
        #expect(text(file) == "garbage")
        summary = DecompressConversion.run([file.path], mode: .decompressList, destination: destination.path, settings: [:],
                                           moveIfUnreadable: true, converter: Converter())
        #expect(!summary.succeeded)
        #expect(text(file) == "garbage")
        summary = DecompressConversion.run([file.path], mode: .compress, destination: destination.path, settings: [:],
                                           moveIfUnreadable: true, converter: Converter())
        #expect(!summary.succeeded)
        #expect(text(destination.appendingPathComponent("bad.dcm")) == "garbage")
        #expect(leftovers(destination).isEmpty)
    }

    @Test func theListStopsAtAFileTheServiceDidNotSurvive() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let files = ["one.dcm", "crash.dcm", "two.dcm"].map { root.appendingPathComponent($0) }
        for file in files { try write(file.lastPathComponent, file) }
        let converter = Converter()
        let summary = DecompressConversion.run(files.map(\.path), mode: .compress, destination: destination.path,
                                               settings: [:], moveIfUnreadable: false, converter: converter)
        #expect(!summary.succeeded && summary.crashed)
        #expect(converter.files == ["one.dcm", "crash.dcm"])
        #expect(text(files[1]) == "crash.dcm" && text(files[2]) == "two.dcm")
        #expect(leftovers(destination).isEmpty)
    }

    @Test func noConversionWhereNoTemporaryFileCanBeMade() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.dcm")
        try write("pixels", file)
        let converter = Converter()
        let summary = DecompressConversion.run([file.path], mode: .compress,
                                               destination: root.appendingPathComponent("missing").path,
                                               settings: [:], moveIfUnreadable: false, converter: converter)
        #expect(!summary.succeeded)
        #expect(converter.files.isEmpty)
        #expect(text(file) == "pixels")
    }

    @Test func freeNamesKeepTheExtension() {
        #expect(DecompressConversion.freeNameCandidate("/in/1.dcm", attempt: 0) == "/in/1.dcm")
        #expect(DecompressConversion.freeNameCandidate("/in/1.dcm", attempt: 2) == "/in/1-2.dcm")
        #expect(DecompressConversion.freeNameCandidate("/in/IM0001", attempt: 1) == "/in/IM0001-1")
    }

    @Test func theSettingsAreTheConversionKeysTheDefaultsHave() {
        let defaults = UserDefaults(suiteName: "decompress-conversion-\(UUID().uuidString)")!
        defaults.set(512, forKey: "CompressionResolutionLimit")
        defaults.set("other", forKey: "Unrelated")
        let settings = DecompressConversion.settings(from: defaults)
        #expect(settings.count == 1)
        #expect((settings["CompressionResolutionLimit"] as? NSNumber)?.intValue == 512)
    }

    @Test func theReportTypeFollowsTheExtension() {
        #expect(DecompressService.reportMIMEType(ofPath: "/tmp/report.html") == "text/html")
        #expect(DecompressService.reportMIMEType(ofPath: "/tmp/IM0001.xml").hasSuffix("/xml"))
        #expect(DecompressService.reportMIMEType(ofPath: "/tmp/noextension") == "text/html")
    }

    @Test func theServiceIsToldAbsolutePaths() {
        #expect(DecompressService.absolutePath("/data/in/1.dcm") == "/data/in/1.dcm")
        let relative = DecompressService.absolutePath("in/1.dcm")
        #expect(relative == FileManager.default.currentDirectoryPath + "/in/1.dcm")
    }

    @Test func theSyntaxFollowsTheSettingsOfTheModality() {
        let rows: [[String: Any]] = [["modality": "default", "compression": 3, "quality": 0],
                                     ["modality": "MR", "compression": 4, "quality": 2],
                                     ["modality": "CR", "compression": 1, "quality": 0],
                                     ["modality": "US", "compression": 2, "quality": 7]]
        let low: [[String: Any]] = [["modality": "default", "compression": 1, "quality": 0]]
        let settings: NSDictionary = ["CompressionSettings": rows, "CompressionSettingsLowRes": low,
                                      "CompressionResolutionLimit": "256"]
        func plan(_ modality: String?, _ side: Int = 512, original: String = DecompressConversion.explicitLittleEndian,
                  compressed: Bool = false) -> String? {
            DecompressConversion.targetSyntax(compress: true, settings: settings, modality: modality, rows: side, columns: side,
                                              originalSyntax: original, pixelDataCompressed: compressed)
                .map { "\($0.syntax) \($0.quality)" }
        }
        #expect(DecompressConversion.targetSyntax(compress: false, settings: settings, modality: "CT", rows: nil, columns: nil,
                                                  originalSyntax: "1.2.840.10008.1.2.4.90", pixelDataCompressed: true)?.syntax
                == DecompressConversion.explicitLittleEndian)
        #expect(plan("CT") == "1.2.840.10008.1.2.4.90 0")
        #expect(plan("MR") == "1.2.840.10008.1.2.4.81 2")
        #expect(plan("US") == "1.2.840.10008.1.2.4.70 0")
        #expect(plan("CR") == nil)
        #expect(plan("SR") == nil)
        #expect(plan(nil) == "1.2.840.10008.1.2.4.90 0")
        #expect(plan("CT", 200) == nil)
        #expect(plan("CT", original: "1.2.840.10008.1.2.4.91", compressed: true) == nil)
        #expect(plan("CT", original: "1.2.840.10008.1.2.4.80", compressed: true) == "1.2.840.10008.1.2.4.90 0")
        #expect(plan("US", original: "1.2.840.10008.1.2.4.70", compressed: true) == nil)
        // The smaller side decides, rows first, a side of zero taking the other.
        #expect(DecompressConversion.targetSyntax(compress: true, settings: settings, modality: "CT", rows: 0, columns: 512,
                                                  originalSyntax: "", pixelDataCompressed: false)?.syntax == "1.2.840.10008.1.2.4.90")
        #expect(DecompressConversion.targetSyntax(compress: true, settings: settings, modality: "CT", rows: 512, columns: 100,
                                                  originalSyntax: "", pixelDataCompressed: false) == nil)
    }
}
