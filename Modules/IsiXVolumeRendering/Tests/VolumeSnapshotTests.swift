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
import Testing
@testable import IsiXVolumeRendering

/// What the 3D view hands its Metal renderer, computed from VTK's state as
/// numbers. Their comparison with the Objective-C++ they replaced is
/// tests/test-vr-host-snapshot-equivalence.py.
struct VolumeSnapshotTests {

    @Test func samplesPerMillimetreFollowTheRayStepAndTheOverride() {
        #expect(VolumeOpacityCurve.samplesPerMillimetre(superSampling: 2, spacingX: 0.5, rayStep: 0, override: 0) == 2 / (0.5 * 1.6))
        #expect(VolumeOpacityCurve.samplesPerMillimetre(superSampling: 2, spacingX: 0.5, rayStep: 1, override: 0) == 4)
        #expect(VolumeOpacityCurve.samplesPerMillimetre(superSampling: 0, spacingX: 0.5, rayStep: 1, override: 0) == 1)
        #expect(VolumeOpacityCurve.samplesPerMillimetre(superSampling: 2, spacingX: 0.5, rayStep: 1, override: 3) == 3)
    }

    @Test func theCurveIsPerMillimetreInCompositeAndItselfForAProjection() {
        let points: [(x: Double, y: Double)] = [(1000, 0), (1500, 0.5), (2000, 2)]
        let composite = VolumeOpacityCurve.curvePoints(points, composite: true, superSampling: 2, samplesPerMillimetre: 2)
        #expect(composite.opacity == [0, 0, 500, 1 - pow(1 - 0.25, 2), 1000, 1])
        #expect(composite.projection == [0, 0, 500, 0.5, 1000, 2])
        let projection = VolumeOpacityCurve.curvePoints(points, composite: false, superSampling: 2, samplesPerMillimetre: 2)
        #expect(projection.opacity[3] == 1 - pow(1 - 0.5, 2))
    }

    @Test func aNaNOpacityStaysNaNAsTheCMacrosLeftIt() {
        #expect(VolumeOpacityCurve.perMillimetre(.nan, samplesPerMillimetre: 2).isNaN)
        let alphas = [Double.nan, -1, 0.5, 3]
        let tables = alphas.withUnsafeBufferPointer { VolumeOpacityCurve.tables(alphas: $0, samplesPerMillimetre: 1) }
        #expect(tables.painted[0].isNaN && tables.painted[1] == 0 && tables.painted[2] == 0.5 && tables.painted[3] == 1)
    }

    @Test func theFusedTableSpreadsOverTheWindow() {
        let table = (0..<257).map { Double($0) / 254 }
        let points = table.withUnsafeBufferPointer { VolumeOpacityCurve.fusedPoints(table: $0.baseAddress!, samplesPerMillimetre: 1) }
        #expect(points.opacity.count == 510 && points.projection.count == 510)
        #expect(points.projection[508] == 256 && points.projection[509] == 1)
    }

    @Test func coloursBecomeOpaqueBytes() {
        let colours: [Double] = [0, 0.5, 1, .nan, -1, 2]
        let bytes = colours.withUnsafeBufferPointer { VolumeColourTable.rgba(colours: $0.baseAddress!, count: 2) }
        #expect(bytes == [0, 128, 255, 255, 0, 0, 255, 255])
    }

    @Test func onlyPlanesThatCutTheVoxelsAreKept() throws {
        // x ≥ 0 cuts nothing; x ≤ 5 (−x + 5 ≥ 0) cuts a 10-voxel-wide volume.
        let planes: [Float] = [1, 0, 0, 0, -1, 0, 0, 5]
        let kept = try VolumeCropPlanes.cuttingPlanes(voxelPlanes: planes, cropping: nil, width: 10, height: 10, depth: 10)
        #expect(kept == [-1, 0, 0, 5])
    }

