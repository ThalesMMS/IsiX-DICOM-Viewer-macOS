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

/// The processing threads: the lock of the reslice processors, the locks of the flip and convolution threads and the thick slab controller.
final class ViewerProcessingState: @unchecked Sendable {
    var processorsLock: NSConditionLock?
    var convThread: NSConditionLock?
    /// Retained when replaced, never released by the holder (as the instance variable was).
    @ManuallyRetained var thickSlab: ThickSlabController?
}

extension ViewerController {
    nonisolated var horos_processorsLock: NSConditionLock? {
        get { processingState.processorsLock }
        set { processingState.processorsLock = newValue }
    }
    var horos_convThread: NSConditionLock? {
        get { processingState.convThread }
        set { processingState.convThread = newValue }
    }
    var horos_thickSlab: ThickSlabController? {
        get { processingState.thickSlab }
        set { processingState.thickSlab = newValue }
    }
}
