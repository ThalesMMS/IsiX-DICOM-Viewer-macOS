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
import Synchronization

/// `static volatile int sendControllerObjects`: the SendController instances
/// alive, which BrowserController asks before quitting, with the sends they
/// queued. Atomic: a controller may be released after the main thread's pool.
private let liveSendControllers = Atomic<Int32>(0)

/// What %@ printed for an object: its description, or (null).
private func describe(_ object: Any?) -> String {
    guard let object = object else { return "(null)" }
    return (object as AnyObject).description
}

/// -intValue of an NSNumber or NSString; 0 for nil, as a message to nil.
private func intValue(_ object: Any?) -> Int32 {
    if let number = object as? NSNumber { return number.int32Value }
    if let string = object as? NSString { return string.intValue }
    return 0
}

/// Window Controller for DICOM Send (Send.xib): the sheet that chooses the
/// destination and what to send, and the request it makes of that choice.
/// The send itself is `DICOMSendQueue`'s, on threads the Activity window
/// lists (`ActivitySendTransport`).
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/SendController.h> are those of the former class, the File's Owner of
/// Send.xib.
///
/// Whoever makes a controller does not release it, as under the former
/// manual retain/release: the controller gives that reference back once its
/// send is queued, or when the sheet is cancelled or nothing is left to send.
@objc(SendController)
public final class SendController: NSWindowController {
    /// The process's preferences and send queue, from whoever made the controller.
    let processGraph: ProcessGraph

    // Ivars of the former class.
    private var _files: [Any] = []
    private var _numberFiles: String?
    private var _keyImageIndex: Int = 0
    private var _serverIndex: Int = 0
    private var _destinationServer: [AnyHashable: Any]?

    // Outlets the xib sets: ivars of the former class. Send.xib also connects a
    // `sendSCU` outlet that the former class never had; AppKit logs it and goes
    // on, as before.
    @IBOutlet @objc var newServerList: NSPopUpButton!
    @IBOutlet @objc var keyImageMatrix: NSMatrix!
    @IBOutlet @objc var numberImagesTextField: NSTextField!
    @IBOutlet @objc var addressAndPort: NSTextField!
    @IBOutlet @objc var syntaxListOffis: NSPopUpButton!

    public override var windowNibName: NSNib.Name? {
        return "Send"
    }

    /// The controllers alive and the sends queued or running.
    @objc(sendControllerObjects)
    public class func sendControllerObjects() -> Int32 {
        let sends = Int32(truncatingIfNeeded: ProcessGraph.process.dicomSendQueue.pendingSends)
        return liveSendControllers.load(ordering: .relaxed) &+ sends
    }

    /// The destinations the sheet lists: the DIMSE nodes that send, then the
    /// DICOMweb nodes with Send on, which STOW-RS sends to. The DIMSE
    /// nodes come first so that `lastSendServer` keeps naming the same one.
    static func destinations() -> [[String: Any]] {
        let dimse = DICOMNodeService.dicomNodes(sendOnly: true, queryRetrieveOnly: false)
        return dimse.map(\.propertyList) + DICOMwebSources.sendDestinations()
    }

    @objc(sendFiles:toNode:)
    public class func sendFiles(_ files: [Any]!, toNode node: [AnyHashable: Any]!) {
        return SendController.sendFiles(files, toNode: node, usingSyntax: Int32(SendExplicitLittleEndian.rawValue))
    }

    @objc(sendFiles:toNode:usingSyntax:)
    public class func sendFiles(_ files: [Any]!, toNode node: [AnyHashable: Any]!, usingSyntax syntax: Int32) {
        let sendController = SendController(files: files)
        let preferences = sendController.processGraph.preferences
        let s = preferences[NetworkPreferences.sendsROIs]

        preferences.set(true, for: NetworkPreferences.sendsROIs)
        preferences.set(Int(syntax), for: NetworkPreferences.sendTransferSyntax)

        _ = Unmanaged.passRetained(sendController) // given back once the send is queued
        sendController.sendToNode(node)

        preferences.set(s, for: NetworkPreferences.sendsROIs)
    }

