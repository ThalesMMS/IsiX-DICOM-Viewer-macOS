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
import IsiXImaging

/// Which windows Window > Close Viewers of This Study closes.
@Suite struct StudyViewerClosingTests {

    typealias Window = StudyViewerClosing.Window<String>

    func viewer(_ name: String, _ study: String?) -> Window { Window(owner: name, study: study, is2D: true) }
    func window3D(of name: String?, _ study: String?) -> Window { Window(owner: name, study: study, is2D: false) }

    @Test func theStudysWindowsCloseAndTheOtherStudiesStayOpen() {
        let windows = [
            viewer("A1", "1.2.3"),          // 0
            viewer("B1", "4.5.6"),          // 1
            window3D(of: "A1", "1.2.3"),    // 2: a VR of A1
            viewer("A2", "1.2.3"),          // 3: another series of the study
            window3D(of: "B1", "4.5.6"),    // 4: an MPR of the other study
            window3D(of: "A2", "1.2.3"),    // 5: a 4D window of A2
        ]
        let closed = StudyViewerClosing.windowsToClose(windows, active: "A2", study: "1.2.3")
        #expect(closed == [2, 5, 0, 3])
        #expect(!closed.contains(1) && !closed.contains(4))
    }

    @Test func everyThreeDWindowClosesBeforeTheTwoDViewers() {
        let windows = [viewer("A1", "S"), window3D(of: "A1", "S"), viewer("A2", "S"), window3D(of: "A2", "S")]
        let closed = StudyViewerClosing.windowsToClose(windows, active: "A1", study: "S")
        #expect(closed == [1, 3, 0, 2])
    }

    @Test func aViewerOfNoKnownStudyClosesOnlyItsOwnWindows() {
        let windows = [viewer("A", nil), window3D(of: "A", nil), viewer("B", nil), viewer("C", ""), window3D(of: "B", nil)]
        #expect(StudyViewerClosing.windowsToClose(windows, active: "A", study: nil) == [1, 0])
        #expect(StudyViewerClosing.windowsToClose(windows, active: "C", study: "") == [3])
    }

    @Test func aWindowOfNoKnownStudyIsNotTakenForTheActiveOne() {
        let windows = [viewer("A", "S"), viewer("B", nil), viewer("C", ""), window3D(of: nil, "S"), window3D(of: "D", "S")]
        // The 3D window without an owner stays; the one whose owner is of the study goes.
        #expect(StudyViewerClosing.windowsToClose(windows, active: "A", study: "S") == [4, 0])
    }

    @Test func theActiveViewersWindowsCloseEvenWhenTheirStudyIsReadDifferently() {
        // The study is read from the current time point of each viewer: the
        // active viewer's own windows go whatever their copy of it says.
        let windows = [viewer("A", "S"), window3D(of: "A", "T"), viewer("B", "T")]
        #expect(StudyViewerClosing.windowsToClose(windows, active: "A", study: "S") == [1, 0])
    }

    @Test func noWindowsNothingToClose() {
        #expect(StudyViewerClosing.windowsToClose([Window](), active: "A", study: "S").isEmpty)
    }
}
