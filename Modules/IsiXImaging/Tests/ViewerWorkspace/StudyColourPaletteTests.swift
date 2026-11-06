//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Testing
@testable import IsiXImaging

@Suite struct StudyColourPaletteTests {

    @Test func twelveColoursInTheirOrder() {
        let colours = StudyColourPalette.viewers.colours
        #expect(colours.count == 12)
        let tenths: [(Float, Float, Float)] = [
            (0.4, 0.4, 0.0), (0.4, 0.0, 0.4), (0.0, 0.4, 0.4), (0.4, 0.0, 0.0), (0.0, 0.4, 0.0), (0.0, 0.0, 0.4),
            (0.3, 0.5, 0.0), (0.3, 0.0, 0.6), (0.0, 0.5, 0.6), (0.3, 0.0, 0.0), (0.0, 0.5, 0.0),
        ]
        for (colour, expected) in zip(colours, tenths) {
            #expect(colour == StudyColour(red: Double(expected.0), green: Double(expected.1), blue: Double(expected.2)))
        }
    }

    @Test func componentsKeepTheirPrecision() {
        let colours = StudyColourPalette.viewers.colours
        // 0.4f widened, not the double 0.4.
        #expect(colours[0].red == Double(Float(0.4)))
        #expect(colours[0].red != 0.4)
        // The blue of the last colour alone is the double 0.6.
        #expect(colours[11].blue == 0.6)
        #expect(colours[7].blue == Double(Float(0.6)))
        #expect(colours[11].red == 0 && colours[11].green == 0)
    }

    @Test func distinctColours() {
        let colours = StudyColourPalette.viewers.colours
        for (index, colour) in colours.enumerated() {
            #expect(!colours[(index + 1)...].contains(colour))
        }
    }
}
