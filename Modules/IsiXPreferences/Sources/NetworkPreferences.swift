/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The preferences of the DICOM network, the listener, the query window, DICOMweb, XML-RPC, the web portal
/// and email. Each key is declared once, with the type it is read as and the value the application registers;
/// `catalog` lists them for DefaultPreferences.
public enum NetworkPreferences {
    public static let activateCFINDSCP = PreferenceKey<Bool>("activateCFINDSCP", registered: "1")
    public static let activateCGETSCP = PreferenceKey<Bool>("activateCGETSCP", registered: "1")
    public static let aePort = PreferenceKey<String?>("AEPORT", registered: "11112")
    public static let aeTitle = PreferenceKey<String?>("AETITLE", registered: PreferenceDefault { environment in
        // This computer's host name up to the first dot, at most 16 characters,
        // in the application; ISIX in the Decompress helper.
        guard environment.viewer, var title = environment.hostName.map({ $0 as NSString }) else { return "ISIX" }
        let dot = title.range(of: ".")
        if dot.location != NSNotFound { title = title.substring(to: dot.location) as NSString }
        return title.length > 16 ? title.substring(to: 16) : title as String
    })
    public static let aeTransferSyntax = PreferenceKey<String?>("AETransferSyntax", registered: "+xi")
    public static let allowsQueryByAccessionNumber = PreferenceKey<Bool>("allow_qr_accession_number", registered: "1")
    public static let allowsQueryByBirthDate = PreferenceKey<Bool>("allow_qr_birthdate", registered: "1")
    public static let allowsBlankQuery = PreferenceKey<Bool>("allow_qr_blank_query", registered: "1")
    public static let allowsQueryByComments = PreferenceKey<Bool>("allow_qr_comments", registered: "1")
    public static let allowsQueryByCustomField = PreferenceKey<Bool>("allow_qr_custom_dicom_field", registered: "1")
    public static let allowsQueryByDescription = PreferenceKey<Bool>("allow_qr_description", registered: "1")
    public static let allowsQueryByID = PreferenceKey<Bool>("allow_qr_id", registered: "1")
    public static let allowsQueryByInstitution = PreferenceKey<Bool>("allow_qr_institution", registered: "1")
    public static let allowsQueryByModality = PreferenceKey<Bool>("allow_qr_modality", registered: "1")
    public static let allowsQueryByName = PreferenceKey<Bool>("allow_qr_name", registered: "1")
    public static let allowsQueryByReferringPhysician = PreferenceKey<Bool>("allow_qr_referring_physician", registered: "1")
    public static let allowsQueryByStatus = PreferenceKey<Bool>("allow_qr_status", registered: "1")
    public static let allowsQueryByStudyDate = PreferenceKey<Bool>("allow_qr_study_date", registered: "1")
    public static let allowPluginAuthenticationForWebPortal = PreferenceKey<Bool>("AllowPluginAuthenticationForWebPortal", registered: "1")
    public static let automaticallyRetrievePartialStudies = PreferenceKey<Bool>("automaticallyRetrievePartialStudies", registered: "1")
    public static let autoroutingActivated = PreferenceKey<Bool>("AUTOROUTINGACTIVATED", registered: "0")
    public static let bringOsiriXToFrontAfterReceivingMessage = PreferenceKey<Bool>("bringOsiriXToFrontAfterReceivingMessage", registered: "1")
    public static let cfindBodyPartExaminedSupport = PreferenceKey<Bool>("CFINDBodyPartExaminedSupport", registered: "0")
    public static let cfindCommentsAndStatusSupport = PreferenceKey<Bool>("CFINDCommentsAndStatusSupport", registered: "1")
    public static let closeAllWindowsBeforeXMLRPCOpen = PreferenceKey<Bool>("CloseAllWindowsBeforeXMLRPCOpen", registered: "1")
    public static let dicomPrintInterval = PreferenceKey<Int>("DCMPRINT_Interval", registered: "1")
    public static let dicomConnectionTimeout = PreferenceKey<Int>("DICOMConnectionTimeout", registered: "10")
    public static let dicomQueryAllowsFutureQuery = PreferenceKey<Bool>("DICOMQueryAllowFutureQuery", registered: "1")
    public static let dicomSendAllowed = PreferenceKey<Bool>("DICOMSENDALLOWED", registered: "1")
    public static let dicomTimeout = PreferenceKey<Int>("DICOMTimeout", registered: "40")
    public static let fetchLimitForWebPortal = PreferenceKey<Int>("FetchLimitForWebPortal", registered: "200")
    /// Open on the first batch of a retrieve, nudge the importer, coalesce reloads.
    public static let progressiveRetrieveViewing = PreferenceKey<Bool>("HorosProgressiveRetrieveViewing", registered: "YES")
    public static let webServer = PreferenceKey<Bool>("httpWebServer", registered: "0")
    public static let webServerPort = PreferenceKey<Int>("httpWebServerPort", registered: "3333")
    public static let xmlrpcServer = PreferenceKey<Bool>("httpXMLRPCServer", registered: "0")
    /// As Horos and OsiriX: once the server is turned on, any address is answered without a password (scope
    /// 2). The Listener pane says so in red and offers this Mac only, the local network and a password
    /// instead.
    public static let xmlrpcServerAccessScope = PreferenceKey<Int>("httpXMLRPCServerAccessScope", registered: "2")
    public static let xmlrpcServerAllowedAddresses = PreferenceKey<String?>("httpXMLRPCServerAllowedAddresses", registered: "")
    public static let xmlrpcServerDoesNotRespond = PreferenceKey<Bool>("httpXMLRPCServerDoNotRespond", registered: "0")
    public static let xmlrpcServerHTTPS = PreferenceKey<Bool>("httpXMLRPCServerHTTPS", registered: "0")
    public static let xmlrpcServerPort = PreferenceKey<Int>("httpXMLRPCServerPort", registered: "8080")
    public static let xmlrpcServerRequiresPassword = PreferenceKey<Bool>("httpXMLRPCServerRequirePassword", registered: "0")
    /// Seconds between scans of the incoming folder: each scan is a commit, notifications and a browser
    /// refresh; larger batches mean fewer.
    public static let listenerCheckInterval = PreferenceKey<Int>("LISTENERCHECKINTERVAL", registered: "15")
    public static let listenerCompressionSettings = PreferenceKey<Int>("ListenerCompressionSettings", registered: "0")
    public static let maxConcurrentPODRetrieves = PreferenceKey<Int>("MaxConcurrentPODRetrieves", registered: "2")
    public static let maximumNumberOfCFindObjects = PreferenceKey<Int>("maximumNumberOfCFindObjects", registered: "10000")
    public static let maximumNumberOfConcurrentDICOMAssociations = PreferenceKey<Int>("maximumNumberOfConcurrentDICOMAssociations", registered: "20")
    public static let maximumSendControllerConcurrentThreads = PreferenceKey<Int>("MaximumSendControllerConcurrentThreads", registered: "4")
    public static let maximumSendGlobalControllerConcurrentThreads = PreferenceKey<Int>("MaximumSendGlobalControllerConcurrentThreads", registered: "4")
    public static let maxNumberOfFramesForWebPortalMovies = PreferenceKey<Int>("MaxNumberOfFramesForWebPortalMovies", registered: "400")
    public static let maxNumberOfRetrieveForAutoQR = PreferenceKey<PropertyListValue?>("MaxNumberOfRetrieveForAutoQR", registered: "20")
    public static let multipleAssociationsRetrieve = PreferenceKey<Bool>("MultipleAssociationsRetrieve", registered: "0")
    public static let networkLogs = PreferenceKey<Bool>("NETWORKLOGS", registered: "0")
    public static let noOfMultipleAssociationsRetrieve = PreferenceKey<Int>("NoOfMultipleAssociationsRetrieve", registered: "3")
    public static let notificationsEmails = PreferenceKey<Bool>("notificationsEmails", registered: "0")
    public static let notificationsEmailsInterval = PreferenceKey<Int>("notificationsEmailsInterval", registered: "1")
    public static let osirixServers = PreferenceKey<[PropertyListValue]?>("OSIRIXSERVERS", registered: PreferenceDefault { _ in [Any]() })
    public static let pacsOnDemandForSearchField = PreferenceKey<Bool>("PACSOnDemandForSearchField", registered: "1")
    /// 2: EXS_LittleEndianExplicit.
    public static let preferredSyntaxForIncoming = PreferenceKey<Int>("preferredSyntaxForIncoming", registered: "2")
    public static let publishDICOMBonjour = PreferenceKey<Bool>("publishDICOMBonjour", registered: "1")
    public static let putsDestinationAETitleInPrivateInformationCreatorUID = PreferenceKey<Bool>("putDstAETitleInPrivateInformationCreatorUID", registered: "0")
    public static let putsSourceAETitleInSourceApplicationEntityTitle = PreferenceKey<Bool>("putSrcAETitleInSourceApplicationEntityTitle", registered: "1")
    public static let qrRemoveDuplicateEntries = PreferenceKey<Bool>("QRRemoveDuplicateEntries", registered: "1")
    public static let restorePasswordWebServer = PreferenceKey<Bool>("restorePasswordWebServer", registered: "1")
    public static let routingCalendars = PreferenceKey<[String]?>("ROUTING CALENDARS", registered: .value(["Osirix"]))
    public static let routingActivated = PreferenceKey<Bool>("ROUTINGACTIVATED", registered: "0")
    public static let runListenerOnlyIfActive = PreferenceKey<Bool>("RunListenerOnlyIfActive", registered: "0")
    public static let searchDICOMBonjour = PreferenceKey<Bool>("searchDICOMBonjour", registered: "1")
    public static let sendControllerConcurrentThreads = PreferenceKey<Int>("SendControllerConcurrentThreads", registered: "1")
    public static let dicomNodes = PreferenceKey<[PropertyListValue]?>("SERVERS", registered: PreferenceDefault { _ in
        // The example node.
        [["Activated": "1", "Address": "127.0.0.1", "AETitle": "ISIX", "Port": "4444", "TransferSyntax": NSNumber(value: Int32(0)),
          "Description": NSLocalizedString("This is an example", comment: "")] as [String: Any]]
    })
    public static let showErrorMessagesForAutorouting = PreferenceKey<Bool>("ShowErrorMessagesForAutorouting", registered: "1")
    public static let singleProcessMultiThreadedListener = PreferenceKey<Bool>("SingleProcessMultiThreadedListener", registered: "1")
    public static let storeSCP = PreferenceKey<Bool>("STORESCP", registered: "1")
    public static let storeSCPExtra = PreferenceKey<String?>("STORESCPEXTRA", registered: "")
    public static let queryCharacterSet = PreferenceKey<String?>("STRINGENCODING", registered: "ISO_IR 100")
    public static let supportsQRModalitiesInStudy = PreferenceKey<Bool>("SupportQRModalitiesinStudy", registered: "1")
    public static let syncDICOMNodesURL = PreferenceKey<String?>("syncDICOMNodesURL", registered: "http://list.dicom.dcm/DICOMNodes.plist")
    public static let syncOsiriXDBURL = PreferenceKey<String?>("syncOsiriXDBURL", registered: "http://list.dicom.dcm/OsiriXDB.plist")
    public static let temporaryUserDuration = PreferenceKey<Int>("temporaryUserDuration", registered: "60")
    public static let triesImageLevelRetrieveIfLocalImages = PreferenceKey<Bool>("TryIMAGELevelDICOMRetrieveIfLocalImages", registered: "0")
    public static let usesStoreSCP = PreferenceKey<Bool>("USESTORESCP", registered: "1")
    public static let wadoMaximumConcurrentDownloads = PreferenceKey<Int>("WADOMaximumConcurrentDownloads", registered: "10")
    public static let wadoRequestRequireValidToken = PreferenceKey<Bool>("wadoRequestRequireValidToken", registered: "1")
    /// How many times a WADO retrieval asks again for the instances that did not arrive, when the reason was
    /// transient. 0 turns it off.
    public static let wadoRetryAttempts = PreferenceKey<Int>("WADORetryAttempts", registered: "1")
    public static let wadoServer = PreferenceKey<Bool>("wadoServer", registered: true)
    public static let wadoTimeout = PreferenceKey<Float>("WADOTimeout", registered: "600")
    public static let webPortalMaximumNumberOfDaysForRecentStudies = PreferenceKey<Double>("WebPortalMaximumNumberOfDaysForRecentStudies", registered: "10")
    public static let webPortalMaximumNumberOfRecentStudies = PreferenceKey<Int>("WebPortalMaximumNumberOfRecentStudies", registered: "30")
    public static let webServerMaxWidthForMovie = PreferenceKey<Float>("WebServerMaxWidthForMovie", registered: "880")
    public static let webServerMaxWidthForStillImage = PreferenceKey<Float>("WebServerMaxWidthForStillImage", registered: "880")
    public static let webServerMinWidthForMovie = PreferenceKey<Float>("WebServerMinWidthForMovie", registered: "512")
    public static let webServerPrefersFlash = PreferenceKey<Bool>("WebServerPrefersFlash", registered: true)
    public static let webServerTagUploadedStudiesWithUsername = PreferenceKey<Bool>("WebServerTagUploadedStudiesWithUsername", registered: "1")
    /// Seconds: 30 minutes.
    public static let webServerTimeOut = PreferenceKey<Int>("WebServerTimeOut", registered: "1800")
    public static let webServerUseMailAppForEmails = PreferenceKey<Bool>("WebServerUseMailAppForEmails", registered: "1")
    public static let webServerUsesWeasis = PreferenceKey<Bool>("WebServerUsesWeasis", registered: true)
    public static let autoRetrieveSkipsDuplicateAccessionNumbers = PreferenceKey<Bool>("QR_CheckForDuplicateAccessionNumber")
    public static let autoRetrieveSkipsRecentRetrieves = PreferenceKey<Bool>("QR_DontReDownloadStudies")
    public static let autoRetrieveSkipsMammographyDescriptions = PreferenceKey<Bool>("QR_DontDownloadMGDescription")
    public static let countsZeroImagesAsUnknown = PreferenceKey<Bool>("SupportPACSWithNoNumberOfImagesField")
    public static let autoQueryInstances = PreferenceKey<[PropertyListValue]?>("savedAutoDICOMQuerySettingsArray")
    public static let formerAutoQueryInstance = PreferenceKey<[String: PropertyListValue]?>("savedAutoDICOMQuerySettings")
    public static let dicomwebNodes = PreferenceKey<[PropertyListValue]?>("DICOMWEB_SERVERS")
    public static let syncsDICOMNodes = PreferenceKey<Bool>("syncDICOMNodes")
    public static let hidesListenerErrors = PreferenceKey<Bool>("hideListenerError")
    /// hideListenerError as the user had it, kept while an abort of the incoming transfers hides the
    /// listener's errors: a launch that finds it puts it back.
    public static let savedHidesListenerErrors = PreferenceKey<Bool>("copyHideListenerError")
    /// The TLS listener: on or off, its AE title and its port, and the file of its Diffie-Hellman parameters.
    public static let tlsListener = PreferenceKey<Bool>("STORESCPTLS")
    public static let tlsListenerAETitle = PreferenceKey<String?>("TLSStoreSCPAETITLE")
    public static let tlsListenerPort = PreferenceKey<String?>("TLSStoreSCPAEPORT")
    public static let tlsListenerUsesDHParameterFile = PreferenceKey<Bool>("TLSStoreSCPUseDHParameterFileURL")
    public static let tlsListenerDHParameterFile = PreferenceKey<String?>("TLSStoreSCPDHParameterFileURL")
    /// The listener answers to this computer's host name rather than to AETITLE.
    public static let usesHostNameForAETitle = PreferenceKey<Bool>("UseHostNameForAETitle")
    /// Another listener on this computer receives what a C-MOVE sends here.
    public static let externalStoreSCP = PreferenceKey<Bool>("NinjaSTORESCP")
    /// Whether the TLS listener verifies its peers; read as the number or text it is stored as.
    public static let tlsListenerCertificateVerification = PreferenceKey<PropertyListValue?>("TLSStoreSCPCertificateVerification")
    /// The cipher suites of the Listener pane: each entry's `Cipher`, used when `Supported` is on.
    public static let tlsListenerCipherSuites = PreferenceKey<[PropertyListValue]?>("TLSStoreSCPCipherSuites")
    public static let moveWithoutJPEG = PreferenceKey<Bool>("DontSupportJPEGForCSMove")
    /// Seconds a DICOMweb request may last while it progresses; 0 is a day.
    public static let dicomwebTransferCeiling = PreferenceKey<Double>("DICOMwebTransferCeiling")
    public static let syncsOsiriXDB = PreferenceKey<Bool>("syncOsiriXDB")
    /// Whether the browser's federated search includes the default database; on while never written.
    public static let federatedSearchIncludesDefaultDatabase = PreferenceKey<Bool>("HorosDefaultDatabaseFederatedSearch")

