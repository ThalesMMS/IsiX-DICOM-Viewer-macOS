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
import os

/// errno of the last listener that could not be made, for +lastBindErrno.
private let listenerBindErrno = OSAllocatedUnfairLock(initialState: Int32(0))

/// The implementation of N2ConnectionListener, declared in
/// N2ConnectionListener.h: the listener of the plugin SDK of Horos and OsiriX.
///
/// It bound an IPv4 and an IPv6 socket, or a local one, to the run loop of the
/// thread that made it, and made an N2Connection of the class given over the
/// streams of each connection accepted. That transport left the application
/// with N2Connection's streams (the application's own listeners are
/// SwiftNIO's): a listener cannot be made for a port or a path, and the
/// messages that handled a new connection do nothing. The log is told once.
@objc @implementation extension N2ConnectionListener {
    var threadPerConnection: Bool = false

    private static func noTransport(_ selector: String) {
        FormerSDKFacade.inert("N2ConnectionListener", selector,
                              because: "the sockets of the Nitrogen listeners left the application; nothing listens")
        listenerBindErrno.withLock { $0 = ENOTSUP }
    }

    /// A listener that listens on nothing.
    override init() {
        super.init()
    }

    /// nil, as for a port that could not be bound.
    @objc(initWithPort:connectionClass:)
    convenience init!(port: Int, connectionClass classs: AnyClass!) {
        self.init(port: port, loopbackOnly: false, connectionClass: classs)
    }

    @objc(initWithPort:loopbackOnly:connectionClass:)
    init!(port: Int, loopbackOnly: Bool, connectionClass classs: AnyClass!) {
        super.init()
        Self.noTransport("-initWithPort:connectionClass:")
        return nil
    }

    /// nil, as for a path that could not be bound.
    @objc(initWithPath:connectionClass:)
    init!(path: String!, connectionClass classs: AnyClass!) {
        super.init()
        Self.noTransport("-initWithPath:connectionClass:")
        return nil
    }

    /// ENOTSUP after a listener that could not be made, 0 before any.
    class func lastBindErrno() -> Int32 {
        listenerBindErrno.withLock { $0 }
    }

    /// The port of the listening socket; there is none.
    func port() -> in_port_t {
        0
    }

    /// Made the connection of an accepted socket, over its streams.
    @objc(handleNewConnectionFromAddress:inputStream:outputStream:)
    func handleNewConnection(fromAddress addr: Data!, inputStream istr: InputStream!, outputStream ostr: OutputStream!) {
        Self.noTransport("-handleNewConnectionFromAddress:inputStream:outputStream:")
    }

    /// The body of the thread a connection had when threadPerConnection was set.
    @objc(_threadHandleNewConnection:)
    func _threadHandleNewConnection(_ args: [Any]!) {
        Self.noTransport("-_threadHandleNewConnection:")
    }

    /// Dropped a connection of the listener once it had closed. The listener
    /// has none.
    @objc(connectionStatusDidChange:)
    func connectionStatusDidChange(_ notification: Notification!) {
    }
}
