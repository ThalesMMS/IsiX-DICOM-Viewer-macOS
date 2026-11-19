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

// Selectors of the surface view in the plugin SDK of Horos and OsiriX. The
// stereoscopic display on two screens or side by side is gone, and so is the
// sheet of the QuickTime VR export: those answer with nothing done. The two
// that hand the view an actor of VTK and a text for a 3D point still do it.
extension SRView {
    private func inert(_ selector: String, _ reason: String = "the stereoscopic display of the 3D views is not part of the application") {
        FormerSDKFacade.inert("SRView", selector, because: reason)
    }

    @objc(LeftRightDualScreen) func legacyLeftRightDualScreen() -> Int16 { inert("-LeftRightDualScreen"); return 0 }
    @objc(LeftRightMovieScreen) func legacyLeftRightMovieScreen() -> Int16 { inert("-LeftRightMovieScreen"); return 0 }
    @objc(LeftRightSingleScreen) func legacyLeftRightSingleScreen() { inert("-LeftRightSingleScreen") }
    @objc(initStereoLeftRight) func legacyInitStereoLeftRight() { inert("-initStereoLeftRight") }
    @objc(updateStereoLeftRight) func legacyUpdateStereoLeftRight() { inert("-updateStereoLeftRight") }
    @objc(disableStereoModeLeftRight) func legacyDisableStereoModeLeftRight() { inert("-disableStereoModeLeftRight") }
    @objc(adjustWindowContent:) func legacyAdjustWindowContent(_ proposedFrameSize: NSSize) { inert("-adjustWindowContent:") }
    @objc(setDisplayStereo3DPoints::) func legacySetDisplayStereo3DPoints(_ renderer: UnsafeMutableRawPointer?, _ on: Bool) { inert("-setDisplayStereo3DPoints::") }
    @objc(setNewGeometry:::) func legacySetNewGeometry(_ screenHeight: Double, _ screenDistance: Double, _ eyeDistance: Double) { inert("-setNewGeometry:::") }
    @objc(StereoVisionOn) func legacyStereoVisionOn() -> Bool { false }
    @objc(setStereoVisionOn:) func legacySetStereoVisionOn(_ on: Bool) { inert("-setStereoVisionOn:") }
    @objc(endQuicktimeVRSettings:) func legacyEndQuicktimeVRSettings(_ sender: Any?) {
        inert("-endQuicktimeVRSettings:", "the QuickTime VR export and its settings sheet are not part of the application")
    }

    /// The tool of the left button.
    @objc(currentTool) func legacyCurrentTool() -> ToolMode { currentTool }

    /// A vtkActor a plugin made: added to the scene, as the view did. It is
    /// not one of the view's own 3D points, which it makes itself.
    @objc(add3DPointActor:) func legacyAdd3DPointActor(_ actor: UnsafeMutableRawPointer?) {
        guard let actor else { return }
        scene.addActor(pointer: actor)
    }

    /// The text beside the 3D point `index`, as C text.
    @objc(setAnnotation:for3DPointAtIndex:) func legacySetAnnotation(_ annotation: UnsafePointer<CChar>?, for3DPointAt index: UInt32) {
        guard let annotation, Int(index) < point3DPositions.count else { return }
        setAnnotation(String(cString: annotation), for3DPointAt: Int(index))
    }
}
