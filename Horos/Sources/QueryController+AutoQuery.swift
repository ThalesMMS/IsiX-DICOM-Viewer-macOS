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

/// The refresh of the results and the automatic query: the one-second timer,
/// the instances of the automatic query (each a preset with its name and last
/// results), the query each one runs on a worker, and the retrieve of what it
/// finds.
extension QueryController {
    // MARK: Instances of the automatic query

    /// The names of the instances, for the instance menu.
    @objc public var instancesMenuList: [String] {
        return (autoQRInstances ?? NSMutableArray()).compactMap { ($0 as? NSDictionary)?.object(forKey: "instanceName") as? String }
    }

    /// Shows the instance `index`, after saving the one shown: -setCurrentAutoQR:.
    func showAutoQRInstance(_ requested: Int32) {
        saveSettings()

        guard let instances = autoQRInstances else { return }
        QueryController.synchronized(instances) {
            var index = requested
            if instances.count == 0 {
                index = 0

                emptyPreset(self)

                autoRefreshQueryResults = 0
                UserDefaults.standard.set(false, forKey: "autoRetrieving")

                let preset = savePresetInDictionary(withDICOMNodes: true)
                preset?.setObject(NSLocalizedString("Default Instance", comment: ""), forKey: "instanceName" as NSString)
                if let preset { instances.add(preset) }
            }

            if currentAutoQRValue >= 0 && Int(currentAutoQRValue) < instances.count { // During deleteAutoQRInstance:
                let current = instances[Int(currentAutoQRValue)] as? NSMutableDictionary
                try? HorosObjCException.perform {
                    current?.setObject(self.resultArray.copy(), forKey: "resultArray" as NSString)
                }
            }

            if index < 0 {
                index = Int32(instances.count - 1)
            }

            if index >= Int32(instances.count) {
                index = 0
            }

            currentAutoQRValue = index

            let instance = instances[Int(index)] as? NSDictionary
            window?.title = String(format: "%@ : %@", NSLocalizedString("DICOM Auto Query/Retrieve", comment: ""),
                                   QueryController.text(instance?.object(forKey: "instanceName")))
            applyPresetDictionary(instance)

            refreshList(instance?.object(forKey: "resultArray") as? [Any])

            autoQRNavigationControl?.isEnabled = instances.count > 1
        }
    }

    @IBAction @objc(changeAutoQRInstance:)
    func changeAutoQRInstance(_ sender: NSSegmentedControl) {
        var i = currentAutoQRValue

        if sender.selectedSegment == 0 {
            i -= 1
        } else {
            i += 1
        }

        currentAutoQR = i
    }

