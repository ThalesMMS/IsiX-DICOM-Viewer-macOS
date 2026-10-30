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

/// The fusion with another viewer (the blending viewer, the registered viewer) and the mask subtraction (on or off, the mask, its range and offset).
final class ViewerFusionState: @unchecked Sendable {
    /// Retained when replaced, never released by the holder (as the instance variable was).
    @ManuallyRetained var blendingController: ViewerController?
    var blendedWindow: ViewerController?
    /// Retained when replaced, never released by the holder (as the instance variable was).
    @ManuallyRetained var registeredViewer: ViewerController?
    var enableSubtraction: Bool = false
    var subCtrlMaskID: Int = 0
    var subCtrlMinMax: NSPoint = .zero
    var subCtrlMinMaxComputed: Bool = false
    var subCtrlOffset: NSPoint = .zero
}

extension ViewerController {
    var horos_blending: ViewerController? {
        get { fusionState.blendingController }
        set { fusionState.blendingController = newValue }
    }
    func horos_assignBlendingController(_ value: ViewerController?) { fusionState.$blendingController.assign(value) }
    var horos_blendedWindow: ViewerController? {
        get { fusionState.blendedWindow }
        set { fusionState.blendedWindow = newValue }
    }
    var horos_registeredViewer: ViewerController? {
        get { fusionState.registeredViewer }
        set { fusionState.registeredViewer = newValue }
    }
    func horos_assignRegisteredViewer(_ value: ViewerController?) { fusionState.$registeredViewer.assign(value) }
    var horos_enableSubtraction: Bool {
        get { fusionState.enableSubtraction }
        set { fusionState.enableSubtraction = newValue }
    }
    var horos_subCtrlMaskID: Int {
        get { fusionState.subCtrlMaskID }
        set { fusionState.subCtrlMaskID = newValue }
    }
    var horos_subCtrlMinMax: NSPoint {
        get { fusionState.subCtrlMinMax }
        set { fusionState.subCtrlMinMax = newValue }
    }
    var horos_subCtrlMinMaxComputed: Bool {
        get { fusionState.subCtrlMinMaxComputed }
        set { fusionState.subCtrlMinMaxComputed = newValue }
    }
    var horos_subCtrlOffset: NSPoint {
        get { fusionState.subCtrlOffset }
        set { fusionState.subCtrlOffset = newValue }
    }
    /// _blendingType of OSIWindowController, which -blendWithViewer:blendingType: stores.
    var horos_blendingType: Int32 {
        get { blendingType() }
        set { horosSetBlendingType(newValue) }
    }
}
