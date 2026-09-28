//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

extension DicomWebMultipartLimits {
    /// A whole study may be retrieved at once and goes to disk part by part, so
    /// only the headers and the size of one object are bounded.
    static let horosRetrieve = DicomWebMultipartLimits(maximumHeaderBytes: 64 * 1024,
                                                       maximumPartBytes: 1 << 34,
                                                       maximumPartCount: 1_000_000,
                                                       maximumTotalBytes: 1 << 50)
}

/// Writes the application/dicom parts of a WADO-RS response into a staging
/// directory it creates and owns (#197). Nothing reaches the database until
/// the whole response has been validated: a failure, a cancellation or a part
/// of another type removes the directory with everything in it.
final class DICOMwebStagingSink: DicomWebRetrieveSink, @unchecked Sendable {
    enum Failure: Error { case existingDirectory, invalidContentType, unexpectedTransferSyntax, incomplete, emptyResponse }

    let directory: URL
    /// The transfer syntax asked for, or nil for "as stored". A part that names
    /// another syntax is refused; a part that names none is accepted.
    let transferSyntax: String?
    private let lock = NSLock()
    private var files: [URL] = []
    private var output: FileHandle?

    init(directory: URL, transferSyntax: String?) {
        self.directory = directory
        self.transferSyntax = transferSyntax
    }

    /// Creates the directory. A directory that already exists is the caller's
    /// and is never used or removed.
    func begin() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw Failure.existingDirectory }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func receive(_ event: DicomWebMultipartEvent) async throws { try accept(event) }

    func accept(_ event: DicomWebMultipartEvent) throws {
        lock.lock(); defer { lock.unlock() }
        // Each event drains what it autoreleased (#819): the thread that runs
        // the retrieve may never drain its pool while a whole study arrives.
        try autoreleasepool {
            switch event {
            case .partHeaders(let headers, _):
                guard output == nil else { throw Failure.incomplete }
                guard let type = headers.dicomWebHeaderValue("Content-Type"),
                      let media = try? DicomWebMediaType(type), media.type == "application/dicom"
                else { throw Failure.invalidContentType }
                if let wanted = transferSyntax, let sent = media.parameters["transfer-syntax"], sent != "*", sent != wanted {
                    throw Failure.unexpectedTransferSyntax
                }
                let file = directory.appendingPathComponent("\(files.count).dcm")
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                else { throw Failure.incomplete }
                files.append(file)
                output = try FileHandle(forWritingTo: file)
            case .payload(let data):
                guard let output = output else { throw Failure.incomplete }
                try output.write(contentsOf: data)
            case .partEnd:
                guard let open = output else { throw Failure.incomplete }
                try open.close()
                output = nil
            case .epilogue:
                break
            }
        }
    }

    /// The staged files, once every part has ended.
    func finish() throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        guard output == nil else { throw Failure.incomplete }
        guard !files.isEmpty else { throw Failure.emptyResponse }
        return files
    }

    /// Removes the directory and everything written into it.
    func discard() {
        lock.lock(); defer { lock.unlock() }
        try? output?.close()
        output = nil
        files = []
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Streaming extraction of a WADO-RS multipart file with DICOM-Swift's parser
/// into an owned staging directory. The retrieve itself runs through
/// `DicomWebClient`; this is the same parser and sink over a file.
enum DICOMwebMultipart {
    enum Failure: Error { case invalidContentType, malformedEnvelope, cancelled, emptyResponse }

    static func extract(from input: URL, contentType: String, into directory: URL,
                        chunkSize: Int = 64 * 1024, cancelled: () -> Bool = { false }) throws -> [URL] {
        guard chunkSize > 0 else { throw Failure.malformedEnvelope }
        var parser: DicomWebMultipartStreamParser
        do { parser = try DicomWebMultipartStreamParser(contentType: contentType, limits: .horosRetrieve) }
        catch { throw Failure.invalidContentType }
        let sink = DICOMwebStagingSink(directory: directory, transferSyntax: nil)
        // Never remove a caller-owned existing directory on a parsing failure.
        do { try sink.begin() } catch { throw Failure.malformedEnvelope }
        do {
            let source = try FileHandle(forReadingFrom: input)
            defer { try? source.close() }
            var atEnd = false
            while !atEnd {
                try autoreleasepool {
                    if cancelled() { throw Failure.cancelled }
                    let chunk = try source.read(upToCount: chunkSize) ?? Data()
                    atEnd = chunk.isEmpty
                    let events = atEnd ? try parser.finish() : try parser.feed(chunk)
                    for event in events { try sink.accept(event) }
                }
            }
            if cancelled() { throw Failure.cancelled }
            return try sink.finish()
        } catch {
            sink.discard()
            switch error {
            case Failure.cancelled: throw Failure.cancelled
            case DICOMwebStagingSink.Failure.invalidContentType: throw Failure.invalidContentType
            case DICOMwebStagingSink.Failure.emptyResponse: throw Failure.emptyResponse
            default: throw Failure.malformedEnvelope
            }
        }
    }
}
