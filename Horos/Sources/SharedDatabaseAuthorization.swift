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
import IsiXDICOMNetwork

/// Versioned per-connection authorization for the legacy shared-database protocol.
/// This envelope authenticates a request; the existing transport is not encrypted.
/// The framing is IsiXDICOMNetwork's (SharedDatabaseEnvelope); this class keeps
/// its Objective-C names for the client.
@objc(HorosSharedDatabaseAuthorization)
public final class SharedDatabaseAuthorization: NSObject {
    @objc public static func isPublicCommand(_ command: String) -> Bool {
        SharedDatabaseEnvelope.isPublicCommand(command)
    }

    @objc public static func authenticatedRequest(_ request: Data, password: String) -> Data? {
        SharedDatabaseEnvelope.authenticatedRequest(request, password: password)
    }

    /// The request an authorization envelope carries, or the request itself when it has
    /// none or the envelope is incomplete. What a request does is decided by this inner
    /// command, not by the `AUTHR` in front of it.
    @objc public static func requestInsideEnvelope(_ request: Data) -> Data {
        SharedDatabaseEnvelope.requestInsideEnvelope(request)
    }

    /// Zero means more data is needed; -1 rejects; positive consumes the envelope.
    /// The six-byte operation header must also be present before authorization.
    @objc public static func authorizedPrefixLength(_ data: Data, password: String?, required: Bool) -> Int {
        SharedDatabaseEnvelope.authorizedPrefixLength(data, password: password, required: required)
    }
}