    @IBAction @objc(createAutoQRInstance:)
    func createAutoQRInstance(_ sender: Any?) {
        if (autoQRInstances?.count ?? 0) >= QueryController.maximumInstances {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Create Auto QR Instance", comment: ""),
                                            message: NSLocalizedString("Too many Auto QR Instances already exist.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        autoQRInstanceName.stringValue = ""

        window?.beginSheet(addAutoQRInstanceWindow, completionHandler: nil)
    }

    @IBAction @objc(endCreateAutoQRInstance:)
    func endCreateAutoQRInstance(_ sender: Any?) {
        let tag = (sender as? NSControl)?.tag ?? 0
        guard tag != 0 else {
            addAutoQRInstanceWindow.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))
            return
        }

        if autoQRInstanceName.stringValue.isEmpty {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Create Auto QR Instance", comment: ""), message: NSLocalizedString("Give a name !", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        for case let instance as NSDictionary in autoQRInstances ?? NSMutableArray() {
            if (instance.object(forKey: "instanceName") as? String) == autoQRInstanceName.stringValue {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Create Auto QR Instance", comment: ""),
                                                message: NSLocalizedString("An Auto QR Instance with the same name already exists.", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            }
        }

        addAutoQRInstanceWindow.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        willChangeValue(forKey: "instancesMenuList")

        if let instances = autoQRInstances {
            QueryController.synchronized(instances) {
                let preset = savePresetInDictionary(withDICOMNodes: true)
                preset?.setObject(autoQRInstanceName.stringValue, forKey: "instanceName" as NSString)
                if let preset { instances.add(preset) }

                currentAutoQR = Int32(instances.count - 1)

                emptyPreset(self)

                autoRefreshQueryResults = 0
                let current = instances[Int(currentAutoQRValue)] as? NSMutableDictionary
                try? HorosObjCException.perform {
                    current?.setObject(NSNumber(value: Int32(truncatingIfNeeded: self.autoRefreshQueryResults)), forKey: "autoRefreshQueryResults" as NSString)
                    UserDefaults.standard.set(false, forKey: "autoRetrieving")
                    current?.setObject(NSNumber(value: false), forKey: "autoRetrieving" as NSString)
                }
            }
        }

        didChangeValue(forKey: "instancesMenuList")
    }

    @IBAction @objc(deleteAutoQRInstance:)
    func deleteAutoQRInstance(_ sender: Any?) {
        guard let instances = autoQRInstances, Int(currentAutoQRValue) < instances.count, currentAutoQRValue >= 0 else { return }
        let name = QueryController.text((instances[Int(currentAutoQRValue)] as? NSDictionary)?.object(forKey: "instanceName"))
        // Delete the instance
        if HorosAlertPanel.runCritical(title: NSLocalizedString("Delete Auto QR Instance", comment: ""),
                                       message: String(format: NSLocalizedString("Are you sure you want to delete the current Auto QR Instance (%@)?", comment: ""), name),
                                       defaultButton: NSLocalizedString("OK", comment: ""),
                                       alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) == HorosAlertDefaultResponse {
            willChangeValue(forKey: "instancesMenuList")

            QueryController.synchronized(instances) {
                let newIndex = currentAutoQRValue - 1
                instances.removeObject(at: Int(currentAutoQRValue))
                currentAutoQRValue = -1
                currentAutoQR = newIndex
            }

            didChangeValue(forKey: "instancesMenuList")
        }
    }

    @IBAction @objc(lockAutoQRWindow:)
    func lockAutoQRWindow(_ sender: Any?) {
    }

    /// The retrieve settings of the automatic query, in a sheet; kept in the
    /// instance shown.
    @IBAction @objc(autoRetrieveSettings:)
    public func autoRetrieveSettings(_ sender: Any?) {
        let defaults = UserDefaults.standard
        let numberOfPreviousStudyToRetrieve = defaults.object(forKey: "NumberOfPreviousStudyToRetrieve")
        let retrieveSameModality = defaults.object(forKey: "retrieveSameModality")
        let retrieveSameDescription = defaults.object(forKey: "retrieveSameDescription")

        window?.beginSheet(autoRetrieveWindow, completionHandler: nil)

        let result = NSApp.runModal(for: autoRetrieveWindow)

        autoRetrieveWindow.orderOutAndEndSheet()

        if result != .stop { // Cancel
            if let numberOfPreviousStudyToRetrieve { defaults.set(numberOfPreviousStudyToRetrieve, forKey: "NumberOfPreviousStudyToRetrieve") }
            if let retrieveSameModality { defaults.set(retrieveSameModality, forKey: "retrieveSameModality") }
            if let retrieveSameDescription { defaults.set(retrieveSameDescription, forKey: "retrieveSameDescription") }
        } else {
            if let instances = autoQRInstances, currentAutoQRValue >= 0, Int(currentAutoQRValue) < instances.count {
                QueryController.synchronized(instances) {
                    let current = instances[Int(currentAutoQRValue)] as? NSMutableDictionary
                    try? HorosObjCException.perform {
                        for key in ["NumberOfPreviousStudyToRetrieve", "retrieveSameModality", "retrieveSameDescription"] {
                            if let value = defaults.object(forKey: key) {
                                current?.setObject(value, forKey: key as NSString)
                            }
                        }
                    }
                }
            }

            saveSettings()
        }
    }

    @IBAction @objc(switchAutoRetrieving:)
    public func switchAutoRetrieving(_ sender: Any?) {
        NSLog("auto-retrieving switched")

        RetrieveInTransfer.withLock { $0.removeAll() }

        if autoQueryValue, let instances = autoQRInstances, currentAutoQRValue >= 0, Int(currentAutoQRValue) < instances.count,
           QueryController.bool((instances[Int(currentAutoQRValue)] as? NSDictionary)?.object(forKey: "autoRetrieving")) {
            refreshAutoQR(self)
        }
    }

    /// Saves the filters: of the instance shown (automatic query), or of the
    /// window.
    @objc(saveSettings)
    public func saveSettings() {
        if autoQueryValue {
            guard currentAutoQRValue >= 0, let instances = autoQRInstances else { return }
            QueryController.synchronized(instances) {
                do {
                    try HorosObjCException.perform {
                        guard Int(self.currentAutoQRValue) < instances.count else { return }
                        let newDic = (instances[Int(self.currentAutoQRValue)] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary
                        if let newDic, let preset = self.savePresetInDictionary(withDICOMNodes: true) as? [AnyHashable: Any] {
                            newDic.addEntries(from: preset)
                            instances.replaceObject(at: Int(self.currentAutoQRValue), with: newDic)
                        }

                        // Every instance is saved, as a copy without its
                        // results: those stay in the instance, and are not
                        // wanted in the preferences. An instance read from the
                        // preferences is immutable until it is shown; it is
                        // replaced here by a mutable copy, so that its next
                        // results can be kept in it.
                        var saved: [Any] = []
                        for i in 0..<instances.count {
                            guard let instance = instances[i] as? NSDictionary,
                                  let copy = instance.mutableCopy() as? NSMutableDictionary else {
                                saved.append(instances[i])
                                continue
                            }
                            if !(instance is NSMutableDictionary), let mutable = instance.mutableCopy() as? NSMutableDictionary {
                                instances.replaceObject(at: i, with: mutable)
                            }
                            copy.removeObject(forKey: "resultArray")
                            saved.append(copy)
                        }

                        UserDefaults.standard.set(saved, forKey: "savedAutoDICOMQuerySettingsArray")
                    }
                } catch {
                    QueryController.log(error, "-[QueryController saveSettings]")
                }
            }
        } else {
            let settings = savePresetInDictionary(withDICOMNodes: true)
            UserDefaults.standard.set(settings, forKey: "savedDICOMQuerySettings")
        }
    }

    // MARK: The refresh timer

    /// Refreshes now: every instance of the automatic query, or the window's.
    @objc(refreshAutoQR:)
    public func refreshAutoQR(_ sender: Any?) {
        queryButtonPressed = true

        if autoQueryValue {
            for i in 0..<min(autoQRInstances?.count ?? 0, QueryController.maximumInstances) {
                autoQueryRemainingSecs[i] = 2
            }
        } else if currentAutoQRValue >= 0 {
            autoQueryRemainingSecs[Int(currentAutoQRValue)] = 2
        }

        autoQueryTimerFunction(queryTimer)
    }

    /// Starts the one-second timer again, from the refresh interval chosen.
    @IBAction @objc(autoQueryTimer:)
    public func autoQueryTimer(_ sender: Any?) {
        queryTimer?.invalidate()
        queryTimer = nil

        let current = max(Int(currentAutoQRValue), 0)
        let refresh = autoRefreshQueryResults
        autoQueryRemainingSecs[current] = refresh >= 0 ? 60 * refresh /* minutes */ : -refresh /* seconds */

        showRemainingTime()

        saveSettings()

        queryTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(autoQueryTimerFunction(_:)), userInfo: nil, repeats: true)
    }

    private func showRemainingTime() {
        let seconds = autoQueryRemainingSecs[max(Int(currentAutoQRValue), 0)]
        if autoRefreshQueryResults != 0 {
            autoQueryCounter?.stringValue = String(format: "%2.2d:%2.2d", Int32(seconds / 60), Int32(seconds % 60))
        } else {
            autoQueryCounter?.stringValue = ""
        }
    }

    /// Once a second: counts down, and starts the query of each instance whose
    /// time has come, on a worker.
    @objc(autoQueryTimerFunction:)
    public func autoQueryTimerFunction(_ t: Timer?) {
        captureWindowState()

        if !autoQueryValue && !queryButtonPressed { // We will refresh the results only after a valid query, generated by the user
            return
        }

        if !DatabaseIsEdited {
            if autoQueryValue {
                if let instances = autoQRInstances {
                    QueryController.synchronized(instances) {
                        // Each instance counts down its own interval and
                        // queries with its own filters.
                        for i in 0..<min(instances.count, QueryController.maximumInstances) {
                            let refresh = Int(QueryController.int32((instances[i] as? NSDictionary)?.object(forKey: "autoRefreshQueryResults")))
                            if refresh != 0 {
                                autoQueryRemainingSecs[i] -= 1
                                if autoQueryRemainingSecs[i] <= 0 {
                                    if autoQueryLock.try() {
                                        if i == Int(currentAutoQRValue) {
                                            saveSettings()
                                        }
                                        // Read after the save, which replaces the instance shown.
                                        let qrInstance = instances[i] as? NSDictionary

                                        AppController.shared()?.notificationTitle(NSLocalizedString("Q&R Auto-Query", comment: ""),
                                                                                 description: NSLocalizedString("Refreshing...", comment: ""), name: "autoquery")

                                        let work: NSDictionary = ["instance": qrInstance?.mutableCopy() ?? NSMutableDictionary(),
                                                                  "index": NSNumber(value: Int32(i))]
                                        let thread = Thread(target: self, selector: #selector(autoQueryThread(_:)), object: work)

                                        let name = qrInstance?.object(forKey: "instanceName") as? String ?? ""
                                        if !name.isEmpty && instances.count > 1 {
                                            thread.name = String(format: NSLocalizedString("Auto-Querying images (%@)...", comment: ""), name)
                                        } else {
                                            thread.name = NSLocalizedString("Auto-Querying images...", comment: "")
                                        }

                                        thread.supportsCancel = true
                                        ThreadsManager.default()?.addThreadAndStart(thread)

                                        let seconds = Int(QueryController.int32(qrInstance?.object(forKey: "autoRefreshQueryResults")))
                                        autoQueryRemainingSecs[i] = seconds >= 0 ? 60 * seconds /* minutes */ : -seconds /* seconds */

                                        autoQueryLock.unlock()
                                    } else {
                                        autoQueryRemainingSecs[i] = 0
                                    }
                                }
                            }
                        }
                    }
                }
            } else if autoRefreshQueryResults != 0 {
                let current = max(Int(currentAutoQRValue), 0)
                autoQueryRemainingSecs[current] -= 1
                if autoQueryRemainingSecs[current] <= 0 {
                    if autoQueryLock.try() {
                        AppController.shared()?.notificationTitle(NSLocalizedString("Q&R Auto-Query", comment: ""),
                                                                 description: NSLocalizedString("Refreshing...", comment: ""), name: "autoquery")

                        saveSettings()

                        // The worker queries with the window's filters, read here.
                        let work: NSDictionary = ["instance": savePresetInDictionary(withDICOMNodes: true) ?? NSMutableDictionary()]
                        let thread = Thread(target: self, selector: #selector(autoQueryThread(_:)), object: work)
                        thread.name = NSLocalizedString("Auto-Querying images...", comment: "")
                        thread.supportsCancel = true
                        ThreadsManager.default()?.addThreadAndStart(thread)

                        let refresh = autoRefreshQueryResults
                        autoQueryRemainingSecs[current] = refresh >= 0 ? 60 * refresh /* minutes */ : -refresh /* seconds */

                        autoQueryLock.unlock()
                    } else {
                        autoQueryRemainingSecs[current] = 0
                    }
                }
            }
        }

        showRemainingTime()
    }

    // MARK: The workers

    /// The query of one instance (automatic query) or of the window, on a
    /// worker; its results are retrieved when the instance says so.
    @objc(autoQueryThread:)
    public nonisolated func autoQueryThread(_ dictionary: NSDictionary!) {
        autoreleasepool {
            let instance = dictionary?.object(forKey: "instance") as? NSMutableDictionary
            if autoQueryValue {
                let index = QueryController.int32(dictionary?.object(forKey: "index"))

                if !queryWithDisplayingErrors(false, instance: instance, index: index) {
                    displayAndRetrieveQueryResults(instance)
                } else {
                    AppController.shared()?.notificationTitle(NSLocalizedString("Q&R Auto-Retrieve", comment: ""), description: "Failed...", name: "autoquery")
                    NSLog("****** Q&R autoQueryThread failed...")
                }
            } else {
                if !queryWithDisplayingErrors(false, instance: instance ?? NSMutableDictionary(), index: -1) {
                    displayAndRetrieveQueryResults(nil)
                } else {
                    AppController.shared()?.notificationTitle(NSLocalizedString("Q&R Auto-Retrieve", comment: ""), description: "Failed...", name: "autoquery")
                    NSLog("****** Q&R autoQueryThread failed...")
                }
            }
        }
    }

    /// Keeps the results of a query in the automatic query's instance at
    /// `index`, with `autoQRInstances` locked; false when there is no such
    /// instance. An instance read from the preferences is immutable until a save
    /// replaces it, so it is replaced here, in place, by a mutable copy that
    /// takes the results: they would be lost otherwise.
    nonisolated func keepResults(_ results: NSArray, inInstanceAt index: Int) -> Bool {
        guard let instances = autoQRInstances, index >= 0, index < instances.count else { return false }
        guard let stored = instances[index] as? NSDictionary else { return true }
        if let mutable = stored as? NSMutableDictionary {
            mutable.setObject(results, forKey: "resultArray" as NSString)
        } else if let mutable = stored.mutableCopy() as? NSMutableDictionary {
            mutable.setObject(results, forKey: "resultArray" as NSString)
            instances.replaceObject(at: index, with: mutable)
        }
        return true
    }

    /// Retrieves the results of `instance` when it retrieves automatically.
    @objc(displayAndRetrieveQueryResults:)
    public nonisolated func displayAndRetrieveQueryResults(_ instance: NSDictionary!) {
        if QueryController.bool(instance?.object(forKey: "autoRetrieving")) && autoQueryValue {
            let thread = Thread(target: self, selector: #selector(autoRetrieveThread(_:)), object: instance)
            thread.name = NSLocalizedString("Retrieving images...", comment: "")
            ThreadsManager.default()?.addThreadAndStart(thread)
        }
    }

    /// Adds `item` to `selectedItems` when some of it is not here yet and it is
    /// not being retrieved with the same number of images.
    @objc(addStudyIfNotAvailable:toArray:)
    nonisolated func addStudyIfNotAvailable(_ item: Any!, toArray selectedItems: NSMutableArray!) {
        let node = item as AnyObject
        var localFiles = Int32(truncatingIfNeeded: localFileCount(forItem: item))
        var totalFiles = QueryController.int32(node.value(forKey: "numberImages"))

        if node.value(forKey: "numberImages") == nil ||
            (UserDefaults.standard.bool(forKey: "SupportPACSWithNoNumberOfImagesField") && QueryController.int32(node.value(forKey: "numberImages")) == 0) {
            // We dont know how many images are stored on the distant PACS... add
            // it, if we have no images on our side...
            if localFiles == 0 {
                totalFiles = 1
            }
        }

        if let query = item as? DCMTKQueryNode, let inventory = query.retrieveInventory,
           inventory.matchesReportedCount(Int(QueryController.int32(node.value(forKey: "numberImages")))) {
            _ = query.refreshRetrieveInventory()
            localFiles = Int32(truncatingIfNeeded: inventory.importedCount)
            totalFiles = Int32(truncatingIfNeeded: inventory.expectedCount)
            // What the peer counts without listing, or cannot send, is not to fetch again.
            if inventory.isSatisfied { localFiles = totalFiles }
        }
        if localFiles < totalFiles {
            let stringID = QueryController.stringID(forStudy: item)

            RetrieveInTransfer.withLock { inTransfer in
                // We only want to re-retrieve the study if they are new files
                // compared to last time... we are maybe currently in the middle
                // of a retrieve...
                if (inTransfer[stringID] ?? 0) != totalFiles {
                    selectedItems?.add(item as Any)
                    inTransfer[stringID] = totalFiles
                }
            }
        }
    }

    /// Retrieves the first studies of `instance`'s results that are not here,
    /// with the patient's previous studies its settings ask for.
    @objc(autoRetrieveThread:)
    nonisolated func autoRetrieveThread(_ instance: NSDictionary!) {
        autoreleasepool {
            autoQueryLock.lock()
            defer { autoQueryLock.unlock() }

            let list = (instance?.object(forKey: "resultArray") as? NSArray)?.copy() as? [Any] ?? []

            guard autoQueryValue else { return }

            guard BrowserController.currentBrowser()?.database === DicomDatabase.activeLocal() else { return }

            if numberOfRunningRetrieve > 5 {
                NSLog("**** numberOfRunningRetrieve > 5... wait for next autoretrieve.")
                return
            }

            // Start to retrieve the first XX studies...
            do {
                try HorosObjCException.perform {
                    self.autoRetrieve(list, instance: instance)
                }
            } catch {
                QueryController.log(error, "-[QueryController autoRetrieveThread:]")
            }
        }
    }

    private nonisolated func autoRetrieve(_ list: [Any], instance: NSDictionary?) {
        let selectedItems = NSMutableArray()
        let defaults = UserDefaults.standard

        for item in list {
            let node = item as AnyObject
            var addItem = true

            if defaults.bool(forKey: "QR_CheckForDuplicateAccessionNumber") {
                for study in selectedItems {
                    if ((study as AnyObject).value(forKey: "accessionNumber") as? String) == (node.value(forKey: "accessionNumber") as? String) &&
                        (study as AnyObject).value(forKey: "accessionNumber") != nil {
                        NSLog("--- Identical AccessionNumber: %@ - %d images", QueryController.text(node.value(forKey: "uid")),
                              QueryController.int32(node.value(forKey: "numberImages")))

                        addItem = false
                        break
                    }
                }
            }

            if defaults.bool(forKey: "QR_DontReDownloadStudies") {
                QueryController.synchronized(self) {
                    if downloadedStudies == nil {
                        downloadedStudies = NSMutableArray()
                    }

                    for case let d as NSDictionary in NSArray(array: downloadedStudies ?? []) {
                        if ((d.value(forKey: "date") as? Date)?.timeIntervalSinceNow ?? 0) > -60 * 60 { // 1 hour - dont redownload it !
                            if defaults.bool(forKey: "QR_DontDownloadMGDescription") {
                                let description = ((node.value(forKey: "theDescription") as? String) ?? "").lowercased()
                                if description.hasPrefix("mg ") || description.hasPrefix("us seins") {
                                    addItem = false
                                }
                            }

                            if (d.value(forKey: "accessionNumber") as? String) != nil &&
                                (d.value(forKey: "accessionNumber") as? String) == (node.value(forKey: "accessionNumber") as? String) &&
                                QueryController.int32(d.value(forKey: "numberImages")) == QueryController.int32(node.value(forKey: "numberImages")) {
                                addItem = false
                            }
                        } else {
                            downloadedStudies?.remove(d)
                        }
                    }
                }
            }

            if addItem {
                addStudyIfNotAvailable(item, toArray: selectedItems)

                if defaults.bool(forKey: "QR_DontReDownloadStudies") {
                    QueryController.synchronized(self) {
                        let entry = NSMutableDictionary()
                        // dictionaryWithObjectsAndKeys: stopped at the first nil.
                        entry["date"] = Date()
                        if let accessionNumber = node.value(forKey: "accessionNumber") {
                            entry["accessionNumber"] = accessionNumber
                            entry["numberImages"] = node.value(forKey: "numberImages")
                        }
                        downloadedStudies?.add(entry)
                    }
                }
            }

            if selectedItems.count >= defaults.integer(forKey: "MaxNumberOfRetrieveForAutoQR") { break }
        }

        guard selectedItems.count > 0 else { return }

        let numberOfPrevious = Int(QueryController.int32(instance?.object(forKey: "NumberOfPreviousStudyToRetrieve")))
        if numberOfPrevious != 0 {
            let previousStudies = NSMutableArray()
            for item in selectedItems {
                let node = item as AnyObject
                let studiesOfThisPatient = ((queryPatientIDwithoutGUI(node.value(forKey: "patientID") as? String) ?? []) as NSArray)
                    // Sort the resut by date & time
                    .sortedArray(using: [NSSortDescriptor(key: "date", ascending: false), NSSortDescriptor(key: "time", ascending: false)])

                var numberOfStudiesAssociated = numberOfPrevious

                for study in studiesOfThisPatient {
                    let related = study as AnyObject
                    // We dont want current study
                    guard (related.value(forKey: "uid") as? String) != (node.value(forKey: "uid") as? String) else { continue }
                    guard numberOfStudiesAssociated > 0 else { continue }

                    var found = false

                    if QueryController.bool(instance?.object(forKey: "retrieveSameModality")) {
                        let modalities = ((node.value(forKey: "modality") as? String) ?? "").components(separatedBy: "\\")
                        let relatedStudyModalities = ((related.value(forKey: "modality") as? String) ?? "").components(separatedBy: "\\")

                        for modality in modalities where !["SR", "SC", "PR", "KO"].contains(modality) {
                            if relatedStudyModalities.contains(modality) {
                                found = true
                            }
                        }
                    }

                    if QueryController.bool(instance?.object(forKey: "retrieveSameDescription")),
                       let description = node.value(forKey: "theDescription") as? String,
                       let relatedDescription = related.value(forKey: "theDescription") as? String,
                       (relatedDescription as NSString).range(of: description).location != NSNotFound {
                        found = true
                    }

                    if found {
                        addStudyIfNotAvailable(study, toArray: previousStudies)
                        numberOfStudiesAssociated -= 1
                    }
                }
            }

            selectedItems.addObjects(from: previousStudies as? [Any] ?? [])
        }

        for item in selectedItems {
            (item as? DCMTKQueryNode)?.setShowErrorMessage(false)
        }

        let thread = Thread(target: self, selector: #selector(performRetrieve(_:)), object: selectedItems)
        thread.name = NSLocalizedString("Retrieving images...", comment: "")
        thread.status = QueryController.singularPluralCount(selectedItems.count, NSLocalizedString("study", comment: ""), NSLocalizedString("studies", comment: ""))
        if selectedItems.count > 1 {
            thread.progress = 0
        }
        thread.supportsCancel = true
        ThreadsManager.default()?.addThreadAndStart(thread)

        NSLog("______________________________________________")
        NSLog("Will auto-retrieve these items:")
        for item in selectedItems {
            NSLog("%@ - %d images", QueryController.text((item as AnyObject).value(forKey: "uid")),
                  QueryController.int32((item as AnyObject).value(forKey: "numberImages")))
        }
        NSLog("______________________________________________")

        let desc: String
        if selectedItems.count == 1 {
            desc = String(format: NSLocalizedString("Will auto-retrieve %d study", comment: ""), Int32(selectedItems.count))
        } else {
            desc = String(format: NSLocalizedString("Will auto-retrieve %d studies", comment: ""), Int32(selectedItems.count))
        }

        AppController.shared()?.notificationTitle(NSLocalizedString("Q&R Auto-Retrieve", comment: ""), description: desc, name: "autoquery")
    }
}
