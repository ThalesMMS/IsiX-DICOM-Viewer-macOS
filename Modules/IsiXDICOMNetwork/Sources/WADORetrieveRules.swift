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
import IsiXPreferences

/// The preferences a WADO-URI retrieve reads, through the keys of the catalog:
/// 0, 0.0 or false when a key has no value. The application gives its own; a
/// test gives `MemoryPreferences`.
public protocol WADOPreferenceReading: PreferenceStore {}

extension UserDefaults: WADOPreferenceReading {}

/// The settings of a WADO-URI retrieve: how many requests at once, how long
/// one may take, and how many times what did not arrive is asked for again.
public struct WADORetrieveSettings: Equatable, Sendable {
    /// The former global limit of requests at once, read when the node has none.
    public static let concurrentDownloadsKey = NetworkPreferences.wadoMaximumConcurrentDownloads.name
    /// Seconds a request, and a pass without progress, may take; at least `minimumTimeout`.
    public static let timeoutKey = NetworkPreferences.wadoTimeout.name
    /// Passes asked again for what did not arrive, 0 to `maximumRetryAttempts`.
    public static let retryAttemptsKey = NetworkPreferences.wadoRetryAttempts.name
    /// Whether the alert of an incomplete retrieve is logged instead of shown.
    public static let hideErrorsKey = NetworkPreferences.hidesListenerErrors.name

    public static let minimumTimeout: Float = 240
    public static let maximumRetryAttempts = 5
    /// In the automatic mode a busy node is asked again, more slowly, at least
    /// this many times: each pass waits for its Retry-After or backoff, and
    /// asks only for what did not arrive.
    public static let adaptiveRetryAttempts = 4

    /// Requests at once in a pass, at least 1.
    public let maximumConcurrentDownloads: Int32
    /// Seconds, at least `minimumTimeout`.
    public let timeout: Float

    /// `nodeLimit` is the node's own limit, 1 to 16; 0 reads the former
    /// global setting.
    public init(nodeLimit: Int, preferences: any PreferenceStore) {
        maximumConcurrentDownloads = Self.concurrentDownloads(nodeLimit: nodeLimit,
                                                              stored: preferences[NetworkPreferences.wadoMaximumConcurrentDownloads])
        timeout = Self.timeout(stored: preferences[NetworkPreferences.wadoTimeout])
    }

    public static func concurrentDownloads(nodeLimit: Int, stored: Int) -> Int32 {
        let limit = Int32(truncatingIfNeeded: nodeLimit > 0 ? nodeLimit : stored)
        return limit < 1 ? 1 : limit
    }

    public static func timeout(stored: Float) -> Float {
        stored < minimumTimeout ? minimumTimeout : stored
    }

    /// The passes after the first that ask again for what did not arrive for
    /// a transient reason; one the server refused is not asked again.
    public static func retryAttempts(stored: Int, adaptive: Bool) -> Int {
        var attempts = min(max(stored, 0), maximumRetryAttempts)
        if adaptive { attempts = max(attempts, adaptiveRetryAttempts) }
        return attempts
    }

    public static func retryAttempts(preferences: any PreferenceStore, adaptive: Bool) -> Int {
        retryAttempts(stored: preferences[NetworkPreferences.wadoRetryAttempts], adaptive: adaptive)
    }
}

