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

// The opacity tables of a 2D viewer's thick slab, as the "OPACITY" preference
// stores them by name: a dictionary with the opacity editor's "Points", each
// the text NSStringFromPoint wrote. The app reads and writes the preference
// through its typed key and hands each entry over as the property list it is.

/// The stored opacity tables of the 2D viewers, entry by entry.
public struct OpacityTableBook: Sendable {

    /// What a stored table gives a viewer.
    public struct Entry: Sendable, Equatable {
        /// The editor's points, nil when the table has none. A point that is
        /// not text is the empty text, which the views read as the point (0, 0),
        /// as they read it before.
        public let points: [String]?

        public init(points: [String]?) {
            self.points = points
        }

        /// The entry of a stored table; nil when it is not a dictionary.
        public init?(stored: Any?) {
            guard let preset = stored as? [String: Any] else { return nil }
            points = (preset[OpacityTableBook.pointsKey] as? [Any]).map { $0.map { $0 as? String ?? "" } }
        }

        /// Whether the slices get a table of opacities: not for a table without points.
        public var givesSlicesATable: Bool {
            !(points ?? []).isEmpty
        }
    }

    public static let pointsKey = "Points"

    /// The stored form of a table the opacity editor made.
    public static func storedForm(points: [Any]) -> [String: Any] {
        [pointsKey: points]
    }
}
