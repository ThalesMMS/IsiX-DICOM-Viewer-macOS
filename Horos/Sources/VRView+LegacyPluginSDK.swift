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
import Accelerate

// Selectors of the volume view in the plugin SDK of Horos and OsiriX whose
// feature is gone: the stereoscopic display on two screens or side by side,
// the GPU mapper of VTK (the volume is rendered by Metal), and the length and
// the ROI the view computed from a 3D measure. A plugin built for that SDK may
// still send them: they answer, with nothing done.
extension VRView {
    private func inert(_ selector: String, _ reason: String = "the stereoscopic display of the 3D views is not part of the application") {
        FormerSDKFacade.inert("VRView", selector, because: reason)
    }

    @objc(LeftRightDualScreen) func legacyLeftRightDualScreen() -> Int16 { inert("-LeftRightDualScreen"); return 0 }
    @objc(LeftRightMovieScreen) func legacyLeftRightMovieScreen() -> Int16 { inert("-LeftRightMovieScreen"); return 0 }
    @objc(LeftRightSingleScreen) func legacyLeftRightSingleScreen() { inert("-LeftRightSingleScreen") }
    @objc(initStereoLeftRight) func legacyInitStereoLeftRight() { inert("-initStereoLeftRight") }
    @objc(disableStereoModeLeftRight) func legacyDisableStereoModeLeftRight() { inert("-disableStereoModeLeftRight") }
    @objc(adjustWindowContent:) func legacyAdjustWindowContent(_ proposedFrameSize: NSSize) { inert("-adjustWindowContent:") }
    @objc(setDisplayStereo3DPoints::) func legacySetDisplayStereo3DPoints(_ renderer: UnsafeMutableRawPointer?, _ on: Bool) { inert("-setDisplayStereo3DPoints::") }
    @objc(setNewGeometry:::) func legacySetNewGeometry(_ screenHeight: Double, _ screenDistance: Double, _ eyeDistance: Double) { inert("-setNewGeometry:::") }
    @objc(setNewViewAngle:) func legacySetNewViewAngle(_ viewAngle: Double) { inert("-setNewViewAngle:") }
    @objc(StereoVisionOn) func legacyStereoVisionOn() -> Bool { false }
    @objc(setStereoVisionOn:) func legacySetStereoVisionOn(_ on: Bool) { inert("-setStereoVisionOn:") }

    @objc(allocateGPUMapper) func legacyAllocateGPUMapper() {
        inert("-allocateGPUMapper", "the volume is rendered by Metal, which has no mapper of VTK to allocate")
    }
    @objc(computeLength) func legacyComputeLength() {
        inert("-computeLength", "the view no longer keeps the 3D measure this computed the length of")
    }
    @objc(generateROI) func legacyGenerateROI() {
        inert("-generateROI", "the view no longer keeps the 3D measure this made a ROI of")
    }
}

// The C arrays and the buffers the plugin SDK of Horos and OsiriX declared
// inside the view are fields of the view, where a plugin reads and writes
// them. The view's code uses each through the address of its first element,
// which is the view's own plus the field's offset and holds while the view
// lives; a pointer taken to the field for the length of a call would not.
extension VRView {
    final func arrayInside<Element>(_ offset: Int) -> UnsafeMutablePointer<Element> {
        (Unmanaged.passUnretained(self).toOpaque() + offset).assumingMemoryBound(to: Element.self)
    }

