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

/// The geometry of the data set: the resampling ratio, the computed slice interval flag, the gantry tilt, the orientation vector and the original orientation, and the orientation tool.
final class ViewerGeometryState: @unchecked Sendable {
    var resampleRatio: Float = 0
    var computeInterval: Bool = false
    var titledGantry: Bool = false
    var titledGantryDegrees: Float = 0
    var orientationVector: Int16 = 0
    var originalOrientation: Int16 = 0
    var currentOrientationTool: Int16 = 0
}

extension ViewerController {
    var horos_resampleRatio: Float {
        get { geometryState.resampleRatio }
        set { geometryState.resampleRatio = newValue }
    }
    var horos_computeInterval: Bool {
        get { geometryState.computeInterval }
        set { geometryState.computeInterval = newValue }
    }
    var horos_titledGantry: Bool {
        get { geometryState.titledGantry }
        set { geometryState.titledGantry = newValue }
    }
    var horos_titledGantryDegrees: Float {
        get { geometryState.titledGantryDegrees }
        set { geometryState.titledGantryDegrees = newValue }
    }
    var horos_orientationVector: Int16 {
        get { geometryState.orientationVector }
        set { geometryState.orientationVector = newValue }
    }
    var horos_originalOrientation: Int16 {
        get { geometryState.originalOrientation }
        set { geometryState.originalOrientation = newValue }
    }
    var horos_currentOrientationTool: Int16 {
        get { geometryState.currentOrientationTool }
        set { geometryState.currentOrientationTool = newValue }
    }
}
