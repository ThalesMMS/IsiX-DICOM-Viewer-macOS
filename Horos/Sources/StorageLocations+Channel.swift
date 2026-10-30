//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import IsiXStorage

extension StorageLocations.Channel {
    /// The build that is running. Only the app target knows it: MACAPPSTORE is
    /// set for the App Store build, and the storage module is compiled once for
    /// both.
    static var running: Self {
        #if MACAPPSTORE
        return .appStore
        #else
        return .direct
        #endif
    }
}
