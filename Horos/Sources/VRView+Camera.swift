/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXVolumeRendering

// The camera of VRView: the Camera objects the presets, the fly-through and
// the MPR and CPR windows read and apply; the standard views; rotations, yaw
// and pan; the projection mode and the view angle; the slice geometry
// (origin, direction cosines, resolution) the exports and the MPR read; the
// orientation letters; the window centre; the background colour; and the
// conversions between the volume's voxels and VTK's world. A Swift extension
// of the class, with the same selectors. The @try of -getOrigin:… is
// HorosObjCException, with the same log.
//
// The arithmetic keeps the Objective-C's types: a float operand of a double
// expression is widened, a float variable rounds what it is given, and a
// product added to a sum is one fused multiply-add, as clang compiled
// `a * b + c` (addingProduct): the left product when both operands are
// products, `a - b * c` as a fused `a + (-b) * c`.

private let radiansToDegrees = 57.2957795130823208767981548141

extension VRView {

    // MARK: - Camera objects

    /// The vtkRenderer * of the view, or NULL.
    @objc(vtkRenderer)
    func vtkRenderer() -> UnsafeMutableRawPointer? {
        let vtk = horos_vtk
        return vtk.hasRenderer ? vtk.rendererHandle : nil
    }

    /// The vtkCamera * of the view.
    @objc(vtkCamera)
    func vtkCamera() -> UnsafeMutableRawPointer? {
        return horos_vtk.cameraHandle
    }

    /// Another view's vtkCamera *, copied into the view's.
    @objc(setVtkCamera:)
    dynamic func setVtkCamera(_ aVtkCamera: UnsafeMutableRawPointer!) {
        guard horos_vtk.copyCamera(fromHandle: aVtkCamera) else { return }

        NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
        needsDisplay = true
    }

    @objc(cameraWithThumbnail:)
    func camera(withThumbnail produceThumbnail: Bool) -> Camera! {
        let vtk = horos_vtk
        // data extraction from the vtkCamera
        var pos = [Double](repeating: 0, count: 3), focal = [Double](repeating: 0, count: 3)
        var vUp = [Double](repeating: 0, count: 3), pWC = [Double](repeating: 0, count: 2)

        vtk.getCameraWindowCenter(&pWC)
        vtk.getCameraPosition(&pos)
        vtk.getCameraFocalPoint(&focal)
        vtk.cameraOrthogonalizeViewUp()
        vtk.getCameraViewUp(&vUp)
        var clippingRange = [Double](repeating: 0, count: 2)
        vtk.getCameraClippingRange(&clippingRange)
        let viewAngle = vtk.cameraViewAngle
        let eyeAngle = vtk.cameraEyeAngle
        let rollAngle = vtk.cameraRoll
        let parallelScale = vtk.cameraParallelScale

        // creation of the Camera
        let cam = Camera()
        let pt = Point3D(values: Float(pos[0]), Float(pos[1]), Float(pos[2]))

        cam.windowCenterX = Float(pWC[0])
        cam.windowCenterY = Float(pWC[1])

        if vtk.hasVolumeMapper {
            cam.lod = vtk.volumeMinimumImageSampleDistance
        }

        cam.position = pt
        cam.focalPoint = Point3D(values: Float(focal[0]), Float(focal[1]), Float(focal[2]))
        cam.viewUp = Point3D(values: Float(vUp[0]), Float(vUp[1]), Float(vUp[2]))
        cam.setClippingRangeFrom(Float(clippingRange[0]), to: Float(clippingRange[1]))
        cam.viewAngle = Float(viewAngle)
        cam.eyeAngle = Float(eyeAngle)
        cam.rollAngle = Float(rollAngle)
        cam.parallelScale = Float(parallelScale)

        // window level
        cam.setWLWW(horos_wl, horos_ww)

        // setCamera: applies imported/flythrough planes to the mapper while
        // hiding the editing widget. The rendered crop is captured, not that stale box.
        var cropOrigins = [Double](repeating: 0, count: 18), cropNormals = [Double](repeating: 0, count: 18)
        let planeCount = Int(vtk.getCameraCropOrigins(&cropOrigins, normals: &cropNormals))
        if planeCount >= 0 {
            if planeCount != 6 {
                NSLog("****** camera crop plane count != 6")
            }

            var i = 0
            while i < planeCount && i < 6 {
                let p = N3VectorMake(CGFloat(cropOrigins[3 * i]), CGFloat(cropOrigins[3 * i + 1]), CGFloat(cropOrigins[3 * i + 2]))
                let n = N3VectorMake(CGFloat(cropNormals[3 * i]), CGFloat(cropNormals[3 * i + 1]), CGFloat(cropNormals[3 * i + 2]))
                let plane = N3PlaneMake(p, n)
                cam.croppingPlanes.replaceObject(at: i, with: NSValue(n3Plane: plane)!)
                i += 1
            }
        }

        // fusion percentage
        cam.fusionPercentage = horos_blendingFactor

        // 4D
        cam.movieIndexIn4D = Int(horos_controller?.curMovieIndex() ?? 0)

        // thumbnail
        if produceThumbnail {
            cam.previewImage = nsimage(true)
        }

        return cam
    }

