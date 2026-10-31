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
@testable import IsiXDatabase

@Suite struct IndexRebuildsUnderWayTests {
    @Test func quittingWaitsUntilTheLastRebuildEnds() {
        let rebuilds = IndexRebuildsUnderWay()
        #expect(rebuilds.isEmpty)
        rebuilds.begin()
        rebuilds.begin()
        #expect(!rebuilds.isEmpty)
        rebuilds.end()
        #expect(!rebuilds.isEmpty)
        rebuilds.end()
        #expect(rebuilds.isEmpty)
    }

    @Test func anEndWithoutABeginLeavesNothingUnderWay() {
        let rebuilds = IndexRebuildsUnderWay()
        rebuilds.end()
        rebuilds.begin()
        #expect(!rebuilds.isEmpty)
        rebuilds.end()
        #expect(rebuilds.isEmpty)
    }
}
