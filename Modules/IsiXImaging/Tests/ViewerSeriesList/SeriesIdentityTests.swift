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

@Suite struct SeriesIdentityTests {
    typealias Window = SeriesIdentity.Window
    typealias Mark = SeriesIdentity.Mark

    @Test func aSeriesIsNumberedByItsPlaceInItsStudy() {
        #expect(SeriesIdentity.number(atPlace: 0) == 1)
        #expect(SeriesIdentity.number(atPlace: 11) == 12)
        // No window shows it: the number is there, in the neutral colour.
        #expect(SeriesIdentity.mark(atPlace: 2, windows: []) == Mark(number: 3, colour: nil, frame: nil))
    }

    @Test func aWindowGivesTheNumberItsStudysColour() {
        #expect(SeriesIdentity.mark(atPlace: 0, windows: [Window(study: .current, isActive: false)])
                == Mark(number: 1, colour: .current, frame: nil))
        #expect(SeriesIdentity.mark(atPlace: 1, windows: [Window(study: .previous, isActive: false)])
                == Mark(number: 2, colour: .previous, frame: nil))
    }

    @Test func onlyTheActiveWindowFramesTheThumbnail() {
        #expect(SeriesIdentity.mark(atPlace: 1, windows: [Window(study: .previous, isActive: true)])
                == Mark(number: 2, colour: .previous, frame: .previous))
        // The same series in two windows, the second one active.
        #expect(SeriesIdentity.mark(atPlace: 0, windows: [Window(study: .current, isActive: false), Window(study: .current, isActive: true)])
                == Mark(number: 1, colour: .current, frame: .current))
    }

    /// The example of the request: two studies, two windows each, the last one active.
    @Test func fourWindowsOfTwoStudies() {
        let recent = [SeriesIdentity.mark(atPlace: 0, windows: [Window(study: .current, isActive: false)]),
                      SeriesIdentity.mark(atPlace: 1, windows: [Window(study: .current, isActive: false)]),
                      SeriesIdentity.mark(atPlace: 2, windows: [])]
        let older = [SeriesIdentity.mark(atPlace: 0, windows: [Window(study: .previous, isActive: false)]),
                     SeriesIdentity.mark(atPlace: 1, windows: [Window(study: .previous, isActive: true)])]
        #expect(recent.map(\.number) == [1, 2, 3] && older.map(\.number) == [1, 2])
        #expect(recent.map(\.colour) == [.current, .current, nil] && older.map(\.colour) == [.previous, .previous])
        #expect((recent + older).compactMap(\.frame) == [.previous])
    }
}