/// How a WADO-URI request is sent and what its answer says.
public enum WADORequestRules {
    /// A GET of `url` that bypasses every cache, with the node's credential in
    /// its `Authorization` header, never in the URL; none when it is empty.
    public static func request(for url: URL, authorization: String?, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let authorization, !authorization.isEmpty {
            request.addValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// The session of one pass: ephemeral, so that no cookie, credential or
    /// cache outlives it, and nothing cached: the images go to the database,
    /// not to Caches/BUNDLE_IDENTIFIER/Cache.db.
    public static func sessionConfiguration(timeout: TimeInterval, ignoresLocalCache: Bool = true) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        if ignoresLocalCache { configuration.requestCachePolicy = .reloadIgnoringLocalCacheData }
        configuration.timeoutIntervalForRequest = timeout
        return configuration
    }

    /// Whether an answer's status refuses the instance. Anything that is not
    /// HTTP - a file URL in a list of URLs - has no status and counts as 200.
    public static func refuses(status: Int) -> Bool { status >= 300 }

    /// Whether the Locations test request refused the node's credential.
    public static func refusesCredential(status: Int) -> Bool { status == 401 || status == 403 }

    /// The bytes an answer announces: its Content-Length, read as
    /// -[NSString longLongValue] reads it, else the expected length of an
    /// answer that is not HTTP, else 0.
    public static func expectedLength(contentLength header: String?, isHTTP: Bool, expectedContentLength: Int64) -> Int64 {
        if let header { return (header as NSString).longLongValue }
        if !isHTTP && expectedContentLength > 0 { return expectedContentLength }
        return 0
    }

    /// Whether a body is worth writing: more than two bytes.
    public static func carriesObject(_ body: Data) -> Bool { body.count > 2 }

    /// "osirixzip" for a body that starts as a zip archive does, else "dcm".
    public static func fileExtension(ofBody body: Data) -> String {
        body.count >= 2 && body.prefix(2).elementsEqual("PK".utf8) ? "osirixzip" : "dcm"
    }

    /// Whether a body carries the DICOM magic after its preamble. A WADO
    /// endpoint behind a proxy answers 200 with a login page often enough to
    /// be worth this check; it is the magic and not a parse, because a parse
    /// of every downloaded file would cost more than it saves.
    public static func looksLikeDICOM(_ body: Data) -> Bool {
        guard body.count > 132 else { return false }
        let start = body.startIndex + 128
        return body[start..<start + 4].elementsEqual("DICM".utf8)
    }

    /// The codes URL loading uses when the server's certificate or the secure
    /// connection itself is refused.
    public static func isTrustFailure(domain: String, code: Int) -> Bool {
        guard domain == NSURLErrorDomain else { return false }
        switch code {
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired,
             NSURLErrorSecureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Why a failed request is a TLS trust failure, or nil when it is not one.
    public static func untrustedServerReason(domain: String, code: Int, description: String, host: String?) -> String? {
        guard isTrustFailure(domain: domain, code: code) else { return nil }
        return String(format: "the certificate of %@ is not trusted (%@); trust its CA in Keychain Access to retrieve from it",
                      (host ?? "the server") as NSString, description as NSString)
    }

    /// What a failed request says of the node's capacity: a timeout or a
    /// dropped connection says it is strained; a certificate refused or a
    /// cancellation says nothing.
    public static func strainsNode(domain: String, code: Int) -> Bool {
        domain == NSURLErrorDomain && !isTrustFailure(domain: domain, code: code) && code != NSURLErrorCancelled
    }

    /// The network log's reason for a failed request. Never its description,
    /// which can quote a failing URL and its credential.
    public static func failureReason(domain: String, code: Int) -> String {
        let category = isTrustFailure(domain: domain, code: code) ? "TLS" : "Transport"
        return "\(category) \(domain == NSURLErrorDomain ? "NSURLErrorDomain" : "error") \(code)"
    }
}

/// What the network log says of a WADO-URI retrieve: one entry for the whole
/// download, including retries and attempts that receive nothing. Its text
/// never contains URLs, UIDs or error bodies.
public struct WADONetworkTally: Equatable, Sendable {
    /// Distinct reasons kept; the others are counted as "other errors".
    public static let maximumReasons = 20

    public private(set) var issues: [String: Int] = [:]
    public var requests = 0
    public var retries = 0
    public var cancelled = false

    public init() {}

    public mutating func record(_ reason: String) {
        if issues[reason] != nil || issues.count < Self.maximumReasons {
            issues[reason, default: 0] += 1
        } else {
            issues["other errors", default: 0] += 1
        }
    }

    /// The request policies of `urls`: scheme and transfer syntax, at most eight.
    public static func policy(for urls: [URL]) -> String {
        var policies = Set<String>()
        for url in urls {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let syntax = items.first { $0.name == "transferSyntax" }?.value
            let safeSyntax: String
            if let syntax, syntax == "*" || (!syntax.isEmpty && syntax.count <= 64
                && syntax.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") })) {
                safeSyntax = syntax
            } else if syntax != nil {
                safeSyntax = "other"
            } else {
                safeSyntax = items.contains { $0.name == "useOrig" && $0.value == "true" } ? "useOrig" : "default"
            }
            let scheme = url.scheme.flatMap { ["http", "https", "file"].contains($0) ? $0 : nil } ?? "other"
            policies.insert("\(scheme); transferSyntax=\(safeSyntax)")
        }
        return policies.sorted().prefix(8).joined(separator: "; ")
    }

    /// The entry's message: in progress until the end, then how it ended.
    public func message(finished: Bool, complete: Bool) -> String {
        finished ? (cancelled ? "Cancelled" : complete ? "Complete" : "Incomplete") : "In Progress"
    }

    /// The entry's details once the retrieve has ended.
    public func details(received: Int, requested: Int, missing: Int, policy: String?) -> String {
        var details = ["WADO", "received=\(received)/\(requested)", "missing=\(missing)",
                       "requests=\(requests)", "retries=\(retries)"]
        if let policy { details.append(policy) }
        details += issues.keys.sorted().map { "\($0) x\(issues[$0] ?? 0)" }
        return details.joined(separator: "; ")
    }
}
