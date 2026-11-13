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
import IsiXROI

/// What generating the missing ROIs of one name came to.
struct ROIMissingGenerationTests {

    @Test func generatedROIsAreTheOutcomeWhateverTheImages() {
        #expect(ROIMissingGeneration.outcome(sourceImages: [2, 6], generatedCount: 3) == .generated)
        #expect(ROIMissingGeneration.outcome(sourceImages: [], generatedCount: 1) == .generated)
    }

    @Test func oneImageAloneHasNothingToMorphTowards() {
        #expect(ROIMissingGeneration.outcome(sourceImages: [4], generatedCount: 0) == .singleImage)
        // Two ROIs of the name on the same image are still one image.
        #expect(ROIMissingGeneration.outcome(sourceImages: [4, 4], generatedCount: 0) == .singleImage)
    }

    @Test func imagesWithoutAGapMissNothing() {
        #expect(ROIMissingGeneration.outcome(sourceImages: [3, 4, 5], generatedCount: 0) == .nothingMissing)
        #expect(ROIMissingGeneration.outcome(sourceImages: [5, 3, 4, 4], generatedCount: 0) == .nothingMissing)
    }

    @Test func aGapLeftEmptyOrNoROIWithAnAreaIsAFailure() {
        #expect(ROIMissingGeneration.outcome(sourceImages: [2, 6], generatedCount: 0) == .notGenerated)
        #expect(ROIMissingGeneration.outcome(sourceImages: [], generatedCount: 0) == .notGenerated)
    }
}