    // The Query window and the automatic query.
    /// The studies of a query are not filtered down to one per Study Instance UID.
    public static let keepsDuplicateStudyInstanceUIDs = PreferenceKey<Bool>("dontFilterQueryStudiesForUniqueInstanceUID")
    /// The window's presets by name, each a dictionary of its filters.
    public static let queryPresets = PreferenceKey<[String: PropertyListValue]?>("QRPresets")
    /// A preset saved from the window also keeps the checked nodes.
    public static let queryPresetsIncludeDICOMNodes = PreferenceKey<Bool>("includeDICOMNodes")
    /// The filters of the window when it was last saved.
    public static let savedQuerySettings = PreferenceKey<[String: PropertyListValue]?>("savedDICOMQuerySettings")
    /// The retrieve setting of the window's filters, beside those of each automatic query.
    public static let autoRetrieving = PreferenceKey<Bool>("autoRetrieving")
    public static let restartsAutoQueryAndRetrieve = PreferenceKey<Bool>("restartAutoQueryAndRetrieve")
    /// The sources of the Query window and of the automatic query, with their checked state.
    public static let querySources = PreferenceKey<[PropertyListValue]?>("SavedQueryArray")
    public static let autoQuerySources = PreferenceKey<[PropertyListValue]?>("SavedQueryArrayAuto")
    public static let queryLastDateFilter = PreferenceKey<Int>("QRLastDateFilterValue")
    public static let queryPatientModeIndex = PreferenceKey<Int>("QRPatientModeMatrixIndex")
    public static let autoQueryPatientModeIndex = PreferenceKey<Int>("AutoQRPatientModeMatrixIndex")
    /// The automatic refresh of the results, in the window and in the automatic query.
    public static let queryRefreshSetting = PreferenceKey<Int>("autoRefreshQueryResults")
    public static let autoQueryRefreshSetting = PreferenceKey<Int>("autoRefreshQueryResultsAutoQR")
    public static let keepsQueryWindowOnTop = PreferenceKey<Bool>("KeepQRWindowOnTop")
    /// The custom date interval: two dates rather than one, and hours and minutes with them.
    public static let betweenDatesMode = PreferenceKey<Bool>("betweenDatesMode")
    public static let customIntervalWithHoursAndMinutes = PreferenceKey<Bool>("customIntervalWithHoursAndMinutes")

