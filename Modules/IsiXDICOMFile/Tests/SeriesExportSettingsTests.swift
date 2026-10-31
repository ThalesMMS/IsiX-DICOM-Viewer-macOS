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
@testable import IsiXDICOMFile

@Suite struct SeriesExportSettingsTests {

    @Test func theSettingsAreReadThroughTheTypedKeys() {
        let preferences = MemoryPreferences(["ANNOTATIONS": "3", "CLUTBARS": 2, "keepCLUTBarsForSecondaryCapture": "YES",
                                             "includeAllTiledViews": 0])
        #expect(SeriesExportSettings(preferences: preferences)
                == SeriesExportSettings(annotations: 3, clutBars: 2, keepsCLUTBars: true, includesAllTiledViews: false))
        // Nothing stored and nothing registered reads as the preferences did: 0 and NO.
        #expect(SeriesExportSettings(preferences: MemoryPreferences())
                == SeriesExportSettings(annotations: 0, clutBars: 0, keepsCLUTBars: false, includesAllTiledViews: false))
        // The registered values of the catalog, as the application registers them.
        let registered = MemoryPreferences([:], registered: ["ANNOTATIONS": "2", "CLUTBARS": "0", "includeAllTiledViews": "1"])
        #expect(SeriesExportSettings(preferences: registered)
                == SeriesExportSettings(annotations: 2, clutBars: 0, keepsCLUTBars: false, includesAllTiledViews: true))
        #expect(preferences.writes.isEmpty)
    }

    @Test func theCaptureKeepsTheColourBarsOnlyWhenThePreferencesSaySo() {
        let kept = SeriesExportSettings(annotations: 2, clutBars: 1, keepsCLUTBars: true, includesAllTiledViews: false)
        #expect(kept.captureCLUTBars(hidden: 0) == 1)
        var hidden = kept
        hidden.keepsCLUTBars = false
        #expect(hidden.captureCLUTBars(hidden: 0) == 0)
    }

    @Test func eachFormatAsksTheViewForWhatItWrites() {
        let settings = SeriesExportSettings(annotations: 2, clutBars: 0, keepsCLUTBars: false, includesAllTiledViews: true)
        // (screen capture, 8 bits, modality kept) of the formats 0, 1, 2 and one the sheet does not have.
        let expected: [(Int32, Bool, Bool, Bool)] = [(0, false, false, true), (1, true, true, false),
                                                     (2, true, false, true), (7, true, true, false)]
        for (format, screen, eightBits, modality) in expected {
            let request = settings.captureRequest(format: format, allViewers: false)
            #expect(request.screenCapture == screen && request.force8bits == eightBits, "format \(format)")
            #expect(SeriesExportSettings.keepsModality(format: format) == modality, "format \(format)")
            #expect(request.removeGraphical && request.squarePixels && request.allTiles && request.allowSmartCropping)
        }
        #expect(!settings.captureRequest(format: 1, allViewers: true).allowSmartCropping)
        var untiled = settings
        untiled.includesAllTiledViews = false
        #expect(!untiled.captureRequest(format: 1, allViewers: false).allTiles)
    }

    @Test func onlyTheImageInMemoryOfOneViewerLeavesTheBarsAlone() {
        #expect(!SeriesExportSettings.drawsForCapture(format: 0, allViewers: false))
        #expect(SeriesExportSettings.drawsForCapture(format: 0, allViewers: true))
        #expect(SeriesExportSettings.drawsForCapture(format: 1, allViewers: false))
        #expect(SeriesExportSettings.drawsForCapture(format: 2, allViewers: false))
    }

    @Test func aSeriesIsNumberedFromItsBaseAndTheTime() {
        #expect(SeriesExportSettings.seriesNumber(.sheet, minute: 10, second: 9) == 8219)
        #expect(SeriesExportSettings.seriesNumber(.series, minute: 59, second: 59) == 5418)
    }

    @Test func theWindowIsConvertedAsCDid() {
        #expect(SeriesExportSettings.windowValue(40.9) == 40)
        #expect(SeriesExportSettings.windowValue(-40.9) == -40)
        #expect(SeriesExportSettings.windowValue(.nan) == 0)
        #expect(SeriesExportSettings.windowValue(.infinity) == Int.max)
        #expect(SeriesExportSettings.windowValue(-.infinity) == Int.min)
    }

    @Test func theSheetOffersTheFormatsTheImageAllows() {
        typealias Format = SeriesExportSettings.SheetFormat
        // A grey image: every format; with ROIs it is captured, without them its RGB capture becomes 16 bits.
        #expect(SeriesExportSettings.sheetFormat(selected: 1, isRGB: false, subtraction: false, hasROIs: false, blending: false)
                == Format(selected: 2, memoryEnabled: true, sixteenBitEnabled: true))
        #expect(SeriesExportSettings.sheetFormat(selected: 0, isRGB: false, subtraction: false, hasROIs: true, blending: false)
                == Format(selected: 1, memoryEnabled: true, sixteenBitEnabled: true))
        #expect(SeriesExportSettings.sheetFormat(selected: 0, isRGB: false, subtraction: false, hasROIs: false, blending: false)
                == Format(selected: 0, memoryEnabled: true, sixteenBitEnabled: true))
        // A colour image: no 16 bits, the image in memory left as it was.
        #expect(SeriesExportSettings.sheetFormat(selected: 2, isRGB: true, subtraction: false, hasROIs: false, blending: false)
                == Format(selected: 1, memoryEnabled: nil, sixteenBitEnabled: false))
        #expect(SeriesExportSettings.sheetFormat(selected: 0, isRGB: true, subtraction: false, hasROIs: false, blending: false)
                == Format(selected: 0, memoryEnabled: nil, sixteenBitEnabled: false))
        // A subtraction: neither 16 bits nor the image in memory.
        #expect(SeriesExportSettings.sheetFormat(selected: 0, isRGB: false, subtraction: true, hasROIs: false, blending: false)
                == Format(selected: 1, memoryEnabled: false, sixteenBitEnabled: false))
        #expect(SeriesExportSettings.sheetFormat(selected: 2, isRGB: false, subtraction: true, hasROIs: false, blending: false)
                == Format(selected: 1, memoryEnabled: false, sixteenBitEnabled: false))
        // A fusion is always captured.
        #expect(SeriesExportSettings.sheetFormat(selected: 0, isRGB: false, subtraction: false, hasROIs: false, blending: true)
                == Format(selected: 1, memoryEnabled: true, sixteenBitEnabled: true))
    }
}
