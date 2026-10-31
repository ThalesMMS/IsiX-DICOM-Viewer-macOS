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
import IsiXPreferences

/// The instances of the automatic query (each a preset with its name), the
/// scheduler that runs them, and the automatic refresh of the Query/Retrieve
/// window. When each instance runs, its query, and what is retrieved of what
/// it finds are AutoQueryScheduler's, in IsiXDICOMNetwork; the window keeps
/// the instances, hands them over after each change, and shows the answers.
extension QueryController {
    // MARK: Instances of the automatic query

    /// The names of the instances, for the instance menu.
    @objc public var instancesMenuList: [String] {
        return autoQRInstances.compactMap(\.name)
    }

    /// The instance shown, nil when there is none.
    private var shownAutoQRInstance: AutoQueryInstance? {
        let index = Int(currentAutoQRValue)
        return index >= 0 && index < autoQRInstances.count ? autoQRInstances[index] : nil
    }

    /// The filters of the window, with its activated nodes.
    private func windowPreset() -> [String: Any] {
        return windowFilters(withDICOMNodes: true).propertyList
    }

    /// Shows the instance `index`, after saving the one shown: -setCurrentAutoQR:.
    func showAutoQRInstance(_ requested: Int32) {
        saveSettings()

        var index = requested
        if autoQRInstances.isEmpty {
            index = 0

            emptyPreset(self)

            autoRefreshQueryResults = 0
            processGraph.preferences.set(false, for: NetworkPreferences.autoRetrieving)

            var preset = AutoQueryInstance(propertyList: windowPreset()) ?? AutoQueryInstance()
            preset.name = NSLocalizedString("Default Instance", comment: "")
            autoQRInstances.append(preset)
        }

        // The list shown goes with the instance it was shown for.
        if let shown = shownAutoQRInstance { // During deleteAutoQRInstance:, there is none.
            autoQRAnswers[shown.id] = resultArray.copy() as? [Any] ?? []
        }

        if index < 0 {
            index = Int32(autoQRInstances.count - 1)
        }

        if index >= Int32(autoQRInstances.count) {
            index = 0
        }

        currentAutoQRValue = index

        let instance = autoQRInstances[Int(index)]
        window?.title = String(format: "%@ : %@", NSLocalizedString("DICOM Auto Query/Retrieve", comment: ""), instance.name ?? "")
        applyPresetDictionary(instance.propertyList as NSDictionary)

        refreshList(autoQRAnswers[instance.id])

        autoQRNavigationControl?.isEnabled = autoQRInstances.count > 1
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
        if autoQRInstances.count >= QueryController.maximumInstances {
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

        let name = autoQRInstanceName.stringValue
        if name.isEmpty {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Create Auto QR Instance", comment: ""), message: NSLocalizedString("Give a name !", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        if autoQRInstances.contains(where: { $0.name == name }) {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Create Auto QR Instance", comment: ""),
                                            message: NSLocalizedString("An Auto QR Instance with the same name already exists.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        addAutoQRInstanceWindow.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        willChangeValue(forKey: "instancesMenuList")

        var preset = AutoQueryInstance(propertyList: windowPreset()) ?? AutoQueryInstance()
        preset.name = name
        autoQRInstances.append(preset)

        currentAutoQR = Int32(autoQRInstances.count - 1)

        emptyPreset(self)

        // A new instance neither refreshes nor retrieves until it is set to.
        autoRefreshQueryResults = 0
        processGraph.preferences.set(false, for: NetworkPreferences.autoRetrieving)
        let index = Int(currentAutoQRValue)
        if index >= 0 && index < autoQRInstances.count {
            autoQRInstances[index].refreshSetting = 0
            autoQRInstances[index].autoRetrieving = false
        }

        didChangeValue(forKey: "instancesMenuList")
    }

    @IBAction @objc(deleteAutoQRInstance:)
    func deleteAutoQRInstance(_ sender: Any?) {
        guard let shown = shownAutoQRInstance else { return }
        // Delete the instance
        if HorosAlertPanel.runCritical(title: NSLocalizedString("Delete Auto QR Instance", comment: ""),
                                       message: String(format: NSLocalizedString("Are you sure you want to delete the current Auto QR Instance (%@)?", comment: ""), shown.name ?? ""),
                                       defaultButton: NSLocalizedString("OK", comment: ""),
                                       alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) == HorosAlertDefaultResponse {
            willChangeValue(forKey: "instancesMenuList")

            let newIndex = currentAutoQRValue - 1
            autoQRInstances.remove(at: Int(currentAutoQRValue))
            autoQRAnswers[shown.id] = nil
            currentAutoQRValue = -1
            currentAutoQR = newIndex

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
        let defaults = processGraph.preferences
        let keys = ["NumberOfPreviousStudyToRetrieve", "retrieveSameModality", "retrieveSameDescription"]
        let before = keys.map { defaults.object(forKey: $0) }

        window?.beginSheet(autoRetrieveWindow, completionHandler: nil)

        let result = NSApp.runModal(for: autoRetrieveWindow)

        autoRetrieveWindow.orderOutAndEndSheet()

        if result != .stop { // Cancel
            for (key, value) in zip(keys, before) {
                if let value { defaults.set(value, forKey: key) }
            }
        } else {
            let index = Int(currentAutoQRValue)
            if index >= 0 && index < autoQRInstances.count {
                for key in keys {
                    if let value = defaults.object(forKey: key).flatMap(PropertyListValue.init),
                       let field = AutoQueryInstance.Key(rawValue: key) {
                        autoQRInstances[index][field] = value
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

        if autoQueryValue, shownAutoQRInstance?.autoRetrieving == true {
            refreshAutoQR(self)
        }
    }

    /// Saves the filters: of the instance shown (automatic query), or of the
    /// window.
    @objc(saveSettings)
    public func saveSettings() {
        if autoQueryValue {
            let index = Int(currentAutoQRValue)
            guard index >= 0 && index < autoQRInstances.count else { return }
            autoQRInstances[index] = autoQRInstances[index].adding(windowPreset())

            // Every instance, without its answers: those stay in the window.
            AutoQueryInstanceStore.save(autoQRInstances, to: NodePreferences(processGraph: processGraph))
        } else {
            if let settings = PropertyListValue.dictionary(windowFilters(withDICOMNodes: true).propertyList) {
                processGraph.preferences.set(settings, for: NetworkPreferences.savedQuerySettings)
            }
        }
    }

    // MARK: The scheduler

    /// Refreshes now: every instance of the automatic query, or the window's.
    @objc(refreshAutoQR:)
    public func refreshAutoQR(_ sender: Any?) {
        queryButtonPressed = true
        sendToAutoQueryScheduler { await $0.refreshNow() }
    }

    /// Starts the countdown of the instance shown again, from the refresh
    /// interval chosen; makes and starts the scheduler the first time.
    @IBAction @objc(autoQueryTimer:)
    public func autoQueryTimer(_ sender: Any?) {
        saveSettings()

        startAutoQueryScheduler()
        if !autoQueryValue {
            autoQueryInstancesDidChange()
        }

        let shown = autoQueryValue ? (shownAutoQRInstance ?? autoQRInstances.first)?.id : windowRefreshID
        if let shown {
            sendToAutoQueryScheduler { await $0.restartCountdown(of: shown) }
        }
    }

    /// The scheduler of this window, made with the ports that reach the
    /// window's query and retrieve, and started.
    private func startAutoQueryScheduler() {
        guard autoQueryScheduler == nil else { return }
        let graph: ProcessGraph = processGraph
        let answers = AutoQueryAnswerNodes()
        let scheduler = AutoQueryScheduler(querying: QueryWindowAutoQueryRunner(controller: self, answers: answers),
                                           retrieving: QueryWindowAutoRetrieveStarter(controller: self, answers: answers,
                                                                                      processGraph: graph),
                                           localStudies: graph.localStudyReader(reading: .activeLocal),
                                           rules: { AutoRetrieveRules(preferences: NodePreferences(processGraph: graph)) })
        autoQueryScheduler = scheduler
        sendToAutoQueryScheduler { [weak self] scheduler in
            await scheduler.setDisplay(self)
            await scheduler.start()
        }
        autoQueryInstancesDidChange()
    }

    /// Hands the instances over to the scheduler: the automatic query's, or
    /// the window's own, whose interval is the refresh chosen in the window.
    func autoQueryInstancesDidChange() {
        let instances: [AutoQueryInstance]
        if autoQueryValue {
            instances = autoQRInstances
        } else {
            var refresh = AutoQueryInstance(id: windowRefreshID)
            refresh.refreshSetting = autoRefreshQueryResults
            instances = [refresh]
        }
        sendToAutoQueryScheduler { await $0.setInstances(instances) }
    }

    /// Runs `command` on the scheduler after the commands given before it.
    private func sendToAutoQueryScheduler(_ command: @escaping @Sendable (AutoQueryScheduler) async -> Void) {
        guard let scheduler = autoQueryScheduler else { return }
        let previous = autoQuerySchedulerCommands
        autoQuerySchedulerCommands = Task {
            await previous?.value
            await command(scheduler)
        }
    }

    // MARK: What the scheduler's ports ask of the window

    /// What a run of `instance` queries with, the name of its thread in
    /// Activity, and whether it is the automatic query's: the instance shown
    /// takes the window's filters first, and the window's refresh queries with
    /// them; an instance not shown queries with its own saved dates. Nil when
    /// the instance is gone. The run is made here, on the main thread, for the
    /// thread that queries.
    func prepareAutoQueryRun(of instance: AutoQueryInstance) -> (run: QueryWindowRun, activityName: String, autoQuery: Bool)? {
        processGraph.appController?.notificationTitle(NSLocalizedString("Q&R Auto-Query", comment: ""),
                                                      description: NSLocalizedString("Refreshing...", comment: ""), name: "autoquery")
        saveSettingsBeforeRun(of: instance)

        guard autoQueryValue else {
            return (queryRun(windowFilters(withDICOMNodes: true)), NSLocalizedString("Auto-Querying images...", comment: ""), false)
        }
        guard let current = autoQRInstances.first(where: { $0.id == instance.id }) else { return nil }
        let windowDates = (from: fromDate?.dateValue ?? Date(), to: toDate?.dateValue ?? Date())
        let run = queryRun(dated: current.queryFilters(windowDates: windowDates, shown: shownAutoQRInstance?.id == current.id))
        let name = current.name ?? ""
        if !name.isEmpty && autoQRInstances.count > 1 {
            return (run, String(format: NSLocalizedString("Auto-Querying images (%@)...", comment: ""), name), true)
        }
        return (run, NSLocalizedString("Auto-Querying images...", comment: ""), true)
    }

    private func saveSettingsBeforeRun(of instance: AutoQueryInstance) {
        if !autoQueryValue || shownAutoQRInstance?.id == instance.id {
            saveSettings()
        }
    }

    /// Keeps the answers of the last query of the instance `id`, and shows
    /// them when it is the one shown.
    func keepAutoQueryAnswers(_ answers: QueryAnswers, of id: UUID) {
        guard autoQRInstances.contains(where: { $0.id == id }) else { return }
        if shownAutoQRInstance?.id == id {
            refreshList(answers.items)
        }
        autoQRAnswers[id] = answers.items
    }
}

// AutoQueryCountdownDisplay is declared on the class itself: the protocol is
// Sendable, and a Sendable conformance must be stated in the class's own file.
extension QueryController {
    /// Once a second, before the countdown: the copy of the window for the
    /// workers is made again, and nothing counts while an edit is in
    /// progress, nor in the Query/Retrieve window before its first query.
    public func shouldCountDown() -> Bool {
        captureWindowState()
        return (autoQueryValue || queryButtonPressed) && !DatabaseIsEdited
    }

    /// The time left before the next query of the instance shown.
    public func showCountdown(_ remaining: [UUID: Int]) {
        let shown = autoQueryValue ? (shownAutoQRInstance ?? autoQRInstances.first)?.id : windowRefreshID
        let seconds = shown.flatMap { remaining[$0] } ?? 0
        if autoRefreshQueryResults != 0 {
            autoQueryCounter?.stringValue = QueryRefreshSetting.countdownText(seconds: seconds)
        } else {
            autoQueryCounter?.stringValue = ""
        }
    }
}
