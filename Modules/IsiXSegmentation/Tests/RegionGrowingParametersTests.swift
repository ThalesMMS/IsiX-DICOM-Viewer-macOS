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
@testable import IsiXSegmentation

// Values worked out by hand. The comparison with the Objective-C the module
// replaced runs outside the package, in tests/.
@Suite struct RegionGrowingParametersTests {
    @Test func algorithmsKeepTheirTagsAndFields() {
        #expect(RegionGrowingAlgorithm.allCases.map(\.rawValue) == [0, 1, 2, 3])
        #expect(RegionGrowingAlgorithm.allCases.map(\.parameterCount) == [1, 2, 3, 3])
        for algorithm in RegionGrowingAlgorithm.allCases {
            #expect(algorithm.defaultValues.count == algorithm.parameterCount)
            #expect(algorithm.helpURL.hasPrefix("http://www.itk.org/"))
        }
        #expect(RegionGrowingAlgorithm.confidence.parameterDefaultsKeys.last == "growingRegionRadius")
    }

    @Test func intervalIsKeptToThreeDecimals() {
        #expect(RegionGrowingRules.roundedInterval(100) == 100)
        #expect(RegionGrowingRules.roundedInterval(1.23456) == Float(1.234))
        #expect(RegionGrowingRules.roundedInterval(-1.23456) == Float(-1.234))
        #expect(RegionGrowingRules.roundedInterval(.nan) == 0)
        #expect(RegionGrowingRules.roundedInterval(1e12) == Float(Double(Int32.max) / 1000))
    }

    @Test func previewNameAndMerge() {
        let typed = "Growing Region", preview = "Segmentation Preview"
        #expect(RegionGrowingRules.previewROIName(fromViewerClick: true, growingModeTag: 0, directlyGenerate: true,
                                                  typedName: typed, previewName: preview) == typed)
        #expect(RegionGrowingRules.previewROIName(fromViewerClick: true, growingModeTag: 1, directlyGenerate: true,
                                                  typedName: typed, previewName: preview) == preview)
        #expect(RegionGrowingRules.previewROIName(fromViewerClick: false, growingModeTag: 0, directlyGenerate: true,
                                                  typedName: typed, previewName: preview) == preview)
        #expect(!RegionGrowingRules.mergesExistingROIs(name: preview, previewName: preview, preference: true))
        #expect(RegionGrowingRules.mergesExistingROIs(name: typed, previewName: preview, preference: true))
    }

    @Test func slicesAndResolution() {
        #expect(RegionGrowingRules.previewSlice(preview3D: true, currentImage: 4) == -1)
        #expect(RegionGrowingRules.previewSlice(preview3D: false, currentImage: 4) == 4)
        #expect(RegionGrowingRules.computeSlice(growingModeTag: 1, currentImage: 4) == -1)
        #expect(RegionGrowingRules.computeSlice(growingModeTag: 0, currentImage: 4) == 4)
        #expect(RegionGrowingRules.roiResolution(sliderMaxValue: 10, sliderValue: 10) == 1)
        #expect(RegionGrowingRules.roiResolution(sliderMaxValue: 10.9, sliderValue: 1) == 10)
        #expect(RegionGrowingRules.parametersProvided(["1", "2"]))
        #expect(!RegionGrowingRules.parametersProvided(["1", ""]))
        #expect(RegionGrowingRules.previews(previewGrowingRegion: false, directlyGenerate: true))
        #expect(!RegionGrowingRules.previews(previewGrowingRegion: false, directlyGenerate: false))
    }
}
