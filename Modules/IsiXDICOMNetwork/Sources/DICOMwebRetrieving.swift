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

/// What went wrong with a DICOMweb request, in the terms the retrieve
/// decides on. The raw values are those of the client's error kinds.
public enum DICOMwebFailureKind: Int, Sendable {
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

/// A DICOMweb request that failed: what the retrieve decides on, and the
/// client's own error, which is what the retrieve reports.
public struct DICOMwebRequestFailure: Error, Sendable {
    public var kind: DICOMwebFailureKind
    /// The HTTP status for an HTTP failure; the client's code otherwise.
    public var code: Int
    /// The Retry-After of a busy answer (HTTP 429 or 503).
    public var retryAfter: String?
    /// The objects a response handed over before it failed.
    public var objectsHandedOver: Int
    public var underlying: any Error

    public init(kind: DICOMwebFailureKind, code: Int, retryAfter: String? = nil, objectsHandedOver: Int = 0, underlying: any Error) {
        self.kind = kind
        self.code = code
        self.retryAfter = retryAfter
        self.objectsHandedOver = objectsHandedOver
        self.underlying = underlying
    }

    /// A response that stopped after handing over some objects, cut by the
    /// connection or by an object it could not send: what it did not bring
    /// is worth asking for in the fallback syntax.
    public var isCutAfterObjects: Bool {
        (kind == .network || kind == .invalidResponse) && objectsHandedOver > 0
    }
}

/// The WADO-RS calls a DICOMweb retrieve makes, declared here and
/// implemented by the application over the DICOM-Swift client, so that the
/// retrieve's decisions do not reach the package.
public protocol DICOMwebRetrieving: AnyObject {
    /// The syntax asked for alone after a response in the node's own syntax
    /// was cut; nil when the node has none.
    var retrieveFallbackTransferSyntax: String? { get }

    /// Whether an object in `syntax` is one the node's Retrieve Syntax asked for.
    func accepts(retrievedTransferSyntax syntax: String) -> Bool

    /// Retrieves the study, series or instance at `path` ("studies/{study}",
    /// ".../series/{series}", ".../instances/{instance}") into
    /// `stagingDirectory`, handing each object over as soon as its part has
    /// ended: `handler` moves the file away and returns nil, or returns why
    /// it refuses the object, which ends the request. `fallbackOnly` asks
    /// for `retrieveFallbackTransferSyntax` alone. Returns how many objects
    /// were handed over.
    func retrieveObjects(path: String, stagingDirectory: String, fallbackOnly: Bool,
                         handler: @escaping (String) -> String?) throws(DICOMwebRequestFailure) -> Int

    /// A picture of a series: its thumbnail, else the rendered `instance`.
    func previewPicture(study: String, series: String, instance: String?) throws(DICOMwebRequestFailure) -> Data
}

/// How a request that failed is recovered. Failures that may pass - the
/// connection, a timeout, an answer that was not what it should be - and
/// HTTP 206, 408, 425, 429, 500, 502, 503 and 504 are transient: asked again,
/// at most `maximumAttempts` times in all, or, once something arrived,
/// resumed with what is still missing. An instance or series the node does
/// not have or refuses to send is skipped. Authentication, credentials, the
/// node's settings, TLS, a redirect and a cancellation stop the retrieve:
/// asking again cannot help.
public enum DICOMwebRecovery {
    /// The order is that of the log's words for it.
    public enum Action: Int, Sendable {
        /// Ask again, after `delay`.
        case retry
        /// Part of the answer arrived before it stopped: ask for what is
        /// still missing, rather than for all of it again.
        case resume
        /// This request will not succeed: what it asked for stays missing,
        /// and the other requests go on.
        case skip
        /// No request to this node will succeed now: the retrieve ends.
        case stop

        public var logText: String { ["asked again", "resumed with what is missing", "left missing", "retrieve stopped"][rawValue] }
    }

    /// Attempts of one request, the first included.
    public static let maximumAttempts = 3

    public static let transientStatuses: Set<Int> = [206, 408, 425, 429, 500, 502, 503, 504]

    public static func action(for failure: DICOMwebRequestFailure, attempts: Int) -> Action {
        let transient: Bool
        switch failure.kind {
        case .none, .configuration, .credentials, .tls, .authentication, .redirect, .cancelled:
            return .stop
        case .network, .timeout, .invalidResponse:
            transient = true
        case .notFound:
            transient = false
        case .http:
            transient = transientStatuses.contains(failure.code)
        }
        guard transient, attempts < maximumAttempts else { return .skip }
        return failure.objectsHandedOver > 0 ? .resume : .retry
    }

    /// How long to wait before attempt `attempt` (2 or more): the node's
    /// Retry-After when it gave one in seconds, at most a minute, else 1, 2,
    /// 4... seconds.
    public static func delay(beforeAttempt attempt: Int, retryAfter: String?) -> TimeInterval {
        if let retryAfter, let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return min(seconds, 60)
        }
        return pow(2, Double(max(0, min(attempt - 2, 5))))
    }
}
