//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

/// How the series of the open studies are told apart: a colour names the
/// study, a number the series, and a frame the active window.
///
/// The number of a series is its place in its own study, in the order the
/// series list shows it, so it is the same on the thumbnail and on every
/// window that shows the series, and does not depend on which windows are open.
public enum SeriesIdentity {

    /// Which of a patient's open studies a window shows.
    public enum Study: Sendable, Equatable {
        /// The newest open study of the patient, or the only one.
        case current
        /// A study older than another open study of the same patient.
        case previous
    }

    /// A window that shows a series.
    public struct Window: Sendable, Equatable {
        public var study: Study
        /// The window the user works in.
        public var isActive: Bool

        public init(study: Study, isActive: Bool) {
            self.study = study
            self.isActive = isActive
        }
    }

    /// What the list draws on the thumbnail of a series.
    public struct Mark: Sendable, Equatable {
        /// From 1, in the list's order within the study.
        public var number: Int
        /// The study's colour while a window shows the series; nil, the
        /// neutral colour of a series no window shows.
        public var colour: Study?
        /// The study's colour around the thumbnail while the active window
        /// shows the series; nil, no frame.
        public var frame: Study?

        public init(number: Int, colour: Study?, frame: Study?) {
            self.number = number
            self.colour = colour
            self.frame = frame
        }
    }

    /// The number of the series at `place`, from 0, of its study's series.
    public static func number(atPlace place: Int) -> Int {
        place + 1
    }

    /// The mark of the series at `place` of its study's series, which
    /// `windows` show.
    public static func mark(atPlace place: Int, windows: [Window]) -> Mark {
        Mark(number: number(atPlace: place), colour: windows.first?.study, frame: windows.first(where: \.isActive)?.study)
    }
}