    // PACS On-Demand.
    public static let searchesComparativeStudiesOnDICOMNodes = PreferenceKey<Bool>("searchForComparativeStudiesOnDICOMNodes")
    /// The nodes chosen in the PACS On-Demand pane.
    public static let pacsOnDemandNodes = PreferenceKey<[PropertyListValue]?>("comparativeSearchDICOMNodes")
    /// The smart albums with an entry in the PACS On-Demand pane show the studies the nodes find for it.
    public static let searchesSmartAlbumStudiesOnDICOMNodes = PreferenceKey<Bool>("searchForSmartAlbumStudiesOnDICOMNodes")

    // The Send window.
    public static let sendsROIs = PreferenceKey<Bool>("sendROIs")
    /// The tag of the transfer syntax chosen in the Send window.
    public static let sendTransferSyntax = PreferenceKey<Int>("syntaxListOffis")
    public static let lastSendServer = PreferenceKey<Int>("lastSendServer")
    public static let lastSendWhat = PreferenceKey<Int>("lastSendWhat")

    // XML-RPC.
    /// RIS orders take the PACS On-Demand path when it is on too.
    public static let xmlrpcWithPACSOnDemand = PreferenceKey<Bool>("XMLRPCWithPOD")
    /// Failed requests are shown in an alert, beyond the log.
    public static let xmlrpcServerShowsFailureAlerts = PreferenceKey<Bool>("httpXMLRPCServerShowFailureAlerts")
    /// Seconds a request waits for a study that has not arrived yet.
    public static let xmlrpcServerWaitForStudy = PreferenceKey<Int>("httpXMLRPCServerWaitForStudy")

