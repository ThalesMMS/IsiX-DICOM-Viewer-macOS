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

struct SlabThicknessTextTests {
    private let english = Locale(identifier: "en_US"), italian = Locale(identifier: "it_IT"), brazilian = Locale(identifier: "pt_BR")

    @Test func theBubbleAndTheFieldWriteOneNumber() {
        let expected: [(Double, String, String)] = [
            (0.625, "0.62", "0,62"), (0.7, "0.7", "0,7"), (1, "1", "1"), (2, "2", "2"), (2.8, "2.8", "2,8"),
            (12.375, "12.4", "12,4"), (359, "359", "359"), (9.999, "10", "10"), (1536, "1536", "1536"),
        ]
        for (thickness, point, comma) in expected {
            #expect(SlabThicknessText.number(thickness, locale: english) == point)
            #expect(SlabThicknessText.text(thickness, locale: english) == point + " mm")
            for locale in [italian, brazilian] {
                #expect(SlabThicknessText.number(thickness, locale: locale) == comma)
                #expect(SlabThicknessText.text(thickness, locale: locale) == comma + " mm")
            }
        }
        #expect(SlabThicknessText.text(.nan, locale: english) == "")
    }

    @Test func aCommaOrAPointIsRead() {
        for text in ["0,62", "0.62", "0,62 mm", "0.62mm", " 0,62 MM ", "+0.62"] {
            #expect(SlabThicknessText.value(of: text) == 0.62, "\(text)")
        }
        #expect(SlabThicknessText.value(of: "12") == 12)
        #expect(SlabThicknessText.value(of: ".5") == 0.5)
        #expect(SlabThicknessText.value(of: "3.") == 3)
        #expect(SlabThicknessText.value(of: "-2") == -2)
        for text in ["", "mm", "abc", "1,2,3", "1.2.3", "1 000", "1e3", "--1", ".", ",", "12 cm", "nan", "inf"] {
            #expect(SlabThicknessText.value(of: text) == nil, "\(text)")
        }
    }

    @Test func whatIsWrittenReadsAsItself() {
        for locale in [english, italian, brazilian] {
            for thickness in [0.625, 0.7, 1, 2, 2.8, 12.375, 359, 0.01, 99.95] {
                let written = SlabThicknessText.number(thickness, locale: locale)
                let read = SlabThicknessText.value(of: written)
                #expect(read != nil)
                #expect(SlabThicknessText.number(read ?? .nan, locale: locale) == written)
                #expect(SlabThicknessText.value(of: SlabThicknessText.text(thickness, locale: locale)) == read)
            }
        }
    }

    @Test func aTypedThicknessStaysBetweenTheEnds() {
        for locale in [english, italian] {
            func typed(_ value: Double, thin: Double = 0.625, thick: Double = 359) -> Double {
                SlabThicknessText.fieldThickness(entered: value, thinEnd: thin, maximum: thick, locale: locale)
            }
            #expect(typed(0.3) == 0.625)
            #expect(typed(500) == 359)
            #expect(typed(-4) == 0.625)
            #expect(typed(.nan) == 0.625)
            // The thin end read back from its own text is the thin end, not 0.62.
            #expect(typed(0.62) == 0.625)
            #expect(typed(0.63) == 0.63)
            // The slab is the number the field shows.
            #expect(typed(12.375) == 12.4)
            #expect(typed(2) == 2)
            #expect(typed(358.96, thick: 358.99) == 358.99)
            // A volume thinner than its thin end has one thickness.
            #expect(typed(5, thin: 2, thick: 1) == 2)
        }
    }
}
