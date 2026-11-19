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

// The shading values beside the Shading check box of the VR window. The
// catalogs' texts and the window's wiring are checked outside the package,
// in tests/.
@Suite struct ShadingValuesTextTests {

    private let english = "Ambient: %1$@\nDiffuse: %2$@\nSpecular: %3$@/%4$@"
    private let portuguese = "Ambiente: %1$@\nDifuso: %2$@\nEspecular: %3$@/%4$@"

    @Test func theOpeningsValuesWithTwoDecimals() {
        let text = ShadingValuesText.string(VolumeRenderingOpening.shadingValues, template: english,
                                            locale: Locale(identifier: "en_US"))
        #expect(text == "Ambient: 0.15\nDiffuse: 0.90\nSpecular: 0.30/15.00")
    }

    @Test func aPresetAsItIsWritten() {
        let glossyBone = VolumeRenderingOpening.ShadingValues(ambient: 0.15, diffuse: 0.24, specular: 1.17, specularPower: 6.98)
        #expect(ShadingValuesText.string(glossyBone, template: english, locale: Locale(identifier: "en_US"))
                == "Ambient: 0.15\nDiffuse: 0.24\nSpecular: 1.17/6.98")
    }

    @Test func theRegionsDecimalSeparator() {
        let values = VolumeRenderingOpening.shadingValues
        #expect(ShadingValuesText.string(values, template: portuguese, locale: Locale(identifier: "pt_BR"))
                == "Ambiente: 0,15\nDifuso: 0,90\nEspecular: 0,30/15,00")
        // The region decides, not the language: English words, German numbers.
        #expect(ShadingValuesText.string(values, template: english, locale: Locale(identifier: "en_DE"))
                == "Ambient: 0,15\nDiffuse: 0,90\nSpecular: 0,30/15,00")
        #expect(ShadingValuesText.number(50, locale: Locale(identifier: "de_DE")) == "50,00")
        #expect(ShadingValuesText.number(0.725, locale: Locale(identifier: "fr_FR")).hasPrefix("0,7"))
    }
}
