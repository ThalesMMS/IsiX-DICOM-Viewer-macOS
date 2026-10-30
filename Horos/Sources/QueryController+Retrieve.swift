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
import CoreData
import IsiXDICOMNetwork

/// The retrieves of the window: what of the selection to ask for, the thread
/// that asks each node, the queue of Settings > Locations, and Retrieve &
/// View, which opens a viewer as soon as the first image of a study is here.
extension QueryController {
    // MARK: Asking for the selection

    @IBAction @objc(retrieve:)
    public func retrieve(_ sender: Any?) {
        retrieve(sender, onlyIfNotAvailable: false)
    }

    @objc(retrieve:onlyIfNotAvailable:)
    public func retrieve(_ sender: Any?, onlyIfNotAvailable: Bool) {
        retrieve(sender, onlyIfNotAvailable: onlyIfNotAvailable, forViewing: false)
    }

    @objc(retrieve:onlyIfNotAvailable:forViewing:)
    func retrieve(_ sender: Any?, onlyIfNotAvailable: Bool, forViewing: Bool) {
        let selectedRowIndexes = outlineView.selectedRowIndexes
        guard !selectedRowIndexes.isEmpty else { return }

        let selectedItems = selectedRowIndexes.compactMap { outlineView.item(atRow: $0) }
        retrieve(sender, onlyIfNotAvailable: onlyIfNotAvailable, forViewing: forViewing, items: selectedItems, showGUI: true)
    }