    @objc(camera)
    func camera() -> Camera! {
        return camera(withThumbnail: true)
    }

    @objc(setCenterlineCamera:)
    func setCenterlineCamera(_ cam: Camera!) {
        let vtk = horos_vtk
        let pos = [Double(cam.position.x), Double(cam.position.y), Double(cam.position.z)]
        let focal = [Double(cam.focalPoint.x), Double(cam.focalPoint.y), Double(cam.focalPoint.z)]

        vtk.cameraDolly(1.0)
        vtk.setCameraPosition(pos)
        vtk.setCameraFocalPoint(focal)
        vtk.cameraComputeViewPlaneNormal()
        vtk.cameraOrthogonalizeViewUp()

        if clipRangeActivated {
            vtk.setCameraClippingRangeNear(0.0, far: clippingRangeThickness)
        } else {
            vtk.resetCameraClippingRange()
        }

        NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
    }

    @objc(setCamera:)
    func setCamera(_ cam: Camera!) {
        guard let cam else { return }
        let vtk = horos_vtk

        let pWC = [Double(cam.windowCenterX), Double(cam.windowCenterY)]
        let pos = [Double(cam.position.x), Double(cam.position.y), Double(cam.position.z)]
        let focal = [Double(cam.focalPoint.x), Double(cam.focalPoint.y), Double(cam.focalPoint.z)]
        let vUp = [Double(cam.viewUp.x), Double(cam.viewUp.y), Double(cam.viewUp.z)]
        let viewAngle = Double(cam.viewAngle)
        let eyeAngle = Double(cam.eyeAngle)
        let parallelScale = Double(cam.parallelScale)

        // window level: apply the transfer before capture. Skip only the 0,0
        // sentinel; a spline overshoot of ww <= 1 used to leave a stale table.
        if !horos_advancedCLUT {
            var resolvedLevel = Double(cam.wl)
            var resolvedWidth = Double(cam.ww)
            if FlyThruWindow.resolve(level: &resolvedLevel, width: &resolvedWidth) {
                setWLWW(Float(resolvedLevel), Float(resolvedWidth))
            }
        }

        // cropping box
        var cropOrigins = [Double](repeating: 0, count: 18), cropNormals = [Double](repeating: 0, count: 18)

        // Set the normals and coordinate values
        for i in 0..<6 {
            let plane = (cam.croppingPlanes.object(at: i) as! NSValue).n3PlaneValue()
            cropOrigins[3 * i] = Double(plane.point.x); cropOrigins[3 * i + 1] = Double(plane.point.y)
            cropOrigins[3 * i + 2] = Double(plane.point.z)
            cropNormals[3 * i] = Double(plane.normal.x); cropNormals[3 * i + 1] = Double(plane.normal.y)
            cropNormals[3 * i + 2] = Double(plane.normal.z)
        }

        vtk.setCropPlanesOrigins(cropOrigins, normals: cropNormals)

        vtk.hideCropBox()

        // fusion percentage
        setBlendingFactor(cam.fusionPercentage)

        // 4D
        if let controller = horos_controller, controller.is4D() {
            if cam.movieIndexIn4D != Int(controller.curMovieIndex()) {
                controller.setMovieFrame(cam.movieIndexIn4D)
            }
        }
        // vtkCamera
        vtk.setCameraWindowCenterX(pWC[0], y: pWC[1])

        vtk.setCameraPosition(pos)
        vtk.setCameraFocalPoint(focal)

        // Compute view plane from position and focalPoint
        vtk.cameraComputeViewPlaneNormal()
        vtk.setCameraViewUp(vUp)
        vtk.cameraViewAngle = viewAngle
        vtk.cameraEyeAngle = eyeAngle
        vtk.cameraParallelScale = parallelScale

        vtk.updateLightsToFollowCamera()

        if clipRangeActivated {
            vtk.cameraDistance = 40.0
            vtk.setCameraClippingRangeNear(0.0, far: clippingRangeThickness)
        } else {
            vtk.resetCameraClippingRange()
        }

        NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
        NotificationCenter.default.post(name: Notification.Name(ViewAngleControl.didChangeNotification), object: self)
    }

