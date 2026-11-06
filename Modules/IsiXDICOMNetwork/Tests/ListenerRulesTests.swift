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
@testable import IsiXDICOMNetwork

/// The listener's rules: its AE title, its limits, what it answers, where a
/// C-MOVE goes and what the network log says. Their use by the DCMTK adapter
/// is tests/test-listener-configuration.py and tests/test-dcmtk-scp-adapter.py.
struct ListenerRulesTests {

    @Test func theAETitleIsTrimmedAndBounded() {
        #expect(ListenerAETitleRules.trimmed("  ISIX VIEWER  ") == "ISIX VIEWER")
        #expect(ListenerAETitleRules.trimmed(nil) == "")
        #expect(ListenerAETitleRules.problem(with: "ABCDEFGHIJKLMNOP") == nil)
        let empty = ListenerAETitleRules.problem(with: "")
        #expect(empty?.contains("Preferences > Listener") == true)
        let long = ListenerAETitleRules.problem(with: "ABCDEFGHIJKLMNOPQ")
        #expect(long?.contains("ABCDEFGHIJKLMNOPQ") == true && long?.contains("16 characters") == true)
        #expect(ListenerAETitleRules.turnOffAdvice.contains("turn it off"))
    }

    @Test func aCalledTitleMatchesWithoutItsPadding() {
        func matches(_ called: String, _ configured: String) -> Bool {
            ListenerAETitleRules.matches(called: Array(called.utf8), configured: Array(configured.utf8))
        }
        #expect(matches("ISIX", "ISIX"))
        #expect(matches("  ISIX  ", "ISIX"))
        #expect(matches("ISIX", " ISIX "))
        #expect(!matches("isix", "ISIX"))
        #expect(!matches("ISI", "ISIX"))
        #expect(!matches("IS IX", "ISIX"))
        #expect(!matches("", ""))
        #expect(!matches("   ", "  "))
    }

    @Test func theLimitsFollowThePreferences() {
        #expect(ListenerLimits.timeout(configured: 0) == 2 && ListenerLimits.timeout(configured: 30) == 30)
        #expect(ListenerLimits.connectionTimeout(configured: 0, timeout: 30) == 30)
        #expect(ListenerLimits.connectionTimeout(configured: 5, timeout: 30) == 5)
        #expect(ListenerLimits.maximumAssociations(configured: 0) == 8)
        #expect(ListenerLimits.maximumAssociations(configured: 3) == 3)
        #expect(ListenerLimits.admits(active: 2, maximum: 3, stopping: false))
        #expect(!ListenerLimits.admits(active: 3, maximum: 3, stopping: false))
        #expect(!ListenerLimits.admits(active: 0, maximum: 3, stopping: true))
    }

    @Test func findAndGetAreAnsweredOnlyWhenTurnedOn() {
        #expect(ListenerAcceptance.services == ["1.2.840.10008.1.1", "1.2.840.10008.5.1.4.1.2.2.1",
                                                "1.2.840.10008.5.1.4.1.2.2.2", "1.2.840.10008.5.1.4.1.2.2.3"])
        for command in [ListenerCommand.echo, .store, .move] {
            #expect(ListenerAcceptance.answers(command, findEnabled: false, getEnabled: false))
        }
        #expect(!ListenerAcceptance.answers(.find, findEnabled: false, getEnabled: true))
        #expect(ListenerAcceptance.answers(.find, findEnabled: true, getEnabled: false))
        #expect(!ListenerAcceptance.answers(.get, findEnabled: true, getEnabled: false))
        #expect(ListenerAcceptance.answers(.get, findEnabled: false, getEnabled: true))
        #expect(ListenerCommand.get.name == "C-GET" && ListenerCommand.store.name == "C-STORE")
    }

    @Test func aMoveDestinationIsAnAETitleThenAName() {
        let titles: [Any?] = ["PACS", NSNull(), "WORKSTATION"]
        let names: [Any?] = ["Main", "WORKSTATION", "Other"]
        #expect(MoveDestinationRule.index(of: "WORKSTATION", aeTitles: titles, names: names) == 2)
        #expect(MoveDestinationRule.index(of: "Other", aeTitles: titles, names: names) == 2)
        #expect(MoveDestinationRule.index(of: "pacs", aeTitles: titles, names: names) == nil)
        #expect(MoveDestinationRule.index(of: "NOWHERE", aeTitles: titles, names: names) == nil)
    }

    @Test func theNetworkLogNamesThePartiesAndBoundsTheValues() {
        #expect(ListenerLogRules.retrieveParties(callingAETitle: "CALLER", moveDestination: []) == "CALLER")
        #expect(ListenerLogRules.retrieveParties(callingAETitle: "CALLER", moveDestination: Array("CALLER".utf8)) == "CALLER")
        #expect(ListenerLogRules.retrieveParties(callingAETitle: "CALLER", moveDestination: Array("DEST".utf8)) == "CALLER / DEST")
        #expect(ListenerLogRules.retrieveParties(callingAETitle: nil, moveDestination: []) == "(null)")
        #expect(ListenerLogRules.receivedCharacterSets(nil) == ["ISO_IR 100"])
        #expect(ListenerLogRules.receivedCharacterSets("\\ISO 2022 IR 87") == ["", "ISO 2022 IR 87"])
        #expect(ListenerLogRules.receivedCharacterSets(Array(repeating: "ISO_IR 100", count: 10).joined(separator: "\\")).isEmpty)
        #expect(ListenerLogRules.bounded(Array(repeating: 65, count: 5000)).count == 1023)
        #expect(ListenerLogRules.bounded(nil).isEmpty)
        #expect(ListenerLogRules.receivedDescription(study: Array("BRAIN".utf8), series: Array("AXIAL".utf8)) == Array("BRAIN AXIAL".utf8))
        #expect(ListenerLogRules.receivedDescription(study: Array("BRAIN".utf8), series: nil) == Array("BRAIN".utf8))
        #expect(ListenerLogRules.receivedDescription(study: Array(repeating: 66, count: 2000), series: Array("S".utf8)).count == 1023)
    }
}
