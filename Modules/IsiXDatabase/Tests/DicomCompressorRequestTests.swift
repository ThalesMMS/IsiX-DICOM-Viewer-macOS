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
import IsiXPreferences
@testable import IsiXDatabase

@Suite struct DicomCompressorRequestTests {

    /// The preferences of an application whose user chose JPEG 2000 for
    /// everything and keeps unreadable files where they are.
    private func preferences() -> MemoryPreferences {
        MemoryPreferences(["CompressionSettings": [["modality": "default", "compression": "3", "quality": "0"]],
                           "CompressionSettingsLowRes": [["modality": "default", "compression": "4", "quality": "0"]],
                           "CompressionResolutionLimit": 512,
                           "UseJPEGColorSpace": true,
                           "DecompressMoveIfFail": false])
    }

    private func request(_ options: [AnyHashable: Any]?, _ store: MemoryPreferences? = nil, directory: String? = nil) -> DicomCompressorRequest {
        DicomCompressorRequest(directory: directory, options: options, preferences: store ?? preferences())
    }

    /// What the conversion of a request is told.
    private func settings(_ request: DicomCompressorRequest) -> [String: Any] {
        DecompressConversion.settings(from: request.preferences) as? [String: Any] ?? [:]
    }

    // No folder and the helper's word for none ask for the same thing: each
    // file converted where it is.
    @Test func noFolderAndItsLiteralAreTheSameDestination() {
        #expect(request(nil, directory: nil).destination == nil)
        #expect(request(nil, directory: "sameAsDestination").destination == nil)
        #expect(request(nil, directory: "/tmp/out").destination == "/tmp/out")
    }

    // Without options the conversion reads what the application's own does.
    @Test func withoutOptionsThePreferencesStand() {
        let store = preferences()
        for options in [nil, [:]] as [[AnyHashable: Any]?] {
            let asked = request(options, store)
            #expect(DecompressConversion.settings(from: store).isEqual(settings(asked)))
            #expect(settings(asked).count == 4)
            #expect(!asked.moveIfUnreadable)
        }
    }

    // What a disc publisher asks when it compresses in JPEG: its own list of
    // settings, a limit of 1 given as text, and the unreadable files moved.
    // The other settings are still the application's.
    @Test func anOptionReplacesThePreferenceOfItsName() throws {
        let jpeg: [[String: String]] = [["modality": "default", "compression": "2", "quality": "1"]]
        let options: [AnyHashable: Any] = ["JPEGinsteadJPEG2000": true, "DecompressMoveIfFail": true,
                                           "CompressionSettings": jpeg, "CompressionResolutionLimit": "1"]
        let asked = request(options)
        let told = settings(asked)
        #expect(asked.moveIfUnreadable)
        #expect(told["CompressionSettings"] as? [[String: String]] == jpeg)
        #expect(told["CompressionResolutionLimit"] as? String == "1")
        let lowResolution = try #require(told["CompressionSettingsLowRes"] as? [[String: String]])
        #expect(lowResolution.first?["compression"] == "4")
        #expect(told["UseJPEGColorSpace"] as? Bool == true)
        // Not settings of the conversion: the helper never read the first,
        // and the second is told apart.
        #expect(told["JPEGinsteadJPEG2000"] == nil)
        #expect(told["DecompressMoveIfFail"] == nil)
        // The settings choose JPEG for an image of any size.
        let target = DecompressConversion.targetSyntax(compress: true, settings: DecompressConversion.settings(from: asked.preferences),
                                                       modality: "CT", rows: 512, columns: 512,
                                                       originalSyntax: DecompressConversion.explicitLittleEndian,
                                                       pixelDataCompressed: false)
        #expect(target?.syntax == "1.2.840.10008.1.2.4.70")
        // With the application's own settings the same image goes to JPEG 2000.
        let own = DecompressConversion.targetSyntax(compress: true, settings: DecompressConversion.settings(from: request(nil).preferences),
                                                    modality: "CT", rows: 512, columns: 512,
                                                    originalSyntax: DecompressConversion.explicitLittleEndian,
                                                    pixelDataCompressed: false)
        #expect(own?.syntax == "1.2.840.10008.1.2.4.90")
    }

