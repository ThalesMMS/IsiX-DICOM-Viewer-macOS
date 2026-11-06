//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

extension StudyColour {
    /// What the views of one 2D viewer show of its study among the patient's:
    /// the colour of its frame and number box, and its number, newest first.
    public struct Mark: Sendable, Equatable {
        /// The colour's place in the palette; nil for no colour.
        public let colourIndex: Int?
        /// The study's place among the patient's studies, newest first; nil when it is not among them.
        public let dateIndex: Int?

        public init(colourIndex: Int?, dateIndex: Int?) {
            self.colourIndex = colourIndex
            self.dateIndex = dateIndex
        }
    }

    /// The marks of the displayed 2D viewers, in their order.
    ///
    /// - Parameters:
    ///   - viewerStudies: each viewer's study instance UID.
    ///   - colouredStudies: the UIDs of the studies of the viewers that show a
    ///     series; only these take a colour.
    ///   - patientStudies: the UIDs of the patient's studies, newest first
    ///     (nil for one without a UID).
    ///   - colourCount: the colours of the palette; a study past the last takes the last.
    /// - Returns: nil while the patient has one study at most: the views then
    ///   show no colour and no number.
    public static func marks(viewerStudies: [String?], colouredStudies: [String?], patientStudies: [String?],
                             colourCount: Int) -> [Mark]? {
        var colours: [String: Int] = [:]
        for case let uid? in colouredStudies where colours[uid] == nil {
            guard let index = patientStudies.firstIndex(of: uid), colourCount > 0 else { continue }
            colours[uid] = min(index, colourCount - 1)
        }
        guard patientStudies.count > 1 else { return nil }
        return viewerStudies.map { uid in
            Mark(colourIndex: uid.flatMap { colours[$0] }, dateIndex: uid.flatMap { patientStudies.firstIndex(of: $0) })
        }
    }
}
