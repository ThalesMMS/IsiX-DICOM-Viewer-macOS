/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:  OsiriX
 Copyright (c) OsiriX Team
 All rights reserved.
 Distributed under GNU - LGPL
 
 See http://www.osirix-viewer.com/copyright.html for details.
   This software is distributed WITHOUT ANY WARRANTY; without even
   the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
   PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import IsiXVolumeRendering

/// The surface view's camera: the standard views, the turns of the exports,
/// the orientation letters and cube, the projection and the view's size for
/// a matrix export.
extension SRView {
    /// Turns the camera to look along `position` from the origin with `viewUp`,
    /// fits the scene (after a dolly of 1.5 with `dolly`), and moves the camera
    /// back to the distance it had.
    private func standardView(position: IsiXVTKPoint, viewUp: IsiXVTKPoint, dolly: Bool) {
        let camera = scene.camera
        let distance = Double(Float(camera.distance))

        camera.focalPoint = IsiXVTKPoint(x: 0, y: 0, z: 0)
        camera.position = position
        camera.computeViewPlaneNormal()
        camera.viewUp = viewUp
        camera.orthogonalizeViewUp()
        if dolly { camera.dolly(1.5) }
        scene.resetCamera()

        // The same zoom.
        let centre = camera.focalPoint, normal = camera.viewPlaneNormal
        camera.position = IsiXVTKPoint(x: centre.x + distance * normal.x, y: centre.y + distance * normal.y, z: centre.z + distance * normal.z)
        scene.resetCameraClippingRange()
        needsDisplay = true
    }

    @objc(axView:)
    func axView(_ sender: Any?) {
        standardView(position: IsiXVTKPoint(x: 0, y: 0, z: -1), viewUp: IsiXVTKPoint(x: 0, y: -1, z: 0), dolly: false)
    }

    @objc(saView:)
    func saView(_ sender: Any?) {
        standardView(position: IsiXVTKPoint(x: 1, y: 0, z: 0), viewUp: IsiXVTKPoint(x: 0, y: 0, z: 1), dolly: true)
    }

    @objc(saViewOpposite:)
    func saViewOpposite(_ sender: Any?) {
        standardView(position: IsiXVTKPoint(x: -1, y: 0, z: 0), viewUp: IsiXVTKPoint(x: 0, y: 0, z: 1), dolly: true)
    }

    @objc(coView:)
    func coView(_ sender: Any?) {
        standardView(position: IsiXVTKPoint(x: 0, y: -1, z: 0), viewUp: IsiXVTKPoint(x: 0, y: 0, z: 1), dolly: false)
    }

    /// Back to the camera the view opened with.
    @IBAction @objc(resetImage:)
    func resetImage(_ sender: Any?) {
        let camera = scene.camera
        camera.viewUp = IsiXVTKPoint(x: 0, y: 1, z: 0)
        camera.focalPoint = IsiXVTKPoint(x: 0, y: 0, z: 0)
        camera.position = IsiXVTKPoint(x: 0, y: 0, z: 1)
        camera.setRoll(180)
        camera.dolly(1.5)
        scene.resetCamera()
        saView(self)
        needsDisplay = true
    }

    @objc(Azimuth:)
    func azimuth(_ a: Float) {
        let camera = scene.camera
        camera.azimuth(Double(a))
        camera.orthogonalizeViewUp()
    }

    @objc(Vertical:)
    func vertical(_ a: Float) {
        let camera = scene.camera
        camera.elevation(Double(a))
        camera.orthogonalizeViewUp()
    }

    @objc(yaw:)
    func yaw(_ degrees: Float) {
        scene.camera.yaw(Double(degrees))
        scene.resetCameraClippingRange()
        needsDisplay = true
    }

    /// Moves the camera a hundredth of the way towards the display point (x, y).
    @objc(panX:Y:)
    func pan(x: Float, y: Float) {
        let camera = scene.camera
        var focus = camera.focalPoint
        let focalDepth = scene.displayPoint(ofWorld: focus).z
        let pick = scene.worldPoint(ofDisplayX: Double(x), y: Double(y), z: focalDepth)
        focus = camera.focalPoint
        let viewPoint = camera.position
        let motion = IsiXVTKPoint(x: 0.01 * (focus.x - pick.x), y: 0.01 * (focus.y - pick.y), z: 0.01 * (focus.z - pick.z))
        camera.focalPoint = IsiXVTKPoint(x: motion.x + focus.x, y: motion.y + focus.y, z: motion.z + focus.z)
        camera.position = IsiXVTKPoint(x: motion.x + viewPoint.x, y: motion.y + viewPoint.y, z: motion.z + viewPoint.z)
        if scene.lightFollowsCamera { scene.updateLightsToFollowCamera() }
    }

    // MARK: Fly-through cameras

    /// The camera as the fly-through keeps it, with a picture of the view.
    @objc func camera() -> Camera {
        let source = scene.camera
        let position = source.position, focal = source.focalPoint, up = source.viewUp
        var near = 0.0, far = 0.0
        source.getClippingRange(near: &near, far: &far)
        let camera = Camera()
        camera.position = Point3D(values: Float(position.x), Float(position.y), Float(position.z))
        camera.focalPoint = Point3D(values: Float(focal.x), Float(focal.y), Float(focal.z))
        camera.viewUp = Point3D(values: Float(up.x), Float(up.y), Float(up.z))
        camera.setClippingRangeFrom(Float(near), to: Float(far))
        camera.viewAngle = Float(source.viewAngle)
        camera.eyeAngle = Float(source.eyeAngle)
        camera.parallelScale = Float(source.parallelScale)
        camera.previewImage = nsimage(true)
        return camera
    }

