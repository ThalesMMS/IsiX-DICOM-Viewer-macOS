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

/// `static volatile int sendControllerObjects`: the SendController instances
/// alive, which BrowserController asks before quitting.
private var liveSendControllers: Int32 = 0

/// `static int globalDCMTKSCUCounter`: the sends running, across controllers.
///
/// Behind a lock since #762. The former counter was read and written by the
/// sending threads without one, and a send counted itself before waiting for
/// its turn: once MaximumSendGlobalControllerConcurrentThreads sends were
/// waiting, none running, each saw the others and they all waited forever.
/// Only running sends count now, and a send checks and takes its slot at once.
private enum GlobalSendSlots {
    private static let lock = NSLock()
    private static var running = 0

    /// Waits for a slot. As before, a send starts when none runs, or when it
    /// makes fewer than MaximumSendGlobalControllerConcurrentThreads.
    static func acquire() {
        while true {
            let maximum = UserDefaults.standard.integer(forKey: "MaximumSendGlobalControllerConcurrentThreads")

            lock.lock()
            if running == 0 || running + 1 < maximum {
                running += 1
                lock.unlock()
                return
            }
            lock.unlock()

            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    static func release() {
        lock.lock()
        running -= 1
        lock.unlock()
    }
}

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

/// -integerValue of an NSNumber or NSString; 0 for nil, as a message to nil.
private func integerValue(_ object: Any?) -> Int {
    if let number = object as? NSNumber { return number.intValue }
    if let string = object as? NSString { return string.integerValue }
    return 0
}

/// N2LocalizedSingularPluralCount of N2Stuff.h.
private func N2LocalizedSingularPluralCount(_ c: Int, _ s: String, _ p: String) -> String {
    return String(format: "%@ %@",
                  NumberFormatter.localizedString(from: NSNumber(value: c), number: .decimal),
                  c == 1 ? s : p)
}

/// One DCMTKStoreSCU run over part of the files, in the operation queue of
/// -[SendController executeSend:patientName:].
///
/// Private to SendController.m before #716, and public here so the executable
/// keeps exporting the class under the same name.
@objc(DCMTKStoreSCUOperation)
public final class DCMTKStoreSCUOperation: Operation, @unchecked Sendable {
    /// The former properties were atomic: -executeSend:patientName: reads
    /// `thread` from the sending thread while -main sets it on the queue's.
    private let propertyLock = NSLock()
    private var _files: NSArray?
    private var _server: NSDictionary?
    private var _thread: Thread?

    @objc public var files: NSArray! {
        get { propertyLock.lock(); defer { propertyLock.unlock() }; return _files }
        set { propertyLock.lock(); _files = newValue; propertyLock.unlock() }
    }

    @objc public var server: NSDictionary! {
        get { propertyLock.lock(); defer { propertyLock.unlock() }; return _server }
        set { propertyLock.lock(); _server = newValue; propertyLock.unlock() }
    }

    @objc public var thread: Thread! {
        get { propertyLock.lock(); defer { propertyLock.unlock() }; return _thread }
        set { propertyLock.lock(); _thread = newValue; propertyLock.unlock() }
    }

    @objc(initWithFiles:server:)
    public init(files a: NSArray!, server s: NSDictionary!) {
        super.init()

        self.files = a
        self.server = s
    }

    @objc(showErrorMessage:)
    public func showErrorMessage(_ ne: NSException!) {
        let message = String(format: "%@\r\r%@\r%@", NSLocalizedString("DICOM StoreSCU operation failed.", comment: ""), describe(ne?.name.rawValue), describe(ne?.reason))

        HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Send Error", comment: ""), message: message, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    public override func main() {
        autoreleasepool {
            if self.isCancelled {
                return
            }

            self.thread = Thread.current
            self.thread.progress = 0

            let server = self.server
            let storeSCU = DCMTKStoreSCU(callingAET: UserDefaults.defaultAETitle(),
                                         calledAET: server?.object(forKey: "AETitle") as? String,
                                         hostname: server?.object(forKey: "Address") as? String,
                                         port: intValue(server?.object(forKey: "Port")),
                                         filesToSend: files as? [Any],
                                         transferSyntax: Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "syntaxListOffis")),
                                         compression: 1.0,
                                         extraParameters: server as? [AnyHashable: Any])

            do {
                try HorosObjCException.perform {
                    storeSCU?.run(self)
                }
            } catch {
                let ne = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                self.performSelector(onMainThread: #selector(showErrorMessage(_:)), with: ne, waitUntilDone: false)
            }
        }
    }
}

/// Window Controller for DICOM Send (Send.xib), and the send itself: the files
/// go to the node through HorosDirectTransferService or DCMTKStoreSCU, which
/// stays Objective-C++.
///
/// Implemented in Swift since #716: the Objective-C name, the selectors and
/// <Horos/SendController.h> are those of the former class, the File's Owner of
/// Send.xib.
///
/// A controller keeps itself alive until its send ends, as the former one did
/// under manual retain/release: whoever makes one does not release it.
/// -sendToNode:objects: locks `_lock` and starts -releaseSelfWhenDone:, which
/// waits for the send to unlock it and then autoreleases the controller on the
/// main thread; the sheet's Cancel, and an empty selection, autorelease it too.
/// When nothing is left to send after the filters, -sendToNode:objects:
/// unlocks `_lock` itself (#762).
@objc(SendController)
public final class SendController: NSWindowController {
    // Ivars of the former class.
    private var _files: NSArray?
    private var _numberFiles: String?
    private var _keyImageIndex: Int = 0
    private var _serverIndex: Int = 0
    private var _offisTS: Int = 0
    private var _readyForRelease = false
    private var _abort = false
    private let _lock = NSRecursiveLock()
    private var _destinationServer: NSDictionary?

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