    @objc(setLowResolutionCamera:)
    func setLowResolutionCamera(_ cam: Camera!) {
        let vtk = horos_vtk
        vtk.setVolumeMinimumImageSampleDistance(horos_LOD * lowResLODFactor)
        vtk.setBlendingMinimumImageSampleDistance(horos_LOD * lowResLODFactor)

        setCamera(cam)

        window?.display()

        vtk.setVolumeMinimumImageSampleDistance(horos_LOD)
        vtk.setBlendingMinimumImageSampleDistance(horos_LOD)
    }

    // MARK: - Standard views

    /// Looks at the volume from `position` with `viewUp`, the camera's
    /// distance and parallel scale kept (as floats, as the Objective-C kept
    /// them), dollied by `dolly` first when there is one.
    private func standardView(position: [Double], viewUp: [Double], dolly: Double?) {
        let vtk = horos_vtk
        let distance = Float(vtk.cameraDistance)
        let pp = Float(vtk.cameraParallelScale)

        vtk.setCameraFocalPoint([0, 0, 0])
        vtk.setCameraPosition(position)
        vtk.cameraComputeViewPlaneNormal()
        vtk.setCameraViewUp(viewUp)
        vtk.cameraOrthogonalizeViewUp()
        if let dolly { vtk.cameraDolly(dolly) }
        horosResetCameraFitting(false)

        // Apply the same zoom
        var vn = [Double](repeating: 0, count: 3), center = [Double](repeating: 0, count: 3)
        vtk.getCameraFocalPoint(&center)
        vtk.getCameraViewPlaneNormal(&vn)
        let d = Double(distance)
        vtk.setCameraPosition([center[0].addingProduct(d, vn[0]), center[1].addingProduct(d, vn[1]),
                               center[2].addingProduct(d, vn[2])])
        checkInVolume()
        vtk.cameraParallelScale = Double(pp)

        if clipRangeActivated {
            vtk.setCameraClippingRangeNear(0.0, far: clippingRangeThickness)
        } else {
            vtk.resetCameraClippingRange()
        }

        vtk.setCropBoxHandleSize(0.005)

        needsDisplay = true
    }

    @objc(axView:)
    func axView(_ sender: Any?) {
        standardView(position: [0, 0, -1], viewUp: [0, -1, 0], dolly: nil)
    }

    @objc(saView:)
    func saView(_ sender: Any?) {
        standardView(position: [1, 0, 0], viewUp: [0, 0, 1], dolly: 1.5)
    }

    @objc(saViewOpposite:)
    func saViewOpposite(_ sender: Any?) {
        standardView(position: [-1, 0, 0], viewUp: [0, 0, 1], dolly: 1.5)
    }

    @objc(coView:)
    func coView(_ sender: Any?) {
        standardView(position: [0, -1, 0], viewUp: [0, 0, 1], dolly: nil)
    }

    // MARK: - Rotation, yaw and pan

    @objc(rotation)
    func rotation() -> Float { horos_rotationValue }

    @objc(numberOfFrames)
    func numberOfFrames() -> Float { Float(horos_numberOfFrames) }

    @objc(Azimuth:)
    func azimuth(_ a: Float) {
        VRInteractionBenchmark.beginSample("rotate")
        horos_vtk.cameraAzimuth(Double(a))
        horos_vtk.cameraOrthogonalizeViewUp()
        VRInteractionBenchmark.endSample()
    }

    @objc(Vertical:)
    func vertical(_ a: Float) {
        horos_vtk.cameraElevation(Double(a))
        horos_vtk.cameraOrthogonalizeViewUp()
    }

