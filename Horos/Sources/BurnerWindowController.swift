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
import UniformTypeIdentifiers
import DiscRecording
import DiscRecordingUI
import Synchronization

/// Window Controller for DICOM disk burning
///
/// Implemented in Swift: the Objective-C name, the selectors, the outlets and
/// bindings of BurnViewer.xib and <Horos/BurnerWindowController.h> are those
/// of the former class.
///
/// As before, the controller owns itself while its window is open: the code
/// that makes one does not release it, and -windowWillClose: autoreleases it.
@objc(BurnerWindowController)
public final class BurnerWindowController: NSWindowController, NSWindowDelegate {
    // Main thread only: the burn thread publishes its progress through the main
    // queue.
    private var burning = false
    private var runBurnAnimation = false
    private var isExtracting = false
    private var isSettingUpBurn = false
    private var windowWillClose = false

    // Pointers, as the former ivars: tools/probe-burn-size-estimate.m sets
    // `files` and `sizeField` by name.
    private var files: NSMutableArray?
    private var anonymizedFiles: NSMutableArray?
    private var dbObjectsID: NSMutableArray?
    private var originalDbObjectsID: NSMutableArray?

    @IBOutlet var nameField: NSTextField!
    @IBOutlet var sizeField: NSTextField!
    @IBOutlet var finalSizeField: NSTextField!
    @IBOutlet var compressionMode: NSMatrix!
    @IBOutlet var burnButton: NSButton!
    @IBOutlet var anonymizedCheckButton: NSButton!
    @IBOutlet var passwordWindow: NSWindow!

    private var cdName: String?
    private var burnAnimationTimer: Timer?
    private var irisAnimationTimer: Timer?
    private var _multiplePatients = false
    private let cancelState = Mutex(false)
    /// Set on the main thread, read by the burn thread between its steps.
    nonisolated private var cancelled: Bool {
        get { cancelState.withLock { $0 } }
        set { cancelState.withLock { $0 = newValue } }
    }
    // A burn that did not write the medium, and why, so the window can say so
    // instead of sounding and closing as if it had.
    private var failed = false
    private var burnFailure: String?
    private var writeDMGPath: String?
    private var writeVolumePath: String?
    private var anonymizationTags: NSArray?
    private var sizeInMb: Int32 = 0

    private var burnAnimationIndex: Int32 = 0
    private var irisAnimationIndex: Int32 = 0

    /// Bound to the enabled state of the window's controls; KVO compliant.
    @objc public dynamic var buttonsDisabled: Bool = false
    /// Bound to the selected index of the USB volume menu.
    @objc public dynamic var selectedUSB: UInt = 0
    /// Bound to the value of the password field.
    @objc public dynamic var password: String?

    @objc public dynamic var filesToBurn: NSArray?

    /// Overridden so that -initWithWindowNibName: is inherited, unchanged.
    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(createDMG:withSource:)
    func createDMG(_ imagePathIn: String!, withSource directoryPathIn: String!) -> Bool {
        let result = BurnerWindowController.makeDiskImage(imagePathIn, from: directoryPathIn)
        if result.written == false {
            burnFailure = result.failure
        }
        return result.written
    }

    /// Builds the disc image at `imagePathIn` from `directoryPathIn`, on the burn
    /// thread; `failure` says why when the image was not written.
    nonisolated private static func makeDiskImage(_ imagePathIn: String?, from directoryPathIn: String?) -> (written: Bool, failure: String?) {
        var imagePath: NSString? = imagePathIn as NSString?
        var directoryPath: NSString? = directoryPathIn as NSString?

        if let imagePath = imagePath {
            try? FileManager.default.removeItem(atPath: imagePath as String)
        }

        let makeImageTask = Process()

        makeImageTask.launchPath = "/bin/sh"

        imagePath = imagePath?.replacingOccurrences(of: "\"", with: "\\\"") as NSString?
        directoryPath = directoryPath?.replacingOccurrences(of: "\"", with: "\\\"") as NSString?

        let cmdString = String(format: "hdiutil create \"%@\" -srcfolder \"%@\"",
                               imagePath ?? "(null)",
                               directoryPath ?? "(null)")

        let args = ["-c", cmdString]

        makeImageTask.arguments = args

        // Building the image is the slow part of a burn, so the deadline is
        // generous; what it rules out is waiting forever for a shell that never
        // returns, which is what the unbounded poll here used to do.
        var taskError: NSError?
        if HorosRunTaskUntilExit(makeImageTask, 1800, &taskError) == false {
            NSLog("****** disk image creation failed: %@", taskError?.localizedDescription ?? "(null)")
            return (false, taskError?.localizedDescription)
        }

        // The task finishing is not the task succeeding. hdiutil reports a full
        // destination, a read-only one or a bad path by exiting non-zero, and that
        // used to be ignored: the window played the success sound and closed itself
        // with no disc image anywhere.
        if makeImageTask.terminationStatus != 0 {
            NSLog("****** disk image creation failed: hdiutil exited %d", makeImageTask.terminationStatus)
            return (false, String(format: NSLocalizedString("The disc image could not be created at %@ (hdiutil exited %d). The files were not written.", comment: ""), imagePath ?? "(null)", makeImageTask.terminationStatus))
        }

        if FileManager.default.fileExists(atPath: (imagePath ?? "") as String) == false {
            return (false, String(format: NSLocalizedString("The disc image %@ was not created. The files were not written.", comment: ""), imagePath ?? "(null)"))
        }

        return (true, nil)
    }

    @objc(initWithFiles:)
    public convenience init(files theFiles: [Any]!) {
        self.init(windowNibName: "BurnViewer")

        try? FileManager.default.removeItem(atPath: folderToBurn())

        files = (theFiles as NSArray?)?.mutableCopy() as? NSMutableArray
        burning = false

        window?.center()

        NSLog("Burner allocated")
    }

