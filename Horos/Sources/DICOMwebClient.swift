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

import CryptoKit
import Foundation
import DicomData
import DicomWebClient
import Synchronization

// MARK: - Node

/// Where a DICOMweb node answers: an address, and QIDO-RS and WADO-RS
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
    /// The transfer syntax UID a retrieve asks for, or empty for the objects
    /// as stored: `*` and Implicit VR Little Endian, which WADO-RS does not
    /// send, are read as empty.
    @objc public let retrieveTransferSyntax: String
    /// The SHA-256 of the server certificate this node trusts besides the
    /// system's anchors, as 64 lowercase hexadecimal digits, or empty for none.
    @objc public let trustedCertificateSHA256: String
    /// The Keychain's persistent reference to the client certificate the node
    /// presents when its server asks for one, or nil.
    let clientIdentityReference: Data?
    /// What gives each request its credential headers and renews them after a
    /// 401, for a node that signs in (OpenID Connect); nil sends the stored
    /// credential, if any.
    let authorization: (any DicomWebAuthorizationProvider)?

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
    public convenience init(address: String, qidoPath: String, wadoPath: String,
                            credentialIdentifier: String, retrieveTransferSyntax: String, allowInsecureHTTP: Bool) throws {
        try self.init(address: address, qidoPath: qidoPath, wadoPath: wadoPath,
                      credentialIdentifier: credentialIdentifier, retrieveTransferSyntax: retrieveTransferSyntax,
                      allowInsecureHTTP: allowInsecureHTTP, trustedCertificateSHA256: "")
    }

    @objc(initWithAddress:qidoPath:wadoPath:credentialIdentifier:retrieveTransferSyntax:allowInsecureHTTP:trustedCertificateSHA256:error:)
    public convenience init(address: String, qidoPath: String, wadoPath: String, credentialIdentifier: String,
                            retrieveTransferSyntax: String, allowInsecureHTTP: Bool, trustedCertificateSHA256: String) throws {
        try self.init(address: address, qidoPath: qidoPath, wadoPath: wadoPath, credentialIdentifier: credentialIdentifier,
                      retrieveTransferSyntax: retrieveTransferSyntax, allowInsecureHTTP: allowInsecureHTTP,
                      trustedCertificateSHA256: trustedCertificateSHA256, clientIdentityReference: nil, authorization: nil)
    }

    public init(address: String, qidoPath: String, wadoPath: String, credentialIdentifier: String,
                retrieveTransferSyntax: String, allowInsecureHTTP: Bool, trustedCertificateSHA256: String,
                clientIdentityReference: Data?, authorization: (any DicomWebAuthorizationProvider)?) throws {
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
        self.retrieveTransferSyntax = syntax == "*" || syntax == DICOMwebClient.implicitVRLittleEndian ? "" : syntax
        self.trustedCertificateSHA256 = try DICOMwebServerTrust.normalizedFingerprint(trustedCertificateSHA256)
        self.clientIdentityReference = clientIdentityReference?.isEmpty == false ? clientIdentityReference : nil
        self.authorization = authorization
        addressURL = base
        qidoURL = try Self.resolve(self.qidoPath, against: base, service: "QIDO")
        wadoURL = try Self.resolve(self.wadoPath, against: base, service: "WADO")
        super.init()
    }

    /// The pilot's single URL: QIDO and WADO both at the address.
    @objc(nodeWithEndpoint:credentialIdentifier:error:)
    public static func node(endpoint: String, credentialIdentifier: String) throws -> DICOMwebNodeConfiguration {
        try DICOMwebNodeConfiguration(address: endpoint, qidoPath: "", wadoPath: "",
                                      credentialIdentifier: credentialIdentifier, retrieveTransferSyntax: "")
    }

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }

    /// The URL of a QIDO or WADO path below the address, by the node
    /// editor's own rule (`DICOMwebNode.relativePath`): a path the editor
    /// takes is one a request can use. Its segments are already
    /// percent-encoded, so an escape such as `%41` is sent as it is written.
    private static func resolve(_ path: String, against base: URL, service: String) throws -> URL {
        let refused = DICOMwebClient.failure(1, "The \(service) path must be relative to the address, such as dicom-web or wado.", kind: .configuration)
        guard let relative = DICOMwebNode.relativePath(path) else { throw refused }
        if relative.isEmpty { return base }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw refused }
        components.percentEncodedPath += "/" + relative
        guard let url = components.url else { throw refused }
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
    /// A retrieve parsed while it arrives is spooled in files of about this
    /// size, each removed once it has been read, so that the temporary folder
    /// holds what is still to be read, not the whole study.
    var retrieveSegmentBytes = 8 * 1024 * 1024
    /// And at most about this much is spooled ahead of the reader: beyond
    /// it, delivery is held until the reader has caught up halfway, and TCP
    /// flow control holds the node back meanwhile.
    var retrieveAheadBytes = 64 * 1024 * 1024

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

/// A node's explicit trust in its server's certificate, for a server whose
/// certificate the system does not trust, such as a self-signed one. The
/// system's evaluation always comes first; the node's certificate only adds an
/// anchor, and never turns validation off.
@objc(HorosDICOMwebServerTrust)
public final class DICOMwebServerTrust: NSObject {
    /// What the node setting means, for its column and cells.
    @objc public static var help: String {
        NSLocalizedString("The SHA-256 fingerprint of the server's certificate, for an HTTPS node whose certificate this Mac does not trust, such as a self-signed one. Only that certificate is trusted, and its host name and dates are still checked. Leave empty to use the system's trust only.", comment: "DICOMweb trusted certificate help")
    }

    /// The fingerprint as stored: 64 lowercase hexadecimal digits, from text
    /// that may separate them with colons or spaces; empty stays empty.
    @objc(normalizedFingerprint:error:)
    public static func normalizedFingerprint(_ text: String) throws -> String {
        let digits = text.lowercased().filter { !":- \t\n".contains($0) }
        guard !digits.isEmpty else { return "" }
        guard digits.count == 64, digits.allSatisfy({ $0.isHexDigit }) else {
            throw DICOMwebClient.failure(1, NSLocalizedString("Enter the certificate's SHA-256 fingerprint: 64 hexadecimal digits, with or without colons.", comment: "DICOMweb trusted certificate format"), kind: .configuration)
        }
        return digits
    }

    /// The SHA-256 of a certificate's DER encoding, as stored.
    static func fingerprint(of certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the server's chain is trusted with its leaf certificate as the
    /// only anchor, when that leaf is the one the node names. The SSL policy
    /// still checks the host name, and the evaluation the certificate's dates.
    static func trusts(_ trust: SecTrust, host: String, fingerprint: String) -> SecTrust? {
        guard !fingerprint.isEmpty, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, Self.fingerprint(of: leaf) == fingerprint else { return nil }
        var pinned: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, host as CFString), &pinned) == errSecSuccess,
              let pinned, SecTrustSetAnchorCertificates(pinned, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(pinned, true) == errSecSuccess,
              SecTrustEvaluateWithError(pinned, nil) else { return nil }
        return pinned
    }
}