    @objc(sendControllerObjects)
    public class func sendControllerObjects() -> Int32 {
        return liveSendControllers
    }

    /// The destinations the sheet lists: the DIMSE nodes that send, then the
    /// DICOMweb nodes with Send on (#799), which STOW-RS sends to. The DIMSE
    /// nodes come first so that `lastSendServer` keeps naming the same one.
    static func destinations() -> [Any] {
        let dimse = DCMNetServiceDelegate.dicomServersListSendOnly(true, qrOnly: false) ?? []
        return dimse + DICOMwebSources.sendDestinations().map { $0 as NSDictionary }
    }

    @objc(sendFiles:toNode:)
    public class func sendFiles(_ files: [Any]!, toNode node: NSDictionary!) {
        return SendController.sendFiles(files, toNode: node, usingSyntax: Int32(SendExplicitLittleEndian.rawValue))
    }

    @objc(sendFiles:toNode:usingSyntax:)
    public class func sendFiles(_ files: [Any]!, toNode node: NSDictionary!, usingSyntax syntax: Int32) {
        let s = UserDefaults.standard.bool(forKey: "sendROIs")

        UserDefaults.standard.set(true, forKey: "sendROIs")
        UserDefaults.standard.set(Int(syntax), forKey: "syntaxListOffis")

        let sendController = SendController(files: files)
        _ = Unmanaged.passRetained(sendController) // released when the send ends
        sendController.sendToNode(node)

        UserDefaults.standard.set(s, forKey: "sendROIs")
    }