    /// Every key of this file.
    static let catalog: [any CataloguedPreference] = [
        activateCFINDSCP, activateCGETSCP, aePort, aeTitle, aeTransferSyntax, allowsQueryByAccessionNumber,
        allowsQueryByBirthDate, allowsBlankQuery, allowsQueryByComments, allowsQueryByCustomField,
        allowsQueryByDescription, allowsQueryByID, allowsQueryByInstitution, allowsQueryByModality, allowsQueryByName,
        allowsQueryByReferringPhysician, allowsQueryByStatus, allowsQueryByStudyDate,
        allowPluginAuthenticationForWebPortal, automaticallyRetrievePartialStudies, autoroutingActivated,
        bringOsiriXToFrontAfterReceivingMessage, cfindBodyPartExaminedSupport, cfindCommentsAndStatusSupport,
        closeAllWindowsBeforeXMLRPCOpen, dicomPrintInterval, dicomConnectionTimeout, dicomQueryAllowsFutureQuery,
        dicomSendAllowed, dicomTimeout, fetchLimitForWebPortal, progressiveRetrieveViewing, webServer, webServerPort,
        xmlrpcServer, xmlrpcServerAccessScope, xmlrpcServerAllowedAddresses, xmlrpcServerDoesNotRespond,
        xmlrpcServerHTTPS, xmlrpcServerPort, xmlrpcServerRequiresPassword, listenerCheckInterval,
        listenerCompressionSettings, maxConcurrentPODRetrieves, maximumNumberOfCFindObjects,
        maximumNumberOfConcurrentDICOMAssociations, maximumSendControllerConcurrentThreads,
        maximumSendGlobalControllerConcurrentThreads, maxNumberOfFramesForWebPortalMovies,
        maxNumberOfRetrieveForAutoQR, multipleAssociationsRetrieve, networkLogs, noOfMultipleAssociationsRetrieve,
        notificationsEmails, notificationsEmailsInterval, osirixServers, pacsOnDemandForSearchField,
        preferredSyntaxForIncoming, publishDICOMBonjour, putsDestinationAETitleInPrivateInformationCreatorUID,
        putsSourceAETitleInSourceApplicationEntityTitle, qrRemoveDuplicateEntries, restorePasswordWebServer,
        routingCalendars, routingActivated, runListenerOnlyIfActive, searchDICOMBonjour,
        sendControllerConcurrentThreads, dicomNodes, showErrorMessagesForAutorouting,
        singleProcessMultiThreadedListener, storeSCP, storeSCPExtra, queryCharacterSet, supportsQRModalitiesInStudy,
        syncDICOMNodesURL, syncOsiriXDBURL, temporaryUserDuration, triesImageLevelRetrieveIfLocalImages, usesStoreSCP,
        wadoMaximumConcurrentDownloads, wadoRequestRequireValidToken, wadoRetryAttempts, wadoServer, wadoTimeout,
        webPortalMaximumNumberOfDaysForRecentStudies, webPortalMaximumNumberOfRecentStudies,
        webServerMaxWidthForMovie, webServerMaxWidthForStillImage, webServerMinWidthForMovie, webServerPrefersFlash,
        webServerTagUploadedStudiesWithUsername, webServerTimeOut, webServerUseMailAppForEmails, webServerUsesWeasis,
        autoRetrieveSkipsDuplicateAccessionNumbers, autoRetrieveSkipsRecentRetrieves,
        autoRetrieveSkipsMammographyDescriptions, countsZeroImagesAsUnknown, autoQueryInstances,
        formerAutoQueryInstance, dicomwebNodes, syncsDICOMNodes, hidesListenerErrors, savedHidesListenerErrors,
        tlsListener, tlsListenerAETitle, tlsListenerPort, tlsListenerUsesDHParameterFile, tlsListenerDHParameterFile,
        usesHostNameForAETitle, externalStoreSCP,
        tlsListenerCertificateVerification, tlsListenerCipherSuites, moveWithoutJPEG, dicomwebTransferCeiling,
        syncsOsiriXDB, federatedSearchIncludesDefaultDatabase, keepsDuplicateStudyInstanceUIDs, queryPresets,
        queryPresetsIncludeDICOMNodes, savedQuerySettings, autoRetrieving, restartsAutoQueryAndRetrieve, querySources,
        autoQuerySources, queryLastDateFilter, queryPatientModeIndex, autoQueryPatientModeIndex, queryRefreshSetting,
        autoQueryRefreshSetting, keepsQueryWindowOnTop, betweenDatesMode, customIntervalWithHoursAndMinutes,
        searchesComparativeStudiesOnDICOMNodes, pacsOnDemandNodes, searchesSmartAlbumStudiesOnDICOMNodes, sendsROIs,
        sendTransferSyntax, lastSendServer, lastSendWhat, xmlrpcWithPACSOnDemand, xmlrpcServerShowsFailureAlerts, xmlrpcServerWaitForStudy,
    ]

    /// The key path of `key` in NSUserDefaultsController, whose observers and bindings hear a change of the key.
    public static func controllerKeyPath<Value>(_ key: PreferenceKey<Value>) -> String {
        "values." + key.name
    }

    /// Whether `store` holds a value under `key`, of whatever type: the user's own, one given at launch or a
    /// registered one.
    public static func holdsValue<Value>(_ key: PreferenceKey<Value>, in store: any PreferenceStore) -> Bool {
        store.object(forKey: key.name) != nil
    }

    /// A switch read as `whenAbsent` while nothing is stored under it, and as `bool(forKey:)` reads it once
    /// something is: the readers that asked `object(forKey:)` first.
    public static func isOn(_ key: PreferenceKey<Bool>, in store: any PreferenceStore, whenAbsent: Bool) -> Bool {
        holdsValue(key, in: store) ? store[key] : whenAbsent
    }
}
