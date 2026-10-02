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
import DicomData
import DicomWebClient
import Synchronization

// MARK: - Node

/// Where a DICOMweb node answers (#799): an address, and QIDO-RS and WADO-RS
/// paths relative to it. STOW-RS goes to `{address}/studies`.
@objc(HorosDICOMwebNodeConfiguration)
public final class DICOMwebNodeConfiguration: NSObject, Sendable {
    /// The base URL, such as `https://pacs.example/dicom-web`, without a trailing slash.
    @objc public let address: String
    /// Allows unencrypted HTTP for this node only; it never bypasses HTTPS trust.
    @objc public let allowInsecureHTTP: Bool
    /// Relative to the address; empty uses the address itself.
    @objc public let qidoPath: String
    @objc public let wadoPath: String
    /// The Keychain reference of the credential, or empty for none.
    @objc public let credentialIdentifier: String
    /// The transfer syntax UID a retrieve asks for, or empty (or `*`) for the
    /// objects as stored.
    @objc public let retrieveTransferSyntax: String

    let addressURL: URL
    let qidoURL: URL
    let wadoURL: URL

    @objc(initWithAddress:qidoPath:wadoPath:credentialIdentifier:retrieveTransferSyntax:error:)
    public convenience init(address: String, qidoPath: String, wadoPath: String,
                            credentialIdentifier: String, retrieveTransferSyntax: String) throws {
        try self.init(address: address, qidoPath: qidoPath, wadoPath: wadoPath,
                      credentialIdentifier: credentialIdentifier, retrieveTransferSyntax: retrieveTransferSyntax,
                      allowInsecureHTTP: false)
    }

    @objc(initWithAddress:qidoPath:wadoPath:credentialIdentifier:retrieveTransferSyntax:allowInsecureHTTP:error:)
    public init(address: String, qidoPath: String, wadoPath: String,
                credentialIdentifier: String, retrieveTransferSyntax: String, allowInsecureHTTP: Bool) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.scheme?.lowercased() == "https" || (components.scheme?.lowercased() == "http" && (allowInsecureHTTP || Self.isLoopback(host)))
        else { throw DICOMwebClient.failure(1, NSLocalizedString("Enter an HTTPS address, such as https://pacs.example/dicom-web. For remote HTTP, enable Allow Insecure HTTP for this node.", comment: ""), kind: .configuration) }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let base = components.url else {
            throw DICOMwebClient.failure(1, NSLocalizedString("Enter an HTTPS address, such as https://pacs.example/dicom-web. For remote HTTP, enable Allow Insecure HTTP for this node.", comment: ""), kind: .configuration)
        }
        let credential = credentialIdentifier.trimmingCharacters(in: .whitespaces)
        guard credential.isEmpty || UUID(uuidString: credential) != nil else {
            throw DICOMwebClient.failure(1, "The node's credential reference is invalid. Set its authentication again.", kind: .configuration)
        }
        let syntax = retrieveTransferSyntax.trimmingCharacters(in: .whitespaces)
        guard (try? DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUID: syntax)) != nil else {
            throw DICOMwebClient.failure(1, "The retrieve transfer syntax is not a valid UID.", kind: .configuration)
        }
        self.address = base.absoluteString
        self.allowInsecureHTTP = allowInsecureHTTP
        self.qidoPath = qidoPath.trimmingCharacters(in: .whitespaces)
        self.wadoPath = wadoPath.trimmingCharacters(in: .whitespaces)
        self.credentialIdentifier = credential
        self.retrieveTransferSyntax = syntax == "*" ? "" : syntax
        addressURL = base
        qidoURL = try Self.resolve(self.qidoPath, against: base, service: "QIDO")
        wadoURL = try Self.resolve(self.wadoPath, against: base, service: "WADO")
        super.init()
    }

    /// The pilot's single URL (#197): QIDO and WADO both at the address.
    @objc(nodeWithEndpoint:credentialIdentifier:error:)
    public static func node(endpoint: String, credentialIdentifier: String) throws -> DICOMwebNodeConfiguration {
        try DICOMwebNodeConfiguration(address: endpoint, qidoPath: "", wadoPath: "",
                                      credentialIdentifier: credentialIdentifier, retrieveTransferSyntax: "")
    }

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }

    private static func resolve(_ path: String, against base: URL, service: String) throws -> URL {
        var url = base
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for part in parts {
            guard part != ".", part != "..", !part.contains(":"), !part.contains("?"), !part.contains("#"),
                  !part.contains("%"), !part.contains("\\"),
                  part.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F })
            else { throw DICOMwebClient.failure(1, "The \(service) path must be relative to the address, such as dicom-web or wado.", kind: .configuration) }
            url.appendPathComponent(part)
        }
        return url
    }

    /// The full URLs, for display next to the node. They carry no credential.
    @objc public var qidoURLString: String { qidoURL.absoluteString }
    @objc public var wadoURLString: String { wadoURL.absoluteString }
    @objc public var storeURLString: String { addressURL.appendingPathComponent("studies").absoluteString }
}

// MARK: - Errors

/// What went wrong, for the messages of Locations' Test and of the Query,
/// Retrieve and Send paths.
@objc(HorosDICOMwebErrorKind)
public enum DICOMwebErrorKind: Int {
    case none = 0
    /// The node's settings are invalid; nothing was sent.
    case configuration
    /// The Keychain did not give the credential.
    case credentials
    /// No connection: the host is unknown or unreachable, or the connection dropped.
    case network
    /// The TLS handshake or the server certificate failed.
    case tls
    case timeout
    /// HTTP 401 or 403.
    case authentication
    /// HTTP 404: the path does not name a DICOMweb resource.
    case notFound
    /// A 3xx answer, which is never followed.
    case redirect
    /// Any other HTTP status.
    case http
    /// The response was not what the service must return.
    case invalidResponse
    case cancelled
}

