//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation
import Testing
@testable import IsiXDatabase

/// The sizes of the browser's text and rows on their own. The comparison with
/// the Objective-C methods they replaced is
/// tests/test-browser-controller-class-equivalence.py.
struct BrowserLayoutRulesTests {
    @Test func everyKindHasASizeInEachKnownMode() {
        for mode: Int32 in [-1, 0, 1] {
            for kind in BrowserFontKind.allCases {
                #expect(BrowserFontSizes.size(of: kind, mode: mode, smallControl: 11, miniControl: 9) != nil)
            }
        }
        #expect(BrowserFontSizes.size(of: .dbFont, mode: 2, smallControl: 11, miniControl: 9) == nil)
        #expect(BrowserFontSizes.fallback == 12)
    }

    @Test func theRegularThreadTextIsTheSystemsControlSize() {
        #expect(BrowserFontSizes.size(of: .threadNameSize, mode: 0, smallControl: 11, miniControl: 9) == 11)
        #expect(BrowserFontSizes.size(of: .threadNameStatus, mode: 0, smallControl: 11, miniControl: 9) == 9)
        #expect(BrowserFontSizes.size(of: .threadNameSize, mode: 1, smallControl: 11, miniControl: 9) == 13)
    }

    @Test func theStudyListGrowsWithTheMode() {
        let sizes = [Int32(-1), 0, 1].compactMap { BrowserFontSizes.size(of: .dbFont, mode: $0, smallControl: 0, miniControl: 0) }
        #expect(sizes == [10, 12, 15])
        #expect(BrowserFontSizes.size(of: .dbSmallMatrixFont, mode: -1, smallControl: 0, miniControl: 0) == 7.5)
        #expect(BrowserFontKind(rawValue: "dbFontSize") == nil)
    }

    @Test func theHistoryIsOneLineAboveTheThumbnailsAndTwoBeside() {
        #expect(BrowserRowHeights.forMode(0, horizontalHistory: true)?.history == 16)
        #expect(BrowserRowHeights.forMode(0, horizontalHistory: false)?.history == 29)
        #expect(BrowserRowHeights.forMode(1, horizontalHistory: false)?.studyList == 22)
        #expect(BrowserRowHeights.forMode(-1, horizontalHistory: false)?.thumbnailCell == CGSize(width: 105 * 0.8, height: 113 * 0.8))
        #expect(BrowserRowHeights.forMode(2, horizontalHistory: false) == nil)
    }

    @Test func aFolderSizeIsSavedOnlyWhenThereIsNone() {
        #expect(DatabaseFolderSize.effective(saved: 0) == (10000, true))
        #expect(DatabaseFolderSize.effective(saved: 500) == (500, false))
        #expect(DatabaseFolderSize.effective(saved: -3) == (-3, false))
    }
}
