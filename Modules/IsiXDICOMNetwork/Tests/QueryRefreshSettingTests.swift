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
@testable import IsiXDICOMNetwork

/// The refresh interval read from the preferences, and the countdown the
/// Query window shows from it.
struct QueryRefreshSettingTests {
    @Test func theIntervalsTheWindowOffersAreKept() {
        for setting in [0, -5, -10, -30, 1, 5, 10, 30, 60] {
            #expect(QueryRefreshSetting.clamped(setting) == setting)
        }
    }

    @Test func anOutOfRangeIntervalIsKeptWithinOneDay() {
        #expect(QueryRefreshSetting.clamped(Int.max) == 1_440)
        #expect(QueryRefreshSetting.clamped(Int(Int32.max) + 1) == 1_440)
        #expect(QueryRefreshSetting.clamped(Int.min) == -86_400)
        #expect(QueryRefreshSetting.clamped(-86_401) == -86_400)
        #expect(QueryRefreshSetting.clamped(1_441) == 1_440)
        // The seconds of a clamped interval are one day, and fit the countdown.
        #expect(AutoQueryInstance.seconds(ofRefreshSetting: QueryRefreshSetting.clamped(Int.max)) == 86_400)
        #expect(AutoQueryInstance.seconds(ofRefreshSetting: QueryRefreshSetting.clamped(Int.min)) == 86_400)
    }

    @Test func theCountdownReadsAsBefore() {
        #expect(QueryRefreshSetting.countdownText(seconds: 0) == "00:00")
        #expect(QueryRefreshSetting.countdownText(seconds: 65) == "01:05")
        #expect(QueryRefreshSetting.countdownText(seconds: 3_600) == "60:00")
        #expect(QueryRefreshSetting.countdownText(seconds: 86_400) == "1440:00")
    }

    @Test func aCountdownTooLongForAnInt32IsShownWithoutTrapping() {
        // Int32(seconds / 60) trapped for these.
        #expect(QueryRefreshSetting.countdownText(seconds: Int.max) == "153722867280912930:07")
        #expect(QueryRefreshSetting.countdownText(seconds: 60 * (Int(Int32.max) + 1)) == "2147483648:00")
    }
}
