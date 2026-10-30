//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The 3D view's camera as the Metal renderer takes it, in the volume's own
/// millimetre frame: VTK works in that frame scaled by the view's `factor`.
public struct VolumeCameraSnapshot: Equatable, Sendable {

    /// VTK's camera, in its scaled world frame.
    public struct Camera: Sendable {
        public var position: [Double], focalPoint: [Double], viewUp: [Double]
        public var parallelProjection: Bool
        public var parallelScale: Double, viewAngle: Double, eyeAngle: Double
        public var leftEye: Bool
        public var windowCenter: [Double]
        public var clippingRange: [Double]
        /// The render window renders a stereo pair.
        public var stereo: Bool

        public init(position: [Double], focalPoint: [Double], viewUp: [Double], parallelProjection: Bool,
                    parallelScale: Double, viewAngle: Double, eyeAngle: Double, leftEye: Bool,
                    windowCenter: [Double], clippingRange: [Double], stereo: Bool) {
            self.position = position
            self.focalPoint = focalPoint
            self.viewUp = viewUp
            self.parallelProjection = parallelProjection
            self.parallelScale = parallelScale
            self.viewAngle = viewAngle
            self.eyeAngle = eyeAngle
            self.leftEye = leftEye
            self.windowCenter = windowCenter
            self.clippingRange = clippingRange
            self.stereo = stereo
        }
    }

    /// position(3), focal point(3), view-up(3), parallel, parallel scale, view
    /// angle; then, when needed, the stereo shear and the window centre.
    public var camera: [Double]
    /// The rays' near and far distances, far < 0 for none.
    public var near: Double, far: Double

    /// `clipThickness` is the clipping range's thickness when the view has
    /// one on, in VTK's frame. A projection (`projection`) starts every ray on
    /// the camera's near plane and samples it as the mapper does, so it takes
    /// the camera's own clipping range.
    public init(camera: Camera, factor: Double, clipThickness: Double?, projection: Bool) {
        var values: [Double] = []
        for i in 0..<3 { values.append(camera.position[i] / factor) }
        for i in 0..<3 { values.append(camera.focalPoint[i] / factor) }
        for i in 0..<3 { values.append(camera.viewUp[i]) }
        values.append(camera.parallelProjection ? 1 : 0)
        values.append(camera.parallelScale / factor)
        values.append(camera.viewAngle)
        // The eye VTK is rendering in stereo: its camera shears the view by
        // tan(-eye angle / 2) for the left eye, + for the right.
        if camera.stereo {
            // vtkMath::RadiansFromDegrees.
            values.append(tan(((camera.leftEye ? -0.5 : 0.5) * camera.eyeAngle) * 0.017453292519943295))
        }
        // The window centre moves VTK's projection, and with it the overlays and
        // picking; the volume must move with them. Its shear slot is 0 without stereo.
        if camera.windowCenter[0] != 0 || camera.windowCenter[1] != 0 {
            if !camera.stereo { values.append(0) }
            values.append(camera.windowCenter[0])
            values.append(camera.windowCenter[1])
        }
        var near = 0.0, far = -1.0
        if let clipThickness { near = 0; far = clipThickness / factor }
        if projection {
            near = camera.clippingRange[0] / factor
            far = camera.clippingRange[1] / factor
        }
        self.camera = values
        self.near = near
        self.far = far
    }
}

/// Where a volume's voxels are, as the renderer takes it.
public enum VolumePlacement {

    /// The voxel-to-world transform, column by column, in millimetres: the
    /// importer's `origin` and `spacing` through the volume's `matrix` (row by
    /// row), out of VTK's frame scaled by `factor`.
    public static func voxelToWorldColumns(matrix: [Double], origin: [Double], spacing: [Double], factor: Double) -> [Double] {
        func element(_ row: Int, _ column: Int) -> Double { matrix[4 * row + column] }
        var transform: [Double] = []
        transform.reserveCapacity(16)
        for column in 0..<4 {
            for row in 0..<4 {
                let value = row == 3 ? (column == 3 ? 1 : 0) :
                    (column < 3 ? element(row, column) * spacing[column] :
                        element(row, 3) + element(row, 0) * origin[0] + element(row, 1) * origin[1] + element(row, 2) * origin[2]) / factor
                transform.append(value)
            }
        }
        return transform
    }

    /// A 4 × 4 matrix given column by column, row by row.
    public static func rows(fromColumns columns: [Double]) -> [Double] {
        var rows: [Double] = []
        rows.reserveCapacity(16)
        for row in 0..<4 { for column in 0..<4 { rows.append(columns[column * 4 + row]) } }
        return rows
    }
}

/// How far apart the renderer samples a ray, in millimetres.
public enum VolumeSamplingStep {

    /// VTK samples every unit of its scaled frame (pixelSpacingX /
    /// superSampling millimetres) in composite rendering; compositing with a
    /// coarser step locks a boundary sample's colour into the pixel, so the
    /// renderer walks the same distance. The slice interval plays no part.
    public static func composite(spacingX: Double, superSampling: Double) -> Double {
        superSampling > 0 ? spacingX / superSampling : spacingX
    }

    /// While the view draws its low-resolution image (a drag, an autorotation),
    /// its mapper spaces the image's rays LOD × lowResLODFactor apart instead of
    /// LOD, and the rays step as much coarser.
    public static func interactionScale(minimumImageSampleDistance: Double, lod: Double) -> Double {
        lod > 0 && minimumImageSampleDistance > lod ? minimumImageSampleDistance / lod : 1
    }
}

/// A volume's shading as VTK's ray caster lights a sample
/// (vtkEncodedGradientShader).
public enum VolumeLighting {

    /// One light of the renderer.
    public struct Light: Sendable {
        public var on: Bool
        public var intensity: Double
        public var ambientColour: [Double]

        public init(on: Bool, intensity: Double, ambientColour: [Double]) {
            self.on = on
            self.intensity = intensity
            self.ambientColour = ambientColour
        }
    }

    /// Each light switched on adds its intensity times its ambient colour to
    /// the ambient term and its intensity to the diffuse and specular ones.
    /// With no light on yet, the headlight the next render makes: no ambient,
    /// intensity 1.
    public static func terms(of lights: [Light]) -> (ambient: Double, intensity: Double) {
        var ambient = 0.0, intensity = 0.0, lit = false
        for light in lights where light.on {
            ambient += light.intensity * (light.ambientColour[0] + light.ambientColour[1] + light.ambientColour[2]) / 3
            intensity += light.intensity
            lit = true
        }
        return lit ? (ambient, intensity) : (0, 1)
    }

    /// The renderer's shading: shade on or off, the property's ambient,
    /// diffuse, specular and specular power, and the lights' ambient and
    /// intensity.
    public static func shading(shade: Bool, ambient: Double, diffuse: Double, specular: Double, specularPower: Double,
                               lights: [Light]) -> [Double] {
        let terms = terms(of: lights)
        return [shade ? 1 : 0, ambient, diffuse, specular, specularPower, terms.ambient, terms.intensity]
    }
}