    @objc(yaw:)
    func yaw(_ degrees: Float) {
        let vtk = horos_vtk
        vtk.cameraYaw(Double(degrees))

        if clipRangeActivated {
            vtk.setCameraClippingRangeNear(0.0, far: clippingRangeThickness)
        } else {
            vtk.resetCameraClippingRange()
        }

        needsDisplay = true
    }

    @objc(panX:Y:)
    func panX(_ x: Double, y: Double) {
        let vtk = horos_vtk
        var viewFocus = [Double](repeating: 0, count: 4)
        var newPickPoint = [Double](repeating: 0, count: 4)

        // Calculate the focal depth
        vtk.getCameraFocalPoint(&viewFocus)
        let focus = viewFocus
        vtk.interactorWorld(toDisplayX: focus[0], y: focus[1], z: focus[2], display: &viewFocus)
        let focalDepth = viewFocus[2]

        vtk.interactorDisplay(toWorldX: x, y: y, z: focalDepth, world: &newPickPoint)

        // Get the current focal point and position
        vtk.getCameraFocalPoint(&viewFocus)

        var viewPoint = [Double](repeating: 0, count: 3)
        vtk.getCameraPosition(&viewPoint)

        // Compute a translation vector, moving everything
        // the distance to the cursor. (Arbitrary scale factor)
        let motionVector = (0..<3).map { 0.0001 * (viewFocus[$0] - newPickPoint[$0]) }

        vtk.setCameraFocalPoint([motionVector[0] + viewFocus[0], motionVector[1] + viewFocus[1], motionVector[2] + viewFocus[2]])
        vtk.setCameraPosition([motionVector[0] + viewPoint[0], motionVector[1] + viewPoint[1], motionVector[2] + viewPoint[2]])

        vtk.updateLightsAfterPan()
    }

    // MARK: - Projection and view angle

    /// The projection: 0 perspective, 1 parallel, 2 endoscopy. Setting it
    /// sets the camera's projection and starting angle, resets the view when
    /// needed and enables the length tool only in parallel. The getter reads
    /// the ivar (the former synthesized property), the setter is the former
    /// -setProjectionMode:.
    @objc dynamic var projectionMode: Int32 {
        get { horos_projectionMode }
        set { applyProjectionMode(newValue) }
    }

    private func applyProjectionMode(_ mode: Int32) {
        let vtk = horos_vtk
        horos_projectionMode = mode
        horos_chosenViewAngle = 0

        if !vtk.hasCamera { return }

        let wasMode = mode

        switch mode {
        case 0:
            vtk.cameraParallelProjection = false
            vtk.cameraViewAngle = 30
        case 2:
            vtk.cameraParallelProjection = false
            vtk.cameraViewAngle = 60
        case 1:
            vtk.cameraParallelProjection = true
            vtk.cameraViewAngle = 30
        default:
            break
        }

        if !clipRangeActivated && (mode == 0 || mode == 1) && (wasMode == 0 || wasMode == 1) {
        } else {
            resetImage(self)
        }

        let measurementHelp = vtk.cameraParallelProjection
            ? NSLocalizedString("Measure projected length in the parallel view.", comment: "")
            : NSLocalizedString("Length measurements require parallel projection. Select Parallel in the Perspective controls.", comment: "")
        let measurementTools = horos_controller?.toolsMatrix()
        let measurementCell = measurementTools?.cell(withTag: Int(ToolMode.tMesure.rawValue))
        if let measurementTools, let measurementCell {
            measurementTools.setToolTip(measurementHelp, for: measurementCell)
        }
        measurementCell?.setAccessibilityHelp(measurementHelp)

        if vtk.cameraParallelProjection {
            measurementCell?.isEnabled = true
        } else {
            horos_controller?.toolsMatrix()?.cell(withTag: Int(ToolMode.tMesure.rawValue))?.isEnabled = false

            if currentTool() == .tMesure {
                setCurrentTool(.t3DRotate)
                horos_controller?.toolsMatrix()?.selectCell(withTag: Int(ToolMode.t3DRotate.rawValue))
            }
        }

        NotificationCenter.default.post(name: Notification.Name(ViewAngleControl.didChangeNotification), object: self)
        needsDisplay = true
    }