    final var horos_srcf: UnsafeMutablePointer<vImage_Buffer> { arrayInside(VRViewArrayOffsets.srcf) }
    final var horos_dst8: UnsafeMutablePointer<vImage_Buffer> { arrayInside(VRViewArrayOffsets.dst8) }
    final var horos_blendingSrcf: UnsafeMutablePointer<vImage_Buffer> { arrayInside(VRViewArrayOffsets.blendingSrcf) }
    final var horos_blendingDst8: UnsafeMutablePointer<vImage_Buffer> { arrayInside(VRViewArrayOffsets.blendingDst8) }
    final var horos_cosines: UnsafeMutablePointer<Float> { arrayInside(VRViewArrayOffsets.cosines) }
    final var horos_blendingcosines: UnsafeMutablePointer<Float> { arrayInside(VRViewArrayOffsets.blendingcosines) }
    final var horos_table: UnsafeMutablePointer<Double> { arrayInside(VRViewArrayOffsets.table) }
    final var horos_blendingtable: UnsafeMutablePointer<Double> { arrayInside(VRViewArrayOffsets.blendingtable) }
    final var horos_alpha: UnsafeMutablePointer<Double> { arrayInside(VRViewArrayOffsets.alpha) }
    final var horos_WLWWString: UnsafeMutablePointer<CChar> { arrayInside(VRViewArrayOffsets.windowText) }
    final var horos_flyToDestination: UnsafeMutablePointer<Float> { arrayInside(VRViewArrayOffsets.flyToDestination) }
    final var horos_camPosition: UnsafeMutablePointer<Double> { arrayInside(VRViewArrayOffsets.camPosition) }
    final var horos_camFocal: UnsafeMutablePointer<Double> { arrayInside(VRViewArrayOffsets.camFocal) }
    final var horos_angleMeasurementPatient: UnsafeMutablePointer<Double> { arrayInside(VRViewArrayOffsets.angleMeasurementPatient) }
    final var horos_Oval2DCos: UnsafeMutablePointer<Float> { arrayInside(VRViewArrayOffsets.ovalCosines) }
    final var horos_Oval2DPosition: UnsafeMutablePointer<Float> { arrayInside(VRViewArrayOffsets.ovalPosition) }
    final var horos_Oval2DPixZBufferOrigin: UnsafeMutablePointer<Int32> { arrayInside(VRViewArrayOffsets.ovalPixelOrigin) }

    /// The opacity points last applied.
    final var horos_currentOpacityArray: [Any]? {
        get { _currentOpacityArray.map { $0 as [AnyObject] } }
        set { _currentOpacityArray = newValue.map { $0 as NSArray } }
    }

    // The lists of the 3D points. The SDK's variables may be set to nil by a
    // plugin, where the view's code expects a list: an empty one is made.
    final var horos_point3DActorArray: NSMutableArray { VRView.listMadeIfNil(&_point3DActorArray) }
    final var horos_point3DPositionsArray: NSMutableArray { VRView.listMadeIfNil(&_point3DPositionsArray) }
    final var horos_point3DRadiusArray: NSMutableArray { VRView.listMadeIfNil(&_point3DRadiusArray) }
    final var horos_point3DColorsArray: NSMutableArray { VRView.listMadeIfNil(&_point3DColorsArray) }

    private static func listMadeIfNil(_ field: inout NSMutableArray?) -> NSMutableArray {
        if let list = field { return list }
        let list = NSMutableArray(capacity: 0)
        field = list
        return list
    }
}

/// Where the C arrays and the buffers of the former plugin SDK are inside a
/// VRView: the offsets of the fields that hold them, as the runtime has them.
enum VRViewArrayOffsets {
    static let srcf = offset("_srcf"), dst8 = offset("_dst8")
    static let blendingSrcf = offset("_blendingSrcf"), blendingDst8 = offset("_blendingDst8")
    static let cosines = offset("_cosines"), blendingcosines = offset("_blendingcosines")
    static let table = offset("_table"), blendingtable = offset("_blendingtable"), alpha = offset("_alpha")
    static let windowText = offset("_WLWWString"), flyToDestination = offset("_flyToDestination")
    static let camPosition = offset("_camPosition"), camFocal = offset("_camFocal")
    static let angleMeasurementPatient = offset("_angleMeasurementPatient")
    static let ovalCosines = offset("_Oval2DCos"), ovalPosition = offset("_Oval2DPosition")
    static let ovalPixelOrigin = offset("_Oval2DPixZBufferOrigin")

    private static func offset(_ field: String) -> Int {
        guard let variable = class_getInstanceVariable(VRView.self, field) else {
            preconditionFailure("VRView keeps no field named \(field)")
        }
        return ivar_getOffset(variable)
    }
}
