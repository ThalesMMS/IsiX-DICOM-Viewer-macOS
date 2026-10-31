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

/// Whether an update of a database shared by another computer replaces the
/// index the database reads.
///
/// The database reads a copy of the other computer's index; each update
/// downloads it again and opens it in a new store, and the store it replaces
/// goes once nothing uses it. A viewer shows objects of the store it opened
/// from: replaced under it, its studies and series stop answering. No update
/// starts while a 2D viewer is open, but one that started before a viewer of
/// the database opened finishes after it. Such an update used to hide every 2D
/// viewer, whose windows came back only when something tiled them, with their
/// objects already in the replaced store.
///
/// While viewers of the database are open, the index they read stays and the
/// one the update brought is dropped; the database's timer updates it once
/// they are closed.
public enum SharedIndexReplacement {

    /// - Parameter openViewersOfDatabase: the 2D viewers shown, not closing,
    ///   whose images are this database's.
    public static func replacesIndex(openViewersOfDatabase: Int) -> Bool {
        openViewersOfDatabase <= 0
    }
}
