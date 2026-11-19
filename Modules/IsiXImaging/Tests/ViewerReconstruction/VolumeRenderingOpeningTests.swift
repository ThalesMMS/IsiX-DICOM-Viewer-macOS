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
@testable import IsiXImaging

// The presentation of a first opening of the VR window, which Revert Series
// restores. The wiring in the window (the opening, the saved state's defaults
// and Revert Series) is checked outside the package, in tests/.
@Suite struct VolumeRenderingOpeningTests {

    private func opening(volumeRendering: Bool, isRGB: Bool = false, isPET: Bool = false,
                         defaultShading: Bool = true) -> VolumeRenderingOpening {
        VolumeRenderingOpening(volumeRendering: volumeRendering, isRGB: isRGB, isPET: isPET, viewerColourTable: "Hot Iron",
                               viewerWindowLevel: 40, viewerWindowWidth: 400, defaultShading: defaultShading)
    }

    @Test func volumeRenderingGivesAGreyscaleSeriesItsTables() {
        let vr = opening(volumeRendering: true)
        #expect(vr.colourTable == "VR Muscles-Bones")
        #expect(vr.opacityTable == .logarithmicInverse)
        #expect(vr.windowLevel == 40 && vr.windowWidth == 400)
        #expect(vr.shading == true)
        #expect(opening(volumeRendering: true, defaultShading: false).shading == false)
        // A PET series too: the mode's tables replace the PET opacity.
        #expect(opening(volumeRendering: true, isPET: true) == vr)
    }

    @Test func projectionKeepsTheViewersTableAndTheShadingFlag() {
        let mip = opening(volumeRendering: false)
        #expect(mip.colourTable == "Hot Iron")
        #expect(mip.opacityTable == .linear)
        #expect(mip.windowLevel == 40 && mip.windowWidth == 400)
        #expect(mip.shading == nil)
        #expect(opening(volumeRendering: false, isPET: true).opacityTable == .logarithmic)
    }

    @Test func anRGBSeriesKeepsTheViewersTableInEveryMode() {
        for volumeRendering in [true, false] {
            let rgb = opening(volumeRendering: volumeRendering, isRGB: true, isPET: true)
            #expect(rgb.colourTable == "Hot Iron")
            #expect(rgb.opacityTable == .linear)
        }
        #expect(VolumeRenderingOpening.modeColourTable(volumeRendering: true, isRGB: true) == nil)
        #expect(VolumeRenderingOpening.modeOpacityTable(volumeRendering: false, isRGB: false) == nil)
    }

    @Test func theShadingValuesAreTheWindowsOwn() {
        #expect(VolumeRenderingOpening.shadingValues
                == .init(ambient: 0.15, diffuse: 0.9, specular: 0.3, specularPower: 15))
    }

    private func panel(isRGB: Bool = false, isPET: Bool = false, volumeRendering: Bool = false, suvConverted: Bool = false,
                       petColourTable: String? = "PET") -> VolumeRenderingOpening {
        .panel(volumeRendering: volumeRendering, isRGB: isRGB, isPET: isPET, noColourTable: "No CLUT",
               petColourTable: petColourTable, suvConverted: suvConverted, maximumValue: 20000,
               viewerWindowLevel: 40, viewerWindowWidth: 400, defaultShading: true)
    }

    @Test func thePanelKeepsItsOwnColourTableAndTheViewersWindow() {
        let mip = panel()
        #expect(mip.colourTable == "No CLUT")
        #expect(mip.opacityTable == .linear)
        #expect(mip.windowLevel == 40 && mip.windowWidth == 400)
        #expect(mip.shading == nil)
        // An RGB PET series is not given the PET tables.
        #expect(panel(isRGB: true, isPET: true) == mip)
        // In volume rendering, the shading of the preference, not the mode's tables.
        let vr = panel(volumeRendering: true)
        #expect(vr.colourTable == "No CLUT" && vr.opacityTable == .linear && vr.shading == true)
    }

    @Test func thePanelGivesAPETSeriesThePETTablesAndWindow() {
        let pet = panel(isPET: true)
        #expect(pet.colourTable == "PET")
        #expect(pet.opacityTable == .logarithmic)
        #expect(pet.windowLevel == 5000 && pet.windowWidth == 10000)
        let suv = panel(isPET: true, suvConverted: true)
        #expect(suv.windowLevel == 3 && suv.windowWidth == 6)
        #expect(panel(isPET: true, petColourTable: nil).colourTable == "No CLUT")
        #expect(VolumeRenderingOpening.petColourTable(clutMode: "B/W Inverse", defaultTable: "PET") == "B/W Inverse")
        #expect(VolumeRenderingOpening.petColourTable(clutMode: "Default", defaultTable: "PET") == "PET")
        #expect(VolumeRenderingOpening.petColourTable(clutMode: nil, defaultTable: nil) == nil)
    }

    // The endoscopy window applied its own shading preset at every opening,
    // over the shading values its saved state had just given the view.
    @Test func theEndoscopyKeepsTheShadingItsStateHolds() {
        #expect(VolumeRenderingOpening.endoscopyShadingPreset(savedName: nil, stateHoldsShadingValues: false) == "Endoscopy")
        #expect(VolumeRenderingOpening.endoscopyShadingPreset(savedName: nil, stateHoldsShadingValues: true) == nil)
        #expect(VolumeRenderingOpening.endoscopyShadingPreset(savedName: "", stateHoldsShadingValues: false) == "Endoscopy")
        // A state that names a preset: that one, whatever values it holds.
        #expect(VolumeRenderingOpening.endoscopyShadingPreset(savedName: "Glossy Bone", stateHoldsShadingValues: true) == "Glossy Bone")
        #expect(VolumeRenderingOpening.endoscopyShadingPreset(savedName: "Glossy Bone", stateHoldsShadingValues: false) == "Glossy Bone")
    }
}