    // Each projection mode starts at its own angle (30 degrees in perspective, 60 in
    // endoscopy); in perspective the angle can then be set, in parallel there is none.
    @objc var viewAngleAdjustable: Bool {
        return horos_vtk.hasCamera && horos_projectionMode != 1
    }

    /// The camera's field of view, in degrees, in a perspective projection mode.
    @objc dynamic var viewAngle: Double {
        get { horos_vtk.hasCamera ? horos_vtk.cameraViewAngle : 30 }
        set { applyViewAngle(newValue) }
    }

    private func applyViewAngle(_ angle: Double) {
        let vtk = horos_vtk
        if !viewAngleAdjustable || !angle.isFinite { return }
        let angle = min(max(angle, ViewAngleControl.minimumAngle), ViewAngleControl.maximumAngle)
        horos_chosenViewAngle = angle
        if angle == vtk.cameraViewAngle { return }

        vtk.cameraViewAngle = angle
        if !clipRangeActivated && vtk.hasRenderer {
            vtk.resetCameraClippingRange()
        }

        NotificationCenter.default.post(name: Notification.Name(ViewAngleControl.didChangeNotification), object: self)
        needsDisplay = true
    }

    // MARK: - Slice geometry

    @objc(getOrigin:)
    func getOrigin(_ origin: UnsafeMutablePointer<Float>!) {
        getOrigin(origin, windowCentered: false)
    }

    @objc(getOrigin:windowCentered:)
    func getOrigin(_ origin: UnsafeMutablePointer<Float>!, windowCentered wc: Bool) {
        getOrigin(origin, windowCentered: wc, sliceMiddle: true)
    }

    @objc(getOrigin:windowCentered:sliceMiddle:)
    func getOrigin(_ origin: UnsafeMutablePointer<Float>!, windowCentered wc: Bool, sliceMiddle: Bool) {
        getOrigin(origin, windowCentered: wc, sliceMiddle: sliceMiddle, blendedView: false)
    }

    /// The upper left corner of the view's picture in the patient's
    /// millimetres, on the slab's middle plane when `sliceMiddle`, the window
    /// centre taken out when `wc`.
    @objc(getOrigin:windowCentered:sliceMiddle:blendedView:)
    func getOrigin(_ origin: UnsafeMutablePointer<Float>!, windowCentered wc: Bool, sliceMiddle: Bool, blendedView: Bool) {
        let vtk = horos_vtk
        if !vtk.hasVolumeMapper {
            NSLog("****** vrView getOrigin volumeMapper == nil")
            return
        }

        let exception = HorosObjCException.caught {
            let factor = Double(self.horos_factor)
            var cameraPosition = [Double](repeating: 0, count: 3)
            vtk.getCameraPosition(&cameraPosition)

            cameraPosition[0] /= factor
            cameraPosition[1] /= factor
            cameraPosition[2] /= factor

            let rayCastImage = vtk.rayCastImageInfoFused(blendedView)

            // Position of upper left part of the image
            var viewport = [Double](repeating: 0, count: 4)
            vtk.getViewport(&viewport)
            var renWinWidth: Int32 = 0, renWinHeight: Int32 = 0
            vtk.getWindowWidth(&renWinWidth, height: &renWinHeight)

            let sampleDistance = rayCastImage.sampleDistance

            // turn ImageOrigin into (x1,y1) in window (not viewport!) coordinates.
            let imageOrigin = rayCastImage.origin
            let x1 = CConversion.int((Double(imageOrigin.0) * sampleDistance).addingProduct(viewport[0], Double(renWinWidth)))
            let y1 = CConversion.int((Double(imageOrigin.1) * sampleDistance).addingProduct(viewport[1], Double(renWinHeight)))

            // cameraPosition is in the center of the screen
            var x = Double(x1) - Double(renWinWidth) / 2.0
            var y = Double(y1) - Double(renWinHeight) / 2.0

            if wc {
                let wC = self.windowCenter()
                x -= Double(wC.x)
                y -= Double(wC.y)
            }

            var cos = [Float](repeating: 0, count: 9)
            _ = self.getCosMatrix(&cos)

            let r = self.getResolution()

            // Upper Left corner
            for i in 0..<3 {
                origin[i] = Float(cameraPosition[i].addingProduct(y * Double(cos[3 + i]), r).addingProduct(x * Double(cos[i]), r))
            }

            // Take into account the sliceThickness -> Origin is in the middle of the slice thickness
            if sliceMiddle {
                var thickness = self.clippingRangeThickness / factor
                thickness /= 2.0

                for i in 0..<3 {
                    origin[i] = Float(Double(origin[i]).addingProduct(thickness, Double(cos[6 + i])))
                }
            }
        }
        if let exception {
            NSLog("***** exception in %@: %@", "-[VRView getOrigin:windowCentered:sliceMiddle:blendedView:]", exception)
        }
    }

