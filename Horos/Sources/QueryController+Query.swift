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
import IsiXPreferences

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
                LogText.log(exception, stack: false, in: "-[QueryController query:]")
            }
        }
    }

    /// Queries with the filters of the window, on the main thread.
    @objc(queryWithDisplayingErrors:)
    public func queryWithDisplayingErrors(_ showError: Bool) -> Bool {
        let filters = windowFilters(withDICOMNodes: true)
        captureWindowState()
        _ = queryAnswers(showError, run: queryRun(filters), showing: !autoQueryValue)
        return false
    }

    /// Queries the activated nodes of `instance`, a preset, with its filters,
    /// and shows the answers in the Query/Retrieve window. In the automatic
    /// query's window a query of the window shows its answers as they come
    /// only: the scheduler keeps and shows those of each instance.
    @objc(queryWithDisplayingErrors:instance:)
    public func queryWithDisplayingErrors(_ showError: Bool, instance: NSMutableDictionary!) -> Bool {
        let filters = QueryWindowFilters(propertyList: instance as? [String: Any] ?? [:])
        _ = queryAnswers(showError, run: queryRun(filters), showing: !autoQueryValue)
        return false
    }

    /// One query with `filters`, as the thread that runs it receives it; main
    /// thread. A query of the window reads the dates of its pickers, whatever
    /// dates the filters hold.
    func queryRun(_ filters: QueryWindowFilters) -> QueryWindowRun {
        var filters = filters
        filters.fromDate = fromDate?.dateValue ?? Date()
        filters.toDate = toDate?.dateValue ?? Date()
        return queryRun(dated: filters)
    }

    /// The same with the dates `filters` hold, and the nodes as the sources
    /// table lists them when it starts.
    func queryRun(dated filters: QueryWindowFilters) -> QueryWindowRun {
        preferences.set(sourcesArray, forKey: queryArrayPrefs)
        let keyword = filters.field == .customField ? customFieldKeyword(forAttribute: filters.customFieldAttribute) : nil
        var sources = QueryWindowState()
        sources.sources = currentSources()
        return QueryWindowRun(filters: filters, customFieldKeyword: keyword, sources: sources)
    }

    /// The keyword of the attribute titled `title` in the custom field's menu.
    func customFieldKeyword(forAttribute title: String?) -> String? {
        let dicomField = dicomFields.first { $0.title() == title }
        let tag = (UInt32(UInt16(truncatingIfNeeded: dicomField?.group() ?? 0)) << 16) | UInt32(UInt16(truncatingIfNeeded: dicomField?.element() ?? 0))
        return try? IsiXDCMTKDictionary.keyword(forTag: tag)
    }

    /// The answers of the nodes of `run`, queried with its filters, merged and
    /// sorted; on any thread, and shown in the window when `showing`. The
    /// automatic query runs it on a thread of its own.
    nonisolated func queryAnswers(_ showError: Bool, run: QueryWindowRun, showing: Bool) -> [Any] {
        let onMain = Thread.isMainThread
        let workers = self.workers
        let tempResultArray = NSMutableArray()

        workers.beginRealtimeAnswers(showing: onMain)

        objc_sync_enter(self)
        workers.cancelQueryThreads()
        objc_sync_exit(self)

        autoQueryLock.lock()

        var atLeastOneSource = false

        do {
            try HorosObjCException.perform {
                workers.isFirstNode = true

                if onMain {
                    MainActor.assumeIsolated { self.refreshList([]) } // Clean the list
                }

                for server in run.servers {
                    let manager = QueryArrayController(callingAET: UserDefaults.defaultAETitle(), distantServer: server.propertyList as NSDictionary)
                    workers.queryManager = manager

                    atLeastOneSource = true

                    let (queryItem, nameAlternatives) = self.addFilters(of: run, to: manager, showError: showError)

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

                        if !self.preferences[NetworkPreferences.allowsBlankQuery] {
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
                        workers.resetRealtimeUpdate()
                        // If there are multiple sources
                        self.realtimeCFindResults(Notification(name: Notification.Name("realtimeCFindResults"), object: manager.rootNode()))
                    }

                    if workers.isFirstNode {
                        workers.isFirstNode = false
                        tempResultArray.removeAllObjects()
                        tempResultArray.addObjects(from: manager.queries() as? [Any] ?? [])
                    } else {
                        QueryController.mergeAnswers(manager.queries() as? [Any] ?? [], into: tempResultArray)
                    }
                }

                if tempResultArray.count > 0 {
                    tempResultArray.sort(using: self.sortArray())
                }

                workers.isFirstNode = true
            }
        } catch {
            QueryController.log(error, "-[QueryController queryAnswers:run:showing:]")
        }

        autoQueryLock.unlock()

        if showing {
            showResults(tempResultArray.map { $0 as AnyObject })
        }

        if !atLeastOneSource && Thread.isMainThread && showError {
            MainActor.assumeIsolated {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Query", comment: ""),
                                                message: NSLocalizedString("Please select a DICOM node (check box).", comment: ""),
                                                defaultButton: NSLocalizedString("Continue", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }

        // After the complete list: a list made while the C-FIND ran may still
        // be on its way through the main queue, and must not replace it.
        workers.endRealtimeAnswers()

        return tempResultArray.map { $0 }
    }

    /// Gives `manager` the filters of `run`, as each node receives them
    /// (QueryWindowFilters builds them): whether the query asks for something,
    /// and the other spellings of a patient's name to try when that one finds
    /// nothing. A value the character set cannot write is reported on the
    /// main thread, with the offer to switch to UTF-8.
    nonisolated func addFilters(of run: QueryWindowRun, to manager: QueryArrayController, showError: Bool) -> (Bool, [String]) {
        let preferences = self.preferences
        let query = run.filters.query(settings: QueryWindowQuerySettings(defaults: preferences), customFieldKeyword: run.customFieldKeyword,
                                      now: Date(), timeZone: NSTimeZone.default)
        if query.field == .customField {
            NSLog("DICOM Q&R with custom field: %@", QueryLog.term(key: run.customFieldKeyword, value: query.typedValue))
        }
        if query.unknownDateChoice {
            NSLog("******* unknown setDateQuery tag: %d", run.filters.dateChoice)
        }

        for filter in query.filters {
            manager.addFilter(filter.value, forDescription: filter.key)
        }

        if let field = query.field, field.checksEncoding, showError, Thread.isMainThread,
           (query.typedValue as NSString?)?.cString(using: NSString.encoding(forDICOMCharacterSet: preferences[NetworkPreferences.queryCharacterSet])) == nil {
            let switchToUTF8 = MainActor.assumeIsolated {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Query Encoding", comment: ""),
                                            message: NSLocalizedString("The query cannot be encoded in current character set. Should I switch to UTF-8 (ISO_IR 192) encoding?", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""),
                                            alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) == HorosAlertDefaultResponse
            }
            if switchToUTF8 {
                preferences.set("ISO_IR 192", for: NetworkPreferences.queryCharacterSet)
                manager.addFilter(preferences[NetworkPreferences.queryCharacterSet], forDescription: "SpecificCharacterSet")
            }
        }

        guard let name = query.patientName else { return (query.asksForSomething, []) }
        let alternatives = PatientNameMatching.alternativeRemoteTerms(
            for: name, encoding: NSString.encoding(forDICOMCharacterSet: preferences[NetworkPreferences.queryCharacterSet]))
        return (query.asksForSomething, alternatives)
    }

    /// The answers of one more node, merged into those of the nodes before it.
    nonisolated static func mergeAnswers(_ answers: [Any], into results: NSMutableArray) {
        var merged = results.map { $0 as AnyObject }
        QueryResultMerge.merge(answers.map { $0 as AnyObject }, into: &merged, indexingAdditions: false,
                               uid: queryUID, images: queryImageCount)
        results.setArray(merged)
    }

    /// The same, for the answers shown while a C-FIND runs.
    nonisolated static func mergeAnswers(_ answers: [AnyObject], into results: inout [AnyObject]) {
        QueryResultMerge.merge(answers, into: &results, indexingAdditions: false, uid: queryUID, images: queryImageCount)
    }

    /// Shows `results`, the complete list of a query, in the window, from any
    /// thread.
    nonisolated func showResults(_ results: [AnyObject]) {
        let controller = self
        let handed = QueryAnswers(items: results)
        onMainActor { controller.refreshList(handed.items) }
    }

    /// Runs the query prepared in the query manager, on any thread; a query of
    /// the window cancels the ones still running.
    @objc(performQuery:)
    public nonisolated func performQuery(_ showErrors: NSNumber!) {
        let controller = self
        onMainActor { controller.checkAndViewTry = -1 }

        var showErrors = showErrors?.boolValue ?? false
        if !Thread.isMainThread {
            showErrors = false
        }

        autoreleasepool {
            var performQuery = false

            objc_sync_enter(self)
            workers.cancelQueryThreads()

            if workers.beginCFind(on: Thread.current) {
                startProgress()

                performQuery = true
            }
            objc_sync_exit(self)

            if performQuery {
                workers.queryManager?.performQuery(showErrors)

                objc_sync_enter(self)
                stopProgress()

                workers.endCFind(on: Thread.current)
                objc_sync_exit(self)
            }
        }
    }

    nonisolated func startProgress() {
        let controller = self
        onMainActor { controller.progressIndicator?.startAnimation(nil) }
    }

    nonisolated func stopProgress() {
        let controller = self
        onMainActor { controller.progressIndicator?.stopAnimation(nil) }
    }

    /// The answers of a node while its C-FIND runs: shown once a second.
    @objc(realtimeCFindResults:)
    nonisolated func realtimeCFindResults(_ notification: Notification) {
        guard let root = notification.object as AnyObject?, root === (workers.queryManager?.rootNode() as AnyObject?) else { return }

        let visible = Thread.isMainThread ? MainActor.assumeIsolated { self.window?.isVisible ?? false } : windowState.visible
        let now = Date.timeIntervalSinceReferenceDate
        guard visible && workers.realtimeAnswersAreDue(now: now) else { return }

        let curResult = ((root as? DCMTKQueryNode)?.children() ?? []).map { $0 as AnyObject }
        if let shown = workers.realtimeAnswers(adding: curResult, now: now, merge: QueryController.mergeAnswers) {
            showPartialResults(shown.answers, turn: shown.turn)
        }
    }

    /// Shows `results`, what a C-FIND under way has answered so far, from any
    /// thread, unless the window has moved on: the C-FIND reports on its own
    /// thread and the list crosses the main queue, while the thread that
    /// asked shows the complete list itself as soon as the C-FIND ends. A
    /// partial list that arrives after that, or after a later one, is dropped.
    nonisolated func showPartialResults(_ results: [AnyObject], turn: LiveQueryAnswers<AnyObject>.Turn) {
        let controller = self
        let handed = QueryAnswers(items: results)
        onMainActor {
            guard controller.workers.takeRealtimeTurn(turn) else { return }
            controller.refreshList(handed.items)
        }
    }

    /// Shows `l`, sorted as the outline is; main thread.
    @objc(refreshList:)
    public func refreshList(_ l: [Any]!) {
        if outlineView?.isWaitingForChildren == true {
            outlineView.holdUntilChildrenArrive { [weak self] in self?.refreshList(l) }
            return
        }
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
    /// one selected), without the window; any thread. Off the main thread the
    /// nodes are those of the last copy of the window.
    nonisolated func queryPatientIDwithoutGUI(_ patientID: String!) -> [Any]! {
        let state = Thread.isMainThread ? MainActor.assumeIsolated { self.currentWindowState() } : windowState
        return QueryController.queryPatientID(patientID, sources: state.sourcesForPatientQuery())
    }

    /// The studies of the patient `patientID` on `sources`, on the calling thread.
    nonisolated static func queryPatientID(_ patientID: String?, sources: [QueryWindowSource]) -> [Any] {
        let filterValue = (patientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [Any] = []

        if (filterValue as NSString).length > 0 {
            for source in sources {
                let qm = QueryArrayController(callingAET: UserDefaults.defaultAETitle(), distantServer: source.server.map { $0.propertyList as NSDictionary })

                qm.addFilter(filterValue, forDescription: QueryWindowField.patientID.key)

                qm.performQuery(false)

                result.append(contentsOf: qm.queries() as? [Any] ?? [])
            }
        }

        return result
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
        preferences.set(sourcesArray, forKey: queryArrayPrefs)

        var serversArray: [Any] = DICOMNodeService.dicomNodes(sendOnly: false, queryRetrieveOnly: false).map(\.propertyList)
        let savedArray = preferences.array(forKey: queryArrayPrefs) ?? []

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

        // The C-MOVE destinations: the retrieve sends to the node chosen here.
        func text(_ value: PropertyListValue?) -> String { value?.text ?? "(null)" }
        for node in DICOMNodeService.dicomNodes(sendOnly: false, queryRetrieveOnly: false) {
            var title = String(format: "%@ - %@/%@:%@", text(node[DICOMNode.Key.description]), text(node[DICOMNode.Key.aeTitle]),
                               text(node[DICOMNode.Key.address]), text(node[DICOMNode.Key.port]))

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
            NSLog("The DICOM dictionary could not be read: %@", LogText.error(error))
        }
        return fields
    }
}
