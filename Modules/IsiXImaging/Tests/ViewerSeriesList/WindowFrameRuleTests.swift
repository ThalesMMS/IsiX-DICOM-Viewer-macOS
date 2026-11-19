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

@Suite struct WindowFrameRuleTests {
    typealias Presence = WindowFrameRule.Presence
    typealias Frame = WindowFrameRule.Frame

    private let onScreen = Presence(isVisible: true, isMiniaturized: false, isOnActiveSpace: true)

    private func day(_ offset: Int, hour: Int = 10) -> Date {
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour) = (2026, 3, 10 + offset, hour)
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    /// A window opened with `opening` that now shows `shown`.
    private func studies(opening: StudyReference?, shown: StudyReference?) -> WindowStudies {
        var studies = WindowStudies()
        studies.show(opening)
        studies.show(shown)
        return studies
    }

    private var recent: StudyReference { StudyReference(uid: "1.2.2", date: day(0)) }
    private var older: StudyReference { StudyReference(uid: "1.2.1", date: day(-30)) }
    private var newer: StudyReference { StudyReference(uid: "1.2.3", date: day(30)) }

    // MARK: The windows on screen

    @Test func aWindowIsOnScreenWhenTheUserSeesItAmongTheOthers() {
        #expect(WindowFrameRule.isOnScreen(onScreen))
        // Ordered out, in the Dock, on another Space, closing, or the full screen one.
        #expect(!WindowFrameRule.isOnScreen(Presence(isVisible: false, isMiniaturized: false, isOnActiveSpace: true)))
        #expect(!WindowFrameRule.isOnScreen(Presence(isVisible: true, isMiniaturized: true, isOnActiveSpace: true)))
        #expect(!WindowFrameRule.isOnScreen(Presence(isVisible: true, isMiniaturized: false, isOnActiveSpace: false)))
        #expect(!WindowFrameRule.isOnScreen(Presence(isVisible: true, isMiniaturized: false, isOnActiveSpace: true, isClosing: true)))
        #expect(!WindowFrameRule.isOnScreen(Presence(isVisible: true, isMiniaturized: false, isOnActiveSpace: true, isFullScreen: true)))
    }

    @Test func onlyTheWindowsOnScreenAreCounted() {
        let miniaturized = Presence(isVisible: false, isMiniaturized: true, isOnActiveSpace: true)
        let elsewhere = Presence(isVisible: true, isMiniaturized: false, isOnActiveSpace: false)
        let closing = Presence(isVisible: true, isMiniaturized: false, isOnActiveSpace: true, isClosing: true)
        let fullScreen = Presence(isVisible: true, isMiniaturized: false, isOnActiveSpace: true, isFullScreen: true)
        #expect(!WindowFrameRule.severalOnScreen([]))
        #expect(!WindowFrameRule.severalOnScreen([onScreen]))
        #expect(WindowFrameRule.severalOnScreen([onScreen, onScreen]))
        // A second window in the Dock, on another Space, closing or full screen: one window.
        for other in [miniaturized, elsewhere, closing, fullScreen] {
            #expect(!WindowFrameRule.severalOnScreen([onScreen, other]))
            #expect(!WindowFrameRule.severalOnScreen([other, onScreen]))
            #expect(WindowFrameRule.severalOnScreen([onScreen, other, onScreen]))
        }
        #expect(!WindowFrameRule.severalOnScreen([miniaturized, elsewhere, closing, fullScreen]))
    }

    @Test func theWindowsAreAskedNoFurtherThanTheSecondOnScreen() {
        var asked = 0
        let windows = (0..<5).lazy.map { _ -> Presence in
            asked += 1
            return self.onScreen
        }
        #expect(WindowFrameRule.severalOnScreen(windows))
        #expect(asked == 2)
    }

    // MARK: The study a window was opened with

    @Test func theFirstStudyShownIsTheOneTheWindowWasOpenedWith() {
        var studies = WindowStudies()
        #expect(studies.opening == nil && studies.shown == nil && !studies.showsAnotherStudy)
        studies.show(recent)
        #expect(studies.opening == recent && studies.shown == recent && !studies.showsAnotherStudy)
        // Another series of the same study, from the window's own list.
        studies.show(recent)
        #expect(studies.opening == recent && !studies.showsAnotherStudy)
        // A series of another study, from the window's own list.
        studies.show(older)
        #expect(studies.opening == recent && studies.shown == older && studies.showsAnotherStudy)
        // Back to the study it was opened with.
        studies.show(recent)
        #expect(studies.opening == recent && !studies.showsAnotherStudy)
    }

    @Test func anOpeningAskedForMakesTheStudyShownTheOpeningOne() {
        var studies = WindowStudies()
        studies.show(recent)
        studies.show(older)
        #expect(studies.showsAnotherStudy)
        studies.reopen()
        #expect(studies.opening == older && studies.shown == older && !studies.showsAnotherStudy)
        // A window that shows nothing keeps what it was opened with.
        studies.show(nil)
        studies.reopen()
        #expect(studies.opening == older && !studies.showsAnotherStudy)
        // Nothing opened yet: nothing to make the opening one.
        var empty = WindowStudies()
        empty.reopen()
        #expect(empty.opening == nil)
        empty.show(nil)
        empty.show(newer)
        #expect(empty.opening == newer)
    }