    @objc(sendFiles:)
    public class func sendFiles(_ files: [Any]!) {
        if PreferencesSource.process.preferences[NetworkPreferences.dicomSendAllowed] == false {
            HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Send", comment: ""), message: NSLocalizedString("DICOM Sending is not activated. Contact your PACS manager for more information about DICOM Send.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        if (files?.count ?? 0) > 0 {
            if SendController.destinations().count > 0 {
                let sendController = SendController(files: files)
                _ = Unmanaged.passRetained(sendController) // given back once the send is queued

                if let sheet = sendController.window {
                    if let parent = NSApp.mainWindow {
                        parent.beginSheet(sheet) { response in
                            sendController.sheetDidEnd(sheet, returnCode: Int32(response.rawValue), contextInfo: nil)
                        }
                    } else {
                        sheet.makeKeyAndOrderFront(sendController)
                    }
                }
            } else {
                HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Send", comment: ""), message: NSLocalizedString("No DICOM destinations available. See Preferences to add DICOM locations.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        } else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Send", comment: ""), message: NSLocalizedString("No files are selected...", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    /// Send.xib enables the "Only key images" radio with `self.hasKeyImages`.
    @objc(hasKeyImages)
    public func hasKeyImages() -> Bool {
        let predicate = NSPredicate(format: "isKeyImage == YES")
        return _files.contains { predicate.evaluate(with: $0) }
    }

    /// Send.xib enables the "Only Secondary Captures" radio with
    /// `self.hasSecondaryCapturesImages`.
    @objc(hasSecondaryCapturesImages)
    public func hasSecondaryCapturesImages() -> Bool {
        let predicate = NSPredicate(format: "modality CONTAINS[c] %@", "SC")
        return _files.contains { predicate.evaluate(with: $0) }
    }

    @objc(initWithFiles:)
    public convenience init(files: [Any]!) {
        self.init(files: files, processGraph: ProcessGraph.process)
    }

    init(files: [Any]!, processGraph: ProcessGraph) {
        self.processGraph = processGraph
        super.init(window: nil)

        NSLog("SendController initWithFiles: %d files", Int32(truncatingIfNeeded: files?.count ?? 0))

        liveSendControllers.wrappingAdd(1, ordering: .relaxed)

        _files = files ?? []

        // The files, each once; the images without one count as one more.
        let completePaths = Set(_files.compactMap { $0 as? DicomImage }.map { $0.completePath() })
        setNumberFiles(String(format: "%d", Int32(truncatingIfNeeded: completePaths.count)))

        let preferences = processGraph.preferences
        _serverIndex = preferences[NetworkPreferences.lastSendServer]

        // NSInteger against the NSUInteger count: a negative index was a huge
        // unsigned one, and went back to 0 too.
        let serverCount = SendController.destinations().count
        if _serverIndex < 0 || _serverIndex >= serverCount {
            _serverIndex = 0
        }

        _keyImageIndex = SendWhatFilter.resolvedIndex(preferences[NetworkPreferences.lastSendWhat],
                                                      hasKeyImages: self.hasKeyImages(),
                                                      hasSecondaryCaptures: self.hasSecondaryCapturesImages())

        NSUserDefaultsController.shared.addObserver(self, forValuesKey: NetworkPreferences.dicomNodes.name, options: .initial, context: nil)
        NSUserDefaultsController.shared.addObserver(self, forValuesKey: NetworkPreferences.dicomwebNodes.name, options: [], context: nil)
        NSUserDefaultsController.shared.addObserver(self, forValuesKey: NetworkPreferences.sendControllerConcurrentThreads.name, options: .initial, context: nil)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateDestinationPopup(_:)),
                                               name: NSNotification.Name("DCMNetServicesDidChange"),
                                               object: nil)
    }

    public required init?(coder: NSCoder) {
        processGraph = ProcessGraph.process
        super.init(coder: coder)
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if (object as AnyObject?) === NSUserDefaultsController.shared {
            // The shared defaults controller notifies on the thread that wrote
            // the default.
            onMainActor { self.defaultsDidChange(keyPath) }
        }
    }

    private func defaultsDidChange(_ keyPath: String?) {
        if keyPath == NetworkPreferences.controllerKeyPath(NetworkPreferences.dicomNodes) || keyPath == NetworkPreferences.controllerKeyPath(NetworkPreferences.dicomwebNodes) {
            updateDestinationPopup(nil)
        }

        // The current node keeps the thread count chosen for it. A list given
        // as an argument of the launch is not written back to the preferences.
        let store = DICOMNodeService.store
        if keyPath == NetworkPreferences.controllerKeyPath(NetworkPreferences.sendControllerConcurrentThreads) && !store.dicomNodesGivenAsArgument {
            let currentServer = self.server() as? [String: Any]
            // -isEqualToString: of a nil string, or with one, answered NO.
            func same(_ value: String?, _ key: String) -> Bool {
                guard let value, let current = currentServer?[key] as? String else { return false }
                return value == current
            }
            // The node keeps the value in the form it is stored in; the send reads it as an integer.
            let threads = processGraph.preferences[NetworkPreferences.sendControllerConcurrentThreads.reading(as: PropertyListValue?.self)]
            store.updateFirstDICOMNode(where: { same($0.address, DICOMNode.Key.address) && same($0.nodeDescription, DICOMNode.Key.description) }) {
                $0["SendControllerConcurrentThreads"] = threads
            }
        }
    }