    @Test func aSubvolumeBecomesSixPlanesAndOtherRegionsAreRefused() throws {
        let cropping = VolumeCropPlanes.Cropping(subvolume: true, planes: [2, 8, 0, 9, 0, 9], origin: [0, 0, 0], spacing: [1, 1, 1])
        let kept = try VolumeCropPlanes.cuttingPlanes(voxelPlanes: [], cropping: cropping, width: 10, height: 10, depth: 10)
        #expect(kept == [1, 0, 0, -2, -1, 0, 0, 8])
        var regions = cropping
        regions.subvolume = false
        #expect(throws: VolumeCropPlanes.Refusal.regionsNotSubvolume) {
            try VolumeCropPlanes.cuttingPlanes(voxelPlanes: [], cropping: regions, width: 10, height: 10, depth: 10)
        }
        var flat = cropping
        flat.spacing = [1, 0, 1]
        #expect(throws: VolumeCropPlanes.Refusal.unusableSpacing) {
            try VolumeCropPlanes.cuttingPlanes(voxelPlanes: [], cropping: flat, width: 10, height: 10, depth: 10)
        }
    }

    @Test func theCameraGoesToMillimetresWithItsShearAndCentre() {
        var camera = VolumeCameraSnapshot.Camera(position: [0, 0, 20], focalPoint: [0, 0, 0], viewUp: [0, 1, 0],
                                                 parallelProjection: true, parallelScale: 10, viewAngle: 30, eyeAngle: 2,
                                                 leftEye: true, windowCenter: [0, 0], clippingRange: [4, 40], stereo: false)
        let plain = VolumeCameraSnapshot(camera: camera, factor: 2, clipThickness: nil, projection: false)
        #expect(plain.camera == [0, 0, 10, 0, 0, 0, 0, 1, 0, 1, 5, 30] && plain.near == 0 && plain.far == -1)
        camera.windowCenter = [0.25, 0]
        let centred = VolumeCameraSnapshot(camera: camera, factor: 2, clipThickness: 8, projection: false)
        #expect(Array(centred.camera.suffix(3)) == [0, 0.25, 0] && centred.far == 4)
        camera.stereo = true
        let stereo = VolumeCameraSnapshot(camera: camera, factor: 2, clipThickness: 8, projection: true)
        #expect(stereo.camera.count == 15 && stereo.camera[12] == tan(-1 * 0.017453292519943295))
        #expect(stereo.near == 2 && stereo.far == 20)
    }

    @Test func thePlacementIsColumnMajorInMillimetres() {
        let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let columns = VolumePlacement.voxelToWorldColumns(matrix: identity, origin: [2, 4, 6], spacing: [1, 2, 3], factor: 2)
        #expect(columns == [0.5, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1.5, 0, 1, 2, 3, 1])
        #expect(VolumePlacement.rows(fromColumns: columns) == [0.5, 0, 0, 1, 0, 1, 0, 2, 0, 0, 1.5, 3, 0, 0, 0, 1])
    }

    @Test func theStepFollowsSuperSamplingAndTheLowResolutionImage() {
        #expect(VolumeSamplingStep.composite(spacingX: 0.8, superSampling: 2) == 0.4)
        #expect(VolumeSamplingStep.composite(spacingX: 0.8, superSampling: 0) == 0.8)
        #expect(VolumeSamplingStep.interactionScale(minimumImageSampleDistance: 3, lod: 1.5) == 2)
        #expect(VolumeSamplingStep.interactionScale(minimumImageSampleDistance: 1, lod: 1.5) == 1)
    }

    @Test func lightsOnAddUpAndNoneIsTheHeadlight() {
        let lights = [VolumeLighting.Light(on: true, intensity: 0.5, ambientColour: [0.3, 0.6, 0.9]),
                      VolumeLighting.Light(on: false, intensity: 7, ambientColour: [1, 1, 1])]
        let terms = VolumeLighting.terms(of: lights)
        #expect(abs(terms.ambient - 0.3) < 1e-12 && terms.intensity == 0.5)
        #expect(VolumeLighting.terms(of: []) == (0, 1))
        #expect(VolumeLighting.shading(shade: true, ambient: 0.1, diffuse: 0.2, specular: 0.3, specularPower: 4, lights: [])
                == [1, 0.1, 0.2, 0.3, 4, 0, 1])
    }
}
