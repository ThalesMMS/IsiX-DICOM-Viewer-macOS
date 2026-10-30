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

// The crop of VRView: the clipping range of the slab (its thickness, in the
// view's supersampled units and in millimetres, and whether it is on), the
// camera kept inside the volume while the slab is on, the crop box and the
// orientation cube. A Swift extension of the class, with the same selectors
// and properties.

extension VRView {

    // MARK: - The clipping range

    /// Whether the slab is on. Setting it turns the slab on at a thickness of
    /// 2 or off, and resets the camera unless the 3D state is being restored.
    @objc dynamic var clipRangeActivated: Bool {
        get { horos_clipRangeActivated }
        set {
            if newValue == false {
                clippingRangeThickness = 0
            } else {
                clippingRangeThickness = 2
            }

            if dontResetImage == false {
                resetImage(self)
            }
        }
    }

    /// The thickness of the slab, in the view's supersampled units. Setting it
    /// takes it in the view's units: 0 turns the slab off; another thickness
    /// turns it on, in parallel projection centred on the volume.
    @objc dynamic var clippingRangeThickness: Double {
        get { horos_clippingRangeThickness }
        set { applyClippingRangeThickness(newValue) }
    }

    private func applyClippingRangeThickness(_ thickness: Double) {
        VRInteractionBenchmark.beginSample("clip")
        let vtk = horos_vtk
        let c = thickness * Double(horos_superSampling)

        horos_clippingRangeThickness = c

        if c == 0 {
            horos_clipRangeActivated = false
        } else {
            // The Objective-C raised its copy of the thickness to just above
            // the supersampling here and did not read it again: the range
            // keeps the thickness given.
            horos_clipRangeActivated = true

            if horos_projectionMode != 1 { // Parallel
                projectionMode = 1
                var center = [Double](repeating: 0, count: 3)
                vtk.getVolumeCenter(&center)
                vtk.setCameraFocalPoint(center)
                vtk.getVolumeCenter(&center)
                vtk.setCameraPosition(center)
            }

            willChangeValue(forKey: "clippingRangeThicknessInMm")
        }

        if horos_clipRangeActivated {
            vtk.setCameraClippingRangeNear(0, far: horos_clippingRangeThickness)
        } else {
            vtk.setCameraClippingRangeNear(0, far: 10000)
            vtk.resetCameraClippingRange()
        }

        if horos_clipRangeActivated {
            didChangeValue(forKey: "clippingRangeThicknessInMm")
        }

        needsDisplay = true
        VRInteractionBenchmark.endSample()
    }

    /// The thickness of the slab in the view's units.
    @objc(getClippingRangeThickness)
    func getClippingRangeThickness() -> Double {
        return horos_clippingRangeThickness / Double(horos_superSampling)
    }

    /// The thickness of the slab in millimetres, 0 when it is off (the key
    /// clippingRangeThicknessInMm).
    @objc(getClippingRangeThicknessInMm)
    func getClippingRangeThicknessInMm() -> Double {
        if horos_vtk.hasVolumeMapper {
            if horos_clipRangeActivated {
                return horos_clippingRangeThickness / Double(horos_factor)
            }
        }
        return 0
    }

    /// Sets the thickness of the slab in millimetres, when it is on.
    @objc(setClippingRangeThicknessInMm:)
    func setClippingRangeThicknessInMm(_ c: Double) {
        if horos_vtk.hasVolumeMapper {
            if horos_clipRangeActivated {
                clippingRangeThickness = c * Double(horos_factor) / Double(horos_superSampling)
            }
        }
    }

    // MARK: - The camera inside the volume

    /// Whether `position` is strictly inside the volume's bounds.
    @objc(checkPointInVolume:)
    func checkPointInVolume(_ position: UnsafeMutablePointer<Double>!) -> Bool {
        var bounds = [Double](repeating: 0, count: 6)

        horos_vtk.getVolumeBounds(&bounds)

        if position[0] <= bounds[0] { return false }
        if position[0] >= bounds[1] { return false }

        if position[1] <= bounds[2] { return false }
        if position[1] >= bounds[3] { return false }

        if position[2] <= bounds[4] { return false }
        if position[2] >= bounds[5] { return false }

        return true
    }