    @objc(setCamera:)
    func setCamera(_ cam: Camera?) {
        guard let cam else { return }
        let camera = scene.camera
        camera.position = IsiXVTKPoint(x: Double(cam.position?.x ?? 0), y: Double(cam.position?.y ?? 0), z: Double(cam.position?.z ?? 0))
        camera.focalPoint = IsiXVTKPoint(x: Double(cam.focalPoint?.x ?? 0), y: Double(cam.focalPoint?.y ?? 0), z: Double(cam.focalPoint?.z ?? 0))
        camera.viewUp = IsiXVTKPoint(x: Double(cam.viewUp?.x ?? 0), y: Double(cam.viewUp?.y ?? 0), z: Double(cam.viewUp?.z ?? 0))
        camera.viewAngle = Double(cam.viewAngle)
        camera.eyeAngle = Double(cam.eyeAngle)
        camera.parallelScale = Double(cam.parallelScale)
        scene.resetCameraClippingRange()
    }

    // MARK: Orientation

    /// The orientation of the view: its rows and columns in patient
    /// coordinates, nine floats.
    @objc(getOrientation:)
    func getOrientation(_ o: UnsafeMutablePointer<Float>) {
        var view = [Double](repeating: 0, count: 16)
        scene.camera.getViewTransform(&view)
        let orientation = SurfaceOrientation.vectors(viewTransform: view)
        for i in 0..<9 { o[i] = orientation[i] }
    }

    /// The letters at the view's edges.
    @objc func computeOrientationText() {
        guard oText.count == 4 else { return }
        var vectors = [Float](repeating: 0, count: 9)
        getOrientation(&vectors)
        let row = (vectors[0], vectors[1], vectors[2]), column = (vectors[3], vectors[4], vectors[5])
        oText[0].setText(SRView.orientationText(row, inverted: true))
        oText[1].setText(SRView.orientationText(row, inverted: false))
        oText[2].setText(SRView.orientationText(column, inverted: false))
        oText[3].setText(SRView.orientationText(column, inverted: true))
    }

    /// The letters of the patient directions a vector points to, the strongest first.
    static func orientationText(_ vector: (Float, Float, Float), inverted: Bool) -> String {
        SurfaceOrientation.letters(vector, inverted: inverted).map { letter -> String in
            switch letter {
            case .right: return NSLocalizedString("R", comment: "R: Right")
            case .left: return NSLocalizedString("L", comment: "L: Left")
            case .anterior: return NSLocalizedString("A", comment: "A: Anterior")
            case .posterior: return NSLocalizedString("P", comment: "P: Posterior")
            case .inferior: return NSLocalizedString("I", comment: "I: Inferior")
            case .superior: return NSLocalizedString("S", comment: "S: Superior")
            }
        }.joined()
    }

    /// Shows or hides the orientation cube and letters; the cube does not
    /// come back in stereo.
    @objc(switchOrientationWidget:)
    func switchOrientationWidget(_ sender: Any?) {
        if horosOrientationCubeShown {
            horosOrientationCubeShown = false
            for text in oText { scene.removeText(text) }
        } else if !scene.stereoRender {
            horosOrientationCubeShown = true
            for text in oText { scene.addText(text) }
        }
        needsDisplay = true
    }

    /// The orientation letters go with the cube, which the scene view hides in
    /// stereo, as the stereo button did.
    override func horosStereoDidChange(_ on: Bool) {
        guard horosOrientationCubeShown else { return }
        for text in oText {
            if on { scene.removeText(text) } else { scene.addText(text) }
        }
    }

    @IBAction @objc(switchProjection:)
    func switchProjection(_ sender: Any?) {
        NSLog("switchProjection")
        projectionMode = ((sender as? NSMatrix)?.selectedCell()?.tag) ?? 0
        let camera = scene.camera
        switch projectionMode {
        case 0: camera.viewAngle = 30
        case 2: camera.viewAngle = 60
        case 1:
            camera.parallelProjection = true
            camera.viewAngle = 30
        default: break
        }
        needsDisplay = true
    }

    /// The background colour, from the colour panel when the background well is active.
    @IBAction @objc(changeColor:)
    func changeColor(_ sender: Any?) {
        guard backColor?.isActive == true, let panel = sender as? NSColorPanel,
              let color = panel.color.usingColorSpace(.genericRGB) else { return }
        scene.setBackground(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent))
        needsDisplay = true
    }

    // MARK: The view's size

    @objc(squareView:)
    func squareView(_ sender: Any?) {
        let preference = UserDefaults.standard.integer(forKey: "VRDefaultViewSize")
        NSLog("%d", Int32(truncatingIfNeeded: preference))
        guard let square = SurfaceViewFrame.square(frame, preference: preference) else { return }
        frame = square
        window?.display()
    }

    @objc func setViewSizeToMatrix3DExport() {
        savedViewSizeFrame = frame
        let content = window?.contentView?.frame.size ?? .zero
        if let exportFrame = SurfaceViewFrame.matrixExport(content: content,
                                                           preference: UserDefaults.standard.integer(forKey: "EXPORTMATRIXFOR3D")) {
            frame = exportFrame
        }
        display()
    }

    @objc func restoreViewSizeAfterMatrix3DExport() {
        frame = savedViewSizeFrame
    }
}
