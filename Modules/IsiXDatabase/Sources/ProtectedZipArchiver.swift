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

import Darwin
import Foundation

/// The ZIP archives of the exports, made with /usr/bin/zip and the arguments
/// of `ZipCommand`: files at the archive's root, items of one folder under
/// their names (published only once zip succeeded, the previous archive kept
/// until then), and the protected attachment of "Send by e-mail". Archives
/// to import are expanded with /usr/bin/unzip (`extract`).
///
/// It blocks the calling thread until zip ends, without running its run loop,
/// so that a caller on the main thread is not entered again while it waits.
public struct ProtectedZipArchiver: Sendable {

    /// The zip the system installs.
    public static let systemZip = "/usr/bin/zip"

    private let tool: String

    public init(tool: String = ProtectedZipArchiver.systemZip) {
        self.tool = tool
    }

    // MARK: Archives

    /// The files at the archive's root, in groups of `ZipCommand.chunkSize`,
    /// after removing what the destination held. What zip answers is not
    /// checked: the web portal sends whatever it made.
    public func archiveFlat(files: [String], to archive: String, password: String?) {
        try? FileManager.default.removeItem(atPath: archive)
        for chunk in ZipCommand.chunks(count: files.count) {
            _ = try? run(ZipCommand.flatArguments(encrypted: ZipCommand.encrypts(password), archive: archive, files: Array(files[chunk])),
                         in: nil, password: password)
        }
    }

    /// The items, which must all exist and share one folder, each under its
    /// own name. The archive replaces the destination only when zip succeeded;
    /// the sources are then removed if asked. A failure keeps the sources and
    /// what the destination held.
    public func archive(items: [String], to destination: String, password: String?, deletingSources: Bool) throws {
        guard let first = items.first, !first.isEmpty, !destination.isEmpty else {
            throw Self.failure(code: NSFileWriteInvalidFileNameError,
                               NSLocalizedString("A source and destination are required for ZIP export.", comment: ""))
        }
        let staging = try Staging(destination: destination)
        let files = FileManager.default
        guard let names = ZipCommand.entryNames(items, exists: { files.fileExists(atPath: $0) }), !names.isEmpty,
              (try? run(ZipCommand.recursiveArguments(encrypted: ZipCommand.encrypts(password), archive: staging.archivePath, names: names),
                        in: (first as NSString).deletingLastPathComponent, password: password)) == 0 else {
            throw Self.failure(code: NSFileWriteUnknownError,
                               NSLocalizedString("ZIP export could not be completed. The uncompressed source files were kept.", comment: ""),
                               path: destination)
        }
        try staging.commit()
        if deletingSources {
            for item in items { try? files.removeItem(atPath: item) }
        }
    }

    /// ZIP encryption leaves entry names readable: the archive is wrapped in a
    /// generic entry, Images.zip, so that patient and study names are inside
    /// the encrypted payload. A password is required.
    public func protectedAttachment(from source: String, to destination: String, password: String?) throws {
        guard let password, !password.isEmpty else {
            throw Self.failure(code: NSFileWriteUnknownError, NSLocalizedString("A password is required for email attachments.", comment: ""))
        }
        let files = FileManager.default
        let temporary = (NSTemporaryDirectory() as NSString).appendingPathComponent("horos-email-" + UUID().uuidString)
        defer { try? files.removeItem(atPath: temporary) }
        try files.createDirectory(atPath: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let payload = (temporary as NSString).appendingPathComponent("Images.zip")
        try files.copyItem(atPath: source, toPath: payload)
        try archive(items: [payload], to: destination, password: password, deletingSources: false)
    }

    // MARK: zip

    /// Runs zip and waits for it; its exit status. With a password, zip runs
    /// on a terminal of its own, where the password is typed
    /// (`ZipPasswordTerminal`); without one, it is a plain process waited on
    /// a semaphore.
    private func run(_ arguments: [String], in directory: String?, password: String?) throws -> Int32 {
        if let password, ZipCommand.encrypts(password) {
            return try ZipPasswordTerminal.run(tool: tool, arguments: arguments, directory: directory, password: password)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        if let directory {
            task.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        try task.run()
        finished.wait()
        return task.terminationStatus
    }

    // MARK: unzip

    /// The unzip the system installs.
    public static let systemUnzip = "/usr/bin/unzip"

    /// unzip's command: quiet (-qq), overwriting (-o), into `destination`.
    /// It never holds a password, which every process could read (`ps`).
    public static func extractionArguments(archive: String, destination: String) -> [String] {
        ["-qq", "-o", "-d", destination, archive]
    }

    /// Expands `archive` into `destination` with unzip run in `directory`, and
    /// answers its exit status. With a password, unzip runs on a terminal of
    /// its own where the password is typed when an entry asks for it
    /// (`ZipPasswordTerminal`): a wrong one leaves its entries out, as -P did.
    /// Without one, it is a plain process reading nothing, which reports an
    /// encrypted entry instead of asking. `continuing` is called on the
    /// calling thread about every 20 ms while unzip runs; false stops unzip.
    public static func extract(_ archive: String, to destination: String, password: String?, in directory: String?,
                               tool: String = ProtectedZipArchiver.systemUnzip, continuing: () -> Bool) throws -> Int32 {
        let arguments = extractionArguments(archive: archive, destination: destination)
        if let password {
            return try ZipPasswordTerminal.extract(tool: tool, arguments: arguments, directory: directory,
                                                   password: password, continuing: continuing)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        if let directory {
            task.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        task.standardInput = FileHandle.nullDevice
        try task.run()
        while task.isRunning {
            if !continuing() {
                task.terminate()
                task.waitUntilExit()
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return task.terminationStatus
    }

    private static func failure(code: Int, _ description: String, path: String? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: description]
        if let path { info[NSFilePathErrorKey] = path }
        return NSError(domain: NSCocoaErrorDomain, code: code, userInfo: info)
    }

    /// A private folder beside the destination, where zip writes; the archive
    /// is renamed over the destination, on the same volume, so the previous
    /// one stays until a complete replacement is there. The folder goes with
    /// this object.
    private final class Staging {
        private let destination: URL
        private let folder: URL
        let archivePath: String

        init(destination path: String) throws {
            let destination = URL(fileURLWithPath: path).standardizedFileURL
            let folder = destination.deletingLastPathComponent().appendingPathComponent(".horos-zip-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            self.destination = destination
            self.folder = folder
            archivePath = folder.appendingPathComponent("archive.zip").path
        }

        func commit() throws {
            let failure = archivePath.withCString { source in
                destination.path.withCString { target in Darwin.rename(source, target) == 0 ? 0 : errno }
            }
            guard failure == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [NSFilePathErrorKey: destination.path])
            }
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