    /// The camera at the volume's centre, looking along y.
    @objc(goToCenter)
    func goToCenter() {
        let vtk = horos_vtk
        var bounds = [Double](repeating: 0, count: 6)

        vtk.getVolumeBounds(&bounds)

        var center = [bounds[0] + (bounds[1] - bounds[0]) / 2.0,
                      bounds[2] + (bounds[3] - bounds[2]) / 2.0,
                      bounds[4] + (bounds[5] - bounds[4]) / 2.0]

        vtk.setCameraPosition(center)

        center[1] = center[1] - 1.0 // Sag

        vtk.setCameraFocalPoint(center)

        vtk.cameraOrthogonalizeViewUp()
        vtk.cameraComputeViewPlaneNormal()
    }

    /// The camera's position brought back into the volume's bounds while the
    /// slab is on, the focal point moved with it.
    @objc(checkInVolume)
    func checkInVolume() {
        if horos_clipRangeActivated {
            let vtk = horos_vtk
            var position = [Double](repeating: 0, count: 3), newPosition = [Double](repeating: 0, count: 3)
            var center = [Double](repeating: 0, count: 3)

            _ = vtk.cameraDistance
            vtk.getCameraPosition(&position)
            vtk.getCameraPosition(&newPosition)

            var bounds = [Double](repeating: 0, count: 6)

            vtk.getVolumeBounds(&bounds)

            if newPosition[0] <= bounds[0] { newPosition[0] = bounds[0] }
            if newPosition[0] >= bounds[1] { newPosition[0] = bounds[1] }

            if newPosition[1] <= bounds[2] { newPosition[1] = bounds[2] }
            if newPosition[1] >= bounds[3] { newPosition[1] = bounds[3] }

            if newPosition[2] <= bounds[4] { newPosition[2] = bounds[4] }
            if newPosition[2] >= bounds[5] { newPosition[2] = bounds[5] }

            vtk.setCameraPosition(newPosition)

            vtk.getCameraFocalPoint(&center)

            center[0] += newPosition[0] - position[0]
            center[1] += newPosition[1] - position[1]
            center[2] += newPosition[2] - position[2]

            vtk.setCameraFocalPoint(center)

            vtk.cameraOrthogonalizeViewUp()
            vtk.cameraComputeViewPlaneNormal()
        }
    }

    // MARK: - The orientation cube and the crop box

    @objc(switchOrientationWidget:)
    func switchOrientationWidget(_ sender: Any?) {
        if horos_orientationCubeShown {
            horos_orientationCubeShown = false
            horos_vtk.showOrientationTexts(false)
        } else {
            horos_orientationCubeShown = true
            horos_vtk.showOrientationTexts(true)
        }

        needsDisplay = true
    }

    /// The box reappears on the crop in place, the widget's own or a saved
    /// camera's. Placing it on the whole volume at every toggle undid the crop.
    @objc(placeCropBoxOnAppliedCrop)
    func placeCropBoxOnAppliedCrop() {
        let vtk = horos_vtk
        vtk.placeCropBox()

        var cropOrigins = [Double](repeating: 0, count: 18), cropNormals = [Double](repeating: 0, count: 18)
        var b = [Double](repeating: 0, count: 6)
        if vtk.getAppliedCropOrigins(&cropOrigins, normals: &cropNormals, bounds: &b) == false {
            return
        }

        let origins = cropOrigins.map { NSNumber(value: $0) }
        let normals = cropNormals.map { NSNumber(value: $0) }
        let bounds = b.map { NSNumber(value: $0) }

        let elements = VTKRetinaGeometry.cropBoxTransform(planeOrigins: origins, normals: normals, bounds: bounds)
        if elements.count != 16 {
            return
        }

        let matrix = elements.map(\.doubleValue)

        vtk.setCropBoxTransform(matrix)
    }

    @objc(showCropCube:)
    func showCropCube(_ sender: Any?) {
        let vtk = horos_vtk
        if vtk.hasCropBox {
            let enable = VTKRetinaGeometry.cropBoxEnabled(afterToggle: vtk.cropBoxEnabled)
            if enable {
                // The crop needs the mapper it clips.
                installEngineIfNeeded()
                placeCropBoxOnAppliedCrop()
                vtk.setCropBoxEnabled(true)

                setCurrentTool(.t3DRotate)
                horos_controller?.toolsMatrix()?.selectCell(withTag: Int(ToolMode.t3DRotate.rawValue))

                vtk.executeCropCallback()
            } else {
                vtk.setCropBoxEnabled(false)
            }
        }
    }
}