    /// The direction cosines of the view's picture: its rows, its columns and
    /// the direction of projection. NO without a camera or with a degenerate one.
    @objc(getCosMatrix:)
    @discardableResult
    func getCosMatrix(_ cos: UnsafeMutablePointer<Float>!) -> Bool {
        let vtk = horos_vtk
        if !vtk.hasCamera {
            for i in 0..<9 { cos[i] = 0 }
            return false
        }

        var viewUp = [Double](repeating: 0, count: 3)
        vtk.getCameraViewUp(&viewUp)

        cos[3] = Float(viewUp[0] * -1.0)
        cos[4] = Float(viewUp[1] * -1.0)
        cos[5] = Float(viewUp[2] * -1.0)

        /// sqrt(a*a + b*b + c*c) of floats, as compiled: in float, fused, then widened.
        func length(_ a: Int) -> Double {
            Double((cos[a + 1] * cos[a + 1]).addingProduct(cos[a], cos[a]).addingProduct(cos[a + 2], cos[a + 2])).squareRoot()
        }

        var l = length(3)
        if l != 0 {
            cos[3] = Float(Double(cos[3]) / l)
            cos[4] = Float(Double(cos[4]) / l)
            cos[5] = Float(Double(cos[5]) / l)
        } else {
            return false
        }

        var cos6 = [Double](repeating: 0, count: 3)
        vtk.getCameraDirection(ofProjection: &cos6)

        cos[6] = Float(cos6[0])
        cos[7] = Float(cos6[1])
        cos[8] = Float(cos6[2])

        l = length(6)
        if l != 0 {
            cos[6] = Float(Double(cos[6]) / l)
            cos[7] = Float(Double(cos[7]) / l)
            cos[8] = Float(Double(cos[8]) / l)
        }

        cos[0] = (-(cos[8] * cos[4])).addingProduct(cos[7], cos[5])
        cos[1] = (-(cos[6] * cos[5])).addingProduct(cos[8], cos[3])
        cos[2] = (-(cos[7] * cos[3])).addingProduct(cos[6], cos[4])

        cos[0] = Float(Double(cos[0]) * -1.0)
        cos[1] = Float(Double(cos[1]) * -1.0)
        cos[2] = Float(Double(cos[2]) * -1.0)

        l = length(0)
        if l != 0 {
            cos[0] = Float(Double(cos[0]) / l)
            cos[1] = Float(Double(cos[1]) / l)
            cos[2] = Float(Double(cos[2]) / l)
        } else {
            return false
        }

        return true
    }

    /// Millimetres per pixel of the view in a parallel projection, 0 otherwise.
    @objc(getResolution)
    func getResolution() -> Double {
        let vtk = horos_vtk
        let factor = horos_factor
        guard vtk.hasCamera && vtk.cameraParallelProjection && factor > 0 else { return 0 }

        var point1: [Double] = [0, 0, 0, 0], point2: [Double] = [1, 0, 0, 0]
        let p1 = point1, p2 = point2

        vtk.worldPoint(ofDisplayX: p1[0], y: p1[1], z: p1[2], into: &point1)
        vtk.worldPoint(ofDisplayX: p2[0], y: p2[1], z: p2[2], into: &point2)

        let xd = point2[0] - point1[0]
        let yd = point2[1] - point1[1]
        let zd = point2[2] - point1[2]
        let length = (yd * yd).addingProduct(xd, xd).addingProduct(zd, zd).squareRoot()

        let viewportDiagnosis = CurvedMPRPathSession.diagnoseViewportWorldLength(length)
        if viewportDiagnosis != "ready" {
            // A length of zero is the renderer answering before it has a
            // viewport: display-to-world maps both points onto the same place.
            // The Swift diagnosis names that "no viewport yet"; do not hide it.
            NSLog("****** vrView getResolution: %@ (%f)", viewportDiagnosis, length)
        }

        return length / Double(factor)
    }

