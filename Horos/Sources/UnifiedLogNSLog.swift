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

/// NSLog for the Swift sources of this module, written where the Objective-C
/// one writes.
///
/// Foundation's Swift overlay implements `NSLog(_:_:)` on its own, and on this
/// platform it writes only to standard error. The application is launched with
/// its standard error going nowhere, so every line logged from Swift - most of
/// the application's diagnostics since the migrations - was lost, while the same
/// line from Objective-C reached the unified log. `NSLogv` is still
/// Foundation's C function, which writes to both.
///
/// Declared in this module, it is the one every Swift file here calls: a
/// declaration in the module shadows the imported one with the same signature.
func NSLog(_ format: String, _ args: CVarArg...) {
    withVaList(args) { NSLogv(format, $0) }
}