    public override func windowDidLoad() {
        super.windowDidLoad()

        if !_files.isEmpty {
            updateDestinationPopup(nil)

            let count = SendController.destinations().count
            if _serverIndex < count {
                newServerList?.selectItem(at: _serverIndex)
            }

            _ = keyImageMatrix?.selectCell(withTag: _keyImageIndex)

            selectServer(newServerList)
        }
    }

    deinit {
        NSUserDefaultsController.shared.removeObserver(self, forValuesKey: NetworkPreferences.dicomNodes.name)
        NSUserDefaultsController.shared.removeObserver(self, forValuesKey: NetworkPreferences.dicomwebNodes.name)
        NSUserDefaultsController.shared.removeObserver(self, forValuesKey: NetworkPreferences.sendControllerConcurrentThreads.name)

        NotificationCenter.default.removeObserver(self)

        liveSendControllers.wrappingSubtract(1, ordering: .relaxed)

        NSLog("SendController Released")
    }

    @objc(numberFiles)
    public dynamic func numberFiles() -> String! {
        return _numberFiles
    }

    @objc(setNumberFiles:)
    public dynamic func setNumberFiles(_ numberFiles: String!) {
        _numberFiles = numberFiles
    }

    @objc(server)
    public func server() -> Any! {
        if let destinationServer = _destinationServer {
            return destinationServer
        }

        return server(at: Int32(truncatingIfNeeded: _serverIndex))
    }

    // MARK: Accessors functions

    @objc(serverAtIndex:)
    public func server(at index: Int32) -> Any! {
        let serversArray = SendController.destinations()

        if index > -1 && Int(index) < serversArray.count {
            return serversArray[Int(index)]
        }

        return nil
    }

    @IBAction @objc(selectServer:)
    public func selectServer(_ sender: Any!) {
        _serverIndex = (sender as? NSPopUpButton)?.indexOfSelectedItem ?? 0

        let preferences = processGraph.preferences
        preferences.set(_serverIndex, for: NetworkPreferences.lastSendServer)

        let server = self.server() as? [AnyHashable: Any]
        if let server {
            let preferredTS = intValue(server["TransferSyntax"])

            preferences.set(Int(preferredTS), for: NetworkPreferences.sendTransferSyntax)

            if server["SendControllerConcurrentThreads"] != nil {
                preferences.set(Int(intValue(server["SendControllerConcurrentThreads"])), for: NetworkPreferences.sendControllerConcurrentThreads)
            }
        }

        // A DICOMweb node sends in its own Send Syntax, to {address}/studies.
        if DICOMwebSources.isDICOMwebServer(server) {
            addressAndPort?.stringValue = DICOMwebSources.storeURL(forServer: server)
            syntaxListOffis?.isEnabled = false
        } else {
            addressAndPort?.stringValue = String(format: "%@ : %@", describe(server?["Address"]), describe(server?["Port"]))
            syntaxListOffis?.isEnabled = true
        }
    }

    /// Send.xib binds the radios' selected index to `keyImageIndex`.
    @objc(keyImageIndex)
    public dynamic func keyImageIndex() -> Int32 {
        return Int32(truncatingIfNeeded: _keyImageIndex)
    }

    @objc(setKeyImageIndex:)
    public dynamic func setKeyImageIndex(_ index: Int32) {
        _keyImageIndex = Int(index)
        processGraph.preferences.set(Int(index), for: NetworkPreferences.lastSendWhat)
    }

    // MARK: sheet functions

    @objc(sheetDidEnd:returnCode:contextInfo:)
    public func sheetDidEnd(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer?) {
    }

    @IBAction @objc(endSelectServer:)
    public func endSelectServer(_ sender: Any!) {
        let tag = (sender as? NSControl)?.tag ?? (sender as? NSMenuItem)?.tag ?? 0

        self.window?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.RawValue(tag)))
        var objectsToSend = _files

