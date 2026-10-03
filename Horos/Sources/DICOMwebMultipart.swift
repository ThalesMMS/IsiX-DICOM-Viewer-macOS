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
import DicomWebClient

extension Dictionary where Key == String, Value == String {
    /// HTTP field names are case insensitive; host response policy uses this
    /// without relying on helpers internal to the remote client's module.
    func horosHTTPHeaderValue(_ name: String) -> String? {
        first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

extension DicomWebMultipartLimits {
    /// A whole study may be retrieved at once and goes to disk part by part, so
    /// only the headers and the size of one object are bounded.
    static let horosRetrieve = DicomWebMultipartLimits(maximumHeaderBytes: 64 * 1024,
                                                       maximumPartBytes: 1 << 34,
                                                       maximumPartCount: 1_000_000,
                                                       maximumTotalBytes: 1 << 50)
}

/// Writes the application/dicom parts of a WADO-RS response into a staging
/// directory it creates and owns (#197). Without an object handler, nothing
/// reaches the database until the whole response has been validated: a
/// failure, a cancellation or a part of another type removes the directory
/// with everything in it. With one, each part is handed over as soon as it
/// has ended, while the rest of the response is still arriving; the handler
/// validates it and takes the file, or refuses it, which ends the retrieve.
/// What it took stays taken whatever happens next; a part still being
/// written is never handed over and goes with the directory.
///
/// @unchecked Sendable: DICOM-Swift's parser feeds the events on the request's
/// task while the caller finishes or discards the directory on its own thread.
/// `files`, `handedOver` and `output` are read and written only under `lock`,
/// which each event takes; `directory`, `transferSyntaxes` and
/// `objectHandler` never change.
final class DICOMwebStagingSink: DicomWebRetrieveSink, @unchecked Sendable {
    enum Failure: Error { case existingDirectory, invalidContentType, unexpectedTransferSyntax, incomplete, emptyResponse }
    /// The object handler refused a part, with its reason.
    struct Refused: Error { let reason: String }

    let directory: URL
    /// The transfer syntaxes asked for, or nil for "as stored". A part that
    /// names another syntax is refused; a part that names none is accepted.
    let transferSyntaxes: Set<String>?
    /// Takes a complete part's file, or returns why it refuses it.
    let objectHandler: ((URL) -> String?)?
    private let lock = NSLock()
    private var files: [URL] = []
    private var output: FileHandle?
    /// How many parts the object handler has taken.
    private(set) var handedOver = 0

    /// A list holding "*" asks for the objects as stored, whatever else it holds.
    init(directory: URL, transferSyntaxes: [String]?, objectHandler: ((URL) -> String?)? = nil) {
        self.directory = directory
        self.transferSyntaxes = transferSyntaxes.flatMap { $0.contains("*") ? nil : Set($0) }
        self.objectHandler = objectHandler
    }

    /// How many parts the object handler has taken so far.
    var objectsHandedOver: Int {
        lock.lock(); defer { lock.unlock() }
        return handedOver
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
                guard let type = headers.horosHTTPHeaderValue("Content-Type"),
                      let media = try? DicomWebMediaType(type), media.type == "application/dicom"
                else { throw Failure.invalidContentType }
                if let wanted = transferSyntaxes, let sent = media.parameters["transfer-syntax"], sent != "*", !wanted.contains(sent) {
                    throw Failure.unexpectedTransferSyntax
                }
                let file = directory.appendingPathComponent("\(files.count + handedOver).dcm")
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
                if let objectHandler, let file = files.last {
                    if let reason = objectHandler(file) {
                        try? FileManager.default.removeItem(at: file)
                        throw Refused(reason: reason)
                    }
                    files.removeLast()
                    handedOver += 1
                }
            case .epilogue:
                break
            }
        }
    }

    /// The staged files, once every part has ended: none with an object
    /// handler, which took them all.
    func finish() throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        guard output == nil else { throw Failure.incomplete }
        guard !files.isEmpty || handedOver > 0 else { throw Failure.emptyResponse }
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
        let sink = DICOMwebStagingSink(directory: directory, transferSyntaxes: nil)
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