// MARK: - Store results

@objc(HorosDICOMwebStoreStatus)
public enum DICOMwebStoreStatus: Int {
    case success = 0
    /// Stored, with a warning such as coerced attributes.
    case warning = 1
    /// Not stored, or not confirmed by the node.
    case failure = 2
}

/// What the node answered for one file sent by STOW-RS.
@objc(HorosDICOMwebStoreResult)
public final class DICOMwebStoreResult: NSObject {
    @objc public let path: String
    /// From the file's meta information; empty for a file that is not DICOM.
    @objc public let sopInstanceUID: String
    @objc public let status: DICOMwebStoreStatus
    /// Empty on success. Never carries a URL or a response body.
    @objc public let reason: String
    /// The DICOM Warning Reason (0008,1196) or Failure Reason (0008,1197), or 0.
    @objc public let reasonCode: Int
    /// The HTTP status of the request that carried the file, or 0 if none was sent.
    @objc public let httpStatus: Int

    init(path: String, sopInstanceUID: String, status: DICOMwebStoreStatus, reason: String, reasonCode: Int = 0, httpStatus: Int = 0) {
        self.path = path; self.sopInstanceUID = sopInstanceUID; self.status = status
        self.reason = reason; self.reasonCode = reasonCode; self.httpStatus = httpStatus
        super.init()
    }

    static func describe(reason code: Int, warning: Bool) -> String {
        let known: [Int: String] = [
            0x0107: "attribute list error", 0x0110: "processing failure", 0x0111: "duplicate SOP instance",
            0x0116: "attribute value out of range", 0x0117: "invalid object instance", 0x0122: "SOP class not supported",
            0x0124: "not authorized", 0x0131: "duplicate invocation", 0x0210: "duplicate invocation",
            0xA700: "out of resources", 0xA900: "data set does not match SOP class", 0xC000: "cannot understand",
            0xC122: "transfer syntax not supported", 0xB000: "coercion of data elements",
            0xB006: "elements discarded", 0xB007: "data set does not match SOP class",
        ]
        let hex = String(format: "0x%04X", code)
        let name = known[code] ?? ((code & 0xFF00) == 0xA700 ? "out of resources" : (code & 0xF000) == 0xC000 ? "cannot understand" : nil)
        return (warning ? "Warning " : "Failure reason ") + hex + (name.map { " (\($0))" } ?? "")
    }
}

// MARK: - Transport

/// Host policy for response spooling, independent of the shared client's parser.
/// Metadata is buffered later; studies stay file-backed and may be much larger.
struct DICOMwebResponseBudgets: Sendable {
    var metadataBytes = 32 * 1024 * 1024
    var retrieveBytes = 64 * 1024 * 1024 * 1024
    var errorBytes = 1024 * 1024

    enum Operation: Sendable { case query, retrieve, store }

    func limit(operation: Operation, status: Int) -> Int {
        if (200..<300).contains(status) || (operation == .store && status == 409) {
            return operation == .retrieve ? retrieveBytes : metadataBytes
        }
        return errorBytes
    }
}

/// A local refusal, kept separate from HTTP errors (in particular HTTP 413).
private enum DICOMwebReceiveFailure: Error { case responseTooLarge }

