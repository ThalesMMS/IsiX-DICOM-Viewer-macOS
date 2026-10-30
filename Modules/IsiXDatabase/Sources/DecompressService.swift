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
import UniformTypeIdentifiers

// The Decompress service: the XPC service in Contents/XPCServices that decodes
// and encodes DICOM files apart from the application, so that a file that
// brings the decoder down ends the service and not the application. The
// service sees no path of the application's: the App Store build's service has
// a sandbox of its own, which cannot open what the application can. Every file
// therefore goes to it as an open file handle, and the application does every
// file system operation itself: the temporary files beside the destination,
// the renames, the archives (DecompressConversion).

/// What the service answers. Every call names the file by the path the
/// application knows it by as well, for the service's messages; the service
/// reads it through the handle.
@objc(IsiXDecompressServiceInterface)
public protocol DecompressServiceInterface {
    /// Converts the DICOM file read from `input` and writes the result to
    /// `output`: compressed as the Compression settings in `settings` choose
    /// for its modality, or decompressed to Explicit VR Little Endian. The
    /// reply is a DecompressConversionOutcome.
    @objc(convertFile:path:output:compress:settings:reply:)
    func convertFile(_ input: FileHandle, path: String, output: FileHandle, compress: Bool, settings: NSDictionary,
                     reply: @escaping @Sendable (Int) -> Void)

    /// Loads the first frame of the file as the viewer would: whether it
    /// loads. A file that is not DICOM is not refused.
    @objc(testFile:path:reply:)
    func testFile(_ input: FileHandle, path: String, reply: @escaping @Sendable (Bool) -> Void)

    /// Reads the records of a DICOMDIR: whether reading it ended normally.
    @objc(testDicomDir:path:reply:)
    func testDicomDir(_ input: FileHandle, path: String, reply: @escaping @Sendable (Bool) -> Void)

    /// Prints the HTML or XML report read from `input` to a paginated PDF
    /// within `timeout` seconds: the PDF, or nil.
    @objc(renderReport:mimeType:timeout:reply:)
    func renderReport(_ input: FileHandle, mimeType: String, timeout: Double,
                      reply: @escaping @Sendable (Data?) -> Void)
}

/// How a conversion in the service ended.
@objc(IsiXDecompressConversionOutcome)
public enum DecompressConversionOutcome: Int, Sendable {
    /// DCMTK could not load the file; nothing was written.
    case unreadable = 0
    /// The file is to stay as it is (no compression for its modality, or it
    /// is already compressed that way); nothing was written.
    case unchanged
    /// The converted file was written to the output.
    case written
    /// The pixels could not take the transfer syntax; nothing was written.
    case cannotWrite
    /// Writing the converted file failed.
    case saveFailed
}

/// Why a call to the service did not answer.
public enum DecompressServiceError: Error, Equatable, Sendable {
    /// The service could not be found or started.
    case unavailable
    /// The service ended during the call: it crashed or was ended.
    case crashed
    /// No answer within the time given.
    case timedOut
    /// The caller stopped waiting.
    case cancelled
}

/// The application's connection to the Decompress service. One connection
/// serves every thread: each call waits for its own answer, and a call the
/// service ended without answering fails with `.crashed` while the next one
/// starts the service again.
public final class DecompressService: @unchecked Sendable {

    /// The settings a conversion reads, which the application sends from its
    /// own preferences: the service has none.
    public static let settingsKeys = ["CompressionSettings", "CompressionSettingsLowRes",
                                      "CompressionResolutionLimit", "UseJPEGColorSpace"]

    /// The service's bundle in the application's Contents/XPCServices.
    public static let bundleName = "Decompress.xpc"