    // MARK: - Orientation

    /// The camera's view transform's rotation, rows, the second negated.
    @objc(getOrientation:)
    func getOrientation(_ o: UnsafeMutablePointer<Float>!) {
        let vtk = horos_vtk
        if !vtk.hasCamera { return }

        var matrix = [Double](repeating: 0, count: 16)
        vtk.getCameraViewTransform(&matrix)

        for i in 0..<3 {
            for j in 0..<3 {
                o[3 * i + j] = Float(matrix[4 * i + j])
            }
        }

        o[3] = -o[3]
        o[4] = -o[4]
        o[5] = -o[5]
    }

    /// The orientation letters at the view's four sides and the angles in its corner.
    @objc(computeOrientationText)
    func computeOrientationText() {
        let vtk = horos_vtk
        var cos = [Float](repeating: 0, count: 9)
        var vectors = [Float](repeating: 0, count: 9)

        _ = getCosMatrix(&cos)
        getOrientation(&vectors)

        var theta = Float(acos(Double(cos[8])))
        var psi = Float(-atan2(Double(cos[6]), Double(cos[7])))
        var phi = Float(atan2(Double(cos[2]), Double(cos[5])))

        phi = Float(Double(phi) * radiansToDegrees)
        theta = Float(Double(theta) * radiansToDegrees)
        psi = Float(Double(psi) * radiansToDegrees)

        if phi < 0 {
            phi += 180
        } else {
            phi -= 180
        }

        let angles = String(format: "S-I: %2.1f\nL-R: %2.1f\nRoll: %2.1f", Double(theta) - 90.0, Double(psi), Double(phi))
        vtk.setOrientationText(angles, at: 4)

        vtk.setOrientationText(orientationText(Array(vectors[0..<3]), inversion: true), at: 0)
        vtk.setOrientationText(orientationText(Array(vectors[0..<3]), inversion: false), at: 1)
        vtk.setOrientationText(orientationText(Array(vectors[3..<6]), inversion: false), at: 2)
        vtk.setOrientationText(orientationText(Array(vectors[3..<6]), inversion: true), at: 3)
    }

    /// The letters of up to three axes of `vector`, the largest first, and a space.
    private func orientationText(_ vector: [Float], inversion inv: Bool) -> String {
        let sign: Float = inv ? -1 : 1
        let orientationX = sign * vector[0] < 0 ? NSLocalizedString("R", comment: "R: Right") : NSLocalizedString("L", comment: "L: Left")
        let orientationY = sign * vector[1] < 0 ? NSLocalizedString("A", comment: "A: Anterior") : NSLocalizedString("P", comment: "P: Posterior")
        let orientationZ = sign * vector[2] < 0 ? NSLocalizedString("I", comment: "I: Inferior") : NSLocalizedString("S", comment: "S: Superior")

        var optr = ""
        var absX = abs(vector[0]), absY = abs(vector[1]), absZ = abs(vector[2])

        // get first 3 AXIS
        for _ in 0..<3 {
            if Double(absX) > 0.2 && absX >= absY && absX >= absZ {
                optr += orientationX; absX = 0
            } else if Double(absY) > 0.2 && absY >= absX && absY >= absZ {
                optr += orientationY; absY = 0
            } else if Double(absZ) > 0.2 && absZ >= absX && absZ >= absY {
                optr += orientationZ; absZ = 0
            } else {
                break
            }
        }

        return optr + " "
    }

    @objc(getOrientationText:vector:inversion:)
    func getOrientationText(_ o: UnsafeMutablePointer<CChar>!, vector: UnsafeMutablePointer<Float>!, inversion inv: Bool) {
        let text = orientationText([vector[0], vector[1], vector[2]], inversion: inv)
        _ = text.withCString { strcpy(o, $0) }
    }

    // MARK: - Window centre

    @objc(windowCenter)
    func windowCenter() -> NSPoint {
        var pWC = [Double](repeating: 0, count: 2)
        horos_vtk.getCameraWindowCenter(&pWC)
        let display = VTKRetinaGeometry.displaySize(of: self)
        pWC[0] *= Double(display.width) / 2.0
        pWC[1] *= Double(display.height) / 2.0

        return NSMakePoint(CGFloat(-pWC[0]), CGFloat(pWC[1]))
    }

