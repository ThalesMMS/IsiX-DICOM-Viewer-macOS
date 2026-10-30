/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// Compressing and decompressing files through the Decompress service, which
// the application drives a list at a time: what the Decompress helper did
// around DCMTK, the conversion itself being the service's. Why apart from the
// application: a corrupted file must bring down the service, not the
// application. The service reads each file through a handle and writes the
// converted one into a temporary file this creates beside the destination;
// everything else - the names, the renames, the archives - happens here.

/// What converts a file: the Decompress service in the application, a
/// stand-in in the tests.
public protocol DecompressConverting: Sendable {
    func convertFile(atPath path: String, output: FileHandle, compress: Bool, settings: NSDictionary)
        -> Result<DecompressConversionOutcome, DecompressServiceError>
}

extension DecompressService: DecompressConverting {}

public enum DecompressConversion {

    /// What a list was given to do: "compress" or "decompressList".
    public enum Mode: String, Sendable {
        case compress
        case decompressList
    }

    /// How a list went.
    public struct Summary: Equatable, Sendable {
        /// Every file was converted, or moved, as asked.
        public var succeeded = true
        /// The service ended during a conversion; the files after it were not tried.
        public var crashed = false
        public init() {}
    }

    /// The settings a conversion reads, from the application's preferences.
    public static func settings(from defaults: UserDefaults) -> NSDictionary {
        let settings = NSMutableDictionary()
        for key in DecompressService.settingsKeys {
            if let value = defaults.object(forKey: key) { settings[key] = value }
        }
        return settings
    }

    /// Converts `files` one after the other. `destination` is the folder the
    /// results go to, nil for each in place. A file of a zip or osirixzip
    /// archive is expanded instead. `moveIfUnreadable` (DecompressMoveIfFail)
    /// moves a file the service cannot read to the destination when
    /// compressing. Stops before the next file when `cancelled` says so, and
    /// after a conversion the service did not survive.
    public static func run(_ files: [String], mode: Mode, destination: String?, settings: NSDictionary,
                           moveIfUnreadable: Bool, converter: DecompressConverting,
                           cancelled: () -> Bool = { false }) -> Summary {
        var summary = Summary()
        for file in files {
            if cancelled() { break }
            let target = destination.map { ($0 as NSString).appendingPathComponent((file as NSString).lastPathComponent) }
                ?? file + " temp"

            let fileExtension = (file as NSString).pathExtension.lowercased()
            if fileExtension == "zip" || fileExtension == "osirixzip" {
                let outcome = extractDICOMArchive(file, to: target)
                if outcome != .extracted {
                    summary.succeeded = false
                    if outcome == .notExpanded {
                        surrenderUnreadableArchive(file, destination: target)
                    } else if outcome == .notExpandedForNow {
                        returnArchiveForRetry(file, destination: target)
                    }
                }
                continue
            }

            // In place, the converted file replaces its source; anywhere else
            // it never replaces what is already there.
            let converted = destination != nil ? target : file
            switch convert(file, into: converted, compress: mode == .compress, settings: settings, converter: converter) {
            case .placed:
                break
            case .failed:
                summary.succeeded = false
            case .crashed:
                summary.succeeded = false
                summary.crashed = true
                return summary
            case .unchanged:
                if destination != nil && !relocateDICOMFile(file, to: target) { summary.succeeded = false }
            case .unreadable:
                summary.succeeded = false
                if mode == .compress {
                    if moveIfUnreadable {
                        _ = relocateDICOMFile(file, to: target)
                    } else {
                        NSLog("compress : cannot read file: %@", file)
                    }
                }
            }
        }
        return summary
    }

    // MARK: - The transfer syntax

    /// Explicit VR Little Endian, what decompressing writes.
    public static let explicitLittleEndian = "1.2.840.10008.1.2.1"
    static let jpegLossless = "1.2.840.10008.1.2.4.70"
    static let jpegLSLossless = "1.2.840.10008.1.2.4.80"
    static let jpegLSNearLossless = "1.2.840.10008.1.2.4.81"
    static let jpeg2000Lossless = "1.2.840.10008.1.2.4.90"
    static let jpeg2000 = "1.2.840.10008.1.2.4.91"

