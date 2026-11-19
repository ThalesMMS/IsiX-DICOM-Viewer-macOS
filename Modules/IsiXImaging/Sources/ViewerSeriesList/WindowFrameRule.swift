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

/// A study as the frame of a window compares it: which one, and of what day.
public struct StudyReference: Sendable, Equatable {
    public var uid: String
    public var date: Date?

    public init(uid: String, date: Date?) {
        self.uid = uid
        self.date = date
    }
}

/// The studies of a 2D window: the one it was opened with and the one it
/// shows. A series taken from the window's own lists changes the second only,
/// so the window can tell that it no longer shows the study it was opened for.
public struct WindowStudies: Sendable, Equatable {
    /// The study of the opening the user asked for last; nil before any.
    public private(set) var opening: StudyReference?
    /// The study the window shows; nil while it shows none.
    public private(set) var shown: StudyReference?

    public init() {}

    /// The window shows `study`. The first study it shows is the one it was
    /// opened with.
    public mutating func show(_ study: StudyReference?) {
        shown = study
        if opening == nil { opening = study }
    }

    /// An opening the user asked for put the study shown in the window: it is
    /// the one the window was opened with from now on.
    public mutating func reopen() {
        if shown != nil { opening = shown }
    }

    /// Whether the window shows a study other than the one it was opened with.
    public var showsAnotherStudy: Bool {
        guard let opening, let shown else { return false }
        return opening.uid != shown.uid
    }

    /// Whether the study shown is of an earlier day than the one the window
    /// was opened with. Two studies of one day are not older than each other,
    /// and a study without a date is older than none.
    public func shownIsOlder(calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        guard showsAnotherStudy, let then = shown?.date, let reference = opening?.date else { return false }
        return calendar.startOfDay(for: then) < calendar.startOfDay(for: reference)
    }
}

/// The frame around the views of a 2D window and around the thumbnail of its
/// series: who has one, of which colour and how wide. The image and the series
/// list ask the same rule, so the two never disagree.
///
/// With several windows on screen the frame tells the active one. With one
/// window there is nothing to tell apart, and the frame says something else:
/// that the window shows a study other than the one it was opened with.
public enum WindowFrameRule {

    // MARK: - Widths

    /// The width of the frame of the active window, in points.
    public static let activeWidth = 3.0
    /// The width of the frame of the other windows, in points.
    public static let inactiveWidth = 2.0
    /// The room between the frame and the annotations, in points.
    public static let annotationClearance = 2.0

    /// What the annotations of a view that can have a frame leave free along
    /// each of its sides, in points, frame or no frame: the text does not move
    /// when the frame comes or goes.
    public static var annotationReserve: Double { activeWidth + annotationClearance }

    public static func width(active: Bool) -> Double {
        active ? activeWidth : inactiveWidth
    }

    // MARK: - The windows on screen

    /// What a 2D window says of itself.
    public struct Presence: Sendable, Equatable {
        public var isVisible: Bool
        public var isMiniaturized: Bool
        /// A window on another display is on the active Space of that display.
        public var isOnActiveSpace: Bool
        public var isClosing: Bool
        public var isFullScreen: Bool

        public init(isVisible: Bool, isMiniaturized: Bool, isOnActiveSpace: Bool, isClosing: Bool = false, isFullScreen: Bool = false) {
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
            self.isOnActiveSpace = isOnActiveSpace
            self.isClosing = isClosing
            self.isFullScreen = isFullScreen
        }
    }

    /// Whether the user sees the window among the others: ordered in, not in
    /// the Dock, on the Space shown, not closing, and not the full screen one.
    public static func isOnScreen(_ window: Presence) -> Bool {
        window.isVisible && !window.isMiniaturized && window.isOnActiveSpace && !window.isClosing && !window.isFullScreen
    }

    /// Whether more than one of `windows` is on screen. The windows are asked
    /// in order, and no further than the second one that is.
    public static func severalOnScreen(_ windows: some Sequence<Presence>) -> Bool {
        var seen = false
        for window in windows where isOnScreen(window) {
            if seen { return true }
            seen = true
        }
        return false
    }

    // MARK: - The frame

    public enum Frame: Sendable, Equatable {
        /// No frame.
        case none
        /// The thin frame of a view that is not the active one.
        case neutral
        /// The frame of the active view, in the colour of a study.
        case study(SeriesIdentity.Study)
    }

    /// The frame of a view of a window, or of the thumbnail of its series.
    ///
    /// - `severalOnScreen`: more than one 2D window is on screen.
    /// - `isActive`: the view is the key one of the front window; asked only
    ///   where a frame is drawn.
    /// - `study`: which of the patient's open studies the window shows.
    /// - `studies`: the study the window was opened with and the one it shows.
    public static func frame(severalOnScreen: Bool, isActive: @autoclosure () -> Bool, study: SeriesIdentity.Study,
                             studies: WindowStudies) -> Frame {
        if severalOnScreen {
            return isActive() ? .study(study) : .neutral
        }
        guard studies.showsAnotherStudy else { return .none }
        // Alone, no other window says which study is the older one: the one
        // the window was opened with does.
        return isActive() ? .study(studies.shownIsOlder() ? .previous : .current) : .neutral
    }
}