    @Test func aStudyIsOlderByItsDay() {
        #expect(studies(opening: recent, shown: older).shownIsOlder())
        #expect(!studies(opening: recent, shown: newer).shownIsOlder())
        #expect(!studies(opening: recent, shown: recent).shownIsOlder())
        // The same day, hours apart: neither is older.
        let morning = StudyReference(uid: "1.2.4", date: day(0, hour: 7))
        #expect(!studies(opening: recent, shown: morning).shownIsOlder())
        // A study without a date is older than none, and none is older than it.
        let undated = StudyReference(uid: "1.2.5", date: nil)
        #expect(!studies(opening: recent, shown: undated).shownIsOlder())
        #expect(!studies(opening: undated, shown: older).shownIsOlder())
    }

    // MARK: The frame

    @Test func oneWindowOnScreenWithTheStudyItWasOpenedWithHasNoFrame() {
        for active in [true, false] {
            for study in [SeriesIdentity.Study.current, .previous] {
                #expect(WindowFrameRule.frame(severalOnScreen: false, isActive: active, study: study,
                                              studies: studies(opening: recent, shown: recent)) == Frame.none)
            }
        }
        // A window that shows nothing yet.
        #expect(WindowFrameRule.frame(severalOnScreen: false, isActive: true, study: .current, studies: WindowStudies()) == Frame.none)
    }

    @Test func oneWindowOnScreenWithAnotherStudyHasTheFrameOfThatStudy() {
        // An older study than the one it was opened with: the previous study's colour.
        #expect(WindowFrameRule.frame(severalOnScreen: false, isActive: true, study: .current,
                                      studies: studies(opening: recent, shown: older)) == .study(.previous))
        // A more recent one, or one of the same day: the current study's colour.
        #expect(WindowFrameRule.frame(severalOnScreen: false, isActive: true, study: .current,
                                      studies: studies(opening: recent, shown: newer)) == .study(.current))
        #expect(WindowFrameRule.frame(severalOnScreen: false, isActive: true, study: .previous,
                                      studies: studies(opening: recent, shown: StudyReference(uid: "1.2.4", date: day(0, hour: 7)))) == .study(.current))
        // The other views of the window, as beside any active view.
        #expect(WindowFrameRule.frame(severalOnScreen: false, isActive: false, study: .current,
                                      studies: studies(opening: recent, shown: older)) == .neutral)
        // Back to the study it was opened with, or opened again with the other: none.
        var back = studies(opening: recent, shown: older)
        back.show(recent)
        #expect(WindowFrameRule.frame(severalOnScreen: false, isActive: true, study: .current, studies: back) == Frame.none)
        var reopened = studies(opening: recent, shown: older)
        reopened.reopen()
        #expect(WindowFrameRule.frame(severalOnScreen: false, isActive: true, study: .current, studies: reopened) == Frame.none)
    }

    @Test func severalWindowsOnScreenTellTheActiveOne() {
        for studies in [studies(opening: recent, shown: recent), studies(opening: recent, shown: older), WindowStudies()] {
            #expect(WindowFrameRule.frame(severalOnScreen: true, isActive: true, study: .current, studies: studies) == .study(.current))
            #expect(WindowFrameRule.frame(severalOnScreen: true, isActive: true, study: .previous, studies: studies) == .study(.previous))
            #expect(WindowFrameRule.frame(severalOnScreen: true, isActive: false, study: .previous, studies: studies) == .neutral)
        }
    }

    @Test func aSecondWindowInTheDockLeavesTheFirstAsIfAlone() {
        let miniaturized = Presence(isVisible: false, isMiniaturized: true, isOnActiveSpace: true)
        let several = WindowFrameRule.severalOnScreen([onScreen, miniaturized])
        #expect(WindowFrameRule.frame(severalOnScreen: several, isActive: true, study: .current,
                                      studies: studies(opening: recent, shown: recent)) == Frame.none)
        #expect(WindowFrameRule.frame(severalOnScreen: several, isActive: true, study: .current,
                                      studies: studies(opening: recent, shown: older)) == .study(.previous))
        // Out of the Dock again: the active window is told, as before.
        #expect(WindowFrameRule.frame(severalOnScreen: WindowFrameRule.severalOnScreen([onScreen, onScreen]), isActive: true, study: .current,
                                      studies: studies(opening: recent, shown: recent)) == .study(.current))
    }

    @Test func whetherTheViewIsActiveIsAskedOnlyWhereAFrameIsDrawn() {
        var asked = 0
        func active() -> Bool {
            asked += 1
            return true
        }
        _ = WindowFrameRule.frame(severalOnScreen: false, isActive: active(), study: .current, studies: studies(opening: recent, shown: recent))
        #expect(asked == 0)
        _ = WindowFrameRule.frame(severalOnScreen: false, isActive: active(), study: .current, studies: studies(opening: recent, shown: older))
        _ = WindowFrameRule.frame(severalOnScreen: true, isActive: active(), study: .current, studies: studies(opening: recent, shown: recent))
        #expect(asked == 2)
    }

    // MARK: Widths

    @Test func theActiveFrameIsThinAndTheAnnotationsKeepClearOfIt() {
        #expect(WindowFrameRule.width(active: true) == 3)
        #expect(WindowFrameRule.width(active: false) == 2)
        #expect(WindowFrameRule.annotationReserve == 5)
        #expect(WindowFrameRule.annotationReserve >= WindowFrameRule.activeWidth + 2)
    }
}