    @objc(setWindowCenter:)
    func setWindowCenter(_ loc: NSPoint) {
        let vtk = horos_vtk
        let display = VTKRetinaGeometry.displaySize(of: self)
        let halfWidth = Double(display.width) / 2.0, halfHeight = Double(display.height) / 2.0
        let xx = -(Double(loc.x) - halfWidth)
        let yy = -(Double(loc.y) - halfHeight)

        var pWC = [Double](repeating: 0, count: 2)
        vtk.getCameraWindowCenter(&pWC)
        pWC[0] *= halfWidth
        pWC[1] *= halfHeight

        if pWC[0] != xx || pWC[1] != yy {
            vtk.setCameraWindowCenterX(xx / halfWidth, y: yy / halfHeight)
            panX(halfWidth.addingProduct(-(pWC[0] - xx), 10000.0), y: halfHeight.addingProduct(-(pWC[1] - yy), 10000.0))
        }
    }

    // MARK: - Background colour

    @objc(changeColorWith:)
    func changeColor(with color: NSColor!) {
        guard let color, horos_vtk.hasRenderer else { return }
        // change background color
        horos_vtk.setBackgroundRed(Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent))

        horos_vtk.setTextColourWhite(color.redComponent + color.greenComponent + color.blueComponent < 1.5)
        viewBackgroundColor?.color = NSColor(deviceRed: color.redComponent, green: color.greenComponent,
                                                  blue: color.blueComponent, alpha: 1.0)

        needsDisplay = true
    }

    @objc(changeColor:)
    func changeColor(_ sender: Any?) {
        if viewBackgroundColor?.isActive == true {
            changeColor(with: (sender as? NSColorPanel)?.color.usingColorSpace(.genericRGB))
        }
    }

    @objc(backgroundColor)
    func backgroundColor() -> NSColor! {
        return viewBackgroundColor?.color
    }

    // MARK: - Voxels and world

    /// A point of VTK's world as voxel indices of the volume.
    @objc(convert3Dto2Dpoint::)
    func convert3Dto2Dpoint(_ pt3D: UnsafeMutablePointer<Double>!, _ pt2D: UnsafeMutablePointer<Double>!) {
        guard let pt3D, let pt2D else { return }
        let vtk = horos_vtk
        guard vtk.hasVolume, let transform = vtk.userTransformFused(false) else { return }

        transform.inverseTransformDoublePoint(pt3D, into: pt2D)

        var vPos = [Double](repeating: 0, count: 3)
        vtk.getVolumePosition(&vPos, fused: false)

        pt2D[0] -= vPos[0]
        pt2D[1] -= vPos[1]
        pt2D[2] -= vPos[2]

        let firstObject = horos_firstObject
        pt2D[0] /= firstObject?.pixelSpacingX ?? 0
        pt2D[1] /= firstObject?.pixelSpacingY ?? 0
        pt2D[2] /= firstObject?.sliceInterval ?? 0
    }

    /// Voxel indices of the volume (changed in place to millimetres) as a point of VTK's world.
    @objc(convert2DPoint:to3DPoint:)
    func convert2DPoint(_ pt2D: UnsafeMutablePointer<Float>!, to3DPoint pt3D: UnsafeMutablePointer<Float>!) {
        let vtk = horos_vtk
        let firstObject = horos_firstObject
        // convert to world size
        pt2D[0] = Float(Double(pt2D[0]) * (firstObject?.pixelSpacingX ?? 0))
        pt2D[1] = Float(Double(pt2D[1]) * (firstObject?.pixelSpacingY ?? 0))
        pt2D[2] = Float(Double(pt2D[2]) * (firstObject?.sliceInterval ?? 0))

        var vPos = [Double](repeating: 0, count: 3)
        vtk.getVolumePosition(&vPos, fused: false)

        // add in origin
        pt2D[0] = Float(Double(pt2D[0]) + vPos[0])
        pt2D[1] = Float(Double(pt2D[1]) + vPos[1])
        pt2D[2] = Float(Double(pt2D[2]) + vPos[2])

        // tranform the point using the volume trnsform matrix
        vtk.userTransformFused(false)?.transformFloatPoint(pt2D, into: pt3D)
    }
}