/// Streams one response body into files this client owns and removes.
/// A download task writes into a CFNetworkDownload_*.tmp of CFNetwork's own in
/// the temporary folder, which CFNetwork keeps when the task times out or is
/// cancelled after the response headers arrived, with no resume data naming it.
///
/// A body read once it has finished goes into one file. A body read while it
/// arrives goes into a series of segment files: each is removed as soon as the
/// reader has gone past it. While too much is waiting to be read, the chunk
/// that arrived is held, so that URLSession delivers nothing more and stops
/// reading the connection, and TCP flow control holds the node back: suspending
/// the task does not, as a suspension asked for while the connection is read
/// can be lost. The hold lasts until the reader has caught up halfway, or the
/// body is abandoned or expires. The session's other requests wait meanwhile,
/// as they share its delegate queue. URLSession would time out a request whose
/// delivery is held, so such a body is watched for inactivity here instead,
/// and the time spent held for a slow reader does not count.
///
/// @unchecked Sendable: URLSession calls the delegate on its own queue while
/// the request's task reads the outcome and may abandon it. Every stored `var`
/// is read and written only under `lock`, including `statusCode`, which only
/// the delegate writes; the `let`s never change. The lock is kept as it is on
/// the body's path, where each received chunk takes it; it is a condition, on
/// which a held chunk waits.
private final class DICOMwebResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// One file of the body: the bytes from `start` to `end`, or to what has
    /// been received while it is the one being written.
    private struct Segment {
        let url: URL
        let start: Int
        var end: Int?
    }

    private let lock = NSCondition()
    private let directory: URL
    private let budgets: DICOMwebResponseBudgets
    private let operation: DICOMwebResponseBudgets.Operation
    /// Whether a reader follows the body while it arrives.
    private let follows: Bool
    private var limit = 0
    private var receivedBytes = 0
    private var output: FileHandle?
    private var abandoned = false
    private var finished = false
    private var completion: (@Sendable () -> Void)?
    /// Called once the response headers have arrived, or the task has
    /// finished without them.
    private var responded = false
    private var respondedCompletion: (@Sendable () -> Void)?
    /// A reader waiting for more of the body than has arrived.
    private var progress: (@Sendable () -> Void)?
    /// The task, cancelled when the body is abandoned before it has finished,
    /// and what gives its session back to the pool once it has.
    private var task: URLSessionTask?
    private var release: (@Sendable () -> Void)?
    /// Told the protocol and connection reuse of each transaction.
    private let onMetrics: @Sendable (URLSessionTaskMetrics) -> Void
    /// The body's files not yet removed, in order; the last one may be being
    /// written. `spooling` from the response headers until the body is removed.
    private var segments: [Segment] = []
    private var spooling = false
    /// Segment size and how far the transfer may run ahead of the reader, for
    /// a successful answer that is followed; otherwise unbounded.
    private var segmentBytes = Int.max
    private var aheadBytes = Int.max
    /// Where the reader is, and whether a chunk is held for it.
    private var readOffset = 0
    private var holding = false
    /// The inactivity timeout this response watches itself, if any, and the
    /// last time the transfer progressed or was resumed (system uptime).
    private var inactivity: TimeInterval?
    private var lastActivity: TimeInterval = 0
    private var response: HTTPURLResponse?
    private var error: Error?
    /// Every status the transport saw, so an HTTP error can be told from a
    /// failure of the client's own with the same number.
    private(set) var statusCode = 0

    /// Told when the body goes over its budget, whoever reads it.
    private let onLimit: @Sendable () -> Void
    /// The node's trusted certificate, or empty.
    private let trustedCertificateSHA256: String
    /// The client certificate of the request's origin policy, and the origin
    /// it may be presented to: the node's own.
    private let clientIdentity: DicomWebClientIdentity?
    private let clientIdentityOrigin: URL?
    /// The server asked for a client certificate and none was presented.
    /// URLSession then reports a refused handshake as a lost connection.
    private var clientCertificateWithheld = false

    init(directory: URL, budgets: DICOMwebResponseBudgets, operation: DICOMwebResponseBudgets.Operation,
         follows: Bool = false, trustedCertificateSHA256: String = "",
         clientIdentity: DicomWebClientIdentity? = nil, clientIdentityOrigin: URL? = nil,
         onLimit: @escaping @Sendable () -> Void = {}, onMetrics: @escaping @Sendable (URLSessionTaskMetrics) -> Void = { _ in }) {
        self.directory = directory; self.budgets = budgets; self.operation = operation; self.follows = follows
        self.onLimit = onLimit; self.onMetrics = onMetrics
        self.trustedCertificateSHA256 = trustedCertificateSHA256
        self.clientIdentity = clientIdentity; self.clientIdentityOrigin = clientIdentityOrigin
    }

    /// Whether a challenge comes from `url`'s scheme, host and port.
    static func isOrigin(_ space: URLProtectionSpace, of url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let spacePort = space.port > 0 ? space.port : ((space.protocol?.lowercased() ?? scheme) == "https" ? 443 : 80)
        return (space.protocol?.lowercased() ?? scheme) == scheme && space.host.lowercased() == host && spacePort == port
    }

    /// What the finished task produced. The body, if any, is the caller's to
    /// return or to hand to abandon(). A body that is not followed is one file.
    var outcome: (body: URL?, response: HTTPURLResponse?, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        return (spooling ? segments.first?.url : nil, response, error)
    }

    /// Calls `block` once the task has finished, at once if it already has.
    func whenFinished(_ block: @escaping @Sendable () -> Void) {
        lock.lock()
        if finished { lock.unlock(); block(); return }
        completion = block
        lock.unlock()
    }

    /// Calls `block` once the response headers have arrived or the task has
    /// finished, at once if either has happened.
    func whenResponded(_ block: @escaping @Sendable () -> Void) {
        lock.lock()
        if responded || finished { lock.unlock(); block(); return }
        respondedCompletion = block
        lock.unlock()
    }

    /// Hands the task to the response, before it is resumed: the response
    /// gives the session back with `release` once the task has finished, and
    /// cancels the task alone, never the shared session, when the body is
    /// abandoned first or the transfer outlives `ceiling` seconds, however
    /// it progresses. Inactivity is the session's own timeout, unless
    /// `inactivity` is given: then this response ends the task after that
    /// long without progress, not counting the time a chunk was held.
    func own(_ task: URLSessionTask, ceiling: TimeInterval, inactivity: TimeInterval? = nil,
             release: @escaping @Sendable () -> Void) {
        lock.lock()
        self.task = task
        self.release = release
        self.inactivity = inactivity
        lastActivity = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ceiling) { [weak self] in self?.expire() }
        if let inactivity { watch(every: max(0.05, inactivity / 4)) }
    }

    /// Ends the task once it has gone `inactivity` without progress while
    /// running; checks again every `interval` until the task has finished.
    private func watch(every interval: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.finished, !self.abandoned, let inactivity = self.inactivity else { self.lock.unlock(); return }
            let idle = !self.holding && ProcessInfo.processInfo.systemUptime - self.lastActivity >= inactivity
            self.lock.unlock()
            if idle { self.expire() } else { self.watch(every: interval) }
        }
    }

    /// The whole transfer took too long, or stopped progressing: the
    /// request's own ceiling, which a session shared by requests of different
    /// lengths cannot carry, or the inactivity this response watches.
    private func expire() {
        lock.lock()
        guard !finished, !abandoned, let task else { lock.unlock(); return }
        if error == nil { error = URLError(.timedOut) }
        removeBody()
        lock.broadcast()
        lock.unlock()
        task.cancel()
        signalProgress()
    }

    /// The headers, without waiting for the body.
    var head: (response: HTTPURLResponse?, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        return (response, error)
    }

    /// What a reader following the body may take from `offset`: the file
    /// holding that byte and where the file starts in the body, the bytes
    /// already written to that file from there, whether the task has
    /// finished, and its error. When nothing is there yet and the task goes
    /// on, `waiter` is kept and called on the next chunk or at the end.
    /// The reader has read everything before `offset`: the files wholly
    /// before it are removed, and a chunk held for the reader is let go once
    /// the reader is halfway through what was waiting.
    func available(from offset: Int, waiter: @escaping @Sendable () -> Void)
        -> (file: URL?, fileStart: Int, bytes: Int, finished: Bool, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        readOffset = max(readOffset, offset)
        while let first = segments.first, let end = first.end, end <= readOffset {
            try? FileManager.default.removeItem(at: first.url)
            segments.removeFirst()
        }
        if holding, receivedBytes - readOffset <= aheadBytes / 2 {
            holding = false
            lastActivity = ProcessInfo.processInfo.systemUptime
            lock.broadcast()
        }
        let segment = segments.first { $0.start <= offset && offset < ($0.end ?? receivedBytes) }
        let bytes = segment.map { ($0.end ?? receivedBytes) - offset } ?? 0
        let state = (file: segment?.url, fileStart: segment?.start ?? offset, bytes: bytes,
                     finished: finished || abandoned, error: error)
        if state.bytes == 0 && !state.finished && state.error == nil { progress = waiter }
        return state
    }

    /// Removes the body and ignores whatever the task still delivers.
    func abandon() {
        lock.lock()
        abandoned = true
        removeBody()
        lock.broadcast()
        let running = finished ? nil : task
        let waiter = progress
        progress = nil
        lock.unlock()
        running?.cancel()
        waiter?()
    }

    private func signalProgress() {
        lock.lock()
        let waiter = progress
        progress = nil
        lock.unlock()
        waiter?()
    }

    // Called with the lock held, also on failures while the body is arriving.
    private func removeBody() {
        closeOutput()
        for segment in segments { try? FileManager.default.removeItem(at: segment.url) }
        segments = []
        spooling = false
    }

    // Called with the lock held: the file being written is complete.
    private func closeOutput() {
        try? output?.close()
        output = nil
        if !segments.isEmpty, segments[segments.count - 1].end == nil { segments[segments.count - 1].end = receivedBytes }
    }

    // Called with the lock held: the next file of the body, from what has
    // been received so far.
    private func openSegment() throws {
        closeOutput()
        let url = directory.appendingPathComponent("horos-dicomweb-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        segments.append(Segment(url: url, start: receivedBytes, end: nil))
        output = try FileHandle(forWritingTo: url)
    }

    // Called with the lock held: an empty body, before anything arrives.
    private func openBody() throws {
        removeBody()
        spooling = true
        try openSegment()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // The node's client certificate goes to the node alone. Without one,
        // or elsewhere, the challenge is handled as before.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
           let clientIdentity, Self.isOrigin(challenge.protectionSpace, of: clientIdentityOrigin) {
            completionHandler(.useCredential, URLCredential(identity: clientIdentity.identity,
                                                            certificates: clientIdentity.certificates.isEmpty ? nil : clientIdentity.certificates,
                                                            persistence: .none))
            return
        }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            lock.withLock { clientCertificateWithheld = true }
        }
        // Everything but a server the system refuses and the node trusts is
        // handled as it was before the node could name a certificate.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              !trustedCertificateSHA256.isEmpty, let trust = challenge.protectionSpace.serverTrust,
              !SecTrustEvaluateWithError(trust, nil),
              let pinned = DICOMwebServerTrust.trusts(trust, host: challenge.protectionSpace.host, fingerprint: trustedCertificateSHA256)
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: pinned))
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
            lastActivity = ProcessInfo.processInfo.systemUptime
            let status = self.response?.statusCode ?? 0
            limit = budgets.limit(operation: operation, status: status)
            receivedBytes = 0
            readOffset = 0
            // Only a successful answer is read while it arrives; any other
            // is read once it has finished, from one file.
            if follows, (200..<300).contains(status) {
                segmentBytes = max(1, budgets.retrieveSegmentBytes)
                aheadBytes = max(1, budgets.retrieveAheadBytes)
            }
            // Refuse declared sizes before creating a spool. Unknown lengths are
            // checked as bytes arrive, including decoded compressed bodies.
            if response.expectedContentLength > Int64(limit) {
                onLimit()
                self.error = DICOMwebReceiveFailure.responseTooLarge
                removeBody()
                disposition = .cancel
            } else {
                do { try openBody() }
                catch { self.error = error; removeBody(); disposition = .cancel }
            }
        }
        responded = true
        let block = respondedCompletion
        respondedCompletion = nil
        lock.unlock()
        completionHandler(disposition)
        block?()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        receive(data, task: dataTask)
        let waiter = progress
        progress = nil
        lock.unlock()
        waiter?()
        // The reader is told first: it has the allowance to read meanwhile.
        lock.lock()
        while holding, !abandoned, error == nil { lock.wait() }
        lock.unlock()
    }

    // Called with the lock held: writes a chunk to the spool, and holds it
    // when the reader is too far behind.
    private func receive(_ data: Data, task dataTask: URLSessionDataTask) {
        guard !abandoned, error == nil, spooling else { return }
        guard data.count <= limit - receivedBytes else {
            onLimit()
            error = DICOMwebReceiveFailure.responseTooLarge
            removeBody()
            dataTask.cancel()
            return
        }
        do {
            if output == nil { try openSegment() }
            try output?.write(contentsOf: data)
            receivedBytes += data.count
            lastActivity = ProcessInfo.processInfo.systemUptime
        } catch { self.error = error; removeBody(); dataTask.cancel(); return }
        // A file is complete once it reaches its size; the next chunk opens
        // the next one. The reader removes each once past it.
        if let current = segments.last, receivedBytes - current.start >= segmentBytes { closeOutput() }
        if receivedBytes - readOffset >= aheadBytes { holding = true }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        onMetrics(metrics)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        closeOutput()
        if self.error == nil { self.error = error }
        // A connection that failed before any answer, after the server asked
        // for a client certificate it was not given, failed for want of one.
        if let failure = self.error as? URLError, failure.code != .cancelled, clientCertificateWithheld, task.response == nil {
            self.error = URLError(.clientCertificateRequired)
        }
        response = (task.response as? HTTPURLResponse) ?? response
        statusCode = response?.statusCode ?? 0
        if self.error != nil { removeBody() }
        if !abandoned, self.error == nil, !spooling {
            do { try openBody(); closeOutput() } catch { self.error = error }
        }
        finished = true
        holding = false
        let block = completion
        completion = nil
        let headers = respondedCompletion
        respondedCompletion = nil
        let waiter = progress
        progress = nil
        let ended = self.release
        self.release = nil
        self.task = nil
        lock.unlock()
        ended?()
        headers?()
        block?()
        waiter?()
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

/// Follows a body while it is still arriving: each chunk is read from the
/// spool as soon as it has been written, so the multipart parser sees a
/// part's end without waiting for the rest of the response. The spool is a
/// series of files, each removed once read past; the network runs ahead of
/// the parser by at most the response's allowance before it is held; memory
/// holds one chunk. A failure of the transfer is thrown at the next
/// read. The spool is removed, and a task still running cancelled, when the
/// body has been read, when the reader is cancelled, or when it goes away.
///
/// @unchecked Sendable: the consumer's task reads chunks while URLSession's
/// queue signals progress. `handle`, `handleFile`, `offset`, `done`,
/// `cancelled` and `pending` are read and written only under `lock`, never
/// held while calling into `owner`'s lock from outside `poll`; `owner`
/// never changes.
private final class DICOMwebFollowingReader: @unchecked Sendable {
    private static let chunkSize = 64 * 1024
    private let lock = NSLock()
    private let owner: DICOMwebResponse
    private var handle: FileHandle?
    /// The spool file `handle` reads.
    private var handleFile: URL?
    private var offset = 0
    private var done = false
    private var cancelled = false
    private var pending: CheckedContinuation<Data?, Error>?

    init(owner: DICOMwebResponse) { self.owner = owner }
    deinit { finish() }

    func next() async throws -> Data? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                lock.lock(); pending = continuation; lock.unlock()
                poll()
            }
        } onCancel: {
            lock.lock(); cancelled = true; lock.unlock()
            poll()
        }
    }

    private func resume(_ result: Result<Data?, Error>) {
        lock.lock(); let continuation = pending; pending = nil; lock.unlock()
        continuation?.resume(with: result)
    }

    /// Answers the waiting read if there is something to answer with;
    /// otherwise leaves a waiter with the response, which calls back.
    private func poll() {
        lock.lock()
        guard pending != nil else { lock.unlock(); return }
        if cancelled { lock.unlock(); resume(.failure(CancellationError())); return }
        if done { lock.unlock(); resume(.success(nil)); return }
        let state = owner.available(from: offset, waiter: { [weak self] in self?.poll() })
        if let error = state.error { lock.unlock(); resume(.failure(error)); return }
        if state.bytes > 0, let file = state.file {
            let result: Result<Data?, Error> = Result {
                try autoreleasepool {
                    // The next file of the spool: the one before has been
                    // read whole, and the response removes it.
                    if handleFile != file {
                        try? handle?.close()
                        handle = nil
                        let next = try FileHandle(forReadingFrom: file)
                        handle = next
                        handleFile = file
                        try next.seek(toOffset: UInt64(offset - state.fileStart))
                    }
                    guard let chunk = try handle?.read(upToCount: min(Self.chunkSize, state.bytes)), !chunk.isEmpty
                    else { throw CocoaError(.fileReadUnknown) }
                    offset += chunk.count
                    return chunk
                }
            }
            lock.unlock()
            resume(result)
            return
        }
        lock.unlock()
        if state.finished { finish(); resume(.success(nil)) }
    }

    func finish() {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        try? handle?.close()
        handle = nil
        handleFile = nil
        lock.unlock()
        owner.abandon()
    }
}

