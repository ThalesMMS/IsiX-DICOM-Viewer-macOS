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

/// The keys the DICOM network, the listener, the Query and Send windows, DICOMweb and XML-RPC read: each
/// under the name the code and the nibs used, read as the accessor the code called, with the value the
/// application registered or none.
@Suite struct NetworkPreferencesTests {
    private let factory = DefaultPreferences.defaults(in: testEnvironment, store: MemoryPreferences()) as? [String: Any] ?? [:]

    /// The key's name, the type it is read as, and that it is in the catalog.
    private func check<Value>(_ key: PreferenceKey<Value>, _ name: String, _ type: Value.Type,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(key.name == name, sourceLocation: sourceLocation)
        #expect(ObjectIdentifier(key.valueType) == ObjectIdentifier(type), "\(name)", sourceLocation: sourceLocation)
        #expect(NetworkPreferences.catalog.contains { $0.name == name }, "\(name) is not in the catalog", sourceLocation: sourceLocation)
    }

    /// The text the defaults register under `name`, nil when none.
    private func registered(_ name: String) -> String? {
        factory[name].map { "\($0)" }
    }

    @Test func keysTheNetworkCodeReadsWithARegisteredValue() {
        let keys: [(any CataloguedPreference, String, any PreferenceValue.Type, String)] = [
            (NetworkPreferences.dicomTimeout, "DICOMTimeout", Int.self, "40"),
            (NetworkPreferences.dicomConnectionTimeout, "DICOMConnectionTimeout", Int.self, "10"),
            (NetworkPreferences.queryCharacterSet, "STRINGENCODING", String?.self, "ISO_IR 100"),
            (NetworkPreferences.aePort, "AEPORT", String?.self, "11112"),
            (NetworkPreferences.storeSCP, "STORESCP", Bool.self, "1"),
            (NetworkPreferences.dicomSendAllowed, "DICOMSENDALLOWED", Bool.self, "1"),
            (NetworkPreferences.activateCFINDSCP, "activateCFINDSCP", Bool.self, "1"),
            (NetworkPreferences.activateCGETSCP, "activateCGETSCP", Bool.self, "1"),
            (NetworkPreferences.maximumNumberOfConcurrentDICOMAssociations, "maximumNumberOfConcurrentDICOMAssociations", Int.self, "20"),
            (NetworkPreferences.maximumNumberOfCFindObjects, "maximumNumberOfCFindObjects", Int.self, "10000"),
            (NetworkPreferences.qrRemoveDuplicateEntries, "QRRemoveDuplicateEntries", Bool.self, "1"),
            (NetworkPreferences.cfindBodyPartExaminedSupport, "CFINDBodyPartExaminedSupport", Bool.self, "0"),
            (NetworkPreferences.cfindCommentsAndStatusSupport, "CFINDCommentsAndStatusSupport", Bool.self, "1"),
            (NetworkPreferences.supportsQRModalitiesInStudy, "SupportQRModalitiesinStudy", Bool.self, "1"),
            (NetworkPreferences.dicomQueryAllowsFutureQuery, "DICOMQueryAllowFutureQuery", Bool.self, "1"),
            (NetworkPreferences.allowsBlankQuery, "allow_qr_blank_query", Bool.self, "1"),
            (NetworkPreferences.maxConcurrentPODRetrieves, "MaxConcurrentPODRetrieves", Int.self, "2"),
            (NetworkPreferences.listenerCheckInterval, "LISTENERCHECKINTERVAL", Int.self, "15"),
            (NetworkPreferences.triesImageLevelRetrieveIfLocalImages, "TryIMAGELevelDICOMRetrieveIfLocalImages", Bool.self, "0"),
            (NetworkPreferences.multipleAssociationsRetrieve, "MultipleAssociationsRetrieve", Bool.self, "0"),
            (NetworkPreferences.modalityWorklistRefreshMinutes, "ModalityWorklistRefreshMinutes", Int.self, "0"),
            (NetworkPreferences.preferredSyntaxForIncoming, "preferredSyntaxForIncoming", Int.self, "2"),
            (NetworkPreferences.singleProcessMultiThreadedListener, "SingleProcessMultiThreadedListener", Bool.self, "1"),
            (NetworkPreferences.sendControllerConcurrentThreads, "SendControllerConcurrentThreads", Int.self, "1"),
            (NetworkPreferences.maximumSendControllerConcurrentThreads, "MaximumSendControllerConcurrentThreads", Int.self, "4"),
            (NetworkPreferences.maximumSendGlobalControllerConcurrentThreads, "MaximumSendGlobalControllerConcurrentThreads", Int.self, "4"),
            (NetworkPreferences.showErrorMessagesForAutorouting, "ShowErrorMessagesForAutorouting", Bool.self, "1"),
            (NetworkPreferences.searchDICOMBonjour, "searchDICOMBonjour", Bool.self, "1"),
            (NetworkPreferences.syncOsiriXDBURL, "syncOsiriXDBURL", String?.self, "http://list.dicom.dcm/OsiriXDB.plist"),
            (NetworkPreferences.progressiveRetrieveViewing, "HorosProgressiveRetrieveViewing", Bool.self, "YES"),
            (NetworkPreferences.xmlrpcServerPort, "httpXMLRPCServerPort", Int.self, "8080"),
            (NetworkPreferences.xmlrpcServerHTTPS, "httpXMLRPCServerHTTPS", Bool.self, "0"),
            (NetworkPreferences.xmlrpcServerDoesNotRespond, "httpXMLRPCServerDoNotRespond", Bool.self, "0"),
            (NetworkPreferences.closeAllWindowsBeforeXMLRPCOpen, "CloseAllWindowsBeforeXMLRPCOpen", Bool.self, "1"),
            (NetworkPreferences.bringOsiriXToFrontAfterReceivingMessage, "bringOsiriXToFrontAfterReceivingMessage", Bool.self, "1"),
        ]
        for (key, name, type, value) in keys {
            #expect(key.name == name)
            #expect(ObjectIdentifier(key.valueType) == ObjectIdentifier(type), "\(name)")
            #expect(registered(name) == value, "\(name) registers \(registered(name) ?? "nothing")")
            #expect(NetworkPreferences.catalog.contains { $0.name == name }, "\(name) is not in the catalog")
        }
    }

