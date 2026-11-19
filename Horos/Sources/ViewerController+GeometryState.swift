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
    /// The slices a change of plane made of a series read from its files,
    /// while the viewer shows them: Revert Series can then read the files
    /// again and change the plane again.
    weak var planeChangedSeries: AnyObject?
    /// Where the images stand along the normal of their slices, for the scale of the thick slab.
    let slabPositions = SlabPositions()
    /// The slab's thickness the user asked for, in millimetres, kept from a
    /// change of plane to the next so that going back gives the same slab;
    /// nil once the user picks another thickness.
    var slabRequestMillimetres: Double?
}

extension ViewerController {
    var horos_resampleRatio: Float {
        get { _resampleRatio }
        set { _resampleRatio = newValue }
    }
    var horos_computeInterval: Bool {
        get { _computeInterval }
        set { _computeInterval = newValue }
    }
    var horos_titledGantry: Bool {
        get { _titledGantry }
        set { _titledGantry = newValue }
    }
    var horos_titledGantryDegrees: Float {
        get { _titledGantryDegrees }
        set { _titledGantryDegrees = newValue }
    }
    var horos_orientationVector: Int16 {
        get { _orientationVector }
        set { _orientationVector = newValue }
    }
    var horos_originalOrientation: Int16 {
        get { _originalOrientation }
        set { _originalOrientation = newValue }
    }
    var horos_currentOrientationTool: Int16 {
        get { _currentOrientationTool }
        set { _currentOrientationTool = newValue }
    }
}