/// Streams one response body into a file this client owns and removes.
/// A download task writes into a CFNetworkDownload_*.tmp of CFNetwork's own in
/// the temporary folder, which CFNetwork keeps when the task times out or is
/// cancelled after the response headers arrived, with no resume data naming it.
///
/// @unchecked Sendable: URLSession calls the delegate on its own queue while
/// the request's task reads the outcome and may abandon it. Every stored `var`
/// is read and written only under `lock`, including `statusCode`, which only
/// the delegate writes; `file` never changes. The lock is kept as it is on the
/// body's path, where each received chunk takes it.
private final class DICOMwebResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL
    private let budgets: DICOMwebResponseBudgets
    private let operation: DICOMwebResponseBudgets.Operation
    private var limit = 0
    private var receivedBytes = 0
    private var output: FileHandle?
    private var abandoned = false
    private var finished = false
    private var completion: (@Sendable () -> Void)?
    private var body: URL?
    private var response: HTTPURLResponse?
    private var error: Error?
    /// Every status the transport saw, so an HTTP error can be told from a
    /// failure of the client's own with the same number.
    private(set) var statusCode = 0

    init(file: URL, budgets: DICOMwebResponseBudgets, operation: DICOMwebResponseBudgets.Operation) {
        self.file = file; self.budgets = budgets; self.operation = operation
    }

    /// What the finished task produced. The body, if any, is the caller's to
    /// return or to hand to abandon().
    var outcome: (body: URL?, response: HTTPURLResponse?, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        return (body, response, error)
    }

    /// Calls `block` once the task has finished, at once if it already has.
    func whenFinished(_ block: @escaping @Sendable () -> Void) {
        lock.lock()
        if finished { lock.unlock(); block(); return }
        completion = block
        lock.unlock()
    }

    /// Removes the body and ignores whatever the task still delivers.
    func abandon() {
        lock.lock(); defer { lock.unlock() }
        abandoned = true
        removeBody()
    }

    // Called with the lock held, also on failures while the body is arriving.
    private func removeBody() {
        closeOutput()
        if let body = body { try? FileManager.default.removeItem(at: body) }
        body = nil
    }

    private func closeOutput() {
        try? output?.close()
        output = nil
    }

    // Called with the lock held.
    private func openBody() throws {
        closeOutput()
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        body = file
        output = try FileHandle(forWritingTo: file)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Node URLs are explicit. Never forward a credential header through redirects.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        var disposition = URLSession.ResponseDisposition.allow
        if abandoned { disposition = .cancel }
        else {
            self.response = response as? HTTPURLResponse
            limit = budgets.limit(operation: operation, status: self.response?.statusCode ?? 0)
            receivedBytes = 0
            // Refuse declared sizes before creating a spool. Unknown lengths are
            // checked as bytes arrive, including decoded compressed bodies.
            if response.expectedContentLength > Int64(limit) {
                self.error = DICOMwebReceiveFailure.responseTooLarge
                removeBody()
                disposition = .cancel
            } else {
                do { try openBody() }
                catch { self.error = error; removeBody(); disposition = .cancel }
            }
        }
        lock.unlock()
        completionHandler(disposition)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !abandoned, error == nil, let output = output else { return }
        guard data.count <= limit - receivedBytes else {
            error = DICOMwebReceiveFailure.responseTooLarge
            removeBody()
            dataTask.cancel()
            return
        }
        do {
            try output.write(contentsOf: data)
            receivedBytes += data.count
        } catch { self.error = error; removeBody(); dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        closeOutput()
        if self.error == nil { self.error = error }
        response = (task.response as? HTTPURLResponse) ?? response
        statusCode = response?.statusCode ?? 0
        if self.error != nil { removeBody() }
        if !abandoned, self.error == nil, body == nil {
            do { try openBody(); closeOutput() } catch { self.error = error }
        }
        finished = true
        let block = completion
        completion = nil
        lock.unlock()
        block?()
    }
}

/// Reads a finished response body back in chunks and removes the file when
/// the body has been read, when the reader is cancelled, or when it goes away.
///
/// @unchecked Sendable: the body's stream and its cancellation run on the
/// consumer's tasks. `handle` and `done` are read and written only under
/// `lock`, which each chunk takes; `owner` and `file` never change.
private final class DICOMwebBodyReader: @unchecked Sendable {
    private let lock = NSLock()
    private let owner: DICOMwebResponse
    private let file: URL?
    private var handle: FileHandle?
    private var done = false

    init(owner: DICOMwebResponse, file: URL?) { self.owner = owner; self.file = file }
    deinit { finish() }

    func next() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !done, let file = file else { return nil }
        return try autoreleasepool {
            if handle == nil { handle = try FileHandle(forReadingFrom: file) }
            guard let chunk = try handle?.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                closeLocked()
                return nil
            }
            return chunk
        }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        guard !done else { return }
        done = true
        try? handle?.close()
        handle = nil
        owner.abandon()
    }
}

/// The transport DICOM-Swift's client sends through: an ephemeral session with
/// no cache, cookies or stored credentials, no redirect followed, timeouts, and
/// bodies that go through files the transport owns.
final class DICOMwebTransport: DicomWebHTTPTransport {
    let timeout: TimeInterval
    let transferTimeout: TimeInterval
    private let budgets: DICOMwebResponseBudgets
    private let operation: DICOMwebResponseBudgets.Operation
    private let retrieveAccept: String?
    private let temporaryDirectory: URL
    /// Recorded by the request's task, read by the caller's classification.
    private let statuses = Mutex<[Int]>([])

    init(timeout: TimeInterval, transferTimeout: TimeInterval,
         budgets: DICOMwebResponseBudgets = .init(), operation: DICOMwebResponseBudgets.Operation = .query,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory, retrieveAccept: String? = nil) {
        self.retrieveAccept = retrieveAccept
        self.timeout = timeout
        self.transferTimeout = transferTimeout
        self.budgets = budgets
        self.operation = operation
        self.temporaryDirectory = temporaryDirectory
    }

    /// Whether this transport received an HTTP answer with that status.
    func received(status: Int) -> Bool {
        statuses.withLock { $0.contains(status) }
    }