    /// The transfer syntax the service writes a file in, and the quality
    /// (DCM_CompressionQuality, 0 lossless), from what the file says: nil when
    /// it stays as it is. Decompressing always writes Explicit VR Little
    /// Endian. Compressing writes what the Compression settings choose for
    /// the modality at the smaller of the rows and columns (CompressionChoice,
    /// the browser's choice too), unless that is none or the pixels are
    /// already compressed that way: JPEG lossless (process 14, first-order
    /// prediction), JPEG-LS and JPEG 2000, each lossless at quality 0.
    public static func targetSyntax(compress: Bool, settings: NSDictionary, modality: String?, rows: Int?, columns: Int?,
                                    originalSyntax: String, pixelDataCompressed: Bool) -> (syntax: String, quality: Int32)? {
        guard compress else { return (explicitLittleEndian, 0) }
        var resolution = 0
        for side in [rows, columns] {
            guard let side else { continue }
            if resolution == 0 || resolution > side { resolution = side }
        }
        let choice = CompressionChoice.choice(forModality: modality, resolution: resolution,
                                              resolutionLimit: intValue(settings["CompressionResolutionLimit"]),
                                              settings: settings["CompressionSettings"] as? [Any],
                                              lowResolutionSettings: settings["CompressionSettingsLowRes"] as? [Any])
        let quality = choice.quality ?? 0
        let alreadyCompressed: Bool
        switch choice.compression {
        case CompressionKind.jpegLS: alreadyCompressed = [jpegLSLossless, jpegLSNearLossless].contains(originalSyntax)
        case CompressionKind.jpeg2000: alreadyCompressed = [jpeg2000Lossless, jpeg2000].contains(originalSyntax)
        case CompressionKind.jpeg: alreadyCompressed = originalSyntax == jpegLossless
        default: alreadyCompressed = false
        }
        if pixelDataCompressed && alreadyCompressed { return nil }
        switch choice.compression {
        case CompressionKind.jpeg: return (jpegLossless, quality)
        case CompressionKind.jpegLS: return (quality == 0 ? jpegLSLossless : jpegLSNearLossless, quality)
        case CompressionKind.jpeg2000: return (quality == 0 ? jpeg2000Lossless : jpeg2000, quality)
        default: return nil
        }
    }

