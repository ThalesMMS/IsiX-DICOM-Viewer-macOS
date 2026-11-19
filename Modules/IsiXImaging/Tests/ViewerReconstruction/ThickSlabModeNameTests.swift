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

struct ThickSlabModeNameTests {
    @Test func theNameEndsAtTheDashOfTheLanguage() {
        let expected = [
            "MIP - Max Intensity Projection": "MIP",
            "minIP - Min Intensity Projection": "minIP",
            "MIP – Maximumintensitätsprojektion": "MIP",
            "MinIP – Minimumintensitätsprojektion": "MinIP",
            "minIP — проекция минимальной интенсивности": "minIP",
            "Volumendarstellung – oben": "Volumendarstellung",
            "容积渲染 — 上": "容积渲染",
            "(minIP) - توقعات الحد الأدنى من كثافة": "(minIP)",
            "MIP ‒ figure dash": "MIP", "MIP ― horizontal bar": "MIP", "MIP − minus sign": "MIP",
            "MIP\u{00A0}– espace insécable": "MIP",
        ]
        for (name, short) in expected {
            #expect(ThickSlabModeName.short(of: name) == short, "\(name)")
        }
    }

    @Test func aNameWithNoDashBetweenSpacesStaysWhole() {
        for name in ["Mean", "Mittelwert", "平均", "3D-MPR", "Curved-MPR", "minIP–Minimum", "A -B", "A- B", "MIP -", "- MIP", "–", ""] {
            #expect(ThickSlabModeName.short(of: name) == name, "\(name)")
        }
        #expect(ThickSlabModeName.short(of: "Volume Rendering ") == "Volume Rendering")
        #expect(ThickSlabModeName.short(of: "  MIP - Max  ") == "MIP")
    }

    @Test func theNameEndsAtTheFirstDash() {
        #expect(ThickSlabModeName.short(of: "MIP - Max - Intensity") == "MIP")
        #expect(ThickSlabModeName.short(of: "3D-MIP – Max - Intensity") == "3D-MIP")
    }
}