    /// Keys nothing registers: absent, they read as false, 0 or nil, as the accessors read them.
    @Test func keysWithoutARegisteredValue() {
        check(NetworkPreferences.hidesListenerErrors, "hideListenerError", Bool.self)
        check(NetworkPreferences.externalStoreSCP, "NinjaSTORESCP", Bool.self)
        check(NetworkPreferences.tlsListenerCertificateVerification, "TLSStoreSCPCertificateVerification", PropertyListValue?.self)
        check(NetworkPreferences.tlsListenerCipherSuites, "TLSStoreSCPCipherSuites", [PropertyListValue]?.self)
        check(NetworkPreferences.moveWithoutJPEG, "DontSupportJPEGForCSMove", Bool.self)
        check(NetworkPreferences.dicomwebTransferCeiling, "DICOMwebTransferCeiling", Double.self)
        check(NetworkPreferences.syncsOsiriXDB, "syncOsiriXDB", Bool.self)
        check(NetworkPreferences.federatedSearchIncludesDefaultDatabase, "HorosDefaultDatabaseFederatedSearch", Bool.self)
        check(NetworkPreferences.keepsDuplicateStudyInstanceUIDs, "dontFilterQueryStudiesForUniqueInstanceUID", Bool.self)
        check(NetworkPreferences.queryPresets, "QRPresets", [String: PropertyListValue]?.self)
        check(NetworkPreferences.queryPresetsIncludeDICOMNodes, "includeDICOMNodes", Bool.self)
        check(NetworkPreferences.savedQuerySettings, "savedDICOMQuerySettings", [String: PropertyListValue]?.self)
        check(NetworkPreferences.autoRetrieving, "autoRetrieving", Bool.self)
        check(NetworkPreferences.restartsAutoQueryAndRetrieve, "restartAutoQueryAndRetrieve", Bool.self)
        check(NetworkPreferences.autoQueryInstances, "savedAutoDICOMQuerySettingsArray", [PropertyListValue]?.self)
        check(NetworkPreferences.querySources, "SavedQueryArray", [PropertyListValue]?.self)
        check(NetworkPreferences.autoQuerySources, "SavedQueryArrayAuto", [PropertyListValue]?.self)
        check(NetworkPreferences.queryLastDateFilter, "QRLastDateFilterValue", Int.self)
        check(NetworkPreferences.queryPatientModeIndex, "QRPatientModeMatrixIndex", Int.self)
        check(NetworkPreferences.autoQueryPatientModeIndex, "AutoQRPatientModeMatrixIndex", Int.self)
        check(NetworkPreferences.queryRefreshSetting, "autoRefreshQueryResults", Int.self)
        check(NetworkPreferences.autoQueryRefreshSetting, "autoRefreshQueryResultsAutoQR", Int.self)
        check(NetworkPreferences.keepsQueryWindowOnTop, "KeepQRWindowOnTop", Bool.self)
        check(NetworkPreferences.betweenDatesMode, "betweenDatesMode", Bool.self)
        check(NetworkPreferences.customIntervalWithHoursAndMinutes, "customIntervalWithHoursAndMinutes", Bool.self)
        check(NetworkPreferences.searchesComparativeStudiesOnDICOMNodes, "searchForComparativeStudiesOnDICOMNodes", Bool.self)
        check(NetworkPreferences.pacsOnDemandNodes, "comparativeSearchDICOMNodes", [PropertyListValue]?.self)
        check(NetworkPreferences.searchesSmartAlbumStudiesOnDICOMNodes, "searchForSmartAlbumStudiesOnDICOMNodes", Bool.self)
        check(NetworkPreferences.sendsROIs, "sendROIs", Bool.self)
        check(NetworkPreferences.sendTransferSyntax, "syntaxListOffis", Int.self)
        check(NetworkPreferences.lastSendServer, "lastSendServer", Int.self)
        check(NetworkPreferences.lastSendWhat, "lastSendWhat", Int.self)
        check(NetworkPreferences.xmlrpcWithPACSOnDemand, "XMLRPCWithPOD", Bool.self)
        check(NetworkPreferences.xmlrpcServerShowsFailureAlerts, "httpXMLRPCServerShowFailureAlerts", Bool.self)
        check(NetworkPreferences.xmlrpcServerWaitForStudy, "httpXMLRPCServerWaitForStudy", Int.self)
        check(NetworkPreferences.dicomNodes, "SERVERS", [PropertyListValue]?.self)
        check(NetworkPreferences.dicomwebNodes, "DICOMWEB_SERVERS", [PropertyListValue]?.self)
        check(NetworkPreferences.osirixServers, "OSIRIXSERVERS", [PropertyListValue]?.self)
        check(NetworkPreferences.networkLogs, "NETWORKLOGS", Bool.self)

        let unregistered: [any CataloguedPreference] = [
            NetworkPreferences.hidesListenerErrors, NetworkPreferences.externalStoreSCP,
            NetworkPreferences.tlsListenerCertificateVerification, NetworkPreferences.tlsListenerCipherSuites,
            NetworkPreferences.moveWithoutJPEG, NetworkPreferences.dicomwebTransferCeiling, NetworkPreferences.syncsOsiriXDB,
            NetworkPreferences.federatedSearchIncludesDefaultDatabase, NetworkPreferences.keepsDuplicateStudyInstanceUIDs,
            NetworkPreferences.queryPresets, NetworkPreferences.queryPresetsIncludeDICOMNodes, NetworkPreferences.savedQuerySettings,
            NetworkPreferences.autoRetrieving, NetworkPreferences.restartsAutoQueryAndRetrieve, NetworkPreferences.querySources,
            NetworkPreferences.autoQuerySources, NetworkPreferences.queryLastDateFilter, NetworkPreferences.queryPatientModeIndex,
            NetworkPreferences.autoQueryPatientModeIndex, NetworkPreferences.queryRefreshSetting,
            NetworkPreferences.autoQueryRefreshSetting, NetworkPreferences.keepsQueryWindowOnTop, NetworkPreferences.betweenDatesMode,
            NetworkPreferences.customIntervalWithHoursAndMinutes, NetworkPreferences.searchesComparativeStudiesOnDICOMNodes,
            NetworkPreferences.pacsOnDemandNodes, NetworkPreferences.searchesSmartAlbumStudiesOnDICOMNodes, NetworkPreferences.sendsROIs, NetworkPreferences.sendTransferSyntax,
            NetworkPreferences.lastSendServer, NetworkPreferences.lastSendWhat, NetworkPreferences.xmlrpcWithPACSOnDemand,
            NetworkPreferences.xmlrpcServerShowsFailureAlerts, NetworkPreferences.xmlrpcServerWaitForStudy,
        ]
        for key in unregistered {
            #expect(key.registration == nil, "\(key.name) registers a value")
            #expect(factory[key.name] == nil, "\(key.name) is registered")
        }
        let empty = MemoryPreferences()
        #expect(empty[NetworkPreferences.dicomwebTransferCeiling] == 0)
        #expect(empty[NetworkPreferences.queryPresets] == nil)
        #expect(empty[NetworkPreferences.lastSendServer] == 0)
    }

