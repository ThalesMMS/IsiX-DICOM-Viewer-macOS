//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

extension ViewerController {
    nonisolated var horos_processorsLock: NSConditionLock? {
        get { _processorsLock }
        set { _processorsLock = newValue }
    }
    var horos_thickSlab: ThickSlabController? {
        get { _thickSlab.wrappedValue }
        set { _thickSlab.wrappedValue = newValue }
    }
}
