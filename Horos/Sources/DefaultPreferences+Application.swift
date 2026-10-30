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

// The module builds the factory settings of the application and of a
// target without the viewer; which build this is, only the application knows. The
// Objective-C files ask HorosDefaultPreferences() (DefaultsOsiriX.h).
extension DefaultPreferences {
    /// The factory settings of this build of the application: those of the Mac
    /// App Store build when it is one.
    static func applicationDefaults() -> NSMutableDictionary {
        #if MACAPPSTORE
        defaults(forViewer: true, appStore: true)
        #else
        defaults(forViewer: true, appStore: false)
        #endif
    }
}