    /// The keys two readers took in two ways: each reading as its accessor gave it.
    @Test func keysReadInTwoWays() {
        let store = MemoryPreferences(registered: factory)
        // The associations take the timeout as an integer, echoscu as the text stored.
        #expect(store[NetworkPreferences.dicomTimeout] == 40)
        #expect(store[NetworkPreferences.dicomTimeout.reading(as: String?.self)] == "40")
        store.set(NSNumber(value: 25), forKey: "DICOMTimeout")
        #expect(store[NetworkPreferences.dicomTimeout.reading(as: String?.self)] == "25")
        // The Bonjour announcement takes the port as text, the query's own-address check as an integer.
        #expect(store[NetworkPreferences.aePort] == "11112")
        #expect(store[NetworkPreferences.aePort.reading(as: Int.self)] == 11112)
        // The send reads the thread count as an integer; the node keeps it in the form stored.
        store.set("3", forKey: "SendControllerConcurrentThreads")
        #expect(store[NetworkPreferences.sendControllerConcurrentThreads] == 3)
        #expect(store[NetworkPreferences.sendControllerConcurrentThreads.reading(as: PropertyListValue?.self)] == .string("3"))
    }

    /// The readers that asked whether anything was stored first: a switch on while never written.
    @Test func switchesOnWhileNeverWritten() {
        let key = NetworkPreferences.federatedSearchIncludesDefaultDatabase
        #expect(NetworkPreferences.isOn(key, in: MemoryPreferences(), whenAbsent: true))
        #expect(!NetworkPreferences.isOn(key, in: MemoryPreferences([key.name: false]), whenAbsent: true))
        #expect(!NetworkPreferences.isOn(key, in: MemoryPreferences([key.name: "NO"]), whenAbsent: true))
        #expect(NetworkPreferences.isOn(key, in: MemoryPreferences([key.name: "YES"]), whenAbsent: false))
        #expect(!NetworkPreferences.holdsValue(NetworkPreferences.autoQueryInstances, in: MemoryPreferences()))
        // Any value counts, also one that is not a list.
        #expect(NetworkPreferences.holdsValue(NetworkPreferences.autoQueryInstances,
                                              in: MemoryPreferences(["savedAutoDICOMQuerySettingsArray": "text"])))
    }

    /// The presets of the Query window, read and written back by name in the form the window stored.
    @Test func queryPresetsKeepTheirForm() throws {
        let preset: [String: Any] = ["PatientModeMatrix": NSNumber(value: 1), "searchFieldName": "DOE^JOHN",
                                     "modalityStrings": ["CT", "MR"], "DICOMNodes": ["PACS"], "autoRetrieving": true]
        let store = MemoryPreferences(["QRPresets": ["Morning": preset]])
        var presets = try #require(store[NetworkPreferences.queryPresets])
        #expect(presets["Morning"] == PropertyListValue(preset))
        presets["Evening"] = PropertyListValue(preset)
        presets["Morning"] = nil
        store.set(presets, for: NetworkPreferences.queryPresets)
        let stored = try #require(store.object(forKey: "QRPresets") as? [String: Any])
        #expect(Array(stored.keys) == ["Evening"])
        #expect(PropertyListValue(try #require(stored["Evening"])) == PropertyListValue(preset))
    }

    @Test func observersUseTheKeyPathOfTheCatalogName() {
        #expect(NetworkPreferences.controllerKeyPath(NetworkPreferences.dicomNodes) == "values.SERVERS")
        #expect(NetworkPreferences.controllerKeyPath(NetworkPreferences.dicomwebNodes) == "values.DICOMWEB_SERVERS")
        #expect(NetworkPreferences.sendControllerConcurrentThreads.name == "SendControllerConcurrentThreads")
        #expect(NetworkPreferences.controllerKeyPath(NetworkPreferences.searchDICOMBonjour) == "values.searchDICOMBonjour")
    }
}