/// The URL sessions DICOMweb requests share, one per node configuration, so
/// that successive and simultaneous requests of a node (queries, retrieves,
/// stores) can reuse connections, and multiplex them when the server
/// negotiates HTTP/2: URLSession negotiates the protocol and falls back to
/// HTTP/1.1. Each session is ephemeral, without cache, cookies or stored
/// credentials; a request's own delegate refuses redirects, spools its body
/// and enforces its deadline, and cancelling a request cancels its task alone.
///
/// A session is keyed by everything a connection may carry over: the node's
/// address (scheme, host, port and path), whether plain HTTP is allowed, its
/// credential reference, and the request timeout. Another node, a changed
/// address or credential get another session. Sessions without requests are
/// ended after `idleLifetime`, at once beyond `maximumIdleSessions`, and when
/// nodes or credentials are saved.
///
/// @unchecked Sendable: `entries`, `created` and the limits are read and
/// written only under `lock`; sessions are ended outside it.
@objc(HorosDICOMwebSessionPool)
public final class DICOMwebSessionPool: NSObject, @unchecked Sendable {
    @objc public static let shared = DICOMwebSessionPool()

    struct Key: Hashable, Sendable {
        let identity: String
        let timeout: TimeInterval
    }

    private final class Entry {
        let session: URLSession
        var active = 0
        var lastUsed = Date()
        init(session: URLSession) { self.session = session }
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var _idleLifetime: TimeInterval = 60
    private var _maximumIdleSessions = 4
    private var _created = 0

