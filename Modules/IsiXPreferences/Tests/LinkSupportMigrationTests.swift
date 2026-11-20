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
@testable import IsiXPreferences

// What the first launch that tells the links from the XML-RPC server stores,
// from the user's own values of the three keys.

@Suite struct LinkSupportMigrationTests {
    private typealias Writes = LinkSupportMigration.Writes

    @Test func settingsWithTheServerOnKeepTheLinksAndTheScopeTheServerAnswered() {
        // Carried over from Horos, or of an earlier version: on, and no scope ever stored.
        #expect(LinkSupportMigration.writes(storedLinkSupport: nil, storedServer: true, storedAccessScope: nil)
                == Writes(linkSupport: true, accessScope: 2))
        // As text, the way an earlier version wrote a switch.
        #expect(LinkSupportMigration.writes(storedLinkSupport: nil, storedServer: "1", storedAccessScope: nil)
                == Writes(linkSupport: true, accessScope: 2))
        #expect(LinkSupportMigration.writes(storedLinkSupport: nil, storedServer: "YES", storedAccessScope: nil)
                == Writes(linkSupport: true, accessScope: 2))
        #expect(LinkSupportMigration.formerScope == 2)
    }

    @Test func aScopeTheUserChoseIsLeftAsItIs() {
        for scope in [0, 1, 2] {
            #expect(LinkSupportMigration.writes(storedLinkSupport: nil, storedServer: true, storedAccessScope: scope)
                    == Writes(linkSupport: true, accessScope: nil), "scope \(scope)")
        }
    }

    @Test func settingsWithTheServerOffStoreTheLinksOffAndNoScope() {
        // A first launch, and a server never turned on: the scope stays the registered one, this Mac only.
        for server: Any? in [nil, false, "0", 0] {
            #expect(LinkSupportMigration.writes(storedLinkSupport: nil, storedServer: server, storedAccessScope: nil)
                    == Writes(linkSupport: false, accessScope: nil))
        }
        // The scope chosen while the server was off stays too.
        #expect(LinkSupportMigration.writes(storedLinkSupport: nil, storedServer: false, storedAccessScope: 2)
                == Writes(linkSupport: false, accessScope: nil))
    }

    @Test func nothingIsWrittenOnceTheSwitchOfTheLinksIsStored() {
        // Whatever it says: a server turned on later does not turn the links on, nor open its scope.
        for links: Any in [false, true, "0", 0] {
            #expect(LinkSupportMigration.writes(storedLinkSupport: links, storedServer: true, storedAccessScope: nil) == nil)
            #expect(LinkSupportMigration.writes(storedLinkSupport: links, storedServer: nil, storedAccessScope: nil) == nil)
        }
    }

    @Test func theRegisteredValuesAreClosed() {
        let factory = DefaultPreferences.defaults(in: testEnvironment, store: MemoryPreferences()) as? [String: Any] ?? [:]
        #expect(factory["httpXMLRPCServer"].map { "\($0)" } == "0")
        #expect(factory["httpXMLRPCServerAccessScope"].map { "\($0)" } == "0")
        #expect(factory["LinkSchemeSupport"].map { "\($0)" } == "0")
    }
}
