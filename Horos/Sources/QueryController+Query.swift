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

import AppKit
import IsiXDICOMNetwork
import IsiXDICOMFile

/// The query of the window: the filters of a preset sent to each activated
/// node, the answers merged into one list as they come, and the nodes the
/// window lists. The rules of each field are QueryWindowField of
/// IsiXDICOMNetwork.
extension QueryController {
    // MARK: Asking

    @IBAction @objc(query:)
    public func query(_ sender: Any?) {
        do {
            try HorosObjCException.perform {
                if sender is NSSearchField, let chars = NSApp.currentEvent?.characters, let first = chars.utf16.first {
                    if first != 13 && first != 3 { return }
                }

                self.autoQueryTimer(self)

                _ = self.queryWithDisplayingErrors(true)

                self.queryButtonPressed = true

                if let field = sender as? NSSearchField {
                    field.selectText(self)
                }
            }
        } catch {
            if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(exception, false, "-[QueryController query:]")
            }
        }
    }

    /// Queries with the filters of the window, on the main thread.
    @objc(queryWithDisplayingErrors:)
    public func queryWithDisplayingErrors(_ showError: Bool) -> Bool {
        let instance = savePresetInDictionary(withDICOMNodes: true)
        captureWindowState()
        return queryWithDisplayingErrors(showError, instance: instance, index: -1)
    }

    /// Queries the activated nodes of `instance`, a preset, with its filters,
    /// on any thread; the automatic query runs it on a worker. `index` is the
    /// automatic query's instance (-1 for the window), which keeps the results.
    @objc(queryWithDisplayingErrors:instance:index:)
    public nonisolated func queryWithDisplayingErrors(_ showError: Bool, instance: NSMutableDictionary!, index: Int32) -> Bool {
        let onMain = Thread.isMainThread
        let instance = instance ?? NSMutableDictionary()
        let error = false
        let tempResultArray = NSMutableArray()

        temporaryCFindResultArray = onMain ? NSMutableArray() : nil

        objc_sync_enter(self)
        for case let thread as Thread in performingQueryThreads {
            thread.setIsCancelled(true)
        }
        objc_sync_exit(self)

        autoQueryLock.lock()

        UserDefaults.standard.set(sourcesArray, forKey: queryArrayPrefs)

        var atLeastOneSource = false

        // The dates of the pickers: read now on the main thread, as copied last
        // on a worker.
        let dates: (from: Date, to: Date) = onMain
            ? MainActor.assumeIsolated { (self.fromDate?.dateValue ?? Date(), self.toDate?.dateValue ?? Date()) }
            : (windowState.fromDate, windowState.toDate)

        do {
            try HorosObjCException.perform {
                self.firstServerRealtimeResults = true

                if onMain {
                    MainActor.assumeIsolated { self.refreshList([]) } // Clean the list
                }

                let dicomNodes = instance.object(forKey: "DICOMNodes") as? [String] ?? []
                let dicomNodesAE = instance.object(forKey: "DICOMNodesAETitle") as? [String] ?? []

                for (v, s) in dicomNodes.enumerated() {
                    let ae: String? = v < dicomNodesAE.count ? dicomNodesAE[v] : nil

                    var aServer: NSDictionary?
                    for case let src as NSObject in self.sourcesArray {
                        if (src.value(forKey: "AddressAndPort") as? String) == s && (ae == nil || (src.value(forKey: "AETitle") as? String) == ae) {
                            aServer = src.value(forKey: "server") as? NSDictionary
                        }
                    }

                    guard let aServer else { continue }

                    let manager = QueryArrayController(callingAET: UserDefaults.defaultAETitle(), distantServer: aServer)
                    self.queryManager = manager
                    // add filters as needed

                    if let encoding = UserDefaults.standard.string(forKey: "STRINGENCODING"), encoding != "ISO_IR 100" {
                        // Specific Character Set
                        manager.addFilter(encoding, forDescription: "SpecificCharacterSet")
                    }

                    atLeastOneSource = true

                    var queryItem = false
                    var nameAlternatives: [String] = []

                    if let field = QueryWindowField(rawValue: Int(QueryController.int32(instance.object(forKey: "PatientModeMatrix")))),
                       UserDefaults.standard.bool(forKey: field.preference) {
                        (queryItem, nameAlternatives) = self.addFilter(of: field, from: instance, to: manager, showError: showError)
                    }

                    let (dateQueryFilter, timeQueryFilter) = QueryController.dateAndTimeQueryFilters(
                        tag: QueryController.int32(instance.object(forKey: "dateFilterMatrix")), from: dates.from, to: dates.to)

                    if dateQueryFilter?.object != nil && UserDefaults.standard.bool(forKey: "allow_qr_study_date") {
                        manager.addFilter(dateQueryFilter?.filteredValue(), forDescription: "StudyDate")
                        queryItem = true
                    }

                    if timeQueryFilter?.object != nil && UserDefaults.standard.bool(forKey: "allow_qr_study_date") {
                        manager.addFilter(timeQueryFilter?.filteredValue(), forDescription: "StudyTime")
                        queryItem = true
                    }

                    let modalityQueryFilter = self.getModalityQueryFilter(instance.object(forKey: "modalityStrings") as? [Any])

                    if modalityQueryFilter?.object != nil {
                        if queryItem || UserDefaults.standard.bool(forKey: "allow_qr_modality") {
                            manager.addFilter(modalityQueryFilter?.filteredValue(), forDescription: modalityQueryFilter?.key as? String)
                            queryItem = true
                        }
                    }

                    if queryItem {
                        self.performQuery(NSNumber(value: showError))

                        // A PACS compares the name as it is sent, and many keep
                        // names in capitals without diacritics: one that found
                        // nothing for a name typed in lower case or with
                        // diacritics is asked again in capitals, then in
                        // capitals without diacritics.
                        for alternative in nameAlternatives {
                            if (manager.queries()?.count ?? 0) > 0 || Thread.current.isCancelled {
                                break
                            }
                            NSLog("Q&R: nothing for the name as typed, asking again for %@",
                                  QueryLog.term(key: QueryWindowField.patientName.key, value: alternative))
                            manager.addFilter(alternative + "*", forDescription: QueryWindowField.patientName.key)
                            self.performQuery(NSNumber(value: showError))
                        }
                    } else {
                        // if filter is empty and there is no date the query may
                        // be prolonged and fail. Ask first. Don't run if cancelled
                        var doit = false

                        if !UserDefaults.standard.bool(forKey: "allow_qr_blank_query") {
                            if Thread.isMainThread {
                                MainActor.assumeIsolated {
                                    _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Query Error", comment: ""),
                                                                    message: NSLocalizedString("No query parameters provided. Blank query is not allowed.", comment: ""),
                                                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                                }
                            }
                        } else if showError && Thread.isMainThread {
                            doit = MainActor.assumeIsolated {
                                let alert = NSAlert()
                                alert.messageText = NSLocalizedString("Query", comment: "")
                                alert.informativeText = NSLocalizedString("No query parameters provided. The query may take a long time.", comment: "")
                                alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
                                alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                                return alert.runModal() == .alertFirstButtonReturn
                            }
                        } else {
                            doit = true
                        }

                        if doit {
                            self.performQuery(NSNumber(value: showError))
                        } else {
                            NSLog("The PACS query was not allowed.")
                            break
                        }
                    }

                    if Thread.isMainThread {
                        self.lastTemporaryCFindResultUpdate = 0
                        // If there are multiple sources
                        self.realtimeCFindResults(Notification(name: Notification.Name("realtimeCFindResults"), object: manager.rootNode()))
                    }

                    if self.firstServerRealtimeResults {
                        self.firstServerRealtimeResults = false
                        tempResultArray.removeAllObjects()
                        tempResultArray.addObjects(from: manager.queries() as? [Any] ?? [])
                    } else {
                        QueryController.mergeAnswers(manager.queries() as? [Any] ?? [], into: tempResultArray)
                    }
                }

                if tempResultArray.count > 0 {
                    tempResultArray.sort(using: self.sortArray())
                }

                self.firstServerRealtimeResults = true
            }
        } catch {
            QueryController.log(error, "-[QueryController queryWithDisplayingErrors:instance:index:]")
        }

        autoQueryLock.unlock()

        if !autoQueryValue {
            showResults(tempResultArray)
        } else {
            QueryController.synchronized(autoQRInstances) {
                if index >= 0 {
                    if index == currentAutoQRValue {
                        showResults(tempResultArray)
                    }
                    if keepResults(tempResultArray, inInstanceAt: Int(index)) {
                        // The worker's instance is a copy of the stored one: it takes them too.
                        instance.setObject(tempResultArray, forKey: "resultArray" as NSString)
                    }
                }
            }
        }

        if !atLeastOneSource && Thread.isMainThread && showError {
            MainActor.assumeIsolated {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Query", comment: ""),
                                                message: NSLocalizedString("Please select a DICOM node (check box).", comment: ""),
                                                defaultButton: NSLocalizedString("Continue", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }

        temporaryCFindResultArray = nil

        return error
    }

    /// Adds the filter of the search field `field`, as `instance` holds it, to
    /// `manager`: whether it added one, and the other spellings of a patient's
    /// name to try when that one finds nothing.
    private nonisolated func addFilter(of field: QueryWindowField, from instance: NSDictionary, to manager: QueryArrayController,
                                       showError: Bool) -> (Bool, [String]) {
        let encoding = NSString.encoding(forDICOMCharacterSet: UserDefaults.standard.string(forKey: "STRINGENCODING"))
        var key = field.key
        let typed: String?

        switch field {
        case .customField:
            let name = instance.object(forKey: "searchCustomFieldDICOM") as? String
            let dicomField = dicomFields.first { $0.title() == name }
            let tag = (UInt32(UInt16(truncatingIfNeeded: dicomField?.group() ?? 0)) << 16) | UInt32(UInt16(truncatingIfNeeded: dicomField?.element() ?? 0))
            key = try? IsiXDCMTKDictionary.keyword(forTag: tag)
            typed = instance.object(forKey: "searchCustomField") as? String
            NSLog("DICOM Q&R with custom field: %@", QueryLog.term(key: key, value: typed))
        case .patientBirthDate:
            let tag = Int(QueryController.int32(instance.object(forKey: "birthdateFilterMatrix")))
            let date = Date(timeIntervalSinceReferenceDate: QueryController.double(instance.object(forKey: "searchBirth")))
            if let format = QueryDateFilter.birthDateFormat(forTag: tag) {
                manager.addFilter(DICOMCalendarDate.string(from: date, calendarFormat: format), forDescription: key)
            }
            currentQueryKey = key
            return (true, [])
        case .interpretationStatus:
            typed = String(format: "%d", QueryController.int32(instance.object(forKey: "searchStatus")))
        default:
            typed = instance.object(forKey: QueryController.presetKey(of: field)) as? String
        }
        currentQueryKey = key

        if field.checksEncoding && showError && Thread.isMainThread &&
            (typed as NSString?)?.cString(using: encoding) == nil {
            // On the main thread, which the manager is used on here.
            nonisolated(unsafe) let manager = manager
            MainActor.assumeIsolated {
                if HorosAlertPanel.runCritical(title: NSLocalizedString("Query Encoding", comment: ""),
                                               message: NSLocalizedString("The query cannot be encoded in current character set. Should I switch to UTF-8 (ISO_IR 192) encoding?", comment: ""),
                                               defaultButton: NSLocalizedString("OK", comment: ""),
                                               alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) == HorosAlertDefaultResponse {
                    UserDefaults.standard.set("ISO_IR 192", forKey: "STRINGENCODING")
                    manager.addFilter(UserDefaults.standard.string(forKey: "STRINGENCODING"), forDescription: "SpecificCharacterSet")
                }
            }
        }

        guard let filter = field.filterValue(typed) else { return (false, []) }
        manager.addFilter(filter, forDescription: key)

        if field == .patientName {
            let trimmed = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let alternatives = PatientNameMatching.alternativeRemoteTerms(
                for: trimmed, encoding: NSString.encoding(forDICOMCharacterSet: UserDefaults.standard.string(forKey: "STRINGENCODING")))
            return (true, alternatives)
        }
        return (true, [])
    }

    /// The key of the preset that holds what was typed in `field`.
    private nonisolated static func presetKey(of field: QueryWindowField) -> String {
        switch field {
        case .patientName: return "searchFieldName"
        case .patientID: return "searchFieldID"
        case .accessionNumber: return "searchFieldAN"
        case .studyDescription: return "searchFieldStudyDescription"
        case .referringPhysician: return "searchFieldRefPhysician"
        case .studyComments: return "searchFieldComments"
        case .institutionName: return "searchInstitutionName"
        case .customField: return "searchCustomField"
        case .patientBirthDate: return "searchBirth"
        case .interpretationStatus: return "searchStatus"
        }
    }

    /// The answers of one more node, merged into those of the nodes before it.
    nonisolated static func mergeAnswers(_ answers: [Any], into results: NSMutableArray) {
        var merged = results.map { $0 as AnyObject }
        QueryResultMerge.merge(answers.map { $0 as AnyObject }, into: &merged, indexingAdditions: false,
                               uid: queryUID, images: queryImageCount)
        results.setArray(merged)
    }

    /// Shows `results` in the window, from any thread.
    nonisolated func showResults(_ results: NSArray) {
        if Thread.isMainThread {
            nonisolated(unsafe) let results = results
            MainActor.assumeIsolated { refreshList(results as? [Any]) }
        } else {
            performSelector(onMainThread: #selector(refreshList(_:)), with: results, waitUntilDone: false)
        }
    }

    /// Runs the query prepared in the query manager, on any thread; a query of
    /// the window cancels the ones still running.
    @objc(performQuery:)
    public nonisolated func performQuery(_ showErrors: NSNumber!) {
        checkAndViewTry = -1

        var showErrors = showErrors?.boolValue ?? false
        if !Thread.isMainThread {
            showErrors = false
        }

        autoreleasepool {
            var performQuery = false

            objc_sync_enter(self)
            for case let thread as Thread in performingQueryThreads {
                thread.setIsCancelled(true)
            }

            if !performingCFind {
                performingCFind = true

                startProgress()

                performQuery = true

                performingQueryThreads.add(Thread.current)
            }
            objc_sync_exit(self)

            if performQuery {
                queryManager?.performQuery(showErrors)

                objc_sync_enter(self)
                stopProgress()

                performingCFind = false

                performingQueryThreads.remove(Thread.current)
                objc_sync_exit(self)
            }
        }
    }

    nonisolated func startProgress() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { progressIndicator?.startAnimation(nil) }
        } else {
            progressIndicator?.performSelector(onMainThread: #selector(NSProgressIndicator.startAnimation(_:)), with: nil, waitUntilDone: false)
        }
    }

    nonisolated func stopProgress() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { progressIndicator?.stopAnimation(nil) }
        } else {
            progressIndicator?.performSelector(onMainThread: #selector(NSProgressIndicator.stopAnimation(_:)), with: nil, waitUntilDone: false)
        }
    }

    /// The answers of a node while its C-FIND runs: shown once a second.
    @objc(realtimeCFindResults:)
    nonisolated func realtimeCFindResults(_ notification: Notification) {
        guard let root = notification.object as AnyObject?, root === (queryManager?.rootNode() as AnyObject?),
              let temporary = temporaryCFindResultArray else { return }

        let visible = Thread.isMainThread ? MainActor.assumeIsolated { self.window?.isVisible ?? false } : windowState.visible
        guard visible && Date.timeIntervalSinceReferenceDate - lastTemporaryCFindResultUpdate > 1 else { return }

        let curResult = (root as? DCMTKQueryNode)?.children() ?? []

        if firstServerRealtimeResults {
            temporary.removeAllObjects()
            temporary.addObjects(from: curResult)
        } else if curResult.count < 4000 {
            QueryController.mergeAnswers(curResult, into: temporary)
        }

        showResults(temporary)

        lastTemporaryCFindResultUpdate = Date.timeIntervalSinceReferenceDate
    }

    /// Shows `l`, sorted as the outline is; main thread.
    @objc(refreshList:)
    public func refreshList(_ l: [Any]!) {
        let list = l ?? []
        resultArray.removeAllObjects()
        if !list.isEmpty {
            resultArray.addObjects(from: list)
            resultArray.sort(using: sortArray())
        }
        outlineView?.reloadData()

        updateStudyCountLabel()
        scheduleLocalSnapshot()
    }

    // MARK: Asking for a patient

    /// The studies of the patient `ID` on the nodes of the window; the user's
    /// filters come back afterwards.
    @discardableResult @objc(queryPatientID:)
    public func queryPatientID(_ ID: String!) -> [Any]! {
        let savedSettings = savePresetInDictionary(withDICOMNodes: false)

        emptyPreset(self)

        PatientModeMatrix.selectTabViewItem(at: QueryWindowField.patientID.rawValue) // PatientID search
        searchFieldID.stringValue = ID ?? ""

        query(self)

        let result = resultArray.copy() as? [Any]

        applyPresetDictionary(savedSettings)

        return result
    }

    /// The same, by patient name: the user's filters come back afterwards.
    @discardableResult @objc(queryPatientName:)
    public func queryPatientName(_ name: String!) -> [Any]! {
        let savedSettings = savePresetInDictionary(withDICOMNodes: false)

        emptyPreset(self)

        PatientModeMatrix.selectTabViewItem(at: QueryWindowField.patientName.rawValue) // Patient name search
        searchFieldName.stringValue = name ?? ""

        query(self)

        let result = resultArray.copy() as? [Any]

        applyPresetDictionary(savedSettings)

        return result
    }

    @objc(querySelectedStudy:)
    func querySelectedStudy(_ sender: Any?) {
        let item = outlineView.item(atRow: outlineView.selectedRow)

        if let item = item as AnyObject?, type(of: item) == DCMTKStudyQueryNode.self {
            queryButtonPressed = true
            _ = queryPatientID(item.value(forKey: "patientID") as? String)
        } else {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("No Study Selected", comment: ""),
                                            message: NSLocalizedString("Select a study to query all studies of this patient.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    /// The studies of the patient `patientID` on the activated nodes (or the
    /// one selected), without the window; any thread.
    @objc(queryPatientIDwithoutGUI:)
    nonisolated func queryPatientIDwithoutGUI(_ patientID: String!) -> [Any]! {
        let copiedSources = NSArray(array: sourcesArray)

        let noChecked = !copiedSources.contains { QueryController.bool(($0 as AnyObject).value(forKey: "activated")) }

        var selectedServer = -1
        if noChecked {
            selectedServer = Thread.isMainThread ? MainActor.assumeIsolated { self.sourcesTable?.selectedRow ?? -1 } : windowState.selectedSourceRow
        }

        let filterValue = (patientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let result = NSMutableArray()

        if (filterValue as NSString).length > 0 {
            for i in 0..<copiedSources.count {
                let source = copiedSources[i] as AnyObject
                if QueryController.bool(source.value(forKey: "activated")) || selectedServer == i {
                    let aServer = source.value(forKey: "server") as? NSDictionary

                    let qm = QueryArrayController(callingAET: UserDefaults.defaultAETitle(), distantServer: aServer)

                    qm.addFilter(filterValue, forDescription: QueryWindowField.patientID.key)

                    qm.performQuery(false)

                    result.addObjects(from: qm.queries() as? [Any] ?? [])
                }
            }
        }

        return result as? [Any]
    }

    @objc(clearQuery:)
    public func clearQuery(_ sender: Any?) {
        queryManager = nil
        progressIndicator.stopAnimation(nil)
        searchFieldName.stringValue = ""
        searchFieldRefPhysician.stringValue = ""
        searchInstitutionName.stringValue = ""
        searchFieldID.stringValue = ""
        searchFieldAN.stringValue = ""
        searchFieldStudyDescription.stringValue = ""
        searchFieldComments.stringValue = ""
        outlineView.reloadData()
    }

    @IBAction @objc(pressButtons:)
    public func pressButtons(_ sender: Any?) {
        switch (sender as? NSSegmentedControl)?.selectedSegment ?? -1 {
        case 0: // Query
            query(sender)
        case 2: // Retrieve
            retrieve(sender)
        case 3: // Verify
            verify(sender)
        case 1: // Query Selected Patient
            querySelectedStudy(self)
        default:
            break
        }
    }

    /// Echoes every node of the window and shows the answer in its row.
    @IBAction @objc(verify:)
    public func verify(_ sender: Any?) {
        let selectedRow = sourcesTable.selectedRow

        progressIndicator.startAnimation(nil)

        willChangeValue(forKey: "sourcesArray")

        for i in 0..<sourcesArray.count {
            sourcesTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            sourcesTable.scrollRowToVisible(i)

            guard let aServer = sourcesArray[i] as? NSMutableDictionary else { continue }

            let status: Int32
            switch dicomEcho(aServer.object(forKey: "server") as? [AnyHashable: Any]) {
            case 0: status = -1
            case -1: status = -2
            default: status = 0
            }

            aServer.setObject(NSNumber(value: status), forKey: "test" as NSString)
        }

        sourcesTable.selectRowIndexes(selectedRow >= 0 ? IndexSet(integer: selectedRow) : IndexSet(), byExtendingSelection: false)

        didChangeValue(forKey: "sourcesArray")

        progressIndicator.stopAnimation(nil)
    }

    // MARK: The nodes of the window

    /// Activates only the node double-clicked.
    @IBAction @objc(selectUniqueSource:)
    public func selectUniqueSource(_ sender: Any?) {
        willChangeValue(forKey: "sourcesArray")

        let selectedRow = (sender as? NSTableView)?.selectedRow ?? -1
        for i in 0..<sourcesArray.count {
            let source = NSMutableDictionary(dictionary: sourcesArray[i] as? NSDictionary ?? [:])
            source.setObject(NSNumber(value: selectedRow == i), forKey: "activated" as NSString)
            sourcesArray.replaceObject(at: i, with: source)
        }

        didChangeValue(forKey: "sourcesArray")
    }

    /// The node of `servers` that the saved source `savedServer` names: a
    /// DICOMweb node by its identifier, whatever its name, address and paths
    /// became in Locations; a DIMSE node by its AE title, address and port.
    @objc(findCorrespondingServer:inServers:)
    func findCorrespondingServer(_ savedServer: NSDictionary!, inServers servers: [Any]!) -> NSDictionary! {
        let servers = servers ?? []
        if DICOMwebSources.isDICOMwebServer(savedServer?.object(forKey: "server") as? [AnyHashable: Any]) {
            let identifier = (savedServer?.object(forKey: "server") as? NSDictionary)?.object(forKey: DICOMwebSources.nodeKey) as? NSObject
            for case let server as NSDictionary in servers {
                if let found = server.object(forKey: DICOMwebSources.nodeKey) as? NSObject, let identifier, found.isEqual(identifier) {
                    return server
                }
            }
            return nil
        }

        for case let server as NSDictionary in servers {
            if DICOMwebSources.isDICOMwebServer(server as? [AnyHashable: Any]) {
                continue
            }

            if (savedServer?.object(forKey: "AETitle") as? String) == (server.object(forKey: "AETitle") as? String) &&
                (savedServer?.object(forKey: "AddressAndPort") as? String) == DicomNodeConfiguration.address(forServer: server as? [String: Any] ?? [:]) {
                return server
            }
        }

        return nil
    }

    /// The nodes of the window from Locations, keeping the activation saved
    /// for each, and the destinations of the retrieve menu.
    @objc(refreshSources)
    public func refreshSources() {
        UserDefaults.standard.set(sourcesArray, forKey: queryArrayPrefs)

        var serversArray = DICOMNodeService.nodes(sendOnly: false, queryRetrieveOnly: false)
        let savedArray = UserDefaults.standard.array(forKey: queryArrayPrefs) ?? []

        // DICOMweb nodes with Q&R on are sources too, after the DIMSE nodes;
        // they need no listener. The retrieve destinations below stay DIMSE.
        serversArray.append(contentsOf: DICOMwebSources.queryRetrieveServers() as [Any])

        willChangeValue(forKey: "sourcesArray")

        sourcesArray.removeAllObjects()

        func queryRetrieve(_ server: NSDictionary) -> Bool {
            let qr = server.value(forKey: "QR")
            return qr == nil || QueryController.bool(qr)
        }
        func source(_ server: NSDictionary, activated: Any?) -> NSMutableDictionary {
            let source = NSMutableDictionary()
            // dictionaryWithObjectsAndKeys: stopped at the first nil.
            guard let activated else { return source }
            source["activated"] = activated
            guard let name = server.value(forKey: "Description") else { return source }
            source["name"] = name
            guard let title = server.value(forKey: "AETitle") else { return source }
            source["AETitle"] = title
            source["AddressAndPort"] = DicomNodeConfiguration.address(forServer: server as? [String: Any] ?? [:])
            source["server"] = server
            return source
        }

        for case let saved as NSDictionary in savedArray {
            guard let server = findCorrespondingServer(saved, inServers: serversArray), queryRetrieve(server) else { continue }

            sourcesArray.add(source(server, activated: saved.value(forKey: "activated")))

            serversArray.removeAll { ($0 as? NSDictionary)?.isEqual(server) == true }
        }

        for case let server as NSDictionary in serversArray where queryRetrieve(server) {
            sourcesArray.add(source(server, activated: NSNumber(value: false)))
        }

        sourcesTable?.reloadData()

        didChangeValue(forKey: "sourcesArray")

        // *********** Update Send To popup menu

        guard let sendToPopup else { return }

        let previousItem = sendToPopup.selectedItem?.title

        sendToPopup.removeAllItems()

        let ip = String(utf8String: GetPrivateIP()) ?? ""
        sendToPopup.addItem(withTitle: String(format: NSLocalizedString("This Computer - %@/%@:%d", comment: ""),
                                              UserDefaults.defaultAETitle() ?? "", ip, Int32(UserDefaults.defaultAEPort())))

        sendToPopup.menu?.addItem(NSMenuItem.separator())

        for case let server as NSDictionary in DICOMNodeService.nodes(sendOnly: false, queryRetrieveOnly: false) {
            var title = String(format: "%@ - %@/%@:%@", QueryController.text(server.value(forKey: "Description")),
                               QueryController.text(server.value(forKey: "AETitle")), QueryController.text(server.value(forKey: "Address")),
                               QueryController.text(server.value(forKey: "Port")))

            while sendToPopup.indexOfItem(withTitle: title) != -1 {
                title += " "
            }

            sendToPopup.addItem(withTitle: title)

            if title == previousItem {
                sendToPopup.selectItem(withTitle: title)
            }
        }
        captureWindowState()
    }

    /// The node list changed in Locations: posted on any thread.
    @objc(servicesDidChange:)
    nonisolated func servicesDidChange(_ notification: Notification) {
        let controller = self
        onMainActor { controller.refreshSources() }
    }

    /// %@ of a value.
    nonisolated static func text(_ value: Any?) -> String {
        guard let value else { return "(null)" }
        return (value as? NSObject)?.description ?? String(describing: value)
    }

    /// The attributes of the DICOM dictionary that no private creator owns, in
    /// tag order, for the custom field's menu.
    nonisolated static func publicDICOMFields() -> [CIADICOMField] {
        var fields: [CIADICOMField] = []
        do {
            try IsiXDCMTKDictionary.enumeratePublicAttributes { tag, keyword in
                fields.append(CIADICOMField(group: Int32(tag >> 16), element: Int32(tag & 0xffff), name: keyword))
            }
        } catch {
            NSLog("The DICOM dictionary could not be read: %@", (error as NSError).localizedDescription)
        }
        return fields
    }
}