    /// How long a session without requests is kept.
    var idleLifetime: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _idleLifetime }
        set { lock.lock(); _idleLifetime = max(0, newValue); lock.unlock() }
    }
    /// How many sessions without requests are kept at most.
    var maximumIdleSessions: Int {
        get { lock.lock(); defer { lock.unlock() }; return _maximumIdleSessions }
        set { lock.lock(); _maximumIdleSessions = max(0, newValue); lock.unlock() }
    }
    /// Sessions made so far, and kept now.
    var created: Int { lock.lock(); defer { lock.unlock() }; return _created }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// The session for `key`, made if there is none, counted as in use until
    /// `release(_:)`.
    func lease(_ key: Key) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        if let entry = entries[key] {
            entry.active += 1
            entry.lastUsed = Date()
            return entry.session
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = key.timeout
        // Each request ends itself at its own deadline; the session outlives them.
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        // A node's own limit (at most 16 requests at once) governs; HTTP/1.1's
        // default of six connections per host would cap it.
        configuration.httpMaximumConnectionsPerHost = 16
        let entry = Entry(session: URLSession(configuration: configuration, delegate: nil, delegateQueue: nil))
        entry.active = 1
        entries[key] = entry
        _created += 1
        return entry.session
    }

    func release(_ key: Key) {
        lock.lock()
        if let entry = entries[key] {
            entry.active = max(0, entry.active - 1)
            entry.lastUsed = Date()
        }
        let ended = removeIdle(olderThan: nil)
        let lifetime = _idleLifetime
        lock.unlock()
        ended.forEach { $0.finishTasksAndInvalidate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + lifetime + 0.05) { [weak self] in self?.expireIdle() }
    }

    /// Ends the sessions idle for their lifetime.
    func expireIdle() {
        lock.lock()
        let ended = removeIdle(olderThan: Date().addingTimeInterval(-_idleLifetime))
        lock.unlock()
        ended.forEach { $0.finishTasksAndInvalidate() }
    }

    /// Ends every session without requests: after nodes or credentials were
    /// saved, so that nothing a former configuration opened is used again.
    @objc public func endIdleSessions() {
        lock.lock()
        let ended = removeIdle(olderThan: Date.distantFuture)
        lock.unlock()
        ended.forEach { $0.finishTasksAndInvalidate() }
    }

    // Called with the lock held: the idle sessions used before `date`, and
    // beyond the limit the least recently used ones.
    private func removeIdle(olderThan date: Date?) -> [URLSession] {
        var ended: [URLSession] = []
        if let date {
            for (key, entry) in entries where entry.active == 0 && entry.lastUsed <= date {
                ended.append(entry.session); entries[key] = nil
            }
        }
        let idle = entries.filter { $0.value.active == 0 }.sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (key, entry) in idle.prefix(max(0, idle.count - _maximumIdleSessions)) {
            ended.append(entry.session); entries[key] = nil
        }
        return ended
    }
}

/// The transport DICOM-Swift's client sends through: an ephemeral session with
/// no cache, cookies or stored credentials, no redirect followed, timeouts, and
/// bodies that go through files the transport owns.
/// What a detached request hands to the thread waiting for it while it runs:
/// values posted in order, taken by that thread.
final class DICOMwebMailbox<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])
    func post(_ value: Value) { values.withLock { $0.append(value) } }
    func take() -> [Value] { values.withLock { list in defer { list.removeAll() }; return list } }
}

final class DICOMwebTransport: DicomWebHTTPTransport {
    /// How long a request may wait for data, the session's own timeout.
    let timeout: TimeInterval
    /// The longest a request may take however it progresses.
    let transferCeiling: TimeInterval
    private let budgets: DICOMwebResponseBudgets
    private let operation: DICOMwebResponseBudgets.Operation
    private let temporaryDirectory: URL
    /// Recorded by the request's task, read by the caller's classification.
    private let statuses = Mutex<[Int]>([])
    /// Whether a body went over its budget: a body parsed while it arrives
    /// may fail to parse before the transfer reports the limit.
    private let overLimit = Mutex(false)

    func exceededReceiveLimit() -> Bool { overLimit.withLock { $0 } }
    /// The Retry-After header of the last error answer, if it had one.
    private let retryAfterHeader = Mutex<String?>(nil)
    var retryAfter: String? { retryAfterHeader.withLock { $0 } }

    /// The network transactions so far: how many, how many on a connection an
    /// earlier request opened, and the protocols negotiated. No host or URL.
    var connectionSummary: (requests: Int, reused: Int, protocols: [String]) {
        transactions.withLock { list in
            (list.count, list.filter(\.reused).count, Array(Set(list.map(\.protocolName))).sorted())
        }
    }

    private func record(_ metrics: URLSessionTaskMetrics) {
        let network = metrics.transactionMetrics.filter { $0.resourceFetchType == .networkLoad }
        transactions.withLock { list in
            for transaction in network {
                list.append((transaction.networkProtocolName ?? "unknown", transaction.isReusedConnection))
            }
        }
    }

    /// The pool's key part for this transport's node; a transport made
    /// without one shares its session with no other.
    private let sessionIdentity: String
    private let pool: DICOMwebSessionPool
    /// The node's trusted certificate, or empty for the system's trust only.
    private let trustedCertificateSHA256: String
    /// Given the body of every successful GET, in order: a QIDO-RS search
    /// keeps the node's own JSON, which a typed dataset would normalize.
    private let searchBodies: DICOMwebMailbox<Data>?
    /// The protocol and reuse of each network transaction, in order.
    private let transactions = Mutex<[(protocolName: String, reused: Bool)]>([])