    /// -intValue of a number or a string; 0 for anything else.
    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return Int(number.int32Value) }
        if let string = value as? NSString { return Int(string.intValue) }
        return 0
    }

    enum FileResult: Equatable {
        case placed, unchanged, unreadable, failed, crashed
    }

    /// One file converted by the service into a temporary file beside
    /// `destination`, then put there; the source is removed when it is not
    /// the destination.
    static func convert(_ source: String, into destination: String, compress: Bool, settings: NSDictionary,
                        converter: DecompressConverting) -> FileResult {
        let pattern = ((destination as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".horos-codec-XXXXXX")
        var template = Array(pattern.utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        // No temporary file beside the destination: neither a conversion nor a
        // move could have been put there.
        guard descriptor >= 0 else { return .failed }
        let temporary = FileManager.default.string(withFileSystemRepresentation: template,
                                                   length: template.firstIndex(of: 0) ?? template.count)
        defer { unlink(temporary) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let outcome = converter.convertFile(atPath: source, output: output, compress: compress, settings: settings)
        try? output.close()

        switch outcome {
        case .failure(.crashed), .failure(.timedOut):
            return .crashed
        case .failure:
            return .failed
        case .success(.unreadable):
            return .unreadable
        case .success(.unchanged):
            return .unchanged
        case .success(.cannotWrite), .success(.saveFailed):
            return .failed
        case .success(.written):
            let inPlace = source == destination
            var placed: String?
            if inPlace {
                if rename(temporary, destination) == 0 { placed = destination }
            } else {
                placed = renameWithoutReplacing(temporary, destination)
            }
            guard let placed else { return .failed }
            reportRenamedDestination(placed, destination)
            if !inPlace && unlink(source) != 0 { return .failed }
            return .placed
        }
    }

    // MARK: - Names

    // What is handed back goes into a folder other things write to - the
    // incoming folder above all, where the importer puts files of the same
    // name from different folders and different scans. rename() replaces
    // whatever is already at the destination, so the second 1.dcm converted
    // into INCOMING took the place of the first one before it was indexed,
    // and the first was gone without a word. Nothing handed back takes the
    // place of something already there: it goes beside it under a name of its
    // own, the way the importer names what it moves into the decompression folder.
    static func freeNameCandidate(_ destination: String, attempt: Int) -> String {
        if attempt == 0 { return destination }
        let name = (destination as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        var unique = "\(stem)-\(attempt)"
        if !fileExtension.isEmpty { unique = (unique as NSString).appendingPathExtension(fileExtension) ?? unique }
        return ((destination as NSString).deletingLastPathComponent as NSString).appendingPathComponent(unique)
    }

    /// Renames `from` (beside the destination, on its volume) to the
    /// destination or, when that is taken, to the first free name beside it;
    /// where it went, or nil with errno set. A file system without exclusive
    /// rename gets a check before the rename instead.
    static func renameWithoutReplacing(_ from: String, _ destination: String) -> String? {
        for attempt in 0..<1000 {
            let candidate = freeNameCandidate(destination, attempt: attempt)
            if renamex_np(from, candidate, UInt32(RENAME_EXCL)) == 0 { return candidate }
            if errno == EEXIST { continue }
            if errno != ENOTSUP && errno != EINVAL { return nil }
            var existing = stat()
            if lstat(candidate, &existing) == 0 { continue }
            if rename(from, candidate) == 0 { return candidate }
            return nil
        }
        errno = EEXIST
        return nil
    }

    static func reportRenamedDestination(_ placed: String?, _ destination: String) {
        if let placed, placed != destination {
            NSLog("---- decompress: %@ was already in %@; this one is %@", (destination as NSString).lastPathComponent,
                  ((destination as NSString).deletingLastPathComponent as NSString).lastPathComponent,
                  (placed as NSString).lastPathComponent)
        }
    }

    // MARK: - Archives

    enum ArchiveExtraction: Equatable {
        /// The contents are in place and the archive is gone.
        case extracted
        /// The archive itself is at fault; nothing came out of it.
        case notExpanded
        /// The destination is at fault - no room, no permission.
        case notExpandedForNow
        /// The contents are in place; the archive itself could not be removed.
        case expandedNotCleared
    }

    static func extractDICOMArchive(_ source: String, to destination: String) -> ArchiveExtraction {
        let manager = FileManager.default
        let staging = ((destination as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".horos-extract-" + UUID().uuidString)
        do {
            try manager.createDirectory(atPath: staging, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        } catch {
            // Nothing here says the archive is bad: the place it would go is.
            NSLog("---- decompress: %@ could not be expanded: no working directory beside %@",
                  (source as NSString).lastPathComponent, (destination as NSString).deletingLastPathComponent)
            return .notExpandedForNow
        }
        defer { try? manager.removeItem(atPath: staging) }

        let output = (staging as NSString).appendingPathComponent("contents")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-o", "-d", output, source]
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            NSLog("Archive extraction failed: %@", error.localizedDescription)
            return .notExpanded
        }
        while task.isRunning { Thread.sleep(forTimeInterval: 0.1) }
        let status = task.terminationStatus
        // 1 means unzip finished and warned about something, so the contents
        // are there and throwing them away would be the loss this is meant to
        // avoid. 50 is "the disk is (or was) full": the archive is fine and the
        // destination is not, which is a different answer. Everything else
        // means the archive itself is at fault.
        if status != 0 && status != 1 {
            NSLog("---- decompress: %@ could not be expanded: unzip exited with %d", (source as NSString).lastPathComponent, status)
            return status == 50 ? .notExpandedForNow : .notExpanded
        }
        // Never over an existing destination: swapping it into staging threw
        // away what an earlier archive of the same name had put there and the
        // importer had not yet taken. Only the archive itself, expanded where
        // it is, is replaced by its contents.
        let inPlace = (source as NSString).standardizingPath == (destination as NSString).standardizingPath
        var placed: String?
        if !inPlace {
            placed = renameWithoutReplacing(output, destination)
        } else if renamex_np(output, destination, UInt32(RENAME_SWAP)) == 0 {
            placed = destination
        }
        guard let placed else {
            NSLog("---- decompress: %@ was expanded but its contents could not be put in place: %s",
                  (source as NSString).lastPathComponent, strerror(errno))
            return .notExpandedForNow
        }
        reportRenamedDestination(placed, destination)
        if inPlace { return .extracted }
        if (try? manager.removeItem(atPath: source)) != nil { return .extracted }
        NSLog("---- decompress: %@ was expanded but the archive itself could not be removed", (source as NSString).lastPathComponent)
        return .expandedNotCleared
    }

    // Nothing ever rescans the decompression folder, so an archive left in it
    // is neither imported nor mentioned again. Hand it back to the folder it
    // came from under a name that no longer reads as an archive - kept as it
    // is, it would be sent straight back here on the next scan - and let the
    // importer report and dispose of it the way it does with any other file it
    // cannot read, which is also what makes DELETEFILELISTENER apply to it.
    @discardableResult
    static func surrenderUnreadableArchive(_ source: String, destination: String) -> Bool {
        let manager = FileManager.default
        var handBack = (destination as NSString).appendingPathExtension("horos-unexpanded") ?? destination
        var attempt = 1
        while manager.fileExists(atPath: handBack) && attempt < 1000 {
            handBack = (destination + "-\(attempt)" as NSString).appendingPathExtension("horos-unexpanded") ?? handBack
            attempt += 1
        }
        guard (try? manager.moveItem(atPath: source, toPath: handBack)) != nil else {
            NSLog("---- decompress: %@ could not be handed back for import; it stays in the decompression folder",
                  (source as NSString).lastPathComponent)
            return false
        }
        NSLog("---- decompress: %@ handed back as %@ so the import folder can report it",
              (source as NSString).lastPathComponent, (handBack as NSString).lastPathComponent)
        return true
    }

    // An archive that could not be expanded because of the destination - no
    // room, no permission - is not a bad archive, and disposing of it the way
    // an unreadable file is disposed of would destroy something the next
    // attempt could read perfectly well. Put it back where it came from, under
    // its own name, so the next scan tries again once the cause is gone.
    @discardableResult
    static func returnArchiveForRetry(_ source: String, destination: String) -> Bool {
        if (source as NSString).standardizingPath == (destination as NSString).standardizingPath { return true }
        // Whatever is at the destination is not a partial of this archive - the
        // expansion is staged elsewhere - but something the importer has not
        // taken yet. The move may cross volumes, and never replaces.
        for attempt in 0..<1000 {
            let candidate = freeNameCandidate(destination, attempt: attempt)
            do {
                try FileManager.default.moveItem(atPath: source, toPath: candidate)
                NSLog("---- decompress: %@ put back as %@ for another attempt once there is room for it",
                      (source as NSString).lastPathComponent, (candidate as NSString).lastPathComponent)
                return true
            } catch let error as NSError {
                if !(error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError) { break }
            }
        }
        NSLog("---- decompress: %@ could not be put back for another attempt; it stays in the decompression folder",
              (source as NSString).lastPathComponent)
        return false
    }

    // MARK: - Moves

    /// Copies beside the destination before committing, moves across volumes
    /// included; never over what is already there.
    static func relocateDICOMFile(_ source: String, to destination: String) -> Bool {
        let manager = FileManager.default
        if (source as NSString).standardizingPath == (destination as NSString).standardizingPath {
            return manager.fileExists(atPath: source)
        }
        let staging = ((destination as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".horos-move-" + UUID().uuidString)
        guard (try? manager.createDirectory(atPath: staging, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])) != nil else { return false }
        defer { try? manager.removeItem(atPath: staging) }
        let temporary = (staging as NSString).appendingPathComponent("file")
        guard (try? manager.copyItem(atPath: source, toPath: temporary)) != nil,
              let placed = renameWithoutReplacing(temporary, destination) else { return false }
        reportRenamedDestination(placed, destination)
        return (try? manager.removeItem(atPath: source)) != nil
    }
}

// MARK: - The helper runs of CompressionHelperRun

/// A chunk of CompressionHelperRun converted through the service on a thread
/// of its own, in place of the helper process it used to start: the
/// arguments are the same, the destination ("sameAsDestination" for none),
/// the mode and the files. Ended (`terminate`) when it outlives its time,
/// which also ends the service and the conversion it was stuck in.
public final class DecompressConversionTask: CompressionHelperProcess, @unchecked Sendable {
    private let files: [String]
    private let mode: DecompressConversion.Mode
    private let destination: String?
    private let settings: NSDictionary
    private let moveIfUnreadable: Bool
    private let service: DecompressService?
    private let lock = NSCondition()
    private var running = false
    private var cancelled = false
    private var summary = DecompressConversion.Summary()

    public init(arguments: [String], settings: NSDictionary, moveIfUnreadable: Bool, service: DecompressService?) {
        let destination = arguments.first ?? "sameAsDestination"
        self.destination = destination == "sameAsDestination" ? nil : destination
        mode = DecompressConversion.Mode(rawValue: arguments.count > 1 ? arguments[1] : "") ?? .decompressList
        files = Array(arguments.dropFirst(2))
        self.settings = settings.copy() as? NSDictionary ?? [:]
        self.moveIfUnreadable = moveIfUnreadable
        self.service = service
    }

    public func launch() throws {
        guard let service else { throw DecompressServiceError.unavailable }
        lock.lock()
        running = true
        lock.unlock()
        Thread.detachNewThread { [self] in
            let result = autoreleasepool {
                DecompressConversion.run(files, mode: mode, destination: destination, settings: settings,
                                         moveIfUnreadable: moveIfUnreadable, converter: service,
                                         cancelled: { [self] in lock.lock(); defer { lock.unlock() }; return cancelled })
            }
            lock.lock()
            summary = result
            running = false
            lock.unlock()
        }
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public func terminate() {
        lock.lock()
        cancelled = true
        let stillRunning = running
        lock.unlock()
        if stillRunning { service?.terminate() }
    }

    public var terminationStatus: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return summary.succeeded && !cancelled ? 0 : 1
    }

    public var endedOnUncaughtSignal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return summary.crashed && !cancelled
    }
}