    /// The interface both sides use: the settings are property lists.
    public static func makeInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: DecompressServiceInterface.self)
        let propertyList = NSSet(array: [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self,
                                         NSData.self, NSDate.self]) as? Set<AnyHashable> ?? []
        interface.setClasses(propertyList,
                             for: #selector(DecompressServiceInterface.convertFile(_:path:output:compress:settings:reply:)),
                             argumentIndex: 4, ofReply: false)
        return interface
    }

    /// The service of the running application, nil when it has none.
    public static let shared: DecompressService? = bundled(in: .main)

    /// The service embedded in `bundle`, by the identifier its Info.plist gives.
    public static func bundled(in bundle: Bundle) -> DecompressService? {
        let url = bundle.bundleURL.appendingPathComponent("Contents/XPCServices").appendingPathComponent(bundleName)
        guard let identifier = Bundle(url: url)?.bundleIdentifier else { return nil }
        return DecompressService(serviceName: identifier)
    }

    public let serviceName: String
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init(serviceName: String) {
        self.serviceName = serviceName
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let created = NSXPCConnection(serviceName: serviceName)
        created.remoteObjectInterface = Self.makeInterface()
        created.invalidationHandler = { [weak self, unowned created] in self?.forget(created) }
        created.resume()
        connection = created
        return created
    }

    private func forget(_ ended: NSXPCConnection) {
        lock.lock()
        defer { lock.unlock() }
        if connection === ended { connection = nil }
    }

    /// Ends the service process, when a call it runs will not finish: the
    /// calls it was running fail with `.crashed`, the next ones start it again.
    public func terminate() {
        lock.lock()
        let process = connection?.processIdentifier ?? 0
        lock.unlock()
        if process > 0 { kill(process, SIGKILL) }
    }

    /// The answer of a call, written once from whichever side answers first.
    private final class Answer<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<Value, DecompressServiceError>?
        let arrived = DispatchSemaphore(value: 0)

        func set(_ result: Result<Value, DecompressServiceError>) {
            lock.lock()
            let first = stored == nil
            if first { stored = result }
            lock.unlock()
            if first { arrived.signal() }
        }

        var result: Result<Value, DecompressServiceError>? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Sends one call and waits for its answer: at most `timeout` seconds
    /// (nil, as long as it takes), asking `cancelled` every tenth of a second.
    func call<Value: Sendable>(_ type: Value.Type, timeout: TimeInterval?, cancelled: (() -> Bool)? = nil,
                               _ send: (DecompressServiceInterface, @escaping @Sendable (Value) -> Void) -> Void)
        -> Result<Value, DecompressServiceError> {
        let answer = Answer<Value>()
        let proxy = currentConnection().remoteObjectProxyWithErrorHandler { error in
            let code = (error as NSError).domain == NSCocoaErrorDomain ? (error as NSError).code : 0
            answer.set(.failure(code == NSXPCConnectionInterrupted ? .crashed : .unavailable))
        }
        guard let service = proxy as? DecompressServiceInterface else { return .failure(.unavailable) }
        send(service) { answer.set(.success($0)) }
        let deadline = timeout.map { Date.timeIntervalSinceReferenceDate + $0 }
        while answer.arrived.wait(timeout: .now() + 0.1) == .timedOut {
            if let deadline, Date.timeIntervalSinceReferenceDate > deadline { answer.set(.failure(.timedOut)) }
            else if cancelled?() == true { answer.set(.failure(.cancelled)) }
        }
        return answer.result ?? .failure(.unavailable)
    }

    // MARK: - Calls

    /// The path the service is told, beside the handle: absolute, because the
    /// service reads the file by that path when it may and the path names the
    /// file of the handle, and its working directory is not the caller's. A
    /// relative path would have it read a private copy instead.
    static func absolutePath(_ path: String) -> String {
        path.hasPrefix("/") ? path : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
    }

    /// Converts the file at `path` into `output`, an empty file opened for
    /// writing: `.unreadable` without asking the service when it cannot be opened.
    public func convertFile(atPath path: String, output: FileHandle, compress: Bool, settings: NSDictionary)
        -> Result<DecompressConversionOutcome, DecompressServiceError> {
        guard let input = FileHandle(forReadingAtPath: path) else { return .success(.unreadable) }
        defer { try? input.close() }
        return call(Int.self, timeout: nil) { service, reply in
            service.convertFile(input, path: Self.absolutePath(path), output: output, compress: compress, settings: settings, reply: reply)
        }.map { DecompressConversionOutcome(rawValue: $0) ?? .saveFailed }
    }

    /// Whether the first frame of the file at `path` loads. A file that cannot
    /// be opened is left to the importer, as one that is not DICOM.
    public func testFile(atPath path: String) -> Result<Bool, DecompressServiceError> {
        guard let input = FileHandle(forReadingAtPath: path) else { return .success(true) }
        defer { try? input.close() }
        return call(Bool.self, timeout: nil) { service, reply in
            service.testFile(input, path: Self.absolutePath(path), reply: reply)
        }
    }

    /// Whether the DICOMDIR at `path` reads to its end within `timeout` seconds.
    public func testDicomDir(atPath path: String, timeout: TimeInterval) -> Result<Bool, DecompressServiceError> {
        guard let input = FileHandle(forReadingAtPath: path) else { return .success(true) }
        defer { try? input.close() }
        return call(Bool.self, timeout: timeout) { service, reply in
            service.testDicomDir(input, path: Self.absolutePath(path), reply: reply)
        }
    }

    /// The MIME type WebKit took the report for when it loaded the file
    /// itself: by its extension, HTML when it has none it knows.
    public static func reportMIMEType(ofPath path: String) -> String {
        let fileExtension = (path as NSString).pathExtension
        return UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "text/html"
    }

    /// The longest a report is given to print, as the helper allowed.
    public static let reportTimeout: TimeInterval = 25

    /// Regenerates `<path>.pdf` from the HTML or XML report at `path`, printed
    /// in the service within `timeout` seconds, through a fresh sibling
    /// replaced atomically: on failure the previous PDF stays, and the report
    /// itself is never moved. Whether the PDF was replaced.
    @discardableResult
    public func updateReportPDF(atPath path: String, timeout: TimeInterval,
                                cancelled: (() -> Bool)? = nil) -> Result<Bool, DecompressServiceError> {
        guard let input = FileHandle(forReadingAtPath: path) else { return .success(false) }
        defer { try? input.close() }
        let mimeType = Self.reportMIMEType(ofPath: path)
        let allowed = min(timeout, Self.reportTimeout)
        // The service stops at its own deadline; the wait gives it a moment more to say so.
        let rendered = call(Data?.self, timeout: allowed + 1, cancelled: cancelled) { service, reply in
            service.renderReport(input, mimeType: mimeType, timeout: allowed, reply: reply)
        }
        switch rendered {
        case .failure(let error):
            return .failure(error)
        case .success(nil):
            return .success(false)
        case .success(let pdf?):
            let destination = (path as NSString).appendingPathExtension("pdf") ?? path + ".pdf"
            let staged = ((destination as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("horos-html-print-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(atPath: staged) }
            guard FileManager.default.createFile(atPath: staged, contents: pdf) else { return .success(false) }
            return .success(rename(staged, destination) == 0)
        }
    }
}