    init(timeout: TimeInterval, transferCeiling: TimeInterval,
         budgets: DICOMwebResponseBudgets = .init(), operation: DICOMwebResponseBudgets.Operation = .query,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         sessionIdentity: String? = nil, pool: DICOMwebSessionPool = .shared, trustedCertificateSHA256: String = "",
         searchBodies: DICOMwebMailbox<Data>? = nil) {
        self.searchBodies = searchBodies
        self.sessionIdentity = sessionIdentity ?? "transport " + UUID().uuidString
        self.trustedCertificateSHA256 = trustedCertificateSHA256
        self.pool = pool
        self.timeout = timeout
        self.transferCeiling = transferCeiling
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
        // A retrieve's body is parsed while it arrives, so that each object
        // can be imported as soon as its part has ended. Every other body is
        // read once the whole of it is on disk.
        let follows = operation == .retrieve && request.method == .get
        // A followed body may be held for its reader, and URLSession would
        // time the request out meanwhile: its response watches inactivity
        // instead, and the request's own timeout, which takes precedence over
        // the session's, is only the ceiling.
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                    timeoutInterval: follows ? max(timeout, transferCeiling) : timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = false
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        let result = DICOMwebResponse(directory: temporaryDirectory, budgets: budgets, operation: operation, follows: follows,
                                      trustedCertificateSHA256: trustedCertificateSHA256,
                                      clientIdentity: request.originPolicy?.clientIdentity,
                                      clientIdentityOrigin: request.originPolicy?.configuredURL,
                                      onLimit: { [self] in self.overLimit.withLock { $0 = true } },
                                      onMetrics: { [self] in self.record($0) })
        let key = DICOMwebSessionPool.Key(identity: sessionIdentity, timeout: timeout)
        let session = pool.lease(key)
        let task: URLSessionTask
        if let file = request.bodyFileURL { task = session.uploadTask(with: urlRequest, fromFile: file) }
        else if let body = request.body { task = session.uploadTask(with: urlRequest, from: body) }
        else { task = session.dataTask(with: urlRequest) }
        // The request's own delegate, on a session other requests share; it
        // gives the session back when the task has finished.
        task.delegate = result
        result.own(task, ceiling: transferCeiling, inactivity: follows ? timeout : nil, release: { [pool] in pool.release(key) })
        // The body is this call's to hand over or to remove, on every path,
        // including a timeout or cancellation while it is still arriving.
        var handedOver = false
        defer { if !handedOver { result.abandon() } }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if follows { result.whenResponded { continuation.resume() } }
                else { result.whenFinished { continuation.resume() } }
                task.resume()
            }
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        // An error answer is read whole, as any other body.
        if follows, let status = result.head.response?.statusCode, !(200..<300).contains(status) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    result.whenFinished { continuation.resume() }
                }
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
        }
        let (response, error) = result.head
        if let error = error {
            // A request that timed out is not repeated: the node has had the
            // whole timeout to answer, and each attempt would add as much.
            // DICOM-Swift never repeats a STOW-RS that timed out, and stops the
            // batches after it on a URL error, so a store keeps it as one.
            if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorTimedOut {
                if request.method == .post { throw URLError(.timedOut) }
                throw DICOMwebClient.timedOutError
            }
            throw error
        }
        guard let http = response else { throw DicomWebError(kind: .invalidResponse) }
        record(status: http.statusCode)
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { headers, pair in
            if let key = pair.key as? String { headers[key] = String(describing: pair.value) }
        }
        if !(200..<300).contains(http.statusCode), let wait = headers.horosHTTPHeaderValue("Retry-After") {
            retryAfterHeader.withLock { $0 = String(wait.prefix(64)) }
        }
        if follows, (200..<300).contains(http.statusCode) {
            let reader = DICOMwebFollowingReader(owner: result)
            handedOver = true
            return .init(statusCode: http.statusCode, headers: headers,
                         body: AsyncThrowingStream(unfolding: { try await reader.next() }),
                         cancel: { reader.finish() })
        }
        let body = result.outcome.body
        if let searchBodies, request.method == .get, (200..<300).contains(http.statusCode) {
            searchBodies.post(try body.map { try Data(contentsOf: $0) } ?? Data())
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

/// Horos's DICOMweb client: an adapter over DICOM-Swift's
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
    /// The longest a whole retrieve or store request may take however it
    /// progresses: a ceiling against a node that never ends its answer, not
    /// a deadline for large studies on slow links. A request that stops
    /// progressing ends sooner, after `timeout` seconds without data; one
    /// held while its objects are imported does not count as stopped.
    /// Defaults to `DICOMwebTransferCeiling` (seconds) in the user defaults,
    /// or a day, and is at most a week.
    @objc public var transferCeiling: TimeInterval = DICOMwebClient.defaultTransferCeiling
    static let maximumTransferCeiling: TimeInterval = 7 * 24 * 3600
    @objc public static var defaultTransferCeiling: TimeInterval {
        let configured = UserDefaults.standard.double(forKey: "DICOMwebTransferCeiling")
        return configured > 0 ? min(configured, maximumTransferCeiling) : 24 * 3600
    }
    /// STOW-RS sends at most this many files in one request.
    @objc public var storeBatchMaximumCount: Int = 50
    /// And at most this many bytes of files, unless a single file is larger.
    @objc public var storeBatchMaximumBytes: Int = 64 * 1024 * 1024
    /// Called on the calling thread after each STOW-RS request with the number
    /// of files done and the total.
    @objc public var storeProgress: ((Int, Int) -> Void)?
    /// Whether a request the node refused as busy, or one that failed for a
    /// reason that may pass, is sent again, after the node's Retry-After or a
    /// short backoff (`busyRetryPolicy`). A caller that repeats requests
    /// itself, as the automatic request limit does, turns it off so that a
    /// busy answer is not repeated twice over. Test never repeats.
    @objc public var repeatsBusyRequests = true
    /// Three attempts in all. A query or retrieve is repeated on HTTP 408,
    /// 429, 502, 503 and 504 and on a connection that failed before its
    /// answer began, never on a timeout; a retrieve whose objects have
    /// started to arrive is never repeated. A STOW-RS batch is repeated only
    /// on 429 and 503, or when its connection failed before any answer. A
    /// Retry-After longer than a minute ends the attempts. Cancelling ends a
    /// wait at once.
    static let busyRetryPolicy = DicomWebRetryPolicy(maximumAttempts: 3, maximumRetryAfter: 60,
                                                     initialBackoff: 1, maximumBackoff: 30)

    static let kindKey = "HorosDICOMwebErrorKind"
    /// The Retry-After header of a busy answer (HTTP 429 or 503).
    @objc public static let retryAfterKey = "HorosDICOMwebRetryAfter"


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

    /// The pilot's node: one URL for QIDO and WADO, objects as stored.
    @objc(initWithEndpoint:credentialIdentifier:timeout:error:)
    public convenience init(endpoint: String, credentialIdentifier: String, timeout: TimeInterval) throws {
        self.init(node: try DICOMwebNodeConfiguration.node(endpoint: endpoint, credentialIdentifier: credentialIdentifier),
                  timeout: timeout)
    }

    static let explicitVRLittleEndian = "1.2.840.10008.1.2.1"
    static let implicitVRLittleEndian = "1.2.840.10008.1.2"

    /// The transfer syntaxes a WADO-RS retrieve asks for, by preference: the
    /// node's, then Explicit VR Little Endian, which every WADO-RS server
    /// sends, for a server that cannot convert to the first. "As stored" asks
    /// for the objects' own syntaxes alone.
    var retrieveTransferSyntaxes: [String] {
        let syntax = node.retrieveTransferSyntax
        if syntax.isEmpty { return ["*"] }
        return syntax == Self.explicitVRLittleEndian ? [syntax] : [syntax, Self.explicitVRLittleEndian]
    }

    /// The syntax a retrieve falls back to when the node's own cannot be
    /// served: Explicit VR Little Endian when the node names another syntax,
    /// nil when it asks for that one or for the objects as stored.
    @objc public var retrieveFallbackTransferSyntax: String? {
        let syntaxes = retrieveTransferSyntaxes
        return syntaxes.count > 1 ? syntaxes.last : nil
    }

    /// Whether an object retrieved in `syntax` is in one of the syntaxes asked
    /// for: any is, when the node asks for the objects as stored.
    @objc(acceptsRetrievedTransferSyntax:)
    public func accepts(retrievedTransferSyntax syntax: String) -> Bool {
        let asked = retrieveTransferSyntaxes
        return asked.contains("*") || asked.contains(syntax.trimmingCharacters(in: .whitespaces))
    }

    /// The Accept of a WADO-RS retrieve: `retrieveTransferSyntaxes` in order.
    /// A server that refuses it with 406 is asked again without the first, and
    /// so, once per retrieve, is one that answers 500 to a first syntax:
    /// Orthanc and dcm4chee refuse a syntax they cannot convert to with 500.
    func retrieveAccept(_ syntaxes: [String]? = nil) throws -> DicomWebAcceptList {
        do { return try DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUIDs: syntaxes ?? retrieveTransferSyntaxes) }
        catch { throw Self.failure(1, "The retrieve transfer syntax is not a valid UID.", kind: .configuration) }
    }

    /// The Accept header a WADO-RS retrieve sends first.
    @objc public var retrieveAcceptHeader: String {
        (try? retrieveAccept().headerValue) ?? DicomWebMediaTypeNegotiator.acceptHeader(for: .instance)
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
    static var timedOutError: NSError {
        failure(NSURLErrorTimedOut, "DICOMweb request timed out. Retry or check the node connection.", kind: .timeout)
    }

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

    /// The node's client certificate, read before anything is sent; nil
    /// without one.
    private func clientIdentity(cancelled: () -> Bool) throws -> DicomWebClientIdentity? {
        guard let reference = node.clientIdentityReference else { return nil }
        return try authorization(cancelled: cancelled, read: {
            DicomWebClientIdentity(identity: try DICOMwebCredentials.clientIdentity(reference: reference))
        })
    }

    private func client(base: URL, headers: [String: String], transport: DICOMwebTransport,
                        storeBodyLimit: Int = DicomWebClientConfiguration.defaultMaximumSTOWRequestBodyBytes,
                        repeats: Bool, identity: DicomWebClientIdentity? = nil) -> DicomWebClient {
        var configuration = DicomWebClientConfiguration(baseURL: base, headers: headers, timeout: timeout,
                                                        maximumSTOWRequestBodyBytes: storeBodyLimit)
        configuration.retryPolicy = repeats ? Self.busyRetryPolicy : .none
        configuration.multipartLimits = .horosRetrieve
        configuration.maximumMetadataBytes = 32 * 1024 * 1024
        configuration.followsRedirects = false
        // Presented by the transport's task delegate, to the node's origin only.
        configuration.clientIdentity = identity
        var client = DicomWebClient(configuration: configuration, transport: transport)
        // A node that signs in: each request asks for the current token, and
        // a 401 renews it once before the request is sent again.
        client.authorizationProvider = node.authorization
        return client
    }

    /// Runs `operation` and waits on this thread, returning as soon as
    /// `cancelled` says so, once the operation has cleaned up after itself.
    /// `wake` runs on this thread while it waits, at least every 0.1 s, and
    /// once more at the end. An operation that `reportsCancellation` itself
    /// returns what it made of the cancellation, if it ended in time.
    private func run<T: Sendable>(cancelled: () -> Bool, reportsCancellation: Bool = false, wake: () -> Void = {},
                                  _ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let outcome = DICOMwebOutcome<T>()
        let task = Task.detached(priority: .userInitiated) {
            let result: Result<T, Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            outcome.value.withLock { $0 = result }
            outcome.finished.signal()
        }
        defer { wake() }
        while outcome.finished.wait(timeout: .now() + 0.1) == .timedOut {
            wake()
            if cancelled() {
                task.cancel()
                // Let the request remove what it wrote before returning.
                let ended = outcome.finished.wait(timeout: .now() + 10) == .success
                if reportsCancellation, ended, case .success(let value)? = outcome.value.withLock({ $0 }) { return value }
                throw Self.cancelledError
            }
        }
        if cancelled() && !reportsCancellation { throw Self.cancelledError }
        return try outcome.value.withLock { $0 }!.get()
    }

    /// The key of what the node said about a refused request, whole: see
    /// `serverReason(code:warning:body:)`.
    @objc public static let serverReasonKey = "HorosDICOMwebServerReason"
    /// The longest part of what the node said that goes into an error's
    /// message, which the activity panel and the alerts show on few lines.
    static let messageReasonLength = 300

    /// What the node said about a refused request, on one line: its
    /// X-DICOMweb-Error-Code, its Warning and the start of its body, nil when
    /// it said nothing. DICOM-Swift has already removed from the body every
    /// credential the client sent and the value of every credential-like
    /// header line, and cut it to 4 KiB; control characters and runs of
    /// white space become one space here.
    static func serverReason(code: String?, warning: String?, body: String?) -> String? {
        func line(_ text: String?) -> String? {
            guard let text else { return nil }
            let words = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
                .split(whereSeparator: { $0.isWhitespace })
            return words.isEmpty ? nil : words.joined(separator: " ")
        }
        let parts = [line(code).map { "error code " + $0 }, line(warning).map { "Warning: " + $0 }, line(body)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// `reason` cut for a message, at a word if one ends near the limit.
    static func shortReason(_ reason: String) -> String {
        guard reason.count > messageReasonLength else { return reason }
        let cut = reason.prefix(messageReasonLength)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(word.count > messageReasonLength / 2 ? word : cut) + "…"
    }

    /// One sanitized error for anything a request threw: no URL, host or
    /// credential of the request reaches the message. An HTTP error other
    /// than a redirect ends with what the node said about it, if anything,
    /// cut short; the whole of it goes to the log and to `serverReasonKey`.
    private func classify(_ error: Error, transport: DICOMwebTransport, cancelled: () -> Bool,
                          failed what: String) -> NSError {
        if cancelled() || error is CancellationError { return Self.cancelledError }
        if let refused = error as? DICOMwebStagingSink.Refused { return Self.failure(4, refused.reason) }
        if error is DICOMwebReceiveFailure || transport.exceededReceiveLimit() {
            return Self.failure(4, "DICOMweb response exceeds the local size limit. \(what)", kind: .invalidResponse)
        }
        let nsError = error as NSError
        if nsError.domain == "HorosDICOMweb" || nsError.domain == "HorosDICOMwebCredentials" { return nsError }
        let reportedStatus: Int?
        var reason: String?
        if let web = error as? DicomWebError {
            reportedStatus = web.statusCode
            reason = Self.serverReason(code: web.code, warning: web.warning, body: web.bodyPreview)
        } else if let clientError = error as? DicomWebClientError,
                  case .httpStatus(let status, _, _, _) = clientError {
            reportedStatus = status
        } else {
            reportedStatus = nil
        }
        if let status = reportedStatus, transport.received(status: status), !(200..<300).contains(status) {
            let classified = classify(status: status, transport: transport, failed: what)
            guard let reason, !(300..<400).contains(status) else { return classified }
            NSLog("DICOMweb HTTP %ld: the node said: %@", status, reason)
            var info = classified.userInfo
            info[NSLocalizedDescriptionKey] = classified.localizedDescription + " The node said: " + Self.shortReason(reason)
            info[Self.serverReasonKey] = reason
            return NSError(domain: classified.domain, code: classified.code, userInfo: info)
        }
        return classify(transportError: nsError, failed: what)
    }

    /// The error of an HTTP status the node answered.
    private func classify(status: Int, transport: DICOMwebTransport, failed what: String) -> NSError {
        switch status {
        case 401, 403:
            return Self.failure(status, "DICOMweb authentication was rejected or expired. Update the credentials in Locations.", kind: .authentication)
        case 404:
            return Self.failure(status, "The DICOMweb node has nothing at this path (HTTP 404). Check the node's address and QIDO and WADO paths.", kind: .notFound)
        case 300..<400:
            return Self.failure(status, "The DICOMweb node answered with a redirect (HTTP \(status)), which is not followed. Check the node's address.", kind: .redirect)
        case 406:
            return Self.failure(status, "The DICOMweb node cannot send the requested transfer syntax (HTTP 406). \(what)", kind: .http)
        case 429, 503:
            // The node is busy: its Retry-After goes with the error, for the
            // automatic request limit.
            let busy = Self.failure(status, "The DICOMweb node is busy (HTTP \(status)). \(what)", kind: .http)
            guard let wait = transport.retryAfter else { return busy }
            var info = busy.userInfo
            info[Self.retryAfterKey] = wait
            return NSError(domain: busy.domain, code: busy.code, userInfo: info)
        default:
            return Self.failure(status, "DICOMweb returned HTTP \(status). \(what)", kind: .http)
        }
    }

    /// The error of a request that got no HTTP answer to classify.
    private func classify(transportError nsError: NSError, failed what: String) -> NSError {
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                return Self.cancelledError
            case NSURLErrorTimedOut:
                return Self.timedOutError
            case NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
                return Self.failure(6, "The DICOMweb node requires a client certificate it accepts. Choose the node's client certificate in Locations.", kind: .tls)
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return Self.failure(6, "The secure connection to the DICOMweb node failed. Check its HTTPS certificate.", kind: .tls)
            default:
                return Self.failure(3, "DICOMweb connection failed. Check the node address, TLS certificate and network.", kind: .network)
            }
        }
        return Self.failure(4, "Incomplete or invalid DICOMweb response. \(what)", kind: .invalidResponse)
    }

    /// The node's credential header read, a transport for one operation and
    /// DICOM-Swift's client over it.
    private func connect(base: URL, cancelled: () -> Bool, storeBodyLimit: Int? = nil, transferCeiling: TimeInterval? = nil,
                         responseOperation: DICOMwebResponseBudgets.Operation, repeats: Bool? = nil,
                         searchBodies: DICOMwebMailbox<Data>? = nil) throws -> (DicomWebClient, DICOMwebTransport) {
        let headers = try headers(cancelled: cancelled)
        let identity = try clientIdentity(cancelled: cancelled)
        if cancelled() { throw Self.cancelledError }
        let transport = DICOMwebTransport(timeout: timeout,
                                         transferCeiling: transferCeiling.map { min(max($0, 1), Self.maximumTransferCeiling) } ?? timeout,
                                         budgets: responseBudgets, operation: responseOperation,
                                         sessionIdentity: sessionIdentity, pool: sessionPool,
                                         trustedCertificateSHA256: node.trustedCertificateSHA256, searchBodies: searchBodies)
        let web = client(base: base, headers: headers, transport: transport,
                         storeBodyLimit: storeBodyLimit ?? DicomWebClientConfiguration.defaultMaximumSTOWRequestBodyBytes,
                         repeats: repeats ?? repeatsBusyRequests, identity: identity)
        return (web, transport)
    }

    private func perform<T: Sendable>(base: URL, cancelled: () -> Bool, failed what: String,
                                      transferCeiling: TimeInterval? = nil,
                                      responseOperation: DICOMwebResponseBudgets.Operation = .query,
                                      repeats: Bool? = nil, searchBodies: DICOMwebMailbox<Data>? = nil,
                                      _ operation: @escaping @Sendable (DicomWebClient) async throws -> T) throws -> T {
        let (web, transport) = try connect(base: base, cancelled: cancelled, transferCeiling: transferCeiling,
                                           responseOperation: responseOperation, repeats: repeats, searchBodies: searchBodies)
        defer { report(transport, operation: responseOperation) }
        do { return try run(cancelled: cancelled) { try await operation(web) } }
        catch { throw classify(error, transport: transport, cancelled: cancelled, failed: what) }
    }

    /// What a node's requests may share a connection by: its address, plain
    /// HTTP allowed or not, its credential reference, and the certificate it
    /// trusts and the one it presents, since a connection is authenticated
    /// once, when it is opened.
    var sessionIdentity: String {
        [node.address, node.allowInsecureHTTP ? "http" : "https-only", node.credentialIdentifier,
         node.trustedCertificateSHA256, node.clientIdentityReference?.base64EncodedString() ?? ""].joined(separator: "\n")
    }

    /// The pool this client's requests take their session from.
    var sessionPool = DICOMwebSessionPool.shared

    /// The connections of the last operation, without host or URL: requests,
    /// how many reused a connection, and the protocols negotiated. Several
    /// threads may run operations of one client at once.
    @objc public var lastConnectionReport: String { connectionReport.withLock { $0 } }
    private let connectionReport = Mutex("")

    private func report(_ transport: DICOMwebTransport, operation: DICOMwebResponseBudgets.Operation) {
        let summary = transport.connectionSummary
        guard summary.requests > 0 else { return }
        let text = "\(summary.requests) request(s), \(summary.reused) on a reused connection, protocol \(summary.protocols.joined(separator: ", "))"
        connectionReport.withLock { $0 = text }
        // Transfers are logged; queries, which page, are not.
        if operation != .query { NSLog("DICOMweb %@: %@", operation == .retrieve ? "retrieve" : "store", text) }
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
        // Test reports what the node answers now, without waiting it out.
        let page = try perform(base: node.qidoURL, cancelled: cancelled, failed: "The node did not answer the test query.",
                               repeats: false) {
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
        guard isDICOMJSON(response.headers.horosHTTPHeaderValue("Content-Type")) else {
            throw failure(4, "Invalid or oversized QIDO response.")
        }
        return try qidoRecords(json: response.body)
    }

    private static func qidoRecords(json body: Data) throws -> [[String: Any]] {
        guard let records = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
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

    /// The same search, with `warning` set when it stopped before the node's
    /// last result: the results so far are returned, and the warning says
    /// why there may be more.
    @objc(queryPath:parameters:warning:error:)
    public func query(path: String, parameters: [String: String],
                      warning: AutoreleasingUnsafeMutablePointer<NSString?>?) throws -> [[String: Any]] {
        let thread = Thread.current
        let found = try search(path: path, parameters: parameters, cancelled: { thread.isCancelled })
        warning?.pointee = found.warning as NSString?
        return found.records
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
                search.matches.append(.init(key, vr: uid ? .UI : .unknown, values: qidoValues(value)))
            }
        }
        do { _ = try search.queryItems() }
        catch { throw failure(4, "A query filter could not be sent. Remove line breaks from the filters.", kind: .configuration) }
        return search
    }

    /// A C-FIND filter separates its values with a backslash, as in "CT\MR";
    /// QIDO-RS separates them with commas (PS3.18), and a server
    /// that follows the standard would match the backslash literally. The
    /// values go to DicomWebSearchParameters as a list, for any VR, which
    /// joins them with a literal comma. A comma inside one value is
    /// percent-encoded instead, so a list joined here would reach a server
    /// such as dcm4chee as a single value. A single value is sent unchanged.
    static func qidoValues(_ value: String) -> [String] {
        guard value.contains("\\") else { return [value] }
        let values = value.split(separator: "\\", omittingEmptySubsequences: true).map(String.init)
        return values.isEmpty ? [value] : values
    }

    /// Results asked for in each QIDO-RS request.
    static let qidoPageSize = 100
    /// The most results a search returns; past them it stops and warns.
    static let qidoMaximumResults = 10_000

    func query(path: String, parameters: [String: String], cancelled: () -> Bool) throws -> [[String: Any]] {
        try search(path: path, parameters: parameters, cancelled: cancelled).records
    }

    /// Pages the search with DICOM-Swift's pager, which asks for the next
    /// page while the node fills them or says it has more, returns each
    /// result once, and stops on a page that brings nothing new, as from a
    /// node that ignores `offset`, or at `qidoMaximumResults`. The records
    /// are the node's own JSON: those of each page that the pager kept, in
    /// order.
    func search(path: String, parameters: [String: String], cancelled: () -> Bool) throws
        -> (records: [[String: Any]], warning: String?) {
        try requireBackground()
        var request = try Self.searchParameters(path: path, parameters: parameters)
        request.limit = Self.qidoPageSize
        request.offset = 0
        let search = request
        let identity: (tag: DicomTag, key: String) = switch search.level {
        case .study: (.studyInstanceUID, "0020000D")
        case .series: (.seriesInstanceUID, "0020000E")
        case .instance: (.sopInstanceUID, "00080018")
        }
        let limits = DicomWebSearchPagingLimits(maximumPages: Self.qidoMaximumResults, maximumResults: Self.qidoMaximumResults)
        let bodies = DICOMwebMailbox<Data>()
        let pages = try perform(base: node.qidoURL, cancelled: cancelled, failed: "The query returned no results.",
                                searchBodies: bodies) { client in
            var pages: [DicomWebSearchPage] = []
            for try await page in client.searchPages(parameters: search, continuesOnFullPage: true, limits: limits) {
                pages.append(page)
            }
            return pages
        }
        let documents = bodies.take()
        guard documents.count == pages.count else { throw Self.failure(4, "Invalid or oversized QIDO response.") }
        func uid(_ text: String?) -> String { text?.trimmingCharacters(in: CharacterSet(charactersIn: " \0")) ?? "" }
        var collected: [[String: Any]] = []
        var warnings = Set<String>()
        for (page, document) in zip(pages, documents) {
            // A Warning sent with the results, such as 299 for a filter the
            // node did not apply, goes to the log once per query.
            if let warning = Self.serverReason(code: nil, warning: page.warning, body: nil), warnings.insert(warning).inserted {
                NSLog("DICOMweb query: the node answered with %@", String(warning.prefix(1024)))
            }
            let records = page.statusCode == 204 ? [] : try Self.qidoRecords(json: document)
            let identities = records.map { uid((($0[identity.key] as? [String: Any])?["Value"] as? [String])?.first) }
            guard !identities.contains("") else {
                throw Self.failure(4, "The QIDO response is missing a study, series or instance UID. Check the node's QIDO path.")
            }
            var next = 0
            for dataSet in page.dataSets {
                guard let index = identities[next...].firstIndex(of: uid(dataSet.string(for: identity.tag))) else {
                    throw Self.failure(4, "Invalid or oversized QIDO response.")
                }
                collected.append(records[index])
                next = index + 1
            }
        }
        let warning: String? = switch pages.last?.stopReason {
        case .repeatedPage?:
            "The node repeated results instead of advancing to the next page, so the query stopped after \(collected.count) results. "
                + "There may be more: narrow the query or check the node's pagination support."
        case .resultLimitReached?:
            "The query has more than \(Self.qidoMaximumResults) results; only the first \(collected.count) are shown. Narrow the query."
        case .pageLimitReached?:
            "The query stopped after \(Self.qidoMaximumResults) pages with \(collected.count) results. There may be more: narrow the query."
        case nil: nil
        }
        if let warning { NSLog("DICOMweb query: %@", warning) }
        return (collected, warning)
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
        try retrieve(path: path, stagingDirectory: stagingDirectory, objectHandler: nil, cancelled: cancelled).files
    }

    /// A WADO-RS retrieve that hands each object over as soon as its part has
    /// ended, while the rest of the response is still arriving: `handler`
    /// receives the path of a complete part in `stagingDirectory` on the
    /// request's own thread, before the next part is read, and either moves
    /// the file away and returns nil, or returns why it refuses the object,
    /// which ends the retrieve. Returns how many objects were handed over.
    /// A failure after some were taken throws, with
    /// `HorosDICOMwebObjectsHandedOver` in its user info: those objects are
    /// the handler's, and the retrieve is incomplete.
    @objc(retrievePath:stagingDirectory:objectHandler:error:)
    public func retrieve(path: String, stagingDirectory: String,
                         objectHandler handler: @escaping (String) -> String?) throws -> NSNumber {
        let thread = Thread.current
        return NSNumber(value: try retrieve(path: path, stagingDirectory: stagingDirectory,
                                            objectHandler: { handler($0.path) }, cancelled: { thread.isCancelled }).handedOver)
    }

    /// The same, asking only for `retrieveFallbackTransferSyntax` when
    /// `fallbackOnly` is set and the node has one: for the objects a response
    /// in the node's own syntax did not bring, because the server cut it at
    /// an object it could not convert.
    @objc(retrievePath:stagingDirectory:fallbackOnly:objectHandler:error:)
    public func retrieve(path: String, stagingDirectory: String, fallbackOnly: Bool,
                         objectHandler handler: @escaping (String) -> String?) throws -> NSNumber {
        let thread = Thread.current
        let syntaxes = fallbackOnly ? retrieveFallbackTransferSyntax.map { [$0] } : nil
        return NSNumber(value: try retrieve(path: path, stagingDirectory: stagingDirectory, transferSyntaxes: syntaxes,
                                            objectHandler: { handler($0.path) }, cancelled: { thread.isCancelled }).handedOver)
    }

    static let objectsHandedOverKey = "HorosDICOMwebObjectsHandedOver"

    func retrieve(path: String, stagingDirectory: String, transferSyntaxes: [String]? = nil,
                  objectHandler: ((URL) -> String?)?,
                  cancelled: () -> Bool) throws -> (files: [String], handedOver: Int) {
        try requireBackground()
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let shapes = [["studies"], ["studies", "series"], ["studies", "series", "instances"]]
        guard parts.count % 2 == 0, shapes.contains(stride(from: 0, to: parts.count, by: 2).map { parts[$0] }),
              parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("?") && !$0.contains("#") })
        else { throw Self.failure(1, "Invalid DICOMweb resource path.", kind: .configuration) }
        let syntaxes = transferSyntaxes ?? retrieveTransferSyntaxes
        let accept = try retrieveAccept(syntaxes)
        // A part may come in any syntax that was asked for.
        let sink = DICOMwebStagingSink(directory: URL(fileURLWithPath: stagingDirectory),
                                       transferSyntaxes: syntaxes, objectHandler: objectHandler)
        do { try sink.begin() } catch { throw Self.failure(5, "The DICOMweb staging folder could not be created. Check the database folder.", kind: .configuration) }
        // A failure once objects were handed over says so: they stay imported,
        // and the retrieve is incomplete, never a success.
        func incomplete(_ error: NSError) -> NSError {
            let count = sink.objectsHandedOver
            guard count > 0 else { return error }
            var info = error.userInfo
            info[Self.objectsHandedOverKey] = count
            let reason = error.localizedDescription.replacingOccurrences(of: " No objects were imported.", with: "")
            info[NSLocalizedDescriptionKey] = "The WADO-RS retrieve stopped after \(count) objects, which were imported. The rest is missing: retrieve again to complete it. " + reason
            return NSError(domain: error.domain, code: error.code, userInfo: info)
        }
        do {
            let status = try perform(base: node.wadoURL, cancelled: cancelled, failed: "No objects were imported.",
                                     transferCeiling: transferCeiling, responseOperation: .retrieve) {
                switch parts.count {
                case 2: return try await $0.retrieveStudy(studyInstanceUID: parts[1], accept: accept, sink: sink)
                case 4: return try await $0.retrieveSeries(studyInstanceUID: parts[1], seriesInstanceUID: parts[3],
                                                           accept: accept, sink: sink)
                default: return try await $0.retrieveInstance(studyInstanceUID: parts[1], seriesInstanceUID: parts[3],
                                                              sopInstanceUID: parts[5], accept: accept, sink: sink)
                }
            }
            guard status == 200 else { throw Self.failure(4, "The node returned no DICOM objects.") }
            if cancelled() { throw Self.cancelledError }
            let files = try sink.finish().map { $0.path }
            // The handler took every object: nothing is left to stage.
            if objectHandler != nil { sink.discard() }
            return (files, sink.objectsHandedOver)
        } catch let error as NSError where error.domain == "HorosDICOMweb" || error.domain == "HorosDICOMwebCredentials" {
            sink.discard()
            throw incomplete(error)
        } catch {
            sink.discard()
            throw incomplete(Self.failure(4, "Incomplete or invalid WADO-RS response. No objects were imported."))
        }
    }

    // MARK: Store

    /// STOW-RS of `files` to `{address}/studies`, in requests of at most
    /// `storeBatchMaximumCount` files and `storeBatchMaximumBytes` bytes, each
    /// streamed from disk, by DICOM-Swift's `storeFiles`. Returns one result
    /// per file, in order. A request that fails marks its files failed;
    /// authentication, path, connection, TLS, timeout and cancellation
    /// failures, and a node still busy (HTTP 429 or 503) once its batch has
    /// been repeated, also stop the files after it, which are reported as not
    /// sent. An answer in DICOM JSON or XML, including a 4xx that lists the
    /// instances it refused, gives each instance's outcome. Throws only when
    /// nothing could be tried.
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

    /// Stands for a batch failure DICOM-Swift reports with neither a DICOMweb
    /// nor a URL error, so that `classify` names what the transport saw.
    private struct UnreportedFailure: Error {}

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
        guard !valid.isEmpty else { return results.map { $0! } }
        let what = "The instances were not stored."
        func notSent(_ error: NSError) {
            for file in valid where results[file.index] == nil {
                results[file.index] = DICOMwebStoreResult(path: files[file.index], sopInstanceUID: file.uid, status: .failure,
                                                          reason: "Not sent. " + error.localizedDescription)
            }
        }
        let options = DicomWebStoreBatchOptions(maximumFilesPerBatch: storeBatchMaximumCount,
                                                maximumBytesPerBatch: storeBatchMaximumBytes)
        // The body of each request is written to disk by DICOM-Swift and
        // streamed from there, so its limit is the largest batch the options
        // allow, or the largest file, plus the MIME framing.
        let largest = max(options.maximumBytesPerBatch, valid.map(\.size).max() ?? 0)
        let bodyLimit = largest.addingReportingOverflow(64 * 1024 + options.maximumFilesPerBatch * 1024)
        let (web, transport): (DicomWebClient, DICOMwebTransport)
        do {
            (web, transport) = try connect(base: node.addressURL, cancelled: cancelled,
                                           storeBodyLimit: bodyLimit.overflow ? Int.max : bodyLimit.partialValue,
                                           transferCeiling: transferCeiling, responseOperation: .store)
        } catch {
            notSent(error as NSError)
            return results.map { $0! }
        }
        defer { report(transport, operation: .store) }
        // Progress goes to `storeProgress` on this thread, after each request.
        let unsent = files.count - valid.count
        let progress = DICOMwebMailbox<Int>()
        let urls = valid.map(\.url), uids = valid.map(\.uid)
        let sent: [DicomWebStoreFileResult]
        do {
            sent = try run(cancelled: cancelled, reportsCancellation: true, wake: {
                for done in progress.take() { storeProgress?(unsent + done, files.count) }
            }) {
                await web.storeFiles(urls, sopInstanceUIDs: uids, options: options) { progress.post($0.completedFiles) }
            }
        } catch {
            notSent(classify(error, transport: transport, cancelled: cancelled, failed: what))
            return results.map { $0! }
        }
        // The failure that stopped the send, which the files not sent after it name.
        var stop: NSError?
        func failure(of result: DicomWebStoreFileResult) -> NSError {
            let error: Error = result.error ?? result.transportErrorCode.map { URLError($0) } ?? UnreportedFailure()
            return classify(error, transport: transport, cancelled: cancelled, failed: what)
        }
        for (file, result) in zip(valid, sent) {
            let path = files[file.index]
            let status = result.httpStatus ?? 0
            switch result.state {
            case .stored:
                results[file.index] = DICOMwebStoreResult(path: path, sopInstanceUID: file.uid, status: .success, reason: "", httpStatus: status)
            case .warning:
                let code = Int(result.dicomStatus ?? 0)
                results[file.index] = DICOMwebStoreResult(path: path, sopInstanceUID: file.uid, status: .warning,
                    reason: DICOMwebStoreResult.describe(reason: code, warning: true), reasonCode: code, httpStatus: status)
            case .unknown:
                // PS3.18 10.5.3: 200 means every instance was stored.
                results[file.index] = status == 200
                    ? DICOMwebStoreResult(path: path, sopInstanceUID: file.uid, status: .success, reason: "", httpStatus: status)
                    : DICOMwebStoreResult(path: path, sopInstanceUID: file.uid, status: .failure,
                                          reason: "The node did not report this instance.", httpStatus: status)
            case .failed where result.sopInstanceUID == nil:
                // DICOM-Swift refused the file itself before sending anything.
                results[file.index] = DICOMwebStoreResult(path: path, sopInstanceUID: file.uid, status: .failure,
                    reason: (result.reason ?? "The file could not be read.") + " It was not sent.")
            case .failed where result.error == nil && result.httpStatus != nil:
                // The node's answer lists this instance as refused.
                let code = Int(result.dicomStatus ?? 0)
                results[file.index] = DICOMwebStoreResult(path: path, sopInstanceUID: file.uid, status: .failure,
                    reason: code == 0 ? "The node refused this instance." : DICOMwebStoreResult.describe(reason: code, warning: false),
                    reasonCode: code, httpStatus: status)
            case .failed:
                let error = failure(of: result)
                stop = error
                results[file.index] = DICOMwebStoreResult(path: path, sopInstanceUID: file.uid, status: .failure,
                    reason: error.localizedDescription, httpStatus: (100..<600).contains(error.code) ? error.code : 0)
            case .notSent:
                let error = result.error.map { classify($0, transport: transport, cancelled: cancelled, failed: what) }
                    ?? stop ?? (cancelled() ? Self.cancelledError : failure(of: result))
                results[file.index] = DICOMwebStoreResult(path: path, sopInstanceUID: file.uid, status: .failure,
                    reason: "Not sent. " + error.localizedDescription)
            }
        }
        return results.map { $0! }
    }
}
