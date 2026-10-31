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
import IsiXDatabase

@Suite struct SharedIndexReplacementTests {

    @Test func anIndexNoViewerReadsIsReplaced() {
        #expect(SharedIndexReplacement.replacesIndex(openViewersOfDatabase: 0))
    }

    @Test func theViewersOfTheDatabaseKeepTheIndexTheyRead() {
        // An update started before the viewers opened and finished after them.
        #expect(!SharedIndexReplacement.replacesIndex(openViewersOfDatabase: 1))
        #expect(!SharedIndexReplacement.replacesIndex(openViewersOfDatabase: 2))
    }
}
