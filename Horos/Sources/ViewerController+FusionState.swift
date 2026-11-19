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
    /// The fusion of this viewer, for one call: the fusion with another
    /// viewer, the sheet of a viewer dropped on it, its slider and mode, and
    /// the re-alignment of a fused series.
    var fusion: ViewerFusion {
        ViewerFusion(viewer: self, processGraph: sessionGraph.processGraph, preferences: sessionGraph.preferences)
    }

    var horos_blending: ViewerController? {
        get { _blendingController.wrappedValue }
        set { _blendingController.wrappedValue = newValue }
    }
    func horos_assignBlendingController(_ value: ViewerController?) { _blendingController.assign(value) }
    var horos_blendedWindow: ViewerController? {
        get { _blendedWindow }
        set { _blendedWindow = newValue }
    }
    var horos_registeredViewer: ViewerController? {
        get { _registeredViewer.wrappedValue }
        set { _registeredViewer.wrappedValue = newValue }
    }
    func horos_assignRegisteredViewer(_ value: ViewerController?) { _registeredViewer.assign(value) }
    var horos_enableSubtraction: Bool {
        get { _enableSubtraction }
        set { _enableSubtraction = newValue }
    }
    var horos_subCtrlMaskID: Int {
        get { _subCtrlMaskID }
        set { _subCtrlMaskID = newValue }
    }
    var horos_subCtrlMinMax: NSPoint {
        get { _subCtrlMinMax }
        set { _subCtrlMinMax = newValue }
    }
    var horos_subCtrlMinMaxComputed: Bool {
        get { _subCtrlMinMaxComputed }
        set { _subCtrlMinMaxComputed = newValue }
    }
    var horos_subCtrlOffset: NSPoint {
        get { _subCtrlOffset }
        set { _subCtrlOffset = newValue }
    }
    /// _blendingType of OSIWindowController, which -blendWithViewer:blendingType: stores.
    var horos_blendingType: Int32 {
        get { blendingType() }
        set { horosSetBlendingType(newValue) }
    }
}
