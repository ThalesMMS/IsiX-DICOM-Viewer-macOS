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

// Values worked out by hand. The comparison with the Objective-C the module
// replaced runs outside the package, in tests/.
@Suite struct ThreeDViewerPresetsTests {
    @Test func windowLevelRangeRoundTrips() {
        #expect(ThreeDWindowLevelSheet.range(level: 40, width: 400) == (-160, 240))
        #expect(ThreeDWindowLevelSheet.levelAndWidth(from: -160, to: 240) == (40, 400))
    }

    @Test func menuItemsAreCheckedByTitle() {
        #expect(ThreeDPresetMenus.checksItem(title: "Bone", current: "Bone"))
        #expect(!ThreeDPresetMenus.checksItem(title: "Bone", current: "bone"))
        #expect(!ThreeDPresetMenus.checksItem(title: "Bone", current: nil))
    }
}
