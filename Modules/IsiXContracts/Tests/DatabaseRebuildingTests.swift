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
import IsiXContracts
import Testing

/// The refusal and the work of the real adapter are in tests/test-database-rebuild-failure.py.
private final class RecordingDouble: DatabaseRebuilding, @unchecked Sendable {
    var rebuildAllowed: Bool { true }
    private(set) var calls: [String] = []
    func rebuildIndex(complete: Bool) { calls.append("index \(complete)") }
    func rebuildSQLFile() { calls.append("sql") }
    func checkReportsConsistency() { calls.append("reports") }
}

@Suite struct DatabaseRebuildingTests {
    @Test func aModuleCanUseThePortWithoutTheApp() {
        let double = RecordingDouble()
        let rebuilding: any DatabaseRebuilding = double
        rebuilding.rebuildIndex(complete: false)
        rebuilding.rebuildSQLFile()
        rebuilding.checkReportsConsistency()
        #expect(double.calls == ["index false", "sql", "reports"])
    }
}
