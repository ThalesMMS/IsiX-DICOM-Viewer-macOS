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
import IsiXDatabase

// The Decompress service's side of the calls: why a service apart from the
// application? Because if a file is corrupted, it will not crash the
// application, but only this small process, which the next call starts again.
// DCMTK is reached through the adapters (Adapters/DCMTK), which this target
// compiles; the application sends each file as an open handle (see
// DecompressService in IsiXDatabase).

/// Accepts the application's connections.
final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = DecompressService.makeInterface()
        connection.exportedObject = CodecService()
        connection.resume()
        return true
    }
}

/// A value carried to the queue that works on it, used by that work alone.
struct Carried<Value>: @unchecked Sendable {
    let value: Value
}

final class CodecService: NSObject, DecompressServiceInterface {

    /// The codecs the application registers too (IsiXDCMTKCodecs): JPEG with
    /// the colour model the Photometric Interpretation decides, JPEG-LS, RLE
    /// and JPEG 2000. Once, when the service starts.
    static func registerCodecs() {
        do {
            try IsiXDCMTKCodecs.registerCodecs()
        } catch {
            NSLog("Decompress service: the codecs could not be registered: %@", error.localizedDescription)
        }
    }

    /// The calls arrive one after the other on the connection's queue; the
    /// work runs beside it, so that the application's threads convert and
    /// test files at the same time, as they ran helpers at the same time. The
    /// queue names no quality of service: each call keeps the one of the
    /// application's thread that made it, which XPC carries over.
    private static let work = DispatchQueue(label: "Decompress service work", attributes: .concurrent)

    func convertFile(_ input: FileHandle, path: String, output: FileHandle, compress: Bool, settings: NSDictionary,
                     reply: @escaping @Sendable (Int) -> Void) {
        let settings = Carried(value: settings.copy() as? NSDictionary ?? [:])
        Self.work.async {
            reply(autoreleasepool { Self.convert(input, path: path, output: output, compress: compress,
                                                 settings: settings.value).rawValue })
        }
    }

    func testFile(_ input: FileHandle, path: String, reply: @escaping @Sendable (Bool) -> Void) {
        Self.work.async {
            reply(autoreleasepool {
                guard let readable = ServiceInput(input, path: path) else { return true }
                return FirstFrameTest.loads(readable.path, named: path)
            })
        }
    }

    func testDicomDir(_ input: FileHandle, path: String, reply: @escaping @Sendable (Bool) -> Void) {
        Self.work.async {
            reply(autoreleasepool {
                NSLog("-- Testing DICOMDIR: %@", path)
                guard let readable = ServiceInput(input, path: path) else { return true }
                do {
                    try IsiXDCMTKDicomDir.readRootRecord(ofDicomDirAtPath: readable.path)
                } catch {
                    NSLog("-- Testing DICOMDIR %@ failed: %@", path, error.localizedDescription)
                    return false
                }
                NSLog("-- Testing DICOMDIR done")
                return true
            })
        }
    }

    func renderReport(_ input: FileHandle, mimeType: String, timeout: Double, reply: @escaping @Sendable (Data?) -> Void) {
        Self.work.async {
            let document = (try? input.readToEnd()) ?? Data()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ReportPDFRenderer.render(document, mimeType: mimeType, timeout: timeout, reply: reply)
                }
            }
        }
    }

    // MARK: - Conversion

    /// Compresses as the settings choose for the file's modality, or
    /// decompresses to Explicit VR Little Endian, into `output`.
    private static func convert(_ input: FileHandle, path: String, output: FileHandle, compress: Bool,
                                settings: NSDictionary) -> DecompressConversionOutcome {
        // The application's UseJPEGColorSpace, for the one colour policy the
        // viewer applies too: only a JFIF or Adobe marker of a lossy
        // three-component stream may correct the interpretation.
        let useJPEGColorSpace = settings["UseJPEGColorSpace"]
        IsiXDCMTKCodecs.markersDecideColour = useJPEGColorSpace == nil || (useJPEGColorSpace as AnyObject).boolValue == true

        guard let readable = ServiceInput(input, path: path) else { return .unreadable }
        var failure: NSError?
        let outcome = IsiXDCMTKTranscoding.convertFile(
            atPath: readable.path, workingFolder: NSTemporaryDirectory(),
            destination: "/dev/fd/\(output.fileDescriptor)",
            choosing: { facts, originalSyntax, quality in
                guard let plan = DecompressConversion.targetSyntax(
                    compress: compress, settings: settings, modality: facts.modality,
                    rows: facts.rows?.intValue, columns: facts.columns?.intValue,
                    originalSyntax: originalSyntax, pixelDataCompressed: facts.pixelDataCompressed) else { return nil }
                quality.pointee = plan.quality
                return plan.syntax
            }, error: &failure)
        if let failure, outcome != .unreadable {
            NSLog("Decompress service: %@ was not converted: %@", path, failure.localizedDescription)
        }
        return DecompressConversionOutcome(rawValue: outcome.rawValue) ?? .saveFailed
    }
}

/// The file a call names, as the service can read it by path, which DCMTK
/// needs: the application's path when the service may open it and it is the
/// file of the handle, else a private copy of what the handle reads, removed
/// with this. The App Store build's service has a sandbox of its own and
/// always reads a copy; reading the handle in place is no answer, because
/// DCMTK opens a file more than once and every open of /dev/fd shares one
/// offset.
final class ServiceInput {
    let path: String
    private let copy: Bool

    init?(_ handle: FileHandle, path given: String) {
        var source = stat()
        guard fstat(handle.fileDescriptor, &source) == 0 else { return nil }
        let opened = open(given, O_RDONLY)
        if opened >= 0 {
            var found = stat()
            let same = fstat(opened, &found) == 0 && found.st_dev == source.st_dev && found.st_ino == source.st_ino
            close(opened)
            if same {
                path = given
                copy = false
                return
            }
        }
        var template = Array(((NSTemporaryDirectory() as NSString).appendingPathComponent("isix-decompress-XXXXXX")).utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { return nil }
        let temporary = FileManager.default.string(withFileSystemRepresentation: template,
                                                   length: template.firstIndex(of: 0) ?? template.count)
        lseek(handle.fileDescriptor, 0, SEEK_SET)
        let copied = fcopyfile(handle.fileDescriptor, descriptor, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
        close(descriptor)
        guard copied else {
            unlink(temporary)
            return nil
        }
        path = temporary
        copy = true
    }

    deinit {
        if copy { unlink(path) }
    }
}
