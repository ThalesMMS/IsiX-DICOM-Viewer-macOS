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

/// What plugins may reach on the network, and the identifiers of their C-FINDs.
struct PluginNetworkAccessTests {
    let servers: [Any] = [
        ["AETitle": "PACS", "Address": "Archive.Local", "Port": "104", "Description": "Archive", "Send": true, "QR": true,
         "TLSEnabled": true] as [String: Any],
        ["AETitle": "SENDONLY", "Address": "127.0.0.1", "Port": 11112, "Send": true, "QR": false] as [String: Any],
        ["AETitle": "OFF", "Address": "127.0.0.1", "Port": 4242, "Activated": false] as [String: Any],
        ["AETitle": "WEB", "Address": "web.local", "Port": 80, "retrieveMode": 3] as [String: Any],
        ["AETitle": " ", "Address": "127.0.0.1", "Port": 104] as [String: Any],
        ["AETitle": "NOPORT", "Address": "127.0.0.1"] as [String: Any],
        ["AETitle": "PACS", "Address": "archive.local", "Port": 104, "Description": "Duplicate"] as [String: Any],
        "not a node",
    ]

    @Test func onlyConfiguredActivatedDIMSENodesAreListed() {
        let nodes = PluginNetworkAccess.nodes(fromServers: servers)
        #expect(nodes.map(\.identifier) == ["PACS@archive.local:104", "SENDONLY@127.0.0.1:11112"])
        #expect(nodes[0] == PluginNode(identifier: "PACS@archive.local:104", name: "Archive", aeTitle: "PACS", host: "Archive.Local",
                                       port: 104, usesTLS: true, sends: true, queries: true))
        #expect(nodes[1].name == "SENDONLY" && nodes[1].sends && !nodes[1].queries && !nodes[1].usesTLS)
    }

    @Test func aServiceNeedsTheNodeToAllowIt() {
        #expect(PluginNetworkAccess.entry(withIdentifier: "PACS@archive.local:104", for: .query, inServers: servers)?["Description"] as? String
                == "Archive")
        #expect(PluginNetworkAccess.entry(withIdentifier: "SENDONLY@127.0.0.1:11112", for: .send, inServers: servers) != nil)
        #expect(PluginNetworkAccess.entry(withIdentifier: "SENDONLY@127.0.0.1:11112", for: .query, inServers: servers) == nil)
        #expect(PluginNetworkAccess.entry(withIdentifier: "OFF@127.0.0.1:4242", for: .send, inServers: servers) == nil)
        #expect(PluginNetworkAccess.entry(withIdentifier: "WEB@web.local:80", for: .send, inServers: servers) == nil)
        #expect(PluginNetworkAccess.entry(withIdentifier: "EVIL@203.0.113.9:104", for: .send, inServers: servers) == nil)
    }

    @Test func aLegacyAddressMatchesOnlyAConfiguredNode() {
        #expect(PluginNetworkAccess.identifier(matchingAETitle: "PACS", host: "ARCHIVE.local", port: 104, for: .send, inServers: servers)
                == "PACS@archive.local:104")
        #expect(PluginNetworkAccess.identifier(matchingAETitle: "PACS", host: "archive.local", port: 105, for: .send, inServers: servers) == nil)
        #expect(PluginNetworkAccess.identifier(matchingAETitle: "OTHER", host: "archive.local", port: 104, for: .send, inServers: servers) == nil)
        #expect(PluginNetworkAccess.identifier(matchingAETitle: "SENDONLY", host: "127.0.0.1", port: 11112, for: .query, inServers: servers) == nil)
        #expect(PluginNetworkAccess.identifier(matchingAETitle: nil, host: "127.0.0.1", port: 11112, for: .send, inServers: servers) == nil)
    }

    @Test func studySeriesAndWorklistIdentifiers() throws {
        let day = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 29, hour: 12).date!
        let study = try PluginQueryKeys.identifier(level: .study, filters: .init(patientName: "DOE*", dateFrom: day, dateTo: day))
        #expect(study.first == PluginQueryKeys.Key(.queryRetrieveLevel, "QueryRetrieveLevel", value: "STUDY"))
        #expect(study.first { $0.keyword == "PatientName" }?.value == "DOE*")
        #expect(study.first { $0.keyword == "StudyDate" }?.value == "20261029")
        #expect(study.allSatisfy { !$0.inScheduledStep })

        #expect(throws: PluginQueryKeys.Failure.seriesNeedStudy) { try PluginQueryKeys.identifier(level: .series, filters: .init()) }
        let series = try PluginQueryKeys.identifier(level: .series, filters: .init(studyInstanceUID: "1.2.3", modality: "CT"))
        #expect(series.map(\.keyword).contains("SeriesInstanceUID") && series.first { $0.keyword == "Modality" }?.value == "CT")

        let worklist = try PluginQueryKeys.identifier(level: .worklist,
                                                      filters: .init(modality: "MR", dateFrom: day, scheduledStationAETitle: "SCANNER"))
        #expect(!worklist.contains { $0.keyword == "QueryRetrieveLevel" })
        #expect(worklist.filter(\.inScheduledStep).map(\.keyword) == [
            "ScheduledStationAETitle", "ScheduledProcedureStepStartDate", "ScheduledProcedureStepStartTime", "Modality",
            "ScheduledPerformingPhysicianName", "ScheduledProcedureStepDescription", "ScheduledProcedureStepID",
        ])
        #expect(worklist.first { $0.keyword == "ScheduledProcedureStepStartDate" }?.value == "20261029-")
        #expect(worklist.first { $0.keyword == "ScheduledStationAETitle" }?.value == "SCANNER")
        #expect(PluginQueryKeys.abstractSyntax(for: .worklist) == "1.2.840.10008.5.1.4.31")
        #expect(PluginQueryKeys.abstractSyntax(for: .series) == "1.2.840.10008.5.1.4.1.2.2.1")
    }

    @Test func filtersThatWouldChangeTheQueryAreRefused() throws {
        #expect(throws: PluginQueryKeys.Failure.invalidFilter("A\\B")) {
            try PluginQueryKeys.identifier(level: .study, filters: .init(patientID: "A\\B"))
        }
        #expect(throws: PluginQueryKeys.Failure.invalidFilter("x\ny")) {
            try PluginQueryKeys.identifier(level: .worklist, filters: .init(patientName: "x\ny"))
        }
        let accented = try PluginQueryKeys.identifier(level: .study, filters: .init(patientName: "JOSÉ*"))
        #expect(PluginQueryKeys.needsUTF8(accented))
        #expect(!PluginQueryKeys.needsUTF8(try PluginQueryKeys.identifier(level: .study, filters: .init(patientName: "JOSE*"))))
    }
}