    @objc(initWithFiles:managedObjects:)
    public convenience init(files theFiles: [Any]!, managedObjects: [Any]!) {
        self.init(windowNibName: "BurnViewer")

        try? FileManager.default.removeItem(atPath: folderToBurn())

        files = (theFiles as NSArray?)?.mutableCopy() as? NSMutableArray // file paths
        dbObjectsID = (managedObjects as NSArray?)?.mutableCopy() as? NSMutableArray
        originalDbObjectsID = dbObjectsID?.mutableCopy() as? NSMutableArray

        files?.removeDuplicatedStrings(inSyncWithThisArray: dbObjectsID)

        var patient: NSString?
        _multiplePatients = false

        for managedObject in BrowserController.currentBrowser()?.database?.objects(withIDs: dbObjectsID as? [Any]) ?? [] {
            let newPatient = (managedObject as AnyObject).value(forKeyPath: "series.study.patientUID") as? NSString

            if patient == nil {
                patient = newPatient
            } else if let current = patient,
                      current.compare((newPatient ?? "") as String, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != .orderedSame {
                _multiplePatients = true
                break
            }
            patient = newPatient
        }

        burning = false

        window?.center()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(_observeVolumeNotification(_:)), name: NSWorkspace.didMountNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(_observeVolumeNotification(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(_observeVolumeNotification(_:)), name: NSWorkspace.didRenameVolumeNotification, object: nil)

        NSLog("Burner allocated")
    }

    @objc(_observeVolumeNotification:)
    func _observeVolumeNotification(_ notification: Notification) {
        willChangeValue(forKey: "volumes")
        didChangeValue(forKey: "volumes")
    }

    public override func windowDidLoad() {
        super.windowDidLoad()
        NSLog("BurnViewer did load")

        window?.delegate = self
        setup(nil)

        compressionMode?.selectCell(withTag: UserDefaults.standard.integer(forKey: "Compression Mode for Burning"))
    }

    deinit {
        windowWillClose = true

        runBurnAnimation = false

        NSWorkspace.shared.notificationCenter.removeObserver(self)

        NSLog("Burner dealloc")
    }

    // MARK: -

    @objc(extractFileNames:)
    public func extractFileNames(_ filenames: [Any]!) -> [Any]! {
        var isDir: ObjCBool = false

        let fileNames = NSMutableArray()
        for case let fname as String in (filenames ?? []) {
            autoreleasepool {
                let manager = FileManager.default
                if manager.fileExists(atPath: fname, isDirectory: &isDir) && isDir.boolValue {
                    let direnum = manager.enumerator(atPath: fname)
                    //Loop Through directories
                    while let pname = direnum?.nextObject() as? String {
                        let pathName = (fname as NSString).appendingPathComponent(pname) //make pathanme
                        if manager.fileExists(atPath: pathName, isDirectory: &isDir) && !isDir.boolValue {
                            //check for directory
                            if DicomFile.isDICOMFile(pathName) {
                                fileNames.add(pathName)
                            }
                        }
                    } //while pname

                } //if
                else if DicomFile.isDICOMFile(fname) { //Pathname
                    fileNames.add(fname)
                }
            }
        } //while
        return fileNames as? [Any]
    }

    //Actions
    @IBAction @objc(burn:)
    public func burn(_ sender: Any?) {
        if !(isExtracting || isSettingUpBurn || burning) {
            cancelled = false

            sizeField?.stringValue = ""

            cdName = nameField?.stringValue

            if (cdName as NSString?)?.length ?? 0 <= 0 {
                cdName = "UNTITLED"
            }

            try? FileManager.default.removeItem(atPath: folderToBurn())
            try? FileManager.default.removeItem(atPath: (FileManager.default.tmpDirPath() as NSString).appendingPathComponent("burnAnonymized"))

            writeVolumePath = nil

            writeDMGPath = nil

            anonymizationTags = nil

            if UserDefaults.standard.bool(forKey: "anonymizedBeforeBurning") {
                let panelController = Anonymization.showPanel(forDefaultsKey: "AnonymizationFields", modalFor: window, modalDelegate: nil, didEnd: nil, representedObject: nil)

                if Int64(panelController?.end ?? 0) == Int64(AnonymizationPanelCancel.rawValue) {
                    return
                }

                anonymizationTags = panelController?.anonymizationViewController?.tagsValues() as NSArray?
            } else {
                anonymizedFiles = nil
            }

            buttonsDisabled = true

            do {
                try HorosObjCException.perform {
                    if let cdName = self.cdName, (cdName as NSString).length > 0 {
                        self.runBurnAnimation = true

                        if UserDefaults.standard.integer(forKey: "burnDestination") == Int(USBKey.rawValue) {
                            self.writeVolumePath = nil
                            if self.selectedUSB != UInt(bitPattern: NSNotFound) && self.selectedUSB < UInt(self.volumes().count) {
                                self.writeVolumePath = self.volumes()[Int(self.selectedUSB)] as? String
                            }

                            if self.writeVolumePath == nil {
                                HorosAlertPanel.runCritical(title: NSLocalizedString("USB Writing", comment: ""), message: NSLocalizedString("No destination selected.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)

                                self.buttonsDisabled = false
                                self.runBurnAnimation = false
                                self.burning = false
                                return
                            }

                            let result = HorosAlertPanel.runCritical(title: NSLocalizedString("USB Writing", comment: ""), message: String(format: NSLocalizedString("The ENTIRE content of the selected media (%@) will be deleted, before writing the new data. Do you confirm?", comment: ""), self.writeVolumePath ?? "(null)"), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)

                            if result != HorosAlertPanel.defaultResponse {
                                self.buttonsDisabled = false
                                self.runBurnAnimation = false
                                self.burning = false
                                return
                            }

                            BrowserController.currentBrowser()?.removePath(fromSources: self.writeVolumePath)
                        }

                        if UserDefaults.standard.integer(forKey: "burnDestination") == Int(DMGFile.rawValue) {
                            let savePanel = NSSavePanel()
                            savePanel.canSelectHiddenExtension = true
                            savePanel.allowedContentTypes = [UTType(filenameExtension: "dmg")!]
                            savePanel.title = "Save as DMG"
                            savePanel.nameFieldStringValue = cdName

                            if savePanel.runModal() == .OK {
                                self.writeDMGPath = savePanel.url?.path
                                if let writeDMGPath = self.writeDMGPath {
                                    try? FileManager.default.removeItem(atPath: writeDMGPath)
                                }
                            } else {
                                self.buttonsDisabled = false
                                self.runBurnAnimation = false
                                self.burning = false
                                return
                            }
                        }

                        self.password = ""

                        if UserDefaults.standard.bool(forKey: "EncryptCD") {
                            var result = NSApplication.ModalResponse(rawValue: 0)
                            repeat {
                                self.window!.beginSheet(self.passwordWindow, completionHandler: nil)

                                result = NSApp.runModal(for: self.passwordWindow)
                                self.passwordWindow.makeFirstResponder(nil)

                                self.passwordWindow.sheetParent?.endSheet(self.passwordWindow)
                                self.passwordWindow.orderOut(self)
                            } while ((self.password as NSString?)?.length ?? 0) < 8 && result == .stop

                            if result == .stop {

                            } else {
                                self.buttonsDisabled = false
                                self.runBurnAnimation = false
                                self.burning = false
                                return
                            }
                        }

                        // What the thread needs is taken here, on the main thread.
                        self.isSettingUpBurn = true
                        let t = Thread(target: self, selector: #selector(self.performBurn(_:)), object: self.burnJob())
                        t.name = NSLocalizedString("Burning...", comment: "")
                        ThreadsManager.default().addThreadAndStart(t)
                    } else {
                        self.perform(NSSelectorFromString("beginBurnWarningSheet"))

                        self.buttonsDisabled = false
                        self.runBurnAnimation = false
                        self.burning = false
                        return
                    }
                }
            } catch {
                NSLog("*** exception: %@", BurnerWindowController.logged(error))
            }
        }
    }

    /// What the burn thread needs from the window, taken on the main thread
    /// before the thread starts.
    private func burnJob() -> BurnJob {
        return BurnJob(files: (files?.copy() as? NSArray) ?? NSArray(),
                       dbObjectsID: dbObjectsID?.copy() as? NSArray,
                       originalDbObjectsID: originalDbObjectsID?.copy() as? NSArray,
                       anonymizationTags: anonymizationTags?.copy() as? NSArray,
                       folder: folderToBurn(),
                       name: cdName,
                       destination: UserDefaults.standard.integer(forKey: "burnDestination"),
                       writeDMGPath: writeDMGPath,
                       writeVolumePath: writeVolumePath,
                       compressionMode: compressionMode?.selectedTag() ?? 0,
                       password: password)
    }

    // MARK: - Burn thread

    /// The input of a burn: the files, the database objects, the anonymization
    /// tags, the folder and its name, the destination and the paths chosen for
    /// it, the compression mode and the password. Taken on the main thread by
    /// -burnJob and read by the burn thread instead of the window; immutable,
    /// its arrays copies.
    private final class BurnJob: @unchecked Sendable {
        let files: NSArray
        let dbObjectsID: NSArray?
        let originalDbObjectsID: NSArray?
        let anonymizationTags: NSArray?
        let folder: String
        let name: String?
        let destination: Int
        let writeDMGPath: String?
        let writeVolumePath: String?
        let compressionMode: Int
        let password: String?

        init(files: NSArray, dbObjectsID: NSArray?, originalDbObjectsID: NSArray?, anonymizationTags: NSArray?,
             folder: String, name: String?, destination: Int, writeDMGPath: String?, writeVolumePath: String?,
             compressionMode: Int, password: String?) {
            self.files = files
            self.dbObjectsID = dbObjectsID
            self.originalDbObjectsID = originalDbObjectsID
            self.anonymizationTags = anonymizationTags
            self.folder = folder
            self.name = name
            self.destination = destination
            self.writeDMGPath = writeDMGPath
            self.writeVolumePath = writeVolumePath
            self.compressionMode = compressionMode
            self.password = password
        }
    }

    /// The burn thread, started by -burn: with the BurnJob it took. nonisolated,
    /// so that the @objc thunk does not trap when the thread calls it.
    /// The thread reads only the job; what the window shows - the state its
    /// bindings observe, the alert, the sound, the close - is published on the
    /// main thread, in order, through the main queue. Called without a
    /// job, it takes one from the window first.
    @objc(performBurn:)
    nonisolated public func performBurn(_ object: Any?) {
        let job = (object as? BurnJob) ?? onMainActorSync { () -> BurnJob in
            self.isSettingUpBurn = true
            return self.burnJob()
        }

        autoreleasepool {
            // The burn reads its images on a private-queue context, on its queue.
            let idatabase = BrowserController.currentBrowser()?.database?.privateQueueIndependentDatabase() as AnyObject?
            N2ManagedObjectContextPerformAndWait((idatabase as? DicomDatabase)?.managedObjectContext) {
                // Retained and never released, as before.
                if let idatabase = idatabase {
                    _ = Unmanaged.passUnretained(idatabase).retain()
                }

                let dbObjects = ((idatabase as? DicomDatabase)?.objects(withIDs: job.dbObjectsID as? [Any]) as NSArray?)?.mutableCopy() as? NSMutableArray
                let originalDbObjects = ((idatabase as? DicomDatabase)?.objects(withIDs: job.originalDbObjectsID as? [Any]) as NSArray?)?.mutableCopy() as? NSMutableArray

                do {
                    try HorosObjCException.perform {
                        var files = job.files

                        if let anonymizationTags = job.anonymizationTags {
                            var anonymizationError: NSError?
                            let anonOut = Anonymization.anonymizeFiles(job.files, dicomImages: dbObjects, toPath: (FileManager.default.tmpDirPath() as NSString).appendingPathComponent("burnAnonymized"), withTags: anonymizationTags, error: &anonymizationError)
                            if anonOut == nil {
                                // A requested anonymized burn must never fall back to the source files.
                                let anonymizationError = anonymizationError
                                onMainActor {
                                    self.isSettingUpBurn = false
                                    self.buttonsDisabled = false
                                    self.runBurnAnimation = false
                                    self.burning = false
                                    if !(anonymizationError?.domain == NSCocoaErrorDomain && anonymizationError?.code == NSUserCancelledError) {
                                        AnonymizationErrorPresenter.present(error: anonymizationError)
                                    }
                                }
                                return
                            }

                            files = anonOut!.allValues as NSArray
                            // The window keeps its own copy.
                            nonisolated(unsafe) let anonymizedFiles = files.mutableCopy() as? NSMutableArray
                            onMainActor { self.anonymizedFiles = anonymizedFiles }
                        }

                        self.prepareContent(job, files: files, dbObjects: dbObjects, originalDbObjects: originalDbObjects)

                        onMainActor {
                            self.isSettingUpBurn = false
                            self.burning = true
                        }

                        var failed = false
                        var burnFailure: String?

                        if FileManager.default.fileExists(atPath: job.folder) && self.cancelled == false {
                            if files.count != 0 {
                                switch job.destination {
                                case Int(DMGFile.rawValue):
                                    let result = BurnerWindowController.makeDiskImage(job.writeDMGPath, from: job.folder)
                                    if result.written == false {
                                        failed = true
                                        burnFailure = result.failure
                                    }

                                case Int(CDDVD.rawValue):
                                    // Disc Recording's panels, on the main thread once the state above is
                                    // published; outside the main queue block, as they are modal.
                                    onMainActor {
                                        self.performSelector(onMainThread: #selector(self.burnCD(_:)), with: nil, waitUntilDone: false)
                                    }
                                    return

                                case Int(USBKey.rawValue):
                                    let result = BurnerWindowController.copyToVolume(job.writeVolumePath, from: job.folder, name: job.name)
                                    if result.written == false {
                                        failed = true
                                        burnFailure = result.failure
                                    }

                                default:
                                    break
                                }
                            }
                        }

                        let result = (failed: failed, failure: burnFailure)
                        onMainActor {
                            self.failed = result.failed
                            self.burnFailure = result.failure

                            self.buttonsDisabled = false
                            self.runBurnAnimation = false
                            self.burning = false

                            if self.failed {
                                // A medium that was not written must not sound and look like one that
                                // was. The window stays open, so the destination can be changed and
                                // the burn tried again.
                                let message = self.burnFailure ?? NSLocalizedString("The files were not written.", comment: "")
                                DispatchQueue.main.async {
                                    let alert = NSAlert()
                                    alert.messageText = NSLocalizedString("The medium was not created", comment: "")
                                    alert.informativeText = message
                                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                                    alert.runModal()
                                }
                            } else if self.cancelled == false {
                                // Finished ! Close the window....

                                NSSound(named: "Glass.aiff")?.play()
                                self.window?.performSelector(onMainThread: #selector(NSWindow.performClose(_:)), with: self, waitUntilDone: false)
                            }
                        }
                    }
                } catch {
                    NSLog("*** exception: %@", BurnerWindowController.logged(error))
                }
            }
        }
    }

    @IBAction @objc(setAnonymizedCheck:)
    public func setAnonymizedCheck(_ sender: Any?) {
        if anonymizedCheckButton?.state == .on {
            if (nameField?.stringValue as NSString?)?.isEqual(to: defaultTitle()) == true {
                setCDTitle(String(format: "Archive-%@", BurnerWindowController.calendarDescription(Date(), "%Y%m%d")))
            }
        }
    }

    @objc(setCDTitle:)
    public func setCDTitle(_ title: String!) {
        if let title = title {
            cdName = ((title as NSString).uppercased as NSString).filenameString() as String
            nameField?.stringValue = cdName ?? ""
        }
    }

    @IBAction @objc(setCDName:)
    public func setCDName(_ sender: Any?) {
        let name = (nameField?.stringValue as NSString?)?.uppercased
        setCDTitle(name)
    }

    @objc(folderToBurn)
    public func folderToBurn() -> String! {
        return (FileManager.default.tmpDirPath() as NSString).appendingPathComponent(cdName ?? "(null)")
    }

    @objc(volumes)
    public func volumes() -> [Any]! {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsReadOnlyKey]
        let removeableMedia = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: []) ?? []
        let array = NSMutableArray()

        for mediaURL in removeableMedia {
            guard let values = try? mediaURL.resourceValues(forKeys: keys) else { continue }
            // Unmountable is distinct from ejectable. This current workspace
            // API preserves the original writing-destination eligibility.
            var isUnmountable: ObjCBool = false
            NSWorkspace.shared.getFileSystemInfo(forPath: mediaURL.path, isRemovable: nil, isWritable: nil, isUnmountable: &isUnmountable, description: nil, type: nil)
            if values.volumeIsRemovable == true && values.volumeIsReadOnly == false && isUnmountable.boolValue {
                array.add(mediaURL.path)
            }
        }

        return array as? [Any]
    }

    @objc(saveOnVolume)
    public func saveOnVolume() -> Bool {
        let result = BurnerWindowController.copyToVolume(writeVolumePath, from: folderToBurn(), name: cdName)
        if result.written == false {
            burnFailure = result.failure
        }
        return result.written
    }

    /// Erases the volume at `writeVolumePath`, copies `folder` to it, names it
    /// after `name` and ejects it, on the burn thread; `failure` says why when the
    /// files were not written.
    nonisolated private static func copyToVolume(_ writeVolumePath: String?, from folder: String, name: String?) -> (written: Bool, failure: String?) {
        NSLog("Erase volume : %@", writeVolumePath ?? "(null)")

        // The volume is emptied before the copy, so a copy that then fails leaves the
        // key both erased and empty. It used to fail in silence - the error was
        // discarded and the window closed with the success sound - so a written
        // medium could not be told from one that was not.
        let writeVolume = (writeVolumePath ?? "") as NSString
        for path in (writeVolumePath.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0) } ?? []) {
            try? FileManager.default.removeItem(atPath: writeVolume.appendingPathComponent(path))
        }

        var copyError: NSError?
        if FileManager.default.copyItem(atPath: folder, toPath: writeVolumePath ?? "", byReplacingExisting: true, error: &copyError) == false {
            NSLog("****** copy to the volume failed: %@", copyError?.localizedDescription ?? "(null)")
            return (false, String(format: NSLocalizedString("The files could not be copied to %@: %@", comment: ""), writeVolumePath ?? "(null)", copyError?.localizedDescription ?? NSLocalizedString("the copy did not finish", comment: "")))
        }

        var newName = name ?? ""

        renameVolume(writeVolumePath, to: newName)

        //Did we succeed? Basic MS-DOS FAT support only CAPITAL letters and maximum of 10 characters...
        if FileManager.default.fileExists(atPath: (writeVolume.deletingLastPathComponent as NSString).appendingPathComponent(newName)) == false {
            if (newName as NSString).length > 10 {
                newName = (newName as NSString).substring(to: 10)
            }

            renameVolume(writeVolumePath, to: (newName as NSString).uppercased)

            if FileManager.default.fileExists(atPath: (writeVolume.deletingLastPathComponent as NSString).appendingPathComponent(newName)) == false {
                newName = "DICOM"

                renameVolume(writeVolumePath, to: newName)
            }
        }

        NSWorkspace.shared.unmountAndEjectDevice(atPath: (writeVolume.deletingLastPathComponent as NSString).appendingPathComponent(newName))

        NSLog("Ejecting new DICOM Volume: %@", newName)

        return (true, nil)
    }

    // diskutil used to be waited for by polling -isRunning with no deadline, three
    // times over, on the thread doing the burn.
    @objc(renameVolumeTo:)
    public func renameVolume(to name: String!) {
        BurnerWindowController.renameVolume(writeVolumePath, to: name)
    }

    nonisolated private static func renameVolume(_ writeVolumePath: String?, to name: String?) {
        let rename = Process()
        rename.launchPath = "/usr/sbin/diskutil"
        // +arrayWithObjects: ends at the first nil.
        var arguments = ["rename"]
        if let writeVolumePath = writeVolumePath {
            arguments.append(writeVolumePath)
            if let name = name { arguments.append(name) }
        }
        rename.arguments = arguments

        var taskError: NSError?
        if HorosRunTaskUntilExit(rename, 120, &taskError) == false {
            NSLog("****** renaming the volume did not finish: %@", taskError?.localizedDescription ?? "(null)")
        }

        Thread.sleep(forTimeInterval: 1)
    }

    @objc(burnCD:)
    public func burnCD(_ object: Any?) {
        if Thread.isMainThread == false {
            NSLog("******* THIS SHOULD BE ON THE MAIN THREAD: burnCD")
        }

        sizeInMb = getSizeOfDirectory(folderToBurn()).int32Value / 1024

        let track = DRTrack(forRootFolder: BurnerWindowController.factory(DRFolder.self, "folderWithPath:", folderToBurn()))

        if let track = track, let bsp = BurnerWindowController.factory(DRBurnSetupPanel.self, "setupPanel") {

            bsp.delegate = self

            if bsp.run() == NSApplication.ModalResponse.OK.rawValue {
                let bpp = BurnerWindowController.factory(DRBurnProgressPanel.self, "progressPanel")
                bpp?.delegate = self
                bpp?.beginProgressSheet(for: bsp.burnObject(), layout: track, modalFor: window)

                return
            }
        }

        buttonsDisabled = false
        runBurnAnimation = false
        burning = false
    }

    // MARK: -

    @objc(validateMenuItem:)
    public func validateMenuItem(_ sender: Any?) -> Bool {
        if (sender as AnyObject?)?.action == #selector(NSApplication.terminate(_:)) {
            return burning == false // No quitting while a burn is going on
        }

        return true
    }

    public override func setupPanel(_ aPanel: DRSetupPanel!, deviceContainsSuitableMedia device: DRDevice!, promptString prompt: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Bool {
        return assumeMainActor((device, prompt)) { (device, prompt) in
            let status = device.status() as NSDictionary?

            // [... longLongValue] * 2UL / 1024UL, stored into an int.
            let blocksFree = ((status?.object(forKey: DRDeviceMediaInfoKey) as? NSDictionary)?.object(forKey: DRDeviceMediaBlocksFreeKey) as? NSNumber)?.int64Value ?? 0
            let freeSpace = Int32(truncatingIfNeeded: UInt(bitPattern: Int(blocksFree)) &* 2 / 1024)

            if freeSpace > 0 && sizeInMb >= freeSpace {
                prompt.pointee = String(format: NSLocalizedString("The data to burn is larger than a media size (%d MB), you need a DVD to burn this amount of data (%d MB).", comment: ""), freeSpace, sizeInMb) as NSString
                cancelled = true
                return false
            } else if freeSpace > 0 {
                prompt.pointee = String(format: NSLocalizedString("Data to burn: %d MB (Media size: %d MB), representing %2.2f %%.", comment: ""), sizeInMb, freeSpace, Double(Float(sizeInMb)) * 100.0 / Double(Float(freeSpace))) as NSString
            }

            return true
        }
    }

    public override func burnProgressPanelWillBegin(_ aNotification: Notification!) {
        MainActor.assumeIsolated {
            burnAnimationIndex = 0
            runBurnAnimation = true
        }
    }

    public override func burnProgressPanelDidFinish(_ aNotification: Notification!) {

    }

    public override func burnProgressPanel(_ theBurnPanel: DRBurnProgressPanel!, burnDidFinish burn: DRBurn!) -> Bool {
        return assumeMainActor(burn) { burn in
            let burnStatus = burn.status() as NSDictionary?
            let state = burnStatus?.object(forKey: DRStatusStateKey) as? NSString
            var succeed = false

            if state?.isEqual(to: DRStatusStateFailed) == true {
                let errorStatus = burnStatus?.object(forKey: DRErrorStatusKey) as? NSDictionary
                let errorString = errorStatus?.object(forKey: DRErrorStatusErrorStringKey) as? String

                HorosAlertPanel.runCritical(title: NSLocalizedString("Burning failed", comment: ""), message: errorString ?? "(null)", defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            } else {
                succeed = true
                sizeField?.stringValue = NSLocalizedString("Burning is finished !", comment: "")
            }

            buttonsDisabled = false
            runBurnAnimation = false
            burning = false

            if succeed {
                window?.perform(#selector(NSWindow.performClose(_:)), with: nil, afterDelay: 1)
            }

            return true
        }
    }

    @objc(windowWillClose:)
    public func windowWillClose(_ notification: Notification) {
        irisAnimationTimer?.invalidate()
        irisAnimationTimer = nil

        burnAnimationTimer?.invalidate()
        burnAnimationTimer = nil

        windowWillClose = true

        UserDefaults.standard.set(compressionMode?.selectedTag() ?? 0, forKey: "Compression Mode for Burning")

        NSLog("Burner windowWillClose")

        window?.delegate = nil

        isExtracting = false
        isSettingUpBurn = false
        burning = false
        runBurnAnimation = false

        // [self autorelease]: the reference the code that made it kept.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    @objc(windowShouldClose:)
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSLog("Burner windowShouldClose")

        if isExtracting || isSettingUpBurn || burning {
            return false
        } else {
            try? FileManager.default.removeItem(atPath: folderToBurn())
            try? FileManager.default.removeItem(atPath: (FileManager.default.tmpDirPath() as NSString).appendingPathComponent("burnAnonymized"))

            filesToBurn = nil
            files = nil
            anonymizedFiles = nil

            NSLog("Burner windowShouldClose YES")

            return true
        }
    }

    // MARK: -

    @objc(importFiles:)
    public func importFiles(_ filenames: [Any]!) {
    }

    @objc(defaultTitle)
    public func defaultTitle() -> String! {
        var title: String?

        if let files = files, files.count > 0 {
            let file = files.object(at: 0) as? String
            title = DicomFile.getDicomField("PatientsName", forFile: file)
        }

        if title == nil {
            title = "UNTITLED"
        }

        return ((title! as NSString).uppercased as NSString).filenameString() as String
    }

    @objc(setup:)
    public func setup(_ sender: Any?) {
        autoreleasepool {
            runBurnAnimation = false
            burnButton?.isEnabled = false
            isExtracting = true

            performSelector(onMainThread: #selector(estimateFolderSize(_:)), with: nil, waitUntilDone: true)
            isExtracting = false

            let irisTimer = Timer(timeInterval: 0.07, target: self, selector: #selector(irisAnimation(_:)), userInfo: nil, repeats: true)
            irisAnimationTimer = irisTimer
            RunLoop.current.add(irisTimer, forMode: .modalPanel)
            RunLoop.current.add(irisTimer, forMode: .default)

            let burnTimer = Timer(timeInterval: 0.07, target: self, selector: #selector(burnAnimation(_:)), userInfo: nil, repeats: true)
            burnAnimationTimer = burnTimer

            RunLoop.current.add(burnTimer, forMode: .modalPanel)
            RunLoop.current.add(burnTimer, forMode: .default)

            burnButton?.isEnabled = true

            var title: String?

            if _multiplePatients || UserDefaults.standard.bool(forKey: "anonymizedBeforeBurning") {
                title = String(format: "Archive-%@", BurnerWindowController.calendarDescription(Date(), "%Y%m%d"))
            } else {
                title = (defaultTitle() as NSString).uppercased
            }

            setCDTitle(title)
        }
    }

    // MARK: -

    @objc(addDICOMDIRUsingDCMTK_forFilesAtPaths:dicomImages:)
    func addDICOMDIRUsingDCMTK_forFiles(atPaths paths: [Any]!, dicomImages dimages: [Any]!) {
        DicomDir.createDicomDir(atDir: folderToBurn())
    }

    @objc(produceHtml:dicomObjects:)
    nonisolated func produceHtml(_ burnFolder: String!, dicomObjects originalDbObjects: NSMutableArray!) {
        //We want to create html only for the images, not for PR, and hidden DICOM SR
        let images = NSMutableArray(capacity: originalDbObjects?.count ?? 0)

        for obj in originalDbObjects ?? [] {
            let object = obj as AnyObject
            if DicomStudy.displaySeries(withSOPClassUID: object.value(forKeyPath: "series.seriesSOPClassUID") as? String, andSeriesDescription: object.value(forKeyPath: "series.name") as? String) {
                images.add(obj)
            }
        }

        // -exportQuicktimeInt:::, without the window: the class method is the one
        // made for any thread.
        BrowserController.exportQuicktime(images as? [Any], burnFolder, true, BrowserController.currentBrowser(), nil)
    }

    @objc(getSizeOfDirectory:)
    nonisolated public func getSizeOfDirectory(_ path: String!) -> NSNumber! {
        if FileManager.default.fileExists(atPath: path ?? "") == false { return NSNumber(value: 0 as Int) }

        let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) as NSDictionary?
        let fileType = attributes?.object(forKey: FileAttributeKey.type) as? NSString
        if fileType?.isEqual(to: FileAttributeType.typeSymbolicLink.rawValue) != true && fileType?.isEqual(to: FileAttributeType.typeUnknown.rawValue) != true {
            let args = ["-ks", path!]
            let fromPipe = Pipe()
            let fromDu = fromPipe.fileHandleForWriting
            let duTool = Process()

            duTool.launchPath = "/usr/bin/du"
            duTool.standardOutput = fromDu
            duTool.arguments = args

            var taskError: NSError?
            if HorosRunTaskUntilExit(duTool, 300, &taskError) == false {
                NSLog("****** du failed for %@: %@", path, taskError?.localizedDescription ?? "(null)")
            }

            // du prints "<KiB>\t<path>\n". The output used to be copied, without its length, into an
            // uninitialized 300-byte buffer and read back as a C string: the size came out as 0
            // whenever the bytes after it were not a terminator, and a long path overran the buffer.
            fromDu.closeFile()
            let duOutput = fromPipe.fileHandleForReading.readDataToEndOfFile()
            let size = NSString(data: duOutput, encoding: String.Encoding.utf8.rawValue)

            return NSNumber(value: UInt64(Swift.max(size?.longLongValue ?? 0, 0)))
        } else {
            return NSNumber(value: 0 as UInt64)
        }
    }

    @IBAction @objc(cancel:)
    public func cancel(_ sender: Any?) {
        NSApp.abortModal()
    }

    @IBAction @objc(ok:)
    public func ok(_ sender: Any?) {
        NSApp.stopModal()
    }

    @objc(cleanStringForFile:)
    nonisolated func cleanString(forFile sIn: String!) -> String! {
        var s = sIn as NSString?
        s = s?.replacingOccurrences(of: "/", with: "-") as NSString?
        s = s?.replacingOccurrences(of: ":", with: "-") as NSString?

        return s as String?
    }

    /// The medium's content from the window's current state; the burn thread
    /// prepares it from its BurnJob instead.
    @objc(prepareCDContent::)
    nonisolated public func prepareCDContent(_ dbObjects: NSMutableArray!, _ originalDbObjects: NSMutableArray!) {
        let (job, files) = onMainActorSync { () -> (BurnJob, NSArray) in
            let job = self.burnJob()
            return (job, (self.anonymizedFiles?.copy() as? NSArray) ?? job.files)
        }
        prepareContent(job, files: files, dbObjects: dbObjects, originalDbObjects: originalDbObjects)
    }

    /// Copies `files` into the job's folder, with the DICOMDIR and what the
    /// preferences add, on the burn thread. Reads the job, not the window, and
    /// shows the final size on the main thread.
    nonisolated private func prepareContent(_ job: BurnJob, files: NSArray, dbObjects: NSMutableArray?, originalDbObjects: NSMutableArray?) {
        let thread = Thread.current

        onMainActor { self.finalSizeField?.stringValue = "" }

        do {
            try HorosObjCException.perform {
                let selectedCompressionMode = job.compressionMode

                let enumerator: NSEnumerator? = files.objectEnumerator()

                let burnFolder = job.folder
                let subFolder = String(format: "%@/DICOM", burnFolder)
                let manager = FileManager.default
                var i: Int32 = 0

                //create burn Folder and dicomdir.

                if !manager.fileExists(atPath: burnFolder) {
                    try? manager.createDirectory(atPath: burnFolder, withIntermediateDirectories: true, attributes: nil)
                }
                if !manager.fileExists(atPath: subFolder) {
                    try? manager.createDirectory(atPath: subFolder, withIntermediateDirectories: true, attributes: nil)
                }

                // The bundled DICOMDIR template is absent; do not copy it.

                let newFiles = NSMutableArray()
                let compressedArray = NSMutableArray()
                let bigEndianFilesToConvert = NSMutableArray()

                while let file = enumerator?.nextObject() as? String, self.cancelled == false {
                    autoreleasepool {
                        let newPath = String(format: "%@/%05d", subFolder, i)
                        i += 1

                        try? manager.copyItem(atPath: file, toPath: newPath)

                        if DicomFile.isDICOMFile(newPath) {
                            if (DicomFile.getDicomField("TransferSyntaxUID", forFile: newPath) as NSString?)?.isEqual(to: DCM_ExplicitVRBigEndian) == true {
                                bigEndianFilesToConvert.add(newPath)
                            }

                            switch selectedCompressionMode {
                            case 0:
                                break

                            case 1:
                                compressedArray.add(newPath)

                            case 2:
                                compressedArray.add(newPath)

                            default:
                                break
                            }
                        }

                        newFiles.add(newPath)
                    }
                }

                if bigEndianFilesToConvert.count != 0 {
                    DicomDatabase.decompressDicomFiles(atPaths: bigEndianFilesToConvert as? [Any])
                }

                if newFiles.count > 0 && self.cancelled == false {
                    var copyCompressionSettings: Any?
                    var copyCompressionSettingsLowRes: Any?

                    if UserDefaults.standard.bool(forKey: "JPEGinsteadJPEG2000") && selectedCompressionMode == 1 { // Temporarily switch the prefs... ugly....
                        copyCompressionSettings = UserDefaults.standard.object(forKey: "CompressionSettings")
                        copyCompressionSettingsLowRes = UserDefaults.standard.object(forKey: "CompressionSettingsLowRes")

                        UserDefaults.standard.set([["modality": NSLocalizedString("default", comment: ""), "compression": NSNumber(value: Int32(compression_JPEG)), "quality": "0"] as NSDictionary] as NSArray, forKey: "CompressionSettings")

                        UserDefaults.standard.set([["modality": NSLocalizedString("default", comment: ""), "compression": NSNumber(value: Int32(compression_JPEG)), "quality": "0"] as NSDictionary] as NSArray, forKey: "CompressionSettingsLowRes")

                        UserDefaults.standard.synchronize()
                    }

                    do {
                        try HorosObjCException.perform {
                            switch selectedCompressionMode {
                            case 1:
                                BrowserController.currentBrowser()?.database?.processFiles(atPaths: compressedArray as? [Any], intoDirAtPath: nil, mode: Int32(Compress))

                            case 2:
                                BrowserController.currentBrowser()?.database?.processFiles(atPaths: compressedArray as? [Any], intoDirAtPath: nil, mode: Int32(Decompress))

                            default:
                                break
                            }
                        }
                    } catch {
                        NSLog("Exception while prepareCDContent compression: %@", BurnerWindowController.logged(error))
                    }

                    if let copyCompressionSettings = copyCompressionSettings, let copyCompressionSettingsLowRes = copyCompressionSettingsLowRes {
                        UserDefaults.standard.set(copyCompressionSettings, forKey: "CompressionSettings")
                        UserDefaults.standard.set(copyCompressionSettingsLowRes, forKey: "CompressionSettingsLowRes")
                        UserDefaults.standard.synchronize()
                    }

                    thread.name = NSLocalizedString("Burning...", comment: "")
                    thread.status = NSLocalizedString("Writing DICOMDIR...", comment: "")
                    DicomDir.createDicomDir(atDir: burnFolder)

                    if UserDefaults.standard.bool(forKey: "BurnWeasis") && self.cancelled == false {
                        thread.name = NSLocalizedString("Burning...", comment: "")
                        thread.status = NSLocalizedString("Adding Weasis...", comment: "")

                        let weasisPath = AppController.shared()?.weasisBasePath() as NSString?
                        for subpath in (weasisPath.flatMap { try? manager.contentsOfDirectory(atPath: $0 as String) } ?? []) {
                            try? manager.copyItem(atPath: weasisPath!.appendingPathComponent(subpath), toPath: (burnFolder as NSString).appendingPathComponent(subpath))
                        }

                        let burnWeasisPath = (burnFolder as NSString).appendingPathComponent("weasis") as NSString
                        let skips = [".DS_Store"] as NSArray
                        for case let weasisPath as NSString in (Horos.weasisCustomizationPaths() as NSArray).reverseObjectEnumerator() { // reversed to mimic the WebPortal priorities
                            let de = manager.enumerator(atPath: weasisPath as String)
                            while let subpath = de?.nextObject() as? NSString {
                                if !skips.contains(subpath.lastPathComponent) {
                                    let dest = burnWeasisPath.appendingPathComponent(subpath as String)
                                    if (de?.fileAttributes?[FileAttributeKey.type] as? NSObject)?.isEqual(FileAttributeType.typeDirectory.rawValue) == true {
                                        try? manager.createDirectory(atPath: dest, withIntermediateDirectories: true, attributes: nil)
                                    } else {
                                        if manager.fileExists(atPath: dest) {
                                            try? manager.removeItem(atPath: dest)
                                        }
                                        try? manager.copyItem(atPath: weasisPath.appendingPathComponent(subpath as String), toPath: dest)
                                    }
                                }
                            }
                        }

                        // Change Label in Autorun.inf
                        var encoding: UInt = 0
                        var autorunInf = try? NSString(contentsOfFile: (burnFolder as NSString).appendingPathComponent("Autorun.inf"), usedEncoding: &encoding)

                        if (autorunInf?.length ?? 0) != 0 {
                            autorunInf = autorunInf?.replacingOccurrences(of: "Label=Weasis", with: String(format: "Label=%@", job.name ?? "(null)")) as NSString?

                            try? manager.removeItem(atPath: (burnFolder as NSString).appendingPathComponent("Autorun.inf"))
                            try? autorunInf?.write(toFile: (burnFolder as NSString).appendingPathComponent("Autorun.inf"), atomically: true, encoding: encoding)
                        }
                    }

                    if UserDefaults.standard.bool(forKey: "BurnHtml") == true && UserDefaults.standard.bool(forKey: "anonymizedBeforeBurning") == false && self.cancelled == false {
                        thread.name = NSLocalizedString("Burning...", comment: "")
                        thread.status = NSLocalizedString("Adding HTML pages...", comment: "")
                        self.produceHtml(burnFolder, dicomObjects: originalDbObjects)
                    }

                    if ((UserDefaults.standard.string(forKey: "SupplementaryBurnPath") as NSString?)?.length ?? 0) <= 1 {
                        UserDefaults.standard.set(false, forKey: "BurnSupplementaryFolder")
                    }

                    if (UserDefaults.standard.string(forKey: "SupplementaryBurnPath").map { manager.fileExists(atPath: ($0 as NSString).expandingTildeInPath) } ?? false) == false {
                        UserDefaults.standard.set(false, forKey: "BurnSupplementaryFolder")
                    }

                    if UserDefaults.standard.bool(forKey: "BurnSupplementaryFolder") && self.cancelled == false {
                        thread.name = NSLocalizedString("Burning...", comment: "")
                        thread.status = NSLocalizedString("Adding Supplementary folder...", comment: "")
                        var supplementaryBurnPath = UserDefaults.standard.string(forKey: "SupplementaryBurnPath")
                        if supplementaryBurnPath != nil {
                            supplementaryBurnPath = (supplementaryBurnPath! as NSString).expandingTildeInPath
                            if manager.fileExists(atPath: supplementaryBurnPath!) {
                                let enumerator = manager.enumerator(atPath: supplementaryBurnPath!)
                                while let file = enumerator?.nextObject() as? String {
                                    try? manager.copyItem(atPath: String(format: "%@/%@", supplementaryBurnPath!, file), toPath: String(format: "%@/%@", burnFolder, file))
                                }
                            } else {
                                UserDefaults.standard.set(false, forKey: "BurnSupplementaryFolder")
                            }
                        }
                    }

                    if UserDefaults.standard.bool(forKey: "copyReportsToCD") == true && UserDefaults.standard.bool(forKey: "anonymizedBeforeBurning") == false && self.cancelled == false {
                        thread.name = NSLocalizedString("Burning...", comment: "")
                        thread.status = NSLocalizedString("Adding Reports...", comment: "")

                        let studies = NSMutableArray()

                        for im in dbObjects ?? [] {
                            let image = im as AnyObject
                            if image.value(forKeyPath: "series.study.reportURL") != nil {
                                if let study = image.value(forKeyPath: "series.study"), studies.contains(study) == false {
                                    studies.add(study)
                                }
                            }
                        }

                        for case let study as DicomStudy in studies {
                            let reportURL = study.value(forKey: "reportURL") as? NSString
                            let modality = self.cleanString(forFile: study.value(forKey: "modality") as? String) ?? "(null)"
                            let date = self.cleanString(forFile: BrowserController.dateTime(withSecondsFormat: study.value(forKey: "date") as? Date)) ?? "(null)"

                            if reportURL?.hasPrefix("http://") == true || reportURL?.hasPrefix("https://") == true {
                                var enc: UInt = 0
                                let urlContent = URL(string: reportURL! as String).flatMap { try? NSString(contentsOf: $0, usedEncoding: &enc) }

                                try? urlContent?.write(toFile: String(format: "%@/Report-%@ %@.%@", burnFolder, modality, date, self.cleanString(forFile: reportURL!.pathExtension) ?? "(null)"), atomically: true, encoding: enc)
                            } else {
                                // Convert to PDF

                                // A report that cannot become a PDF goes on the medium as it is.
                                var pdfPath: String?
                                do {
                                    try HorosObjCException.perform {
                                        pdfPath = study.saveReportAsPdfInTmp()
                                    }
                                } catch {
                                    let e = BurnerWindowController.exception(error)
                                    NSLog("****** report not converted to PDF for the medium, copied as it is: %@", e?.reason ?? e?.name.rawValue ?? "(null)")
                                }

                                if ((pdfPath as NSString?)?.length ?? 0) == 0 || manager.fileExists(atPath: pdfPath!) == false {
                                    if let reportURL = reportURL {
                                        try? manager.copyItem(atPath: reportURL as String, toPath: String(format: "%@/Report-%@ %@.%@", burnFolder, modality, date, self.cleanString(forFile: reportURL.pathExtension) ?? "(null)"))
                                    }
                                } else {
                                    try? manager.copyItem(atPath: pdfPath!, toPath: String(format: "%@/Report-%@ %@.pdf", burnFolder, modality, date))
                                }
                            }

                            if self.cancelled {
                                break
                            }
                        }
                    }
                }

                if UserDefaults.standard.bool(forKey: "EncryptCD") && self.cancelled == false {
                    if self.cancelled == false {
                        thread.name = NSLocalizedString("Burning...", comment: "")
                        thread.status = NSLocalizedString("Encrypting...", comment: "")

                        // ZIP method - zip test.zip /testFolder -r -e -P hello

                        BrowserController.encryptFileOrFolder(burnFolder, inZIPFile: ((burnFolder as NSString).deletingLastPathComponent as NSString).appendingPathComponent("encryptedDICOM.zip"), password: job.password)
                        onMainActor { self.password = "" }

                        try? manager.removeItem(atPath: burnFolder)
                        try? manager.createDirectory(atPath: burnFolder, withIntermediateDirectories: true, attributes: nil)

                        try? manager.moveItem(atPath: ((burnFolder as NSString).deletingLastPathComponent as NSString).appendingPathComponent("encryptedDICOM.zip"), toPath: (burnFolder as NSString).appendingPathComponent("encryptedDICOM.zip"))
                        try? (NSLocalizedString("The images are encrypted with a password in this ZIP file: first, unzip this file to read the content. Use an Unzip application to extract the files.", comment: "") as NSString).write(toFile: (burnFolder as NSString).appendingPathComponent("ReadMe.txt"), atomically: true, encoding: String.Encoding.ascii.rawValue)
                    }
                }

                thread.name = NSLocalizedString("Burning...", comment: "")
                thread.status = String(format: NSLocalizedString("Writing %3.2fMB...", comment: ""), Double(Float(self.getSizeOfDirectory(burnFolder).int64Value / 1024)))

                let finalSize = String(format: NSLocalizedString("Final files size to burn: %3.2fMB", comment: ""), Double(Float(self.getSizeOfDirectory(burnFolder).int64Value / 1024)))
                onMainActor { self.finalSizeField?.stringValue = finalSize }
            }
        } catch {
            if let e = BurnerWindowController.exception(error) {
                _N2LogExceptionImpl(e, false, "-[BurnerWindowController prepareCDContent::]")
            }
        }
    }

    @IBAction @objc(estimateFolderSize:)
    public func estimateFolderSize(_ sender: Any?) {
        var size = 0
        let manager = FileManager.default

        for file in files ?? [] {
            let fattrs = (file as? String).flatMap { try? manager.attributesOfItem(atPath: $0) } as NSDictionary?
            size += Int(truncatingIfNeeded: (fattrs?.fileSize() ?? 0) / 1024)
        }

        if UserDefaults.standard.bool(forKey: "BurnWeasis") {
            size += 17 * 1024 // About 17MB
        }

        if ((UserDefaults.standard.string(forKey: "SupplementaryBurnPath") as NSString?)?.length ?? 0) <= 1 {
            UserDefaults.standard.set(false, forKey: "BurnSupplementaryFolder")
        }

        if (UserDefaults.standard.string(forKey: "SupplementaryBurnPath").map { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) } ?? false) == false {
            UserDefaults.standard.set(false, forKey: "BurnSupplementaryFolder")
        }

        if UserDefaults.standard.bool(forKey: "BurnSupplementaryFolder") {
            size += Int(getSizeOfDirectory(UserDefaults.standard.string(forKey: "SupplementaryBurnPath")).int64Value)
        }

        sizeField?.stringValue = String(format: "%@ %d  %@ %3.2fMB", NSLocalizedString("No of files:", comment: ""), Int32(truncatingIfNeeded: files?.count ?? 0), NSLocalizedString("Files size (without compression):", comment: ""), Double(size) / 1024.0)
    }

    // MARK: -

    @objc(burnAnimation:)
    func burnAnimation(_ timer: Timer!) {
        if windowWillClose {
            return
        }

        if runBurnAnimation == false {
            return
        }

        if burnAnimationIndex > 11 {
            burnAnimationIndex = 0
        }

        let animation = String(format: "burn_anim%02d.tif", burnAnimationIndex)
        burnAnimationIndex += 1
        let image = NSImage(named: animation)
        burnButton?.image = image
    }

    @objc(irisAnimation:)
    public func irisAnimation(_ timer: Timer!) {
        if runBurnAnimation {
            return
        }

        if irisAnimationIndex > 17 {
            irisAnimationIndex = 0
        }

        let animation = String(format: "burn_iris%02d.tif", irisAnimationIndex)
        irisAnimationIndex += 1
        let image = NSImage(named: animation)
        burnButton?.image = image
    }

    // MARK: - Helpers

    /// +[DRFolder folderWithPath:], +[DRBurnSetupPanel setupPanel] and
    /// +[DRBurnProgressPanel progressPanel], as the former class called them: Swift
    /// imports them as initializers, which it compiles to +alloc and -init... instead.
    private static func factory<Object: NSObject>(_ objectClass: Object.Type, _ factory: String, _ argument: Any? = nil) -> Object? {
        let selector = NSSelectorFromString(factory)
        let result = argument == nil ? (objectClass as AnyObject).perform(selector) : (objectClass as AnyObject).perform(selector, with: argument)
        return result?.takeUnretainedValue() as? Object
    }

    /// The NSException an @catch received.
    nonisolated private static func exception(_ error: Error) -> NSException? {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }

    /// What NSLog(@"%@", exception) printed of the NSException an @catch received.
    nonisolated private static func logged(_ error: Error) -> NSObject {
        return exception(error) ?? (error as NSError)
    }

    /// -[NSDate descriptionWithCalendarFormat:timeZone:nil locale:nil], which Swift
    /// cannot call.
    private static func calendarDescription(_ date: Date, _ format: String) -> String {
        return HorosDateString(date, format) ?? "(null)"
    }
}
