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

/// The XML-RPC server of the network: the port of the Listener settings, whose
/// calls the interface's methods answer.
///
/// It exists only while the server is turned on. The links and AppleScript
/// call the interface in this process and need no port: turning the links on
/// opens none.
///
/// The methods it reaches include KillOsiriX, Retrieve, DownloadURL and
/// dbwindowfind, and dbwindowfind returns the database: patient names and
/// identifiers included. The socket listens on every interface, as a RIS on
/// this Mac often calls the machine's own network address, and each request
/// is judged by its peer address against the settings of the pane as they are
/// when it arrives, after what a web page sends has been refused. Until the
/// pane is told otherwise, only this Mac is answered.
final class XMLRPCNetworkServer {
    private let listener: XMLRPCListener

    /// Opens the port and answers its connections through `interface`, which
    /// it does not retain; nil when the port could not be opened, which the
    /// user is told, or when HTTPS is on without a certificate.
    init?(interface: XMLRPCInterface, processGraph: ProcessGraph) {
        let preferences = processGraph.preferences
        let port = preferences[NetworkPreferences.xmlrpcServerPort]
        let https = preferences[NetworkPreferences.xmlrpcServerHTTPS]

        // HTTPS presents the web portal's identity, made the first time either
        // needs it: one self-signed certificate for the two servers of this Mac.
        if https && !XMLRPCListener.httpsIdentityAvailable() {
            // No server, rather than one serving plain HTTP.
            NSLog("--- XML-RPC server not activated on port %d: HTTPS is on and no certificate could be read or created in the keychain", Int32(truncatingIfNeeded: port))
            return nil
        }

        // Each connection runs on a thread of its own and answers through the interface.
        let made = XMLRPCListener(port: port, https: https) { [weak interface] transport in
            guard let interface else { return nil }
            let connection = XMLRPCInterfaceConnection(transport: transport)
            connection.dontSpecifyStringType = true
            connection.delegate = interface
            return connection
        }
        guard let made else {
            ApplicationNetworkNotices(processGraph: processGraph).listenBindFailed(service: "XML-RPC", port: port,
                                                                                  errno: XMLRPCListener.lastBindErrno())
            return nil
        }
        listener = made

        let policy = XMLRPCAccessPolicy.policy(from: preferences)
        let scopes = ["this Mac only", "this Mac and the local network", "this Mac and any address"]
        NSLog("--- XML-RPC server activated on port: %d (%@), answering %@%@%@", Int32(truncatingIfNeeded: port),
              (https ? "HTTPS" : "HTTP") as NSString,
              scopes[policy.scope.rawValue] as NSString,
              (policy.scope == .thisMac ? "" : (policy.requirePassword ? ", with a password" : ", WITHOUT a password")) as NSString,
              (policy.allowedAddresses.isEmpty ? "" : ", and the listed addresses without one") as NSString)
    }

    deinit {
        listener.stop()
    }
}
