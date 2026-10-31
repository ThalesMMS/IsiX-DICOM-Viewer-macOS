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
import IsiXPreferences

/// The names a viewer's ROI menus offer, and the preferences of the ROIs it keeps.
struct ROINameCatalogTests {

    @Test func theNamesOfTheSeriesFollowTheDefaultsAfterASeparator() {
        let names = ROINameCatalog.names(defaults: ["Liver"], found: ["Kidney", nil, "Liver", "Spleen", "Kidney"])
        #expect(names == ["Liver", "-", "Kidney", "Spleen"])
    }

    @Test func withoutOtherNamesThereIsNoSeparator() {
        #expect(ROINameCatalog.names(defaults: ["ROI 1", "ROI 2"], found: ["ROI 2", nil]) == ["ROI 1", "ROI 2"])
        #expect(ROINameCatalog.names(defaults: [], found: [String?]()) == [])
        #expect(ROINameCatalog.names(defaults: [], found: ["A"]) == ["-", "A"])
    }

    @Test func theROIsAreSavedAndTheEraseWarningShownUnlessSaidOtherwise() {
        let registered = MemoryPreferences(registered: ["SAVEROIS": "1"])
        #expect(registered[ROINameCatalog.savesROIs])
        #expect(ROINameCatalog.savesROIs.name == "SAVEROIS")
        #expect(!MemoryPreferences()[ROINameCatalog.skipsEraseContentWarning])
        let preferences = MemoryPreferences()
        preferences.set(true, for: ROINameCatalog.skipsEraseContentWarning)
        #expect(preferences[ROINameCatalog.skipsEraseContentWarning])
        #expect(ROINameCatalog.skipsEraseContentWarning.name == "ROIVolumeEraseContentSkipWarning")
    }
}
