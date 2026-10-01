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

/// The portal listener and accepted sockets share this subclass: AsyncSocket
/// creates accepted sockets using the listener's class. The parser remains
/// original; only the host's bounded upload read budget is selected here.
@objc(HorosPortalSocket)
class HorosPortalSocket: AsyncSocket {
    override func readData(toLength length: UInt, withTimeout timeout: TimeInterval, tag: Int) {
        guard tag == 16, length > 0, let connection = delegate() as? WebPortalConnection else {
            super.readData(toLength: length, withTimeout: timeout, tag: tag)
            return
        }
        let remaining = connection.webPortalConnectionRemainingBodyBytes()
        guard remaining > 0, UInt64(length) <= remaining else {
            super.readData(toLength: length, withTimeout: timeout, tag: tag)
            return
        }
        let budget = min(remaining, UInt64(connection.requestBodyChunkSize()))
        super.readData(toLength: UInt(budget), withTimeout: timeout, tag: tag)
    }
}