    private func record(status: Int) {
        statuses.withLock { $0.append(status) }
    }

    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        let response = try await stream(request)
        defer { response.cancel() }
        var body = Data()
        for try await chunk in response.body {
            guard chunk.count <= 32 * 1024 * 1024 - body.count else { throw DicomWebError(kind: .tooLarge) }
            body.append(chunk)
        }
        return .init(statusCode: response.statusCode, headers: response.headers, body: body)
    }

    func stream(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPStreamedResponse {
        try Task.checkCancellation()
        guard request.connectAddress == nil else { throw DicomWebError(kind: .badRequest) }
        guard budgets.metadataBytes >= 0, budgets.retrieveBytes >= 0, budgets.errorBytes >= 0 else {
            throw DicomWebError(kind: .badRequest)
        }
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                    timeoutInterval: timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = false
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        if operation == .retrieve, let retrieveAccept { urlRequest.setValue(retrieveAccept, forHTTPHeaderField: "Accept") }
        if request.method == .post { urlRequest.setValue("application/dicom+json", forHTTPHeaderField: "Accept") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = transferTimeout
        let result = DICOMwebResponse(file: temporaryDirectory
            .appendingPathComponent("horos-dicomweb-" + UUID().uuidString), budgets: budgets, operation: operation)
        let session = URLSession(configuration: configuration, delegate: result, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task: URLSessionTask
        if let file = request.bodyFileURL { task = session.uploadTask(with: urlRequest, fromFile: file) }
        else if let body = request.body { task = session.uploadTask(with: urlRequest, from: body) }
        else { task = session.dataTask(with: urlRequest) }
        // The body is this call's to hand over or to remove, on every path,
        // including a timeout or cancellation while it is still arriving.
        var handedOver = false
        defer { if !handedOver { result.abandon() } }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                result.whenFinished { continuation.resume() }
                task.resume()
            }
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        let (body, response, error) = result.outcome
        if let error = error { throw error }
        guard let http = response else { throw DicomWebError(kind: .invalidResponse) }
        record(status: http.statusCode)
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { headers, pair in
            if let key = pair.key as? String { headers[key] = String(describing: pair.value) }
        }
        if request.method == .post, (200..<300).contains(http.statusCode) || http.statusCode == 409,
           let contentType = headers.horosHTTPHeaderValue("Content-Type"), contentType.lowercased().contains("xml"),
           let body, (try? body.resourceValues(forKeys: [.fileSizeKey]).fileSize) != 0 {
            throw DICOMwebClient.failure(4, "The node did not return a JSON store response.", kind: .invalidResponse)
        }
        let reader = DICOMwebBodyReader(owner: result, file: body)
        handedOver = true
        return .init(statusCode: http.statusCode, headers: headers,
                     body: AsyncThrowingStream(unfolding: { try reader.next() }),
                     cancel: { reader.finish() })
    }
}

// MARK: - Client

/// What the detached request hands to the waiting thread: set once before
/// `finished` is signalled.
private final class DICOMwebOutcome<T: Sendable>: Sendable {
    let finished = DispatchSemaphore(value: 0)
    let value = Mutex<Result<T, Error>?>(nil)
}

/// Horos's DICOMweb client (#197, #799): an adapter over DICOM-Swift's
/// `DicomWebClient` for QIDO-RS, WADO-RS and STOW-RS.
///
/// Every operation is synchronous, refuses the main thread, and returns as
/// soon as the calling thread is cancelled. No redirect is followed, no
/// credential travels in a URL, and no temporary file outlives a request.
@objc(HorosDICOMwebClient)
public final class DICOMwebClient: NSObject {
    @objc public let node: DICOMwebNodeConfiguration
    private let timeout: TimeInterval
    // Configure before starting an operation; each transport receives a value copy.
    var responseBudgets = DICOMwebResponseBudgets()
    /// Maximum bytes spooled for a WADO response, including MIME framing.
    /// Defaults to 64 GiB for desktop studies; memory remains chunked.
    @objc public var maximumRetrieveResponseBytes: Int {
        get { responseBudgets.retrieveBytes }
        set { responseBudgets.retrieveBytes = max(0, newValue) }
    }
    /// The longest a whole retrieve or store request may take (one hour).
    @objc public var transferTimeout: TimeInterval = 3600
    /// STOW-RS sends at most this many files in one request.
    @objc public var storeBatchMaximumCount: Int = 50
    /// And at most this many bytes of files, unless a single file is larger.
    @objc public var storeBatchMaximumBytes: Int = 64 * 1024 * 1024
    /// Called on the calling thread after each STOW-RS request with the number
    /// of files done and the total.
    @objc public var storeProgress: ((Int, Int) -> Void)?

    static let kindKey = "HorosDICOMwebErrorKind"

    static func failure(_ code: Int, _ message: String, kind: DICOMwebErrorKind = .invalidResponse) -> NSError {
        NSError(domain: "HorosDICOMweb", code: code,
                userInfo: [NSLocalizedDescriptionKey: message, kindKey: kind.rawValue])
    }

    @objc(errorKindForError:)
    public static func errorKind(for error: NSError?) -> DICOMwebErrorKind {
        guard let error = error else { return .none }
        if error.domain == "HorosDICOMwebCredentials" { return .credentials }
        if let raw = error.userInfo[kindKey] as? Int, let kind = DICOMwebErrorKind(rawValue: raw) { return kind }
        return .invalidResponse
    }

    @objc(initWithNode:timeout:)
    public init(node: DICOMwebNodeConfiguration, timeout: TimeInterval) {
        self.node = node
        self.timeout = timeout.isFinite ? min(max(timeout, 1), 3600) : 60
        super.init()
    }

    /// The pilot's node (#197): one URL for QIDO and WADO, objects as stored.
    @objc(initWithEndpoint:credentialIdentifier:timeout:error:)
    public convenience init(endpoint: String, credentialIdentifier: String, timeout: TimeInterval) throws {
        self.init(node: try DICOMwebNodeConfiguration.node(endpoint: endpoint, credentialIdentifier: credentialIdentifier),
                  timeout: timeout)
    }

    /// The Accept header of a WADO-RS retrieve with the node's transfer syntax.
    @objc public var retrieveAcceptHeader: String {
        let fallback = DicomWebMediaTypeNegotiator.acceptHeader(for: .instance)
        guard let media = try? DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUID: node.retrieveTransferSyntax),
              let syntax = media.parameters["transfer-syntax"] else { return fallback }
        return fallback.replacingOccurrences(of: "transfer-syntax=*", with: "transfer-syntax=\(syntax)")
    }

    // MARK: Plumbing

    // Keep cancellation responsive even if the keychain service stops responding.
    // No authorization value is cached or included in diagnostics.
    func authorization<T: Sendable>(cancelled: () -> Bool, read: @escaping @Sendable () throws -> T) throws -> T {
        do { return try DICOMwebCredentials.withDeadline(timeout: timeout, cancelled: cancelled, read) }
        catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            throw Self.cancelledError
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut {
            throw Self.failure(NSURLErrorTimedOut, "DICOMweb credential access timed out. Check the keychain and retry.", kind: .timeout)
        }
    }

    static var cancelledError: NSError { failure(NSURLErrorCancelled, "DICOMweb operation cancelled.", kind: .cancelled) }

    private func requireBackground() throws {
        guard !Thread.isMainThread else {
            throw Self.failure(2, "DICOMweb operations must run in the background.", kind: .configuration)
        }
    }

    /// The credential header, read before anything is sent.
    private func headers(cancelled: () -> Bool) throws -> [String: String] {
        try requireBackground()
        guard !node.credentialIdentifier.isEmpty else { return [:] }
        let identifier = node.credentialIdentifier
        guard let header = try authorization(cancelled: cancelled, read: { try DICOMwebCredentials.header(forIdentifier: identifier) })
        else { return [:] }
        return [header.name: header.value]
    }

    private func client(base: URL, headers: [String: String], transport: DICOMwebTransport,
                        storeBodyLimit: Int = DicomWebClientConfiguration.defaultMaximumSTOWRequestBodyBytes) -> DicomWebClient {
        var configuration = DicomWebClientConfiguration(baseURL: base, headers: headers, timeout: timeout,
                                                        maximumSTOWRequestBodyBytes: storeBodyLimit)
        configuration.multipartLimits = .horosRetrieve
        configuration.maximumMetadataBytes = 32 * 1024 * 1024
        configuration.followsRedirects = false
        return DicomWebClient(configuration: configuration, transport: transport)
    }

    /// Runs `operation` and waits on this thread, returning as soon as
    /// `cancelled` says so, once the operation has cleaned up after itself.
    private func run<T: Sendable>(cancelled: () -> Bool, _ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let outcome = DICOMwebOutcome<T>()
        let task = Task.detached(priority: .userInitiated) {
            let result: Result<T, Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            outcome.value.withLock { $0 = result }
            outcome.finished.signal()
        }
        while outcome.finished.wait(timeout: .now() + 0.1) == .timedOut {
            if cancelled() {
                task.cancel()
                // Let the request remove what it wrote before returning.
                _ = outcome.finished.wait(timeout: .now() + 10)
                throw Self.cancelledError
            }
        }
        if cancelled() { throw Self.cancelledError }
        return try outcome.value.withLock { $0 }!.get()
    }

    /// One sanitized error for anything a request threw: no URL, host,
    /// response body or credential ever reaches the message.
    private func classify(_ error: Error, transport: DICOMwebTransport, cancelled: () -> Bool,
                          failed what: String) -> NSError {
        if cancelled() || error is CancellationError { return Self.cancelledError }
        if error is DICOMwebReceiveFailure {
            return Self.failure(4, "DICOMweb response exceeds the local size limit. \(what)", kind: .invalidResponse)
        }
        let nsError = error as NSError
        if nsError.domain == "HorosDICOMweb" || nsError.domain == "HorosDICOMwebCredentials" { return nsError }
        let reportedStatus: Int?
        if let web = error as? DicomWebError {
            reportedStatus = web.statusCode
        } else if let clientError = error as? DicomWebClientError,
                  case .httpStatus(let status, _, _, _) = clientError {
            reportedStatus = status
        } else {
            reportedStatus = nil
        }
        if let status = reportedStatus, transport.received(status: status), !(200..<300).contains(status) {
            switch status {
            case 401, 403:
                return Self.failure(status, "DICOMweb authentication was rejected or expired. Update the credentials in Locations.", kind: .authentication)
            case 404:
                return Self.failure(status, "The DICOMweb node has nothing at this path (HTTP 404). Check the node's address and QIDO and WADO paths.", kind: .notFound)
            case 300..<400:
                return Self.failure(status, "The DICOMweb node answered with a redirect (HTTP \(status)), which is not followed. Check the node's address.", kind: .redirect)
            case 406:
                return Self.failure(status, "The DICOMweb node cannot send the requested transfer syntax (HTTP 406). \(what)", kind: .http)
            default:
                return Self.failure(status, "DICOMweb returned HTTP \(status). \(what)", kind: .http)
            }
        }
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                return Self.cancelledError
            case NSURLErrorTimedOut:
                return Self.failure(NSURLErrorTimedOut, "DICOMweb request timed out. Retry or check the node connection.", kind: .timeout)
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired,
                 NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return Self.failure(6, "The secure connection to the DICOMweb node failed. Check its HTTPS certificate.", kind: .tls)
            default:
                return Self.failure(3, "DICOMweb connection failed. Check the node address, TLS certificate and network.", kind: .network)
            }
        }
        return Self.failure(4, "Incomplete or invalid DICOMweb response. \(what)", kind: .invalidResponse)
    }

    private func perform<T: Sendable>(base: URL, cancelled: () -> Bool, failed what: String, storeBodyLimit: Int? = nil,
                                      transferTimeout: TimeInterval? = nil,
                                      responseOperation: DICOMwebResponseBudgets.Operation = .query,
                                      _ operation: @escaping @Sendable (DicomWebClient) async throws -> T) throws -> T {
        let headers = try headers(cancelled: cancelled)
        if cancelled() { throw Self.cancelledError }
        let transport = DICOMwebTransport(timeout: timeout, transferTimeout: transferTimeout ?? timeout,
                                         budgets: responseBudgets, operation: responseOperation,
                                         retrieveAccept: responseOperation == .retrieve ? retrieveAcceptHeader : nil)
        let web = client(base: base, headers: headers, transport: transport,
                         storeBodyLimit: storeBodyLimit ?? DicomWebClientConfiguration.defaultMaximumSTOWRequestBodyBytes)
        do { return try run(cancelled: cancelled) { try await operation(web) } }
        catch { throw classify(error, transport: transport, cancelled: cancelled, failed: what) }
    }

    // MARK: Verify

    /// Locations' Test: one QIDO-RS study search with `limit=1` and the
    /// node's credential. The error says which of network, TLS, timeout,
    /// authentication (401/403) or path (404) failed.
    @objc(verifyWithError:)
    public func verify() throws {
        let thread = Thread.current
        try verify(cancelled: { thread.isCancelled })
    }

    func verify(cancelled: () -> Bool) throws {
        try requireBackground()
        let parameters = DicomWebSearchParameters(level: .study, includeFields: [], limit: 1)
        let page = try perform(base: node.qidoURL, cancelled: cancelled, failed: "The node did not answer the test query.") {
            try await $0.searchResponse(parameters: parameters)
        }
        _ = try Self.qidoRecords(page)
    }

    static func isDICOMJSON(_ contentType: String?) -> Bool {
        let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        return type == "application/dicom+json" || type == "application/json"
    }

    /// Keep the wire document for Objective-C consumers: decoding through a
    /// typed dataset may normalize unknown VRs, nulls or person-name fields.
    private static func qidoRecords(_ response: DicomWebHTTPResponse) throws -> [[String: Any]] {
        if response.statusCode == 204 { return [] }
        guard isDICOMJSON(response.headers.horosHTTPHeaderValue("Content-Type")),
              let records = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
            throw failure(4, "Invalid or oversized QIDO response.")
        }
        return records
    }

    // MARK: Query

    /// A QIDO-RS search at `path` below the QIDO URL: `studies`, `series`,
    /// `instances`, `studies/{uid}/series`, `studies/{uid}/instances` or
    /// `studies/{uid}/series/{uid}/instances`. `parameters` maps attribute
    /// tags or keywords to match values, plus `includefield`.
    @objc(queryPath:parameters:error:)
    public func query(path: String, parameters: [String: String]) throws -> [[String: Any]] {
        let thread = Thread.current
        return try query(path: path, parameters: parameters, cancelled: { thread.isCancelled })
    }

    static func searchParameters(path: String, parameters: [String: String]) throws -> DicomWebSearchParameters {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var search: DicomWebSearchParameters
        switch parts.count {
        case 1 where parts[0] == "studies": search = .init(level: .study)
        case 1 where parts[0] == "series": search = .init(level: .series)
        case 1 where parts[0] == "instances": search = .init(level: .instance)
        case 3 where parts[0] == "studies" && parts[2] == "series": search = .init(level: .series, studyInstanceUID: parts[1])
        case 3 where parts[0] == "studies" && parts[2] == "instances": search = .init(level: .instance, studyInstanceUID: parts[1])
        case 5 where parts[0] == "studies" && parts[2] == "series" && parts[4] == "instances":
            search = .init(level: .instance, studyInstanceUID: parts[1], seriesInstanceUID: parts[3])
        default: throw failure(1, "Invalid DICOMweb resource path.", kind: .configuration)
        }
        guard parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("?") && !$0.contains("#") }) else {
            throw failure(1, "Invalid DICOMweb resource path.", kind: .configuration)
        }
        search.includeFields = []
        for (key, value) in parameters.sorted(by: { $0.key < $1.key }) {
            switch key.lowercased() {
            case "includefield": search.includeFields = value.split(separator: ",").map(String.init)
            case "limit", "offset", "fuzzymatching": continue
            default:
                let uid = key.uppercased() == "0020000D" || key.uppercased() == "0020000E" || key.uppercased() == "00080018"
                search.matches.append(.init(key, vr: uid ? .UI : .unknown, values: [value]))
            }
        }
        do { _ = try search.queryItems() }
        catch { throw failure(4, "A query filter could not be sent. Remove line breaks from the filters.", kind: .configuration) }
        return search
    }

    static func hasMoreQIDOResults(_ warning: String?) -> Bool {
        guard let warning = warning?.lowercased(),
              warning.range(of: #"(?:^|,)\s*299\s"#, options: .regularExpression) != nil else { return false }
        // Code 299 also reports unsupported fuzzy matching. Only a warning
        // about omitted results requires another page.
        return warning.contains("additional results") || warning.contains("more results")
            || warning.contains("truncat") || warning.contains("exceeded the maximum")
    }

    func query(path: String, parameters: [String: String], cancelled: () -> Bool) throws -> [[String: Any]] {
        try requireBackground()
        let search = try Self.searchParameters(path: path, parameters: parameters)
        var collected: [[String: Any]] = []
        var seenIdentities = Set<String>()
        let identityTag: String
        switch search.level {
        case .study: identityTag = "0020000D"
        case .series: identityTag = "0020000E"
        case .instance: identityTag = "00080018"
        }
        while true {
            var page = search
            page.limit = 100
            page.offset = collected.count
            let request = page
            let result = try perform(base: node.qidoURL, cancelled: cancelled, failed: "The query returned no results.") {
                try await $0.searchResponse(parameters: request)
            }
            if result.statusCode == 204 { return collected }
            let records = try Self.qidoRecords(result)
            if records.isEmpty { return collected }
            let identities = records.map { record -> String in
                let attribute = record[identityTag] as? [String: Any]
                return (attribute?["Value"] as? [String])?.first ?? ""
            }
            guard !identities.contains("") else {
                throw Self.failure(4, "The QIDO response is missing a study, series or instance UID. Check the node's QIDO path.")
            }
            guard identities.allSatisfy({ seenIdentities.insert($0).inserted }) else {
                throw Self.failure(4, "The QIDO server repeated results instead of advancing the offset. Narrow the query or check the node's pagination support.")
            }
            guard collected.count + records.count <= 10000 else {
                throw Self.failure(4, "The QIDO query exceeds 10000 results. Narrow the query.")
            }
            collected.append(contentsOf: records)
            if records.count != 100 && !Self.hasMoreQIDOResults(result.headers.horosHTTPHeaderValue("Warning")) { return collected }
        }
    }

    // MARK: Retrieve

    /// A WADO-RS retrieve of `studies/{uid}`, `studies/{uid}/series/{uid}` or
    /// `studies/{uid}/series/{uid}/instances/{uid}` below the WADO URL, with
    /// the node's transfer syntax, into `stagingDirectory`, which must not
    /// exist yet. Returns the staged files; on any failure the directory is
    /// removed.
    @objc(retrievePath:stagingDirectory:error:)
    public func retrieve(path: String, stagingDirectory: String) throws -> [String] {
        let thread = Thread.current
        return try retrieve(path: path, stagingDirectory: stagingDirectory, cancelled: { thread.isCancelled })
    }

    func retrieve(path: String, stagingDirectory: String, cancelled: () -> Bool) throws -> [String] {
        try requireBackground()
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let shapes = [["studies"], ["studies", "series"], ["studies", "series", "instances"]]
        guard parts.count % 2 == 0, shapes.contains(stride(from: 0, to: parts.count, by: 2).map { parts[$0] }),
              parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("?") && !$0.contains("#") })
        else { throw Self.failure(1, "Invalid DICOMweb resource path.", kind: .configuration) }
        let sink = DICOMwebStagingSink(directory: URL(fileURLWithPath: stagingDirectory),
                                       transferSyntax: node.retrieveTransferSyntax.isEmpty ? nil : node.retrieveTransferSyntax)
        do { try sink.begin() } catch { throw Self.failure(5, "The DICOMweb staging folder could not be created. Check the database folder.", kind: .configuration) }
        do {
            let status = try perform(base: node.wadoURL, cancelled: cancelled, failed: "No objects were imported.",
                                     transferTimeout: transferTimeout, responseOperation: .retrieve) {
                switch parts.count {
                case 2: return try await $0.retrieveStudy(studyInstanceUID: parts[1], sink: sink)
                case 4: return try await $0.retrieveSeries(studyInstanceUID: parts[1], seriesInstanceUID: parts[3], sink: sink)
                default: return try await $0.retrieveInstance(studyInstanceUID: parts[1], seriesInstanceUID: parts[3],
                                                              sopInstanceUID: parts[5], sink: sink)
                }
            }
            guard status == 200 else { throw Self.failure(4, "The node returned no DICOM objects.") }
            if cancelled() { throw Self.cancelledError }
            return try sink.finish().map { $0.path }
        } catch let error as NSError where error.domain == "HorosDICOMweb" || error.domain == "HorosDICOMwebCredentials" {
            sink.discard()
            throw error
        } catch {
            sink.discard()
            throw Self.failure(4, "Incomplete or invalid WADO-RS response. No objects were imported.")
        }
    }

    // MARK: Store

    /// STOW-RS of `files` to `{address}/studies`, in requests of at most
    /// `storeBatchMaximumCount` files and `storeBatchMaximumBytes` bytes, each
    /// streamed from disk. Returns one result per file, in order. A request
    /// that fails marks its files failed; authentication, path, connection,
    /// TLS, timeout and cancellation failures also stop the files after it,
    /// which are reported as not sent. Throws only when nothing could be tried.
    @objc(storeFiles:error:)
    public func store(files: [String]) throws -> [DICOMwebStoreResult] {
        let thread = Thread.current
        return try store(files: files, cancelled: { thread.isCancelled })
    }

    private struct Prepared { let index: Int; let url: URL; let uid: String; let size: Int }

    /// The SOP Instance UID and size of a Part 10 file DICOM-Swift's STOW
    /// will accept, read from its File Meta Information only.
    static func inspect(_ url: URL) -> (uid: String, size: Int)? {
        fileMeta(url).map { ($0.meta.mediaStorageSOPInstanceUID ?? "", $0.size) }
    }

    /// The File Meta Information and size of a Part 10 file DICOM-Swift's
    /// STOW will accept: one that names its transfer syntax.
    static func fileMeta(_ url: URL) -> (meta: DicomPart10FileMetaParser.FileMeta, size: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), let size = Int(exactly: end), size >= 144,
              (try? handle.seek(toOffset: 0)) != nil,
              var prefix = try? handle.read(upToCount: 144), prefix.count == 144,
              DicomPart10FileMetaParser.hasPart10Prefix(prefix),
              Array(prefix[132..<140]) == [2, 0, 0, 0, 85, 76, 4, 0] else { return nil }
        let groupLength = (0..<4).reduce(UInt32(0)) { $0 | UInt32(prefix[140 + $1]) << (8 * $1) }
        // Bound metadata separately from the file and multipart payload budgets.
        guard let metaLength = Int(exactly: groupLength), metaLength <= 64 * 1024,
              metaLength <= size - 144,
              let rest = try? handle.read(upToCount: min(size - 144, metaLength + 8)) else { return nil }
        prefix.append(rest)
        guard let meta = try? DicomPart10FileMetaParser.parse(prefix), meta.dataSetOffset == 144 + metaLength,
              meta.transferSyntaxUID?.isEmpty == false else { return nil }
        return (meta, size)
    }

    func store(files: [String], cancelled: () -> Bool) throws -> [DICOMwebStoreResult] {
        try requireBackground()
        guard !files.isEmpty else { throw Self.failure(1, "No files to send.", kind: .configuration) }
        var results = [DICOMwebStoreResult?](repeating: nil, count: files.count)
        var valid: [Prepared] = []
        for (index, path) in files.enumerated() {
            let url = URL(fileURLWithPath: path)
            if let found = Self.inspect(url) { valid.append(Prepared(index: index, url: url, uid: found.uid, size: found.size)) }
            else {
                results[index] = DICOMwebStoreResult(path: path, sopInstanceUID: "", status: .failure,
                    reason: "Not a DICOM Part 10 file with File Meta Information. It was not sent.")
            }
        }
        var batches: [[Prepared]] = []
        for file in valid {
            if let last = batches.last, last.count < max(1, storeBatchMaximumCount),
               last.reduce(0, { $0 + $1.size }) + file.size <= max(1, storeBatchMaximumBytes) {
                batches[batches.count - 1].append(file)
            } else { batches.append([file]) }
        }
        var done = files.count - valid.count
        var stopped: NSError?
        for batch in batches {
            if stopped == nil, cancelled() { stopped = Self.cancelledError }
            if let stop = stopped {
                for file in batch {
                    results[file.index] = DICOMwebStoreResult(path: files[file.index], sopInstanceUID: file.uid, status: .failure,
                        reason: "Not sent. " + stop.localizedDescription)
                }
                continue
            }
            // The body is written to disk by DICOM-Swift and streamed from there,
            // so its limit is the batch's own size plus the MIME framing.
            let limit = batch.reduce(64 * 1024) { $0 + $1.size + 1024 }
            let urls = batch.map(\.url)
            do {
                let result = try perform(base: node.addressURL, cancelled: cancelled, failed: "The instances were not stored.",
                                         storeBodyLimit: limit, transferTimeout: transferTimeout, responseOperation: .store) {
                    try await $0.storeInstances(files: urls)
                }
                record(result, for: batch, paths: files, into: &results)
            } catch let error as NSError {
                let kind = Self.errorKind(for: error)
                let status = (100..<600).contains(error.code) ? error.code : 0
                for file in batch {
                    results[file.index] = DICOMwebStoreResult(path: files[file.index], sopInstanceUID: file.uid, status: .failure,
                        reason: error.localizedDescription, httpStatus: status)
                }
                if [.authentication, .notFound, .redirect, .network, .tls, .timeout, .cancelled, .credentials, .configuration].contains(kind) {
                    stopped = error
                }
            }
            done += batch.count
            storeProgress?(done, files.count)
        }
        return results.map { $0! }
    }

    private func record(_ result: DicomWebStoreResult, for batch: [Prepared], paths: [String],
                        into results: inout [DICOMwebStoreResult?]) {
        var reported: [String: DicomWebStoreResponse.Instance] = [:]
        for instance in result.storeResponse?.instances ?? [] {
            if let uid = instance.sopInstanceUID { reported[uid] = instance }
        }
        let others = (result.storeResponse?.otherFailureReasons ?? []).map { DICOMwebStoreResult.describe(reason: $0, warning: false) }
        for file in batch {
            let path = paths[file.index]
            guard let instance = reported[file.uid] else {
                // PS3.18 10.5.3: 200 means every instance was stored.
                results[file.index] = result.statusCode == 200
                    ? DICOMwebStoreResult(path: path, sopInstanceUID: file.uid, status: .success, reason: "", httpStatus: result.statusCode)
                    : DICOMwebStoreResult(path: path, sopInstanceUID: file.uid, status: .failure,
                        reason: (["The node did not report this instance."] + others).joined(separator: " "), httpStatus: result.statusCode)
                continue
            }
            switch instance.outcome {
            case .accepted:
                results[file.index] = DICOMwebStoreResult(path: path, sopInstanceUID: file.uid, status: .success, reason: "", httpStatus: result.statusCode)
            case .warning:
                let code = instance.warningReason ?? 0
                results[file.index] = DICOMwebStoreResult(path: path, sopInstanceUID: file.uid, status: .warning,
                    reason: DICOMwebStoreResult.describe(reason: code, warning: true), reasonCode: code, httpStatus: result.statusCode)
            case .failed, .unknown:
                let code = instance.failureReason ?? 0
                results[file.index] = DICOMwebStoreResult(path: path, sopInstanceUID: file.uid, status: .failure,
                    reason: code == 0 ? "The node refused this instance." : DICOMwebStoreResult.describe(reason: code, warning: false),
                    reasonCode: code, httpStatus: result.statusCode)
            }
        }
    }
}