    // DecompressMoveIfFail as a preference is read, a number or its text; an
    // option that says no wins over a preference that says yes.
    @Test func moveIfFailIsReadAsABoolean() {
        let moving = MemoryPreferences(["DecompressMoveIfFail": true])
        #expect(request(nil, moving).moveIfUnreadable)
        #expect(!request(["DecompressMoveIfFail": false], moving).moveIfUnreadable)
        #expect(!request(["DecompressMoveIfFail": "0"], moving).moveIfUnreadable)
        #expect(request(["DecompressMoveIfFail": "1"]).moveIfUnreadable)
        #expect(request(["DecompressMoveIfFail": 1]).moveIfUnreadable)
    }

    // The limits of an archive among the files are the application's.
    @Test func theArchiveBudgetIsThePreferences() {
        let store = MemoryPreferences(["ArchiveExpansionLimitFiles": 7])
        #expect(request(nil, store).archiveBudget == ArchiveExpansionBudget.imported(from: store))
    }

    // The options of a property list are those of its dictionary; a path
    // with no file, or a file that is no dictionary, gives none.
    @Test func optionsAreReadFromAPropertyList() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("compressor-options-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ list: Any, _ name: String) throws -> String {
            let path = folder.appendingPathComponent(name).path
            try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
            return path
        }
        let list = try write(["DecompressMoveIfFail": true, "CompressionResolutionLimit": "1"], "options.plist")
        let options = try #require(DicomCompressorRequest.options(atPath: list))
        #expect(options["DecompressMoveIfFail"] as? Bool == true)
        #expect(options["CompressionResolutionLimit"] as? String == "1")
        #expect(request(options).moveIfUnreadable)

        #expect(DicomCompressorRequest.options(atPath: nil) == nil)
        #expect(DicomCompressorRequest.options(atPath: folder.appendingPathComponent("absent.plist").path) == nil)
        #expect(DicomCompressorRequest.options(atPath: try write(["a", "b"], "array.plist")) == nil)
    }

    // A batch is the conversion of its arguments with the request's settings.
    @Test func aBatchWithoutTheServiceCannotStart() {
        let batch = request(["DecompressMoveIfFail": true]).batch(arguments: ["sameAsDestination", "compress", "/tmp/a"], service: nil)
        #expect(throws: DecompressServiceError.self) { try batch.launch() }
        #expect(!batch.isRunning)
    }

    /// A helper that ends as soon as it is started.
    private final class Batch: CompressionHelperProcess {
        func launch() throws {}
        var isRunning: Bool { false }
        func terminate() {}
        var terminationStatus: Int32 { 0 }
        var endedOnUncaughtSignal: Bool { false }
    }

    private func environment() -> CompressionHelperRun.Environment {
        CompressionHelperRun.Environment(progress: { _ in }, now: { 0 }, sleep: { _ in }, logStackTrace: { _ in },
                                         logLaunchFailure: { _ in }, crashed: { _ in })
    }

    // A thread cancelled while a batch runs: that batch ends, and the ones
    // after it are not started.
    @Test func aCancelledRunStartsNoOtherBatch() {
        let files = (0..<5).map { "file\($0)" }
        var batches: [[String]] = []
        var cancelling = environment()
        cancelling.cancelled = { batches.count == 2 }
        #expect(CompressionHelperRun.run(files, mode: "decompressList", destination: nil, chunkSize: 2, environment: cancelling) {
            batches.append(Array($0.dropFirst(2)))
            return Batch()
        })
        #expect(batches == [["file0", "file1"], ["file2", "file3"]])

        // Unless told otherwise, a run is never cancelled.
        batches = []
        #expect(CompressionHelperRun.run(files, mode: "decompressList", destination: nil, chunkSize: 2, environment: environment()) {
            batches.append(Array($0.dropFirst(2)))
            return Batch()
        })
        #expect(batches.count == 3)
    }
}