    /// Retrieves `items`: with `onlyIfNotAvailable`, only what is not complete
    /// here; with `forViewing`, to open them; with `showGUI`, telling the user.
    /// A study already being retrieved with the same number of images is not
    /// asked for again.
    @objc(retrieve:onlyIfNotAvailable:forViewing:items:showGUI:)
    func retrieve(_ sender: Any?, onlyIfNotAvailable: Bool, forViewing: Bool, items: [Any]!, showGUI: Bool) {
        let items = items ?? []
        let selectedItems = NSMutableArray()
        var takenItems: [Any] = []

        // Retrieve with Option held asks for everything again, including what
        // the node declared it cannot send; otherwise a retrieve asks only for
        // what it can.
        let retryEverything = showGUI && !onlyIfNotAvailable && NSApp.currentEvent?.modifierFlags.contains(.option) == true

        guard !items.isEmpty else { return }

        for item in items {
            let node = item as? DCMTKQueryNode
            node?.setShowErrorMessage(showGUI)
            node?.noSmartMode = retryEverything

            // A series of a study this node is retrieving now goes first in
            // that retrieve; what it already received is not asked for again.
            if !retryEverything && QueryController.giveSeriesToRunningRetrieve(item) {
                takenItems.append(item)
                continue
            }

            let reported = QueryController.int32((item as AnyObject).value(forKey: "numberImages"))
            if onlyIfNotAvailable {
                let localNumber = Int32(truncatingIfNeeded: localFileCount(forItem: item))

                let inventory = node?.retrieveInventory
                if inventory != nil { _ = node?.refreshRetrieveInventory() }
                // Complete but for what the peer counts without listing or
                // cannot send: nothing to fetch while its count stays the same;
                // a new count queries the inventory again. A DICOMweb node does
                // list everything it has: what it counts without listing, while
                // fewer are here, its listing left out, as one with pages
                // shorter than asked does.
                let listingShort = inventory != nil && DICOMwebSources.isDICOMwebServer(node?.extraParameters()) &&
                    (inventory?.unlistedCount ?? 0) > 0 && localNumber < reported
                let wanted: Bool
                if let inventory {
                    wanted = !inventory.matchesReportedCount(Int(reported)) || !inventory.isSatisfied || listingShort
                } else {
                    wanted = localNumber < reported || reported == 0
                }
                if wanted {
                    markInTransfer(item, reported: reported, into: selectedItems)
                } else {
                    NSLog("Already here! We don't need to download it...")
                }
            } else {
                markInTransfer(item, reported: reported, into: selectedItems)
            }
        }

        var startedTransfer = false

        if selectedItems.count > 0 {
            captureWindowState()
            if sendToPopup.indexOfSelectedItem != 0 && forViewing {
                if showGUI {
                    _ = HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Query & Retrieve", comment: ""),
                                                    message: NSLocalizedString("If you want to retrieve & view these images, change the destination to this computer ('retrieve to' menu).", comment: ""),
                                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
            } else {
                var wait: WaitRendering?

                if showGUI {
                    wait = WaitRendering(NSLocalizedString("Starting Retrieving...", comment: ""))
                    wait?.showWindow(self)
                }

                checkAndViewTry = -1

                // The study each series was listed under, for the worker.
                for item in selectedItems where item is DCMTKSeriesQueryNode {
                    if let study = outlineView.parent(forItem: item) {
                        QueryController.synchronized(studiesOfRetrievedSeries) {
                            studiesOfRetrievedSeries.setObject(study as AnyObject, forKey: item as AnyObject)
                        }
                    }
                }

                // A retrieve the user asks for here waits its turn in the queue
                // of Settings > Locations; Command queues it behind the ones
                // under way. Retrieve & View and auto-retrieves do not wait.
                let thread: Thread
                var status = QueryController.singularPluralCount(selectedItems.count, NSLocalizedString("study", comment: ""), NSLocalizedString("studies", comment: ""))
                if showGUI && !forViewing && !onlyIfNotAvailable {
                    // Who is waiting: the patient of a single study, as the
                    // line reads once the retrieve runs.
                    if selectedItems.count == 1, let name = (selectedItems.lastObject as? DCMTKQueryNode)?.name(), !name.isEmpty {
                        status += " - " + name.replacingOccurrences(of: "^", with: " ")
                    }
                    let explicitlyQueued = NSApp.currentEvent?.modifierFlags.contains(.command) == true
                    let ticket = RetrieveQueue.shared.ticket(explicitlyQueued: explicitlyQueued)
                    let queued: NSDictionary = ["items": selectedItems, "ticket": ticket, "status": status]
                    thread = Thread(target: self, selector: #selector(performQueuedRetrieve(_:)), object: queued)
                    // Activity finds the ticket from the row, to move or rename it.
                    thread.threadDictionary[RetrieveQueue.threadKey] = ticket
                    let position = RetrieveQueue.shared.position(of: ticket)
                    if position > 0 {
                        status = RetrieveQueueActivity.waitingStatus(status, position: position)
                    }
                } else {
                    thread = Thread(target: self, selector: #selector(performRetrieve(_:)), object: selectedItems)
                }
                thread.name = NSLocalizedString("Retrieving images...", comment: "")
                thread.status = status
                if selectedItems.count > 1 {
                    thread.progress = 0
                }

                thread.supportsCancel = true
                ThreadsManager.default()?.addThreadAndStart(thread)
                startedTransfer = true

                if showGUI {
                    Thread.sleep(forTimeInterval: 0.2)

                    wait?.close()
                }
            }
        }

        // A study that is already complete here, one already in transfer, and
        // a selection refused because the destination is another node all leave
        // this method without a transfer. A viewing session begun for them has
        // nobody left to end it, so settle them from what is on disk.
        let unstarted = NSMutableArray(array: items)
        if startedTransfer {
            unstarted.removeObjects(in: selectedItems as? [Any] ?? [])
        }
        unstarted.removeObjects(in: takenItems)
        settleRetrieveViewing(forItems: unstarted as? [Any], cancelled: false)
    }

    /// Adds `item` to `selectedItems` unless it is in transfer with the same
    /// number of images, and records it as in transfer.
    private func markInTransfer(_ item: Any, reported: Int32, into selectedItems: NSMutableArray) {
        let stringID = QueryController.stringID(forStudy: item)

        RetrieveInTransfer.withLock { inTransfer in
            // We only want to re-retrieve the study if they are new files
            // compared to last time... we are maybe currently in the middle of
            // a retrieve...
            if (inTransfer[stringID] ?? 0) != reported || reported == 0 {
                selectedItems.add(item)
                inTransfer[stringID] = reported
            } else {
                NSLog("Already in transfer.... We don't need to download it...")
            }
        }
    }

    @IBAction @objc(retrieveAndView:)
    public func retrieveAndView(_ sender: Any?) {
        if QueryController.progressiveRetrieveViewingEnabled() {
            let now = Date.timeIntervalSinceReferenceDate
            for row in outlineView.selectedRowIndexes {
                let item = outlineView.item(atRow: row)
                if RetrieveViewing.shared.begin(studyUID: QueryController.viewingStudyUID(item), seriesUID: QueryController.viewingSeriesUID(item), at: now) {
                    addPendingRetrieveAndViewItem(item)
                }
            }
        }
        retrieve(self, onlyIfNotAvailable: true, forViewing: true)
        view(self)
    }

    @IBAction @objc(retrieveAndViewClick:)
    public func retrieveAndViewClick(_ sender: Any?) {
        let clicked = outlineView.clickedColumn
        if clicked >= 0 && clicked < outlineView.tableColumns.count &&
            outlineView.tableColumns[clicked].identifier.rawValue == "comment" {
            return
        }

        if outlineView.clickedRow >= 0 {
            retrieveAndView(sender)
        }
    }

    @objc(retrieveClick:)
    func retrieveClick(_ sender: Any?) {
        if outlineView.clickedRow >= 0 {
            retrieve(sender)
        }
    }

    /// Command on a row's download arrow (QueryOutlineView): that row only,
    /// queued behind the retrieves under way, as the event still holds Command.
    @objc(queueRetrieveOfItem:)
    func queueRetrieveOfItem(_ item: Any?) {
        if let item {
            retrieve(self, onlyIfNotAvailable: false, forViewing: false, items: [item], showGUI: true)
        }
    }

    // MARK: Series given to the retrieve of their study

    /// Series chosen while their study was being retrieved from the same node:
    /// that retrieve takes them first instead of a second one asking for the
    /// same instances, and their viewing ends with it. By node and study.
    private nonisolated static let seriesTakenByRunningRetrieve = SeriesTakenByRunningRetrieve()

    private final class SeriesTakenByRunningRetrieve: @unchecked Sendable {
        let lock = NSLock()
        var series: [String: [AnyObject]] = [:]
    }

    private nonisolated static func runningRetrieveKey(_ endpoint: String?, _ studyUID: String?) -> String {
        return String(format: "%@\n%@", endpoint ?? "", studyUID ?? "")
    }

    nonisolated static func giveSeriesToRunningRetrieve(_ item: Any) -> Bool {
        guard let series = item as? DCMTKSeriesQueryNode else { return false }
        let study = series.studyInstanceUID() ?? "", endpoint = series.inventoryEndpoint()
        guard !study.isEmpty, !(series.uid() ?? "").isEmpty else { return false }
        guard RetrievePlan.prioritize(series: series.uid() ?? "", study: study, endpoint: endpoint) else { return false }
        let taken = seriesTakenByRunningRetrieve
        taken.lock.lock()
        defer { taken.lock.unlock() }
        let key = runningRetrieveKey(endpoint, study)
        var list = taken.series[key] ?? []
        if !list.contains(where: { $0 === series }) { list.append(series) }
        taken.series[key] = list
        return true
    }

    nonisolated static func seriesTakenByRetrieve(of item: Any) -> [Any] {
        guard let study = item as? DCMTKStudyQueryNode else { return [] }
        let taken = seriesTakenByRunningRetrieve
        taken.lock.lock()
        defer { taken.lock.unlock() }
        let key = runningRetrieveKey(study.inventoryEndpoint(), study.uid())
        let series = taken.series[key] ?? []
        taken.series[key] = nil
        return series
    }

    // MARK: The retrieve threads

    /// A retrieve that ends, however it ends, is no longer in transfer: an
    /// entry left in transfer made every later retrieve of the study stop at
    /// "Already in transfer", without a word.
    @objc(forgetRetrieveInTransfer:)
    nonisolated func forgetRetrieveInTransfer(_ items: [Any]!) {
        RetrieveInTransfer.withLock { inTransfer in
            for item in items ?? [] {
                inTransfer[QueryController.stringID(forStudy: item)] = nil
            }
        }
    }

    /// A retrieve of the queue: waits for its turn, retrieves, and makes room
    /// for the next. Stopped in Activity while it waits, it ends as a cancelled
    /// retrieve, without having asked the node for anything.
    @objc(performQueuedRetrieve:)
    nonisolated func performQueuedRetrieve(_ queued: NSDictionary!) {
        autoreleasepool {
            let items = queued?.object(forKey: "items") as? [Any] ?? []
            guard let ticket = queued?.object(forKey: "ticket") as? RetrieveQueue.Ticket else { return }
            let status = queued?.object(forKey: "status") as? String ?? ""

            // The line shows the retrieve's place, which moves as the ones
            // ahead end or the user reorders the queue in Activity.
            if RetrieveQueue.shared.waitForTurn(ticket, whileWaiting: { position in
                Thread.current.status = RetrieveQueueActivity.waitingStatus(status, position: position)
            }) {
                Thread.current.status = status
                performRetrieve(items)
            } else {
                forgetRetrieveInTransfer(items)
                settleRetrieveViewing(forItems: items, cancelled: true)
            }
            RetrieveQueue.shared.finish(ticket)
        }
    }

    /// Retrieves `array` on the calling worker thread, in the order of the
    /// window's nodes, to this computer or to the node chosen in the retrieve
    /// menu.
    @objc(performRetrieve:)
    public nonisolated func performRetrieve(_ array: [Any]!) {
        guard BrowserController.currentBrowser()?.database != nil else { // During DB rebuild
            return
        }

        autoreleasepool {
            performRetrieveOnThisThread(array ?? [])
        }
    }

    private nonisolated func performRetrieveOnThisThread(_ given: [Any]) {
        // A retrieve the user renamed in Activity keeps its name.
        let ticket = RetrieveQueue.ticket(of: Thread.current)
        let label = ticket.flatMap { RetrieveQueue.shared.label(of: $0) }
        Thread.current.name = (label ?? "").isEmpty ? NSLocalizedString("Retrieving images...", comment: "") : label

        // This used to refuse every retrieval whenever the listener was off,
        // and to return in silence. A WADO retrieval is a C-FIND and then plain
        // HTTP GETs, so nothing listens for it; a user who runs no SCP was
        // blocked from the one method that would have worked, with only an
        // NSLog to say so. Refuse only a batch in which nothing could succeed,
        // and say it where it can be seen.
        let retrieveModes = given.map { item -> NSNumber in
            let parameters = (item as? DCMTKQueryNode)?.extraParameters() as? [String: Any] ?? [:]
            return NSNumber(value: RetrieveListenerRequirement.retrieveMode(forServer: parameters))
        }
        if AppController.shared()?.isStoreSCPRunning() == false &&
            RetrieveListenerRequirement.listenerRequired(forEveryRetrieveMode: retrieveModes) {
            NSLog("----- isStoreSCPRunning == NO, and every node in this retrieve needs the listener")
            DCMTKQueryNode.performSelector(onMainThread: #selector(DCMTKQueryNode.errorMessage(_:)), with:
                [NSLocalizedString("Retrieve Failed", comment: ""),
                 NSLocalizedString("These nodes retrieve with C-MOVE, which requires the DICOM Listener. Activate it in Preferences - Listener, or use C-GET or WADO.", comment: ""),
                 NSLocalizedString("OK", comment: "")] as NSArray, waitUntilDone: false)
            forgetRetrieveInTransfer(given)
            return
        }

        let moveArray = NSMutableArray()

        QueryController.synchronized(self) { numberOfRunningRetrieve += 1 }

        // Apply the same order for retrieving, as the sources order
        var reorderedArray: [Any] = []
        func contains(_ list: [Any], _ item: Any) -> Bool { list.contains { ($0 as AnyObject) === (item as AnyObject) } }

        do {
            try HorosObjCException.perform {
                for case let source as NSObject in NSArray(array: self.sourcesArray) {
                    let server = source.value(forKey: "server") as AnyObject?
                    for case let node as DCMTKQueryNode in given {
                        if node._hostname == server?.value(forKey: "Address") as? String &&
                            node._port == QueryController.int32(server?.value(forKey: "Port")) && !contains(reorderedArray, node) {
                            reorderedArray.append(node)
                        }
                    }
                }
            }
        } catch {
            QueryController.log(error, "-[QueryController performRetrieve:]")
        }

        for node in given where !contains(reorderedArray, node) {
            reorderedArray.append(node)
        }

        var array = given
        if given.count == reorderedArray.count {
            array = reorderedArray
        } else {
            NSLog("------- array.count != reorderedArray.count : QueryController performRetrieve")
        }

        let state = windowState

        do {
            try HorosObjCException.perform {
                let dictionary = NSMutableDictionary(dictionary: self.queryManager?.parameters() as? [AnyHashable: Any] ?? [:], copyItems: true)

                NSLog("Retrieve START")

                var allowNonCMOVE = true

                for case let object as DCMTKQueryNode in array {
                    dictionary["retrieveMode"] = ((object.extraParameters() as NSDictionary?)?.value(forKey: "retrieveMode") as? NSObject)?.copy()
                    dictionary["calledAET"] = (object.value(forKey: "calledAET") as? NSObject)?.copy()
                    dictionary["hostname"] = (object.value(forKey: "hostname") as? NSObject)?.copy()
                    dictionary["port"] = (object.value(forKey: "port") as? NSObject)?.copy()
                    dictionary["transferSyntax"] = (object.value(forKey: "transferSyntax") as? NSObject)?.copy()

                    dictionary["moveDestination"] = UserDefaults.defaultAETitle()

                    var dstDict: NSDictionary?

                    if state.sendToIndex != 0 {
                        let index = state.sendToIndex - 2

                        dstDict = DICOMNodeService.serversList(sendOnly: false, queryRetrieveOnly: false).object(at: index) as? NSDictionary

                        dictionary["moveDestination"] = dstDict?.value(forKey: "AETitle")

                        allowNonCMOVE = false
                    }

                    if QueryController.int32(dstDict?.value(forKey: "Port")) == QueryController.int32(dictionary.value(forKey: "port")) &&
                        (dstDict?.value(forKey: "Address") as? String) != nil &&
                        (dstDict?.value(forKey: "Address") as? String) == (dictionary.value(forKey: "hostname") as? String) {
                        NSLog("move source == move destination -> Do Nothing")
                    } else {
                        let d = NSMutableDictionary()
                        d["query"] = object
                        d["retrieveMode"] = dictionary.object(forKey: "retrieveMode")

                        if type(of: object) == DCMTKSeriesQueryNode.self, let study = self.studyOfSeries(object) {
                            d["study"] = study // for WADO retrieve at Series level
                        }

                        if let destination = dictionary.object(forKey: "moveDestination") {
                            d["moveDestination"] = destination
                        }

                        moveArray.add(d)
                    }
                }

                // Several at once: what did not arrive complete is told in one
                // notice once all have ended, not in one notice each.
                let batch = moveArray.count > 1
                if batch {
                    for case let d as NSDictionary in moveArray {
                        (d.object(forKey: "query") as? DCMTKQueryNode)?.deferFailureNotice = true
                    }
                }

                var i = 0
                for case let d as NSDictionary in moveArray {
                    if Thread.current.isCancelled { break }
                    guard let object = d.object(forKey: "query") as? DCMTKQueryNode else { continue }

                    var status: String?

                    if type(of: object) == DCMTKStudyQueryNode.self {
                        if array.count == 1 {
                            status = String(format: NSLocalizedString("%d study", comment: ""), Int32(array.count))
                        } else {
                            status = String(format: NSLocalizedString("%d studies", comment: ""), Int32(array.count))
                        }

                        if let name = object.name() {
                            status = (status ?? "") + " - " + name
                        }
                    }

                    if type(of: object) == DCMTKSeriesQueryNode.self {
                        status = String(format: NSLocalizedString("%d series", comment: ""), Int32(array.count))

                        // A series knows only its own number and description;
                        // who it belongs to is on the study it was listed under.
                        if let patientName = (d.object(forKey: "study") as? DCMTKQueryNode)?.name(), !patientName.isEmpty {
                            status = (status ?? "") + " - " + patientName
                        }

                        if let description = object.theDescription() {
                            status = (status ?? "") + " - " + description
                        }
                    }

                    Thread.current.status = status?.replacingOccurrences(of: "^", with: " ")

                    do {
                        try HorosObjCException.perform {
                            if HorosDICOMGlobalAbortRequested() == 0 {
                                if allowNonCMOVE {
                                    object.move(d as? [AnyHashable: Any], retrieveMode: QueryController.int32(d.object(forKey: "retrieveMode")))
                                } else {
                                    object.move(d as? [AnyHashable: Any], retrieveMode: Int32(DICOMRetrieveMode.cMove.rawValue))
                                }
                            }
                        }
                    } catch {
                        NSLog("dictionary keys: %@", ((d.allKeys as? [String]) ?? []).joined(separator: ", "))
                        NSLog("object: %@", object.uid() ?? "(null)")
                        QueryController.log(error, "-[QueryController performRetrieve:]")
                    }

                    RetrieveInTransfer.withLock { $0[QueryController.stringID(forStudy: object)] = nil }

                    i += 1
                    Thread.current.progress = CGFloat(Float(i) / Float(moveArray.count))
                    if Thread.current.isCancelled {
                        // move: has observed this worker's cancellation. Do not
                        // broadcast an abort to unrelated retrievals or another
                        // application instance.
                        break
                    }
                }

                if batch {
                    var incomplete: [String] = []
                    for case let d as NSDictionary in moveArray {
                        guard let object = d.object(forKey: "query") as? DCMTKQueryNode else { continue }
                        object.deferFailureNotice = false
                        if !object.lastRetrieveIncomplete || !object.showErrorMessage() {
                            continue
                        }
                        var what = (object.name() ?? "").replacingOccurrences(of: "^", with: " ")
                        if let description = object.theDescription(), !description.isEmpty {
                            what = what.isEmpty ? description : String(format: "%@, %@", what, description)
                        }
                        let missing = object.lastRetrieveMissing > 0
                            ? String(format: NSLocalizedString("%ld missing", comment: "instances missing from a retrieved study"), object.lastRetrieveMissing)
                            : NSLocalizedString("not complete", comment: "a retrieved study with instances missing")
                        incomplete.append(String(format: "\u{2022} %@ \u{2014} %@", what, missing))
                    }
                    if !incomplete.isEmpty && !Thread.current.isCancelled && HorosDICOMGlobalAbortRequested() == 0 {
                        let message = String(format: NSLocalizedString("%lu of %lu did not arrive complete. Retrieve them again to complete them:", comment: "retrieve of several studies"),
                                             incomplete.count, moveArray.count) + "\n" + incomplete.joined(separator: "\n")
                        DCMTKQueryNode.performSelector(onMainThread: #selector(DCMTKQueryNode.errorMessage(_:)), with:
                            [NSLocalizedString("Retrieve Incomplete", comment: ""), message, NSLocalizedString("Continue", comment: "")] as NSArray,
                                                       waitUntilDone: false)
                    }
                }

                Thread.sleep(forTimeInterval: 0.5) // To allow errorMessage on the main thread...

                if self.windowState.visible && HorosDICOMGlobalAbortRequested() == 0 {
                    for item in array {
                        (item as? DCMTKQueryNode)?.setShowErrorMessage(true)
                    }
                }

                NSLog("Retrieve END")
            }
        } catch {
            QueryController.log(error, "-[QueryController performRetrieve:]")
        }

        forgetRetrieveInTransfer(array)

        // Whatever was opened for viewing now learns how the transfer ended.
        // Opening the viewer never meant success; the peer's counters and the
        // confirmed inventory decide, on the main thread where the state is
        // read.
        settleRetrieveViewing(forItems: array, cancelled: Thread.current.isCancelled)

        QueryController.synchronized(self) { numberOfRunningRetrieve -= 1 }
    }

    /// The study a series row was listed under: the outline's parent on the
    /// main thread, the one recorded when its retrieve started elsewhere.
    nonisolated func studyOfSeries(_ series: AnyObject) -> AnyObject? {
        if Thread.isMainThread {
            nonisolated(unsafe) let series = series
            nonisolated(unsafe) var parent: AnyObject?
            MainActor.assumeIsolated { parent = self.outlineView?.parent(forItem: series) as AnyObject? }
            return parent
        }
        return QueryController.synchronized(studiesOfRetrievedSeries) {
            studiesOfRetrievedSeries.object(forKey: series)
        }
    }

    // MARK: How a viewing ends

    /// How a viewing session ends, from what the peer reported and what is on
    /// disk. Called when a transfer finishes and when one never starts: a
    /// session left in "receiving" shows "transfer in progress" for ever.
    @objc(settleRetrieveViewingForItems:cancelled:)
    nonisolated func settleRetrieveViewing(forItems items: [Any]!, cancelled: Bool) {
        nonisolated(unsafe) let items = items ?? []
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.settleRetrieveViewing(forItems: items, cancelled: cancelled)
            }
            return
        }

        let viewing = RetrieveViewing.shared
        var settled = items
        for item in items {
            settled.append(contentsOf: QueryController.seriesTakenByRetrieve(of: item))
        }
        for case let node as DCMTKQueryNode in settled {
            let study = QueryController.viewingStudyUID(node), series = QueryController.viewingSeriesUID(node)
            if viewing.state(studyUID: study, seriesUID: series) == nil { continue }
            // The retrieve inventory is what the completeness column trusts:
            // expected SOP instances from the hierarchical query, imported ones
            // from the database. The peer's counters only stand in when there
            // is none.
            let completeness = localCompleteness(forItem: node)
            let inventory = node.retrieveInventory
            var expected = Int(node.countOfSuboperations)
            let received = Int(node.countOfSuccessfulSuboperations)
            var failed = (expected > received && !cancelled) ? expected - received : 0
            let confirmed = inventory?.inventoryConfirmed ?? node.imageInventoryConfirmed
            // What the retrieve asked for: the series the node's rules left out
            // are no part of it, nor a failure.
            if let inventory, inventory.inventoryConfirmed {
                expected = inventory.scopeExpectedCount
                failed = max(failed, inventory.rejectedUIDs.count)
            }
            let fallback: Int
            if (inventory?.excludedSeries.count ?? 0) > 0 {
                fallback = 0
            } else {
                fallback = completeness?.remoteCountIsKnown == true ? completeness?.remoteCount ?? 0 : 0
            }
            let localCount: Int
            if let inventory, inventory.inventoryConfirmed {
                localCount = inventory.scopeImportedCount
            } else {
                localCount = completeness?.localCount ?? 0
            }
            viewing.transferEnded(studyUID: study, seriesUID: series, cancelled: cancelled, received: received,
                                  expected: expected > 0 ? expected : fallback,
                                  failed: failed, inventoryConfirmed: confirmed, localCount: localCount,
                                  at: Date.timeIntervalSinceReferenceDate)
            if !viewing.isPending(studyUID: study, seriesUID: series) {
                removePendingRetrieveAndViewItem(node)
            }
        }
    }

    /// What was indexed after the transfer ended still counts for its viewing.
    @objc(retrieveInventoryDidRefresh:)
    nonisolated func retrieveInventoryDidRefresh(_ notification: Notification) {
        let node = notification.object as? DCMTKQueryNode
        onMainActor {
            self.outlineView?.needsDisplay = true
            guard let node, let inventory = node.retrieveInventory, inventory.inventoryConfirmed else { return }
            RetrieveViewing.shared.importedCountChanged(studyUID: QueryController.viewingStudyUID(node), seriesUID: QueryController.viewingSeriesUID(node),
                                                        localCount: inventory.scopeImportedCount)
        }
    }

    // MARK: Retrieve & View

    // Retrieve-and-view on the host viewer. The transfer is the existing one;
    // what changes is when the viewer opens (as soon as the database holds the
    // first image of the item, on the batch that brings it, not on a 20-try
    // timer), how the open viewer learns about the rest, and what the operator
    // is told.
    private nonisolated static let pendingItems = PendingItems()

    private final class PendingItems: @unchecked Sendable {
        let lock = NSLock()
        var items: [AnyObject] = []
    }

    nonisolated static func progressiveRetrieveViewingEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: "HorosProgressiveRetrieveViewing")
    }

    nonisolated static func viewingStudyUID(_ item: Any?) -> String {
        if let series = item as? DCMTKSeriesQueryNode { return series.studyInstanceUID() ?? "" }
        return ((item as AnyObject?)?.value(forKey: "uid") as? String) ?? ""
    }

    nonisolated static func viewingSeriesUID(_ item: Any?) -> String {
        if let series = item as? DCMTKSeriesQueryNode { return series.uid() ?? "" }
        return ""
    }

    @objc(addPendingRetrieveAndViewItem:)
    public nonisolated func addPendingRetrieveAndViewItem(_ item: Any?) {
        guard let item = item as AnyObject? else { return }
        let pending = QueryController.pendingItems
        pending.lock.lock()
        if !pending.items.contains(where: { $0 === item || $0.isEqual(item) }) { pending.items.append(item) }
        pending.lock.unlock()
    }

    @objc(removePendingRetrieveAndViewItem:)
    public nonisolated func removePendingRetrieveAndViewItem(_ item: Any?) {
        guard let item = item as AnyObject? else { return }
        let pending = QueryController.pendingItems
        pending.lock.lock()
        pending.items.removeAll { $0 === item || $0.isEqual(item) }
        pending.lock.unlock()
    }

    /// Retrieve-and-view items waiting for their first image.
    @objc(pendingRetrieveAndViewItems)
    public nonisolated func pendingRetrieveAndViewItems() -> [Any] {
        let pending = QueryController.pendingItems
        pending.lock.lock()
        defer { pending.lock.unlock() }
        return pending.items
    }

    /// A batch just landed: open every pending item it concerns, now.
    @objc(openPendingRetrieveAndViewItemsForStudyUIDs:)
    public func openPendingRetrieveAndViewItems(forStudyUIDs studyUIDs: [Any]!) {
        let studyUIDs = (studyUIDs ?? []).compactMap { $0 as? String }
        let viewing = RetrieveViewing.shared
        for item in pendingRetrieveAndViewItems() {
            let study = QueryController.viewingStudyUID(item)
            if !studyUIDs.contains(study) { continue }
            if !viewing.isPending(studyUID: study, seriesUID: QueryController.viewingSeriesUID(item)) {
                removePendingRetrieveAndViewItem(item)
                continue
            }
            checkAndView(item)
        }
    }

    /// A C-STORE for a pending item completed: the importer runs on a timer, so
    /// nudge it.
    @objc(observeStoreCompletedNotification:)
    nonisolated func observeStoreCompletedNotification(_ notification: Notification) {
        guard let study = notification.userInfo?["study"] as? String, !study.isEmpty,
              QueryController.progressiveRetrieveViewingEnabled() else { return }
        if RetrieveViewing.shared.importNudgeWanted(studyUID: study, at: Date.timeIntervalSinceReferenceDate) {
            DicomDatabase.activeLocal()?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
        }
    }

    /// Images were added: refresh the windows, and open the pending items
    /// their studies concern.
    @objc(observeDatabaseAddNotification:)
    nonisolated func observeDatabaseAddNotification(_ notification: Notification) {
        performSelector(onMainThread: #selector(refresh(_:)), with: self, waitUntilDone: false)

        guard QueryController.progressiveRetrieveViewingEnabled() && !pendingRetrieveAndViewItems().isEmpty else { return }
        let images = notification.userInfo?[OsirixAddToDBNotificationImagesArray] as? [Any] ?? []
        var studies = Set<String>()
        for image in images {
            if let uid = (image as AnyObject).value(forKeyPath: "series.study.studyInstanceUID") as? String {
                studies.insert(uid)
            }
        }
        if RetrieveViewing.shared.concernsPending(studyUIDs: Array(studies)) {
            performSelector(onMainThread: #selector(openPendingRetrieveAndViewItems(forStudyUIDs:)), with: Array(studies), waitUntilDone: false)
        }
    }

    /// Opens the item once its first image is here, trying again every second
    /// while it is pending (or twenty times, without progressive viewing).
    @objc(checkAndView:)
    func checkAndView(_ item: Any?) {
        guard window?.isVisible == true else { return }

        let pending = QueryController.progressiveRetrieveViewingEnabled() &&
            RetrieveViewing.shared.isPending(studyUID: QueryController.viewingStudyUID(item), seriesUID: QueryController.viewingSeriesUID(item))

        if checkAndViewTry < 0 && !pending {
            return
        }

        let db = DicomDatabase.activeLocal()
        let browser = BrowserController.currentBrowser()
        browser?.database = db
        db?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()

        guard let context = db?.managedObjectContext else { return }

        N2ManagedObjectContextPerformAndWait(context) {
            MainActor.assumeIsolated {
                self.checkAndView(item, in: context, database: db, browser: browser)
            }
        }
    }

    private func checkAndView(_ item: Any?, in context: NSManagedObjectContext, database db: DicomDatabase?, browser: BrowserController?) {
        do {
            try HorosObjCException.perform {
                var success = false
                let node = item as AnyObject?
                let entities = browser?.database?.managedObjectModel?.entitiesByName

                if let node, type(of: node) == DCMTKStudyQueryNode.self {
                    let request = NSFetchRequest<NSFetchRequestResult>()
                    request.entity = entities?["Study"]
                    request.predicate = NSPredicate(format: "(studyInstanceUID == %@)", argumentArray: [node.value(forKey: "uid") as Any])

                    let studyArray = (try? context.fetch(request)) ?? []
                    if let study = studyArray.first as? NSManagedObject, let browser {
                        let seriesArray = browser.childrenArray(study) ?? []

                        if let series = seriesArray.first as AnyObject? {
                            let image = (series.value(forKey: "images") as? NSSet)?.anyObject() as? DicomImage
                            if !browser.findAndSelectFile(nil, image: image, shouldExpand: false) {
                                browser.showEntireDatabase()
                                if browser.findAndSelectFile(nil, image: image, shouldExpand: false) { success = true }
                            } else {
                                success = true
                            }

                            if success {
                                browser.databaseOpenStudy(study)
                                RetrieveViewing.shared.viewerOpened(studyUID: QueryController.viewingStudyUID(item), seriesUID: QueryController.viewingSeriesUID(item),
                                                                    localCount: RetrieveViewing.uniqueInstanceCount(ofStudyOrSeries: study),
                                                                    at: Date.timeIntervalSinceReferenceDate)
                                self.removePendingRetrieveAndViewItem(item)
                            }
                        }
                    }
                }

                if let node, type(of: node) == DCMTKSeriesQueryNode.self {
                    let predicate = NSPredicate(format: "(seriesDICOMUID == %@)", argumentArray: [node.value(forKey: "uid") as Any])

                    NSLog("%@", predicate.description)

                    let request = NSFetchRequest<NSFetchRequestResult>()
                    request.entity = entities?["Series"]
                    request.predicate = predicate

                    let seriesArray = (try? context.fetch(request)) ?? []
                    if let series = seriesArray.first as? NSManagedObject, let browser {
                        NSLog("%d local series", Int32(seriesArray.count))

                        browser.openViewer(fromImages: [browser.childrenArray(series) as Any], movie: false, viewer: nil, keyImagesOnly: false)

                        if UserDefaults.standard.bool(forKey: "AUTOTILING") {
                            NSApp.sendAction(Selector(("tileWindows:")), to: nil, from: self)
                        } else {
                            AppController.shared()?.checkAllWindowsAreVisible(self, makeKey: true)
                        }

                        success = true
                        RetrieveViewing.shared.viewerOpened(studyUID: QueryController.viewingStudyUID(item), seriesUID: QueryController.viewingSeriesUID(item),
                                                            localCount: RetrieveViewing.uniqueInstanceCount(ofStudyOrSeries: series),
                                                            at: Date.timeIntervalSinceReferenceDate)
                        self.removePendingRetrieveAndViewItem(item)
                    }
                }

                if !success {
                    db?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()

                    let stillPending = QueryController.progressiveRetrieveViewingEnabled() &&
                        RetrieveViewing.shared.isPending(studyUID: QueryController.viewingStudyUID(item), seriesUID: QueryController.viewingSeriesUID(item))
                    let tries = self.checkAndViewTry
                    self.checkAndViewTry -= 1
                    if (tries > 0 || stillPending) && self.sendToPopup.indexOfSelectedItem == 0 {
                        self.perform(#selector(self.checkAndView(_:)), with: item, afterDelay: 1.0)
                    }
                }
            }
        } catch {
            NSLog("**** checkAndView exception: %@", QueryController.describe(error))
        }
    }

    @IBAction @objc(view:)
    public func view(_ sender: Any?) {
        let item = outlineView.item(atRow: outlineView.selectedRow)

        checkAndViewTry = 20
        if let item {
            checkAndView(item)
        }
    }
}
