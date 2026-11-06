//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import IsiXImaging
import IsiXPreferences

/// The colour table the 2D viewers applied last, by the value stored for it:
/// applying it again (switching between a table and none, or across viewers)
/// takes its 768 levels and its black index from here instead of reading them
/// again. A table that changed, or was replaced under the same name, has
/// another stored value and is read anew, so a viewer always shows what the
/// preference holds. One for the process, on the main actor with the viewers;
/// the process graph makes it, from any thread.
@MainActor final class ColourTableCache {

    private var last: (stored: PropertyListValue, entry: ColourTableBook.Entry)?

    nonisolated init() {}

    /// The table `stored` gives a viewer; nil when it is not one it applies.
    func entry(for stored: PropertyListValue) -> ColourTableBook.Entry? {
        if let last, last.stored == stored { return last.entry }
        guard let entry = ColourTableBook.Entry(stored: stored.object) else { return nil }
        last = (stored, entry)
        return entry
    }
}
