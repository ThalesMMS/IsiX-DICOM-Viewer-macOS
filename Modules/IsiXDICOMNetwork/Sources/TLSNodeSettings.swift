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

/// The TLS settings of a node of Locations, as its entry (the extra
/// parameters of a send or a query) holds them.
public struct TLSNodeSettings: Equatable, Sendable {
    /// TLSEnabled. The other settings are read only when it is on.
    public var enabled = false
    /// TLSAuthenticated: this end shows the Keychain identity of the node.
    public var authenticated = false
    /// TLSCertificateVerification as stored (0 require, 1 verify, 2 ignore),
    /// unchecked: the caller normalises it before using it.
    public var storedCertificateVerification = 0
    /// The cipher suites of TLSCipherSuites marked Supported, in their order;
    /// empty: the DICOM TLS profile.
    public var cipherSuites: [String] = []
    /// TLSDHParameterFileURL, when TLSUseDHParameterFileURL is on.
    public var dhParameterFile: String?

    public init() {}

    public init(extraParameters: [AnyHashable: Any]?) {
        let parameters = extraParameters ?? [:]
        enabled = Self.bool(parameters["TLSEnabled"])
        guard enabled else { return }
        authenticated = Self.bool(parameters["TLSAuthenticated"])
        storedCertificateVerification = Self.int(parameters["TLSCertificateVerification"])
        for case let suite as [AnyHashable: Any] in parameters["TLSCipherSuites"] as? [Any] ?? [] where Self.bool(suite["Supported"]) {
            if let cipher = suite["Cipher"] as? String { cipherSuites.append(cipher) }
        }
        if Self.bool(parameters["TLSUseDHParameterFileURL"]) {
            dhParameterFile = parameters["TLSDHParameterFileURL"] as? String
        }
    }

    /// -boolValue of an NSNumber or an NSString; NO for anything else.
    private static func bool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? NSString { return string.boolValue }
        return false
    }

    /// -intValue of an NSNumber or an NSString; 0 for anything else.
    private static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return Int(number.int32Value) }
        if let string = value as? NSString { return Int(string.intValue) }
        return 0
    }
}