    @objc(sendFiles:)
    public class func sendFiles(_ files: [Any]!) {
        if UserDefaults.standard.bool(forKey: "DICOMSENDALLOWED") == false {
            HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Send", comment: ""), message: NSLocalizedString("DICOM Sending is not activated. Contact your PACS manager for more information about DICOM Send.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        if (files?.count ?? 0) > 0 {
            if SendController.destinations().count > 0 {
                let sendController = SendController(files: files)
                _ = Unmanaged.passRetained(sendController) // released when the send ends

                // -beginSheet:modalForWindow:… as sent before, also when there
                // is no main window (the Swift declaration refuses nil there).
                typealias BeginSheet = @convention(c) (AnyObject, Selector, NSWindow?, NSWindow?, AnyObject?, Selector?, UnsafeMutableRawPointer?) -> Void
                let beginSheet = NSSelectorFromString("beginSheet:modalForWindow:modalDelegate:didEndSelector:contextInfo:")
                let imp = unsafeBitCast(NSApp.method(for: beginSheet), to: BeginSheet.self)
                imp(NSApp, beginSheet, sendController.window, NSApp.mainWindow, sendController, #selector(sheetDidEnd(_:returnCode:contextInfo:)), nil)
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
        let objectsToSend = _files?.filtered(using: predicate) ?? []

        return objectsToSend.count > 0
    }

    /// Send.xib enables the "Only Secondary Captures" radio with
    /// `self.hasSecondaryCapturesImages`.
    @objc(hasSecondaryCapturesImages)
    public func hasSecondaryCapturesImages() -> Bool {
        let predicate = NSPredicate(format: "modality CONTAINS[c] %@", "SC")
        let objectsToSend = _files?.filtered(using: predicate) ?? []

        return objectsToSend.count > 0
    }

    @objc(initWithFiles:)
    public init(files: [Any]!) {
        super.init(window: nil)

        NSLog("SendController initWithFiles: %d files", Int32(truncatingIfNeeded: files?.count ?? 0))

        liveSendControllers += 1

        _abort = false
        _files = (files as NSArray?)?.copy() as? NSArray

        let completePaths = _files?.value(forKey: "completePath") as? [Any] ?? []
        setNumberFiles(String(format: "%d", Int32(truncatingIfNeeded: NSSet(array: completePaths).allObjects.count)))

        _serverIndex = UserDefaults.standard.integer(forKey: "lastSendServer")

        // NSInteger against the NSUInteger count: a negative index was a huge
        // unsigned one, and went back to 0 too.
        let serverCount = SendController.destinations().count
        if _serverIndex < 0 || _serverIndex >= serverCount {
            _serverIndex = 0
        }

        _keyImageIndex = SendWhatFilter.resolvedIndex(UserDefaults.standard.integer(forKey: "lastSendWhat"),
                                                      hasKeyImages: self.hasKeyImages(),
                                                      hasSecondaryCaptures: self.hasSecondaryCapturesImages())

        _readyForRelease = false

        NSUserDefaultsController.shared.addObserver(self, forValuesKey: "SERVERS", options: .initial, context: nil)
        NSUserDefaultsController.shared.addObserver(self, forValuesKey: "DICOMWEB_SERVERS", options: [], context: nil)
        NSUserDefaultsController.shared.addObserver(self, forValuesKey: "SendControllerConcurrentThreads", options: .initial, context: nil)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateDestinationPopup(_:)),
                                               name: NSNotification.Name("DCMNetServicesDidChange"),
                                               object: nil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if (object as AnyObject?) === NSUserDefaultsController.shared {
            if keyPath == "values.SERVERS" || keyPath == "values.DICOMWEB_SERVERS" {
                updateDestinationPopup(nil)
            }

            // A list given as an argument of the launch is not written back
            // to the preferences (#855).
            if keyPath == "values.SendControllerConcurrentThreads"
                && UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["SERVERS"] == nil {
                // Find current server (if it exists)

                let servers = (UserDefaults.standard.object(forKey: "SERVERS") as? NSArray)?.mutableCopy() as? NSMutableArray
                let currentServer = self.server() as? NSDictionary

                for index in 0..<(servers?.count ?? 0) {
                    guard let server = servers?.object(at: index) as? NSDictionary else { continue }

                    // -isEqualToString: of a nil string, or with one, answered NO.
                    func same(_ key: String) -> Bool {
                        guard let a = server.object(forKey: key) as? String,
                              let b = currentServer?.object(forKey: key) as? String else { return false }
                        return a == b
                    }

                    if same("Address") && same("Description") {
                        let d = NSMutableDictionary(dictionary: server)

                        d.setObject(UserDefaults.standard.object(forKey: "SendControllerConcurrentThreads") as Any, forKey: "SendControllerConcurrentThreads" as NSString)

                        servers!.replaceObject(at: servers!.index(of: server), with: d)

                        UserDefaults.standard.set(servers, forKey: "SERVERS")

                        break
                    }
                }
            }
        }
    }

    public override func windowDidLoad() {
        super.windowDidLoad()

        if (_files?.count ?? 0) > 0 {
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
        NSUserDefaultsController.shared.removeObserver(self, forValuesKey: "SERVERS")
        NSUserDefaultsController.shared.removeObserver(self, forValuesKey: "DICOMWEB_SERVERS")
        NSUserDefaultsController.shared.removeObserver(self, forValuesKey: "SendControllerConcurrentThreads")

        NotificationCenter.default.removeObserver(self)

        liveSendControllers -= 1

        NSLog("SendController Released")
        _lock.lock()
        _lock.unlock()
    }

    @objc(releaseSelfWhenDone:)
    public func releaseSelfWhenDone(_ sender: Any!) {
        autoreleasepool {
            _lock.lock()
            _lock.unlock()

            // -autorelease on the main thread balances the reference the
            // creator of the controller never released.
            self.performSelector(onMainThread: NSSelectorFromString("autorelease"), with: nil, waitUntilDone: false)
        }
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

        UserDefaults.standard.set(_serverIndex, forKey: "lastSendServer")

        if let server = self.server() as? NSDictionary {
            let preferredTS = intValue(server.object(forKey: "TransferSyntax"))

            UserDefaults.standard.set(Int(preferredTS), forKey: "syntaxListOffis")

            if server.object(forKey: "SendControllerConcurrentThreads") != nil {
                UserDefaults.standard.set(Int(intValue(server.object(forKey: "SendControllerConcurrentThreads"))), forKey: "SendControllerConcurrentThreads")
            }
        }

        let server = self.server() as? NSDictionary
        // A DICOMweb node sends in its own Send Syntax, to {address}/studies.
        if DICOMwebSources.isDICOMwebServer(server as? [AnyHashable: Any]) {
            addressAndPort?.stringValue = DICOMwebSources.storeURL(forServer: server as? [AnyHashable: Any])
            syntaxListOffis?.isEnabled = false
        } else {
            addressAndPort?.stringValue = String(format: "%@ : %@", describe(server?.object(forKey: "Address")), describe(server?.object(forKey: "Port")))
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
        UserDefaults.standard.set(Int(index), forKey: "lastSendWhat")
    }

    // MARK: sheet functions

    @objc(sheetDidEnd:returnCode:contextInfo:)
    public func sheetDidEnd(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer?) {
    }

    @IBAction @objc(endSelectServer:)
    public func endSelectServer(_ sender: Any!) {
        let tag = (sender as? NSControl)?.tag ?? (sender as? NSMenuItem)?.tag ?? 0

        self.window?.orderOut(sender)
        if let window = self.window {
            NSApp.endSheet(window, returnCode: NSApplication.ModalResponse.RawValue(tag))
        }
        var objectsToSend: NSArray? = _files

        if tag != 0 { //User clicks OK Button
            if _keyImageIndex == 1 {
                let predicate = NSPredicate(format: "isKeyImage == YES")
                objectsToSend = _files?.filtered(using: predicate) as NSArray?
            }

            if _keyImageIndex == 2 {
                let predicate = NSPredicate(format: "modality CONTAINS[c] %@", "SC")
                objectsToSend = objectsToSend?.filtered(using: predicate) as NSArray?
            }

            // Remove duplicates
            objectsToSend = NSSet(array: (objectsToSend as? [Any]) ?? []).allObjects as NSArray

            let files2Send = objectsToSend?.value(forKey: "completePath") as? NSArray

            if let files2Send = files2Send, files2Send.count > 0 {
                sendToNode(self.server() as? NSDictionary, objects: objectsToSend as? [Any])
            } else {
                HorosAlertPanel.run(title: NSLocalizedString("DICOM Send", comment: ""), message: NSLocalizedString("There are no files of selected type to send.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)

                _ = Unmanaged.passUnretained(self).autorelease()
            }
        } else { // Cancel
            _ = Unmanaged.passUnretained(self).autorelease()
        }
    }

    @objc(addArray:toArraysOfFiles:andArrayOfPatientNames:)
    public func addArray(_ a: NSMutableArray!, toArraysOfFiles arraysOfFiles: NSMutableArray!, andArrayOfPatientNames arrayOfPatientNames: NSMutableArray!) {
        if (a?.count ?? 0) == 0 {
            return
        }

        if UserDefaults.standard.bool(forKey: "sendROIs") == false {
            do {
                try HorosObjCException.perform {
                    var predicate: NSPredicate

                    predicate = NSPredicate(format: "!(series.name CONTAINS[c] %@) AND !(series.id == %@)", "OsiriX ROI SR", "5002")
                    a.filter(using: predicate)

                    predicate = NSPredicate(format: "!(series.name CONTAINS[c] %@) AND !(series.id == %@)", "OsiriX Report SR", "5003")
                    a.filter(using: predicate)

                    predicate = NSPredicate(format: "!(series.name CONTAINS[c] %@) AND !(series.id == %@)", "OsiriX Annotations SR", "5004")
                    a.filter(using: predicate)

                    predicate = NSPredicate(format: "!(series.name CONTAINS[c] %@) AND !(series.id == %@)", "OsiriX No Autodeletion", "5005")
                    a.filter(using: predicate)

                    predicate = NSPredicate(format: "!(series.name CONTAINS[c] %@) AND !(series.id == %@)", "OsiriX WindowsState SR", "5006")
                    a.filter(using: predicate)
                }
            } catch {
                NSLog("***** executeSend exception: %@", describe((error as NSError).userInfo[HorosObjCExceptionKey]))
            }
        }

        // A patient whose images were all filtered out above has no batch. The
        // former -addObject: raised on the nil patient name instead, and the
        // exception dropped the patients after this one too (#762); a study
        // without a name raised the same way, and its images were not sent.
        if a.count == 0 {
            return
        }

        arrayOfPatientNames.add((a.lastObject as AnyObject?)?.value(forKeyPath: "series.study.name") ?? NSNull())
        arraysOfFiles.add(a.value(forKey: "completePathResolved"))
    }

    @objc(sendToNode:)
    public func sendToNode(_ node: NSDictionary!) {
        sendToNode(node, objects: nil)
    }

    @objc(sendToNode:objects:)
    public func sendToNode(_ node: NSDictionary!, objects: [Any]!) {
        let objects: [Any] = objects ?? (_files as? [Any]) ?? []

        let objectsToSend = NSMutableArray(array: objects)

        _lock.lock()
        Thread.detachNewThreadSelector(#selector(releaseSelfWhenDone(_:)), toTarget: self, with: nil)

        _destinationServer = node

        let arraysOfFiles = NSMutableArray()
        let arrayOfPatientNames = NSMutableArray()

        do {
            try HorosObjCException.perform {
                objectsToSend.sort(using: [NSSortDescriptor(key: "series.study.patientUID", ascending: true)])

                // Remove duplicated files
                let paths = NSMutableArray(array: (objectsToSend.value(forKey: "completePathResolved") as? [Any]) ?? [])
                // MutableArrayCategory, by its Objective-C selector.
                _ = paths.perform(NSSelectorFromString("removeDuplicatedStringsInSyncWithThisArray:"), with: objectsToSend)

                if objectsToSend.count > 0 {
                    var previousPatientUID: String? = nil
                    var samePatientArray = NSMutableArray()

                    for image in objectsToSend {
                        let patientUID = (image as AnyObject).value(forKeyPath: "series.study.patientUID") as? String

                        // One batch per patient (#762). The former code
                        // compared with a previousPatientUID that started nil
                        // and was only set on a change: -compare:options: sent
                        // to nil answered NSOrderedSame, so there never was
                        // one, and every patient went in one batch, under the
                        // last one's name.
                        if samePatientArray.count > 0 {
                            let same = ((previousPatientUID ?? "") as NSString).compare(patientUID ?? "", options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame

                            if !same {
                                addArray(samePatientArray, toArraysOfFiles: arraysOfFiles, andArrayOfPatientNames: arrayOfPatientNames)

                                // Reset
                                samePatientArray = NSMutableArray()
                            }
                        }

                        if samePatientArray.count == 0 {
                            previousPatientUID = patientUID
                        }
                        samePatientArray.add(image)
                    }

                    addArray(samePatientArray, toArraysOfFiles: arraysOfFiles, andArrayOfPatientNames: arrayOfPatientNames)
                }
            }
        } catch {
            NSLog("***** sendDICOMFilesOffis exception: %@", describe((error as NSError).userInfo[HorosObjCExceptionKey]))
        }

        if arraysOfFiles.count > 0 {
            let dict: NSDictionary = ["arraysOfFiles": arraysOfFiles, "arrayOfPatientNames": arrayOfPatientNames]

            let t = Thread(target: self, selector: #selector(sendDICOMFilesOffis(_:)), object: dict)
            t.name = NSLocalizedString("Sending...", comment: "")
            t.supportsCancel = true
            t.progress = 0
            t.status = N2LocalizedSingularPluralCount(_files?.count ?? 0, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))
            ThreadsManager.default().addThreadAndStart(t)
        } else {
            // Nothing left to send: no -sendDICOMFilesOffis: will unlock, so
            // unlock here, on the thread that locked, or -releaseSelfWhenDone:
            // waits forever and the controller leaks (#762).
            _lock.unlock()
        }
    }

    // MARK: Sending functions

    @objc(executeSend:patientName:)
    public func executeSend(_ files: [Any]!, patientName: String!) {
        let files: NSArray = (files as NSArray?) ?? []

        if Thread.current.isCancelled {
            return
        }

        Thread.current.name = String(format: "%@ %@", NSLocalizedString("Sending...", comment: ""), describe(patientName))

        // Send the collected files from the same patient

        let operations = NSMutableArray()
        let queue = OperationQueue()
        queue.name = String(format: "%@ %@", NSLocalizedString("Sending...", comment: ""), describe(patientName))

        // `unsigned int`, compared with the NSInteger defaults as before.
        var maxThreads = UInt32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "SendControllerConcurrentThreads"))

        if Int(maxThreads) > UserDefaults.standard.integer(forKey: "MaximumSendControllerConcurrentThreads") {
            maxThreads = UInt32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "MaximumSendControllerConcurrentThreads"))
        }

        if maxThreads <= 0 {
            maxThreads = 1
        }

        if maxThreads > 1 {
            NSLog("DCMTKStoreSCU threads: %d", Int32(bitPattern: maxThreads))
        }

        var loc = 0
        repeat {
            var range = NSMakeRange(loc, Int(ceil(Double(Float(files.count) / Float(maxThreads)))))
            if operations.count == Int(maxThreads) - 1 {
                range.length = files.count - range.location
            }

            if range.location + range.length > files.count {
                range.length = files.count - range.location
            }

            if range.length > 0 {
                loc += range.length

                let op = DCMTKStoreSCUOperation(files: files.subarray(with: range) as NSArray, server: self.server() as? NSDictionary)

                operations.add(op)
                queue.addOperation(op)
            }
        } while loc < files.count

        while queue.operationCount > 0 {
            if Thread.current.isCancelled {
                Thread.current.progress = -1
                Thread.current.status = NSLocalizedString("Cancelling...", comment: "")
                queue.cancelAllOperations()
                break
            }

            var progress: Float = 0
            for case let o as DCMTKStoreSCUOperation in operations {
                if queue.operations.contains(o) == false {
                    progress += 1.0
                } else if (o.thread?.progress ?? 0) >= 0 {
                    progress += Float(o.thread?.progress ?? 0)
                }
            }

            progress /= Float(operations.count)
            Thread.current.progress = CGFloat(progress)

            let remainingFiles = Int32(Float(files.count) - Float(files.count) * progress)
            Thread.current.status = N2LocalizedSingularPluralCount(Int(remainingFiles), NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))

            Thread.sleep(forTimeInterval: 0.1)
        }

        queue.waitUntilAllOperationsAreFinished()
    }

    @objc(sendDICOMFilesOffis:)
    public func sendDICOMFilesOffis(_ dict: NSDictionary!) {
        autoreleasepool {
            let arraysOfFiles = (dict?.object(forKey: "arraysOfFiles") as? NSArray) ?? []
            let arrayOfPatientNames = (dict?.object(forKey: "arrayOfPatientNames") as? NSArray) ?? []

            GlobalSendSlots.acquire()

            do {
                try HorosObjCException.perform {
                    // A DICOMweb node is sent to by STOW-RS, never by C-STORE (#799).
                    if DICOMwebSources.isDICOMwebServer(self._destinationServer as? [AnyHashable: Any]) {
                        self.sendDICOMweb(arraysOfFiles: arraysOfFiles, patientNames: arrayOfPatientNames)
                        return
                    }
                    var sentDirectly = false
                    let authorized = ((self._destinationServer?.object(forKey: "HorosDirectTransferToken") as? NSString)?.length ?? 0) > 0
                    let route = DirectTransferPolicy.route(server: (self._destinationServer as? [String: Any]) ?? [:],
                                                                destinationChosen: self._destinationServer != nil,
                                                                authorized: authorized)
                    if route == DirectTransferPolicy.routeDirect {
                        let allFiles = NSMutableOrderedSet()
                        for case let patientFiles as [Any] in arraysOfFiles {
                            allFiles.addObjects(from: patientFiles)
                        }
                        let directPort = integerValue(self._destinationServer?.object(forKey: "HorosDirectTransferPort"))
                        NSLog("Horos direct transfer selected: %lu files on one connection (no patient identifiers in the log)",
                              UInt(allFiles.count))
                        sentDirectly = DirectTransferService.shared
                            .send(files: (allFiles.array as? [String]) ?? [],
                                  toHost: (self._destinationServer?.object(forKey: "Address") as? String) ?? "",
                                  port: directPort,
                                  token: (self._destinationServer?.object(forKey: "HorosDirectTransferToken") as? String) ?? "",
                                  activityThread: Thread.current)
                        if !sentDirectly && !Thread.current.isCancelled {
                            NSLog("Horos direct transfer unavailable; falling back to DICOM C-STORE")
                            Thread.current.progress = 0
                            Thread.current.status = NSLocalizedString("Using DICOM transfer...", comment: "")
                        }
                    }

                    if !sentDirectly && !Thread.current.isCancelled {
                        for i in 0..<arraysOfFiles.count {
                            self.executeSend(arraysOfFiles.object(at: i) as? [Any], patientName: arrayOfPatientNames.object(at: i) as? String)
                        }
                    }
                }
            } catch {
                NSLog("***** sendDICOMFilesOffis exception: %@", describe((error as NSError).userInfo[HorosObjCExceptionKey]))
            }

            GlobalSendSlots.release()

            //need to unlock to allow release of self after send complete
            _lock.performSelector(onMainThread: #selector(NSRecursiveLock.unlock), with: nil, waitUntilDone: false)
        }
    }

    // MARK: DICOMweb

    /// STOW-RS of every file to the chosen DICOMweb node, on this thread, the
    /// activity panel's (#799).
    private func sendDICOMweb(arraysOfFiles: NSArray, patientNames: NSArray) {
        let files = NSMutableOrderedSet()
        for case let patientFiles as [Any] in arraysOfFiles {
            files.addObjects(from: patientFiles)
        }
        DICOMwebSendActivity.send(files: files.array.compactMap { $0 as? String },
                                  patientName: patientNames.firstObject as? String,
                                  to: _destinationServer as? [AnyHashable: Any], thread: Thread.current)
    }

    // MARK: serversArray functions

    @objc(updateDestinationPopup:)
    public func updateDestinationPopup(_ note: Notification!) {
        if let newServerList = newServerList {
            let currentTitle = newServerList.selectedItem?.title

            newServerList.removeAllItems()
            for case let d as NSDictionary in SendController.destinations() {
                var title = String(format: "%@ - %@", describe(d.object(forKey: "AETitle")), describe(d.object(forKey: "Description")))

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
