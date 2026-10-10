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

/// What a DICOMweb retrieve does about one of its requests that failed.
@objc(HorosDICOMwebRecoveryAction)
public enum DICOMwebRecoveryAction: Int {
    /// Ask again, after `DICOMwebRetrieveRecovery.delay`.
    case retry
    /// Part of the answer arrived before it stopped: ask for what is still
    /// missing, rather than for all of it again.
    case resume
    /// This request will not succeed: what it asked for stays missing, and
    /// the other requests go on.
    case skip
    /// No request to this node will succeed now: the retrieve ends.
    case stop
}

/// How a DICOMweb retrieve recovers from a request that failed, so that a
/// study is not left incomplete by one lost connection, a node that paused
/// or one instance it cannot send.
///
/// A connection lost or timed out, an answer cut short or invalid, a node
/// busy or failing for a while (HTTP 408, 425, 429, 500, 502, 503, 504) and an
/// answer with only part of what was asked (HTTP 206) are transient: asked
/// again, at most `maximumAttempts` times in all, or, once something arrived,
/// resumed with what is still missing. An instance or series the node does
/// not have or refuses to send (any other HTTP status but those below) is
/// skipped. Authentication, credentials, the node's settings, TLS, a
/// redirect and a cancellation stop the retrieve: asking again cannot help.
@objc(HorosDICOMwebRetrieveRecovery)
public final class DICOMwebRetrieveRecovery: NSObject {
    /// Attempts of one request, the first included.
    @objc public static let maximumAttempts = 3

    @objc(actionForError:attempts:)
    public static func action(for error: NSError, attempts: Int) -> DICOMwebRecoveryAction {
        let kind = DICOMwebClient.errorKind(for: error)
        let transient: Bool
        switch kind {
        case .none, .configuration, .credentials, .tls, .authentication, .redirect, .cancelled:
            return .stop
        case .network, .timeout, .invalidResponse:
            transient = true
        case .notFound:
            transient = false
        case .http:
            transient = [206, 408, 425, 429, 500, 502, 503, 504].contains(error.code)
        }
        guard transient, attempts < maximumAttempts else { return .skip }
        let handedOver = error.userInfo[DICOMwebClient.objectsHandedOverKey] as? Int ?? 0
        return handedOver > 0 ? .resume : .retry
    }

    /// How long to wait before attempt `attempt` (2 or more): the node's
    /// Retry-After when it gave one in seconds, at most a minute, else 1, 2,
    /// 4... seconds.
    @objc(delayBeforeAttempt:retryAfter:)
    public static func delay(beforeAttempt attempt: Int, retryAfter: String?) -> TimeInterval {
        if let retryAfter, let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return min(seconds, 60)
        }
        return pow(2, Double(max(0, min(attempt - 2, 5))))
    }
}