        if tag != 0 { //User clicks OK Button
            if _keyImageIndex == 1 {
                let predicate = NSPredicate(format: "isKeyImage == YES")
                objectsToSend = objectsToSend.filter { predicate.evaluate(with: $0) }
            }

            if _keyImageIndex == 2 {
                let predicate = NSPredicate(format: "modality CONTAINS[c] %@", "SC")
                objectsToSend = objectsToSend.filter { predicate.evaluate(with: $0) }
            }

            // Remove duplicates: an object chosen twice is sent once.
            var seen = Set<ObjectIdentifier>()
            objectsToSend = objectsToSend.filter { seen.insert(ObjectIdentifier($0 as AnyObject)).inserted }

            if !objectsToSend.isEmpty {
                sendToNode(self.server() as? [AnyHashable: Any], objects: objectsToSend)
            } else {
                HorosAlertPanel.run(title: NSLocalizedString("DICOM Send", comment: ""), message: NSLocalizedString("There are no files of selected type to send.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)

                _ = Unmanaged.passUnretained(self).autorelease()
            }
        } else { // Cancel
            _ = Unmanaged.passUnretained(self).autorelease()
        }
    }

    @objc(sendToNode:)
    public func sendToNode(_ node: [AnyHashable: Any]!) {
        sendToNode(node, objects: nil)
    }

    /// Queues the send of `objects` (the controller's files when nil) to
    /// `node` (the destination the sheet shows when nil). The reference its
    /// creator never released is given back afterwards on the main thread, in
    /// an autorelease pool of its own, as the former send did when it ended.
    @objc(sendToNode:objects:)
    public func sendToNode(_ node: [AnyHashable: Any]!, objects: [Any]!) {
        defer {
            DispatchQueue.main.async { _ = Unmanaged.passUnretained(self).autorelease() }
        }

        _destinationServer = node
        if let request = sendRequest(to: node, objects: objects ?? _files) {
            processGraph.dicomSendQueue.enqueue(request, through: ActivitySendTransport())
        }
    }

    // MARK: The request

    /// The send of the images among `objects` to `node`, with the settings of
    /// the preferences; nil when nothing is left to send.
    private func sendRequest(to node: [AnyHashable: Any]?, objects: [Any]) -> DICOMSendRequest? {
        let preferences = processGraph.preferences
        let sendsAppSeries = preferences[NetworkPreferences.sendsROIs]
        let images = objects.compactMap { $0 as? DicomImage }
        var items: [DICOMSendSelection.Item] = []
        do {
            // Core Data raises for an image deleted since it was chosen.
            try HorosObjCException.perform {
                items = DICOMSendSelection.items(of: images, markingAppSeries: !sendsAppSeries)
            }
        } catch {
            NSLog("***** sendToNode exception: %@", describe((error as NSError).userInfo[HorosObjCExceptionKey]))
        }
        let batches = DICOMSendSelection.batches(of: items, sendsAppSeries: sendsAppSeries)
        guard !batches.isEmpty else { return nil }

        // The destination named, or else the one the sheet shows.
        let entry = (node ?? self.server() as? [AnyHashable: Any]) as? [String: Any] ?? [:]
        let destination = DICOMNode(propertyList: entry) ?? DICOMNode(entry: entry.compactMapValues { PropertyListValue($0) })

        let route: DICOMSendRoute
        if DICOMwebSources.isDICOMwebServer(node) {
            route = .dicomweb
        } else if DirectTransferPolicy.route(server: node as? [String: Any] ?? [:], destinationChosen: node != nil,
                                             authorized: ((node?["HorosDirectTransferToken"] as? NSString)?.length ?? 0) > 0)
                    == DirectTransferPolicy.routeDirect {
            route = .directTransferFirst
        } else {
            route = .cStore
        }

        let associations = DICOMSendOptions.associationsPerBatch(
            requested: preferences[NetworkPreferences.sendControllerConcurrentThreads],
            maximum: preferences[NetworkPreferences.maximumSendControllerConcurrentThreads])
        if associations > 1 {
            NSLog("DCMTKStoreSCU threads: %d", Int32(bitPattern: associations))
        }
        let options = DICOMSendOptions(callingAETitle: UserDefaults.defaultAETitle(), associationsPerBatch: associations,
                                       mostConcurrentSends: preferences[NetworkPreferences.maximumSendGlobalControllerConcurrentThreads])
        return DICOMSendRequest(destination: destination, batches: batches,
                                transferSyntax: preferences[NetworkPreferences.sendTransferSyntax], compression: 1,
                                route: route, options: options)
    }

    // MARK: serversArray functions

    @objc(updateDestinationPopup:)
    public func updateDestinationPopup(_ note: Notification!) {
        if let newServerList = newServerList {
            let currentTitle = newServerList.selectedItem?.title

            newServerList.removeAllItems()
            for destination in SendController.destinations() {
                var title = String(format: "%@ - %@", describe(destination["AETitle"]), describe(destination["Description"]))

                while newServerList.indexOfItem(withTitle: title) != -1 {
                    title = title + " "
                }

                newServerList.addItem(withTitle: title)
            }

            for d in newServerList.itemArray {
                if let currentTitle = currentTitle, d.title == currentTitle {
                    newServerList.select(d)
                }
            }
        }
    }
}
