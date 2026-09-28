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
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork
//
//  ICloudDriveDetector.m
//  Horos
//
//  Created by Fauze Polpeta on 30/01/18.
//  Copyright © 2018 The Horos Project. All rights reserved.
//

import AppKit
import ObjectiveC

/// The database path -dontSync: moved away, which the swizzled
/// -confirmDirectoryAtPath: below refuses to create again while Horos quits.
private var purgedDatabasePath: String? = nil

extension FileManager {
    /// Exchanged with -confirmDirectoryAtPath: by -dontSync:. After the
    /// exchange, the call to itself runs the original method. `dynamic`, so
    /// that call goes through objc_msgSend and sees the exchange.
    @objc(restricted_confirmDirectoryAtPath:)
    dynamic func restricted_confirmDirectory(atPath dirPath: String!) -> String! {
        // Only exchanged once purgedDatabasePath is set.
        if let purgedDatabasePath = purgedDatabasePath, (dirPath as NSString?)?.contains(purgedDatabasePath) == true {
            return nil
        }

        return restricted_confirmDirectory(atPath: dirPath)
    }
}

/// Warns at startup when the database is in a folder iCloud Drive syncs, and
/// can move it to a ".nosync" folder (ICloudDriveDetector.xib).
///
/// Implemented in Swift since #716: the Objective-C name, the selectors and
/// <Horos/ICloudDriveDetector.h> are those of the former class, the File's
/// Owner of ICloudDriveDetector.xib.
@objc(ICloudDriveDetector)
public final class ICloudDriveDetector: NSWindowController {

    /// `assign` in the former header: weak here, so a closed browser is not
    /// kept alive nor left dangling.
    @objc public weak var browserController: BrowserController?

    @objc(databasePath)
    class func databasePath() -> String! {
        return DicomDatabase.activeLocal()?.baseDirPath
    }

    @objc(isICloudDriveEnabled)
    class func isICloudDriveEnabled() -> Bool {
        let mobileDocumentsPath = "\(NSHomeDirectory())/Library/Mobile Documents/com~apple~CloudDocs/Documents"
        if FileManager.default.fileExists(atPath: mobileDocumentsPath) {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: mobileDocumentsPath),
               (attributes[.type] as? String) == FileAttributeType.typeSymbolicLink.rawValue {
                return true
            }
        }

        return false
    }

    @objc(hasNoSyncDeployed:)
    class func hasNoSyncDeployed(_ databasePath: String!) -> Bool {
        return (databasePath as NSString?)?.contains(".nosync/") ?? false
    }

    @objc(isDatabaseLocatedInICloudDrive:)
    class func isDatabaseLocatedInICloudDrive(_ databasePath: String!) -> Bool {
        var paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let docFolder = paths[0]
        paths = NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true)
        let desktopFolder = paths[0]

        if let databasePath = databasePath as NSString?,
           databasePath.hasPrefix(docFolder) || databasePath.hasPrefix(desktopFolder) {
            return true
        }

        return false
    }

    @objc(hasUserIgnoredICloudDriveSyncRisk)
    class func hasUserIgnoredICloudDriveSyncRisk() -> Bool {
        let flag = UserDefaults.standard.object(forKey: "ICLOUD_DRIVE_SYNC_RISK_USER_IGNORED")

        // -integerValue of the stored object, a number or a string.
        if let flag = flag, ((flag as? NSNumber)?.intValue ?? (flag as? NSString)?.integerValue ?? 0) != 0 {
            return true
        }

        return false
    }

    @objc(requiresUserNotificationOnICloudDrive)
    class func requiresUserNotificationOnICloudDrive() -> Bool {
        let databasePath: String = ICloudDriveDetector.databasePath()

        if !ICloudDriveDetector.hasUserIgnoredICloudDriveSyncRisk() {
            if ICloudDriveDetector.isDatabaseLocatedInICloudDrive(databasePath) {
                if !ICloudDriveDetector.hasNoSyncDeployed(databasePath) {
                    if ICloudDriveDetector.isICloudDriveEnabled() {
                        return true
                    }
                }
            }
        }

        return false
    }

    @objc(performStartupICloudDriveTasks:)
    public class func performStartupICloudDriveTasks(_ browserController: BrowserController!) {
        if ICloudDriveDetector.requiresUserNotificationOnICloudDrive() {
            //Launch the assistant
            let detector = ICloudDriveDetector(windowNibName: "ICloudDriveDetector")

            // The detector keeps itself until its window closes: the former
            // code did not release it, and -windowWillClose: autoreleases it.
            _ = Unmanaged.passRetained(detector)

            detector.browserController = browserController

            if NSApp.isHidden {
                detector.window?.makeKeyAndOrderFront(self)
            } else {
                NSApp.runModal(for: detector.window!)
            }
            return
        }

        let databasePath = ICloudDriveDetector.databasePath()
        let shouldWarn = NSSelectorFromString("shouldWarnAboutActiveDatabaseAtPath:")
        let present = NSSelectorFromString("presentActiveDatabaseWarningForPath:")
        // Class methods, sent as the former objc_msgSend casts did.
        if let cloud: AnyClass = NSClassFromString("HorosCloudFileAccess"),
           let metaclass: AnyClass = object_getClass(cloud),
           class_respondsToSelector(metaclass, shouldWarn) && class_respondsToSelector(metaclass, present) {
            typealias WarnImp = @convention(c) (AnyObject, Selector, NSString?) -> Bool
            typealias PresentImp = @convention(c) (AnyObject, Selector, NSString?) -> Void
            let warnImp = unsafeBitCast(class_getMethodImplementation(metaclass, shouldWarn), to: WarnImp.self)
            if warnImp(cloud, shouldWarn, databasePath as NSString?) {
                let presentImp = unsafeBitCast(class_getMethodImplementation(metaclass, present), to: PresentImp.self)
                presentImp(cloud, present, databasePath as NSString?)
            }
        }
    }

    /*-----------------------------------------------------
     * Instance methods
     ------------------------------------------------------*/

    public override func windowDidLoad() {
        super.windowDidLoad()
        // Implement this method to handle any initialization after your window controller's window has been loaded from its nib file.
    }

    public override func awakeFromNib() {
        let browserControllerWindow = self.browserController?.window
        let browserFrame = browserControllerWindow?.frame ?? .zero

        let xPos = browserFrame.origin.x + browserFrame.size.width / 2 - (self.window?.frame.size.width ?? 0) / 2
        let yPos = browserFrame.origin.y + browserFrame.size.height / 2 - (self.window?.frame.size.height ?? 0) / 2
        self.window?.makeKeyAndOrderFront(self)
        self.window?.setFrame(NSMakeRect(xPos, yPos, NSWidth(self.window?.frame ?? .zero),
                                         NSHeight(self.window?.frame ?? .zero)), display: true)
    }

    @objc(windowWillClose:)
    public func windowWillClose(_ notification: Notification) {
        if NSApp.isHidden {
            self.window?.orderOut(self)
        } else {
            NSApp.stopModal()
        }

        _ = Unmanaged.passUnretained(self).autorelease()
    }

    @IBAction @objc(askLater:)
    public func askLater(_ sender: Any!) {
        self.window?.close()
    }

    /// Relaunches Horos with this process's pid as its argument, and quits.
    private func relaunch() {
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        let myPath = String(format: "%s", (Bundle.main.executablePath! as NSString).fileSystemRepresentation)
        _ = Process.launchedProcess(launchPath: myPath, arguments: [String(format: "%d", processIdentifier)])

        NSApp.terminate(self)
    }

    @IBAction @objc(dontSync:)
    public func dontSync(_ sender: Any!) {
        let databasePath: String = ICloudDriveDetector.databasePath()

        var nosyncPath = "\(databasePath).nosync"

        while FileManager.default.fileExists(atPath: nosyncPath) {
            // Convert date object to desired output format
            let dateFormat = DateFormatter()
            dateFormat.dateFormat = "yyyyMMddhhmmss"
            let date = Date()
            let timestamp = dateFormat.string(from: date)

            nosyncPath = "\(databasePath)_\(timestamp).nosync"
        }

        //ALERT user about the operation - Missing localization
        let alert = NSAlert()
        alert.messageText = "Please, confirm you want to stop using iCloud Drive for your Horos database."
        alert.informativeText = "Your Horos database and image files will be moved from \"\(databasePath)\" to \"\(nosyncPath)\". Horos will be restarted after this operation is concluded."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        alert.beginSheetModal(for: self.window!) { returnCode in
            if returnCode == .alertSecondButtonReturn {
                NSLog("ICloudDriveDetector - User canceled database migration")
                return
            }

            NSApp.endSheet(alert.window)

            DispatchQueue.main.async {
                // A message to a nil browser answered NO, and aborted too.
                if (BrowserController.currentBrowser()?.shouldTerminate(nil) ?? false) == false {
                    HorosAlertPanel.runInformational(title: NSLocalizedString("Abort", comment: ""),
                                                     message: NSLocalizedString("Operation was aborted because there are background tasks executing.", comment: ""),
                                                     defaultButton: NSLocalizedString("Return", comment: ""), alternateButton: nil, otherButton: nil)

                    return
                }

                var error: Error? = nil
                do {
                    try FileManager.default.createDirectory(atPath: nosyncPath, withIntermediateDirectories: true, attributes: nil)
                } catch let e {
                    error = e
                }
                if error != nil {
                    HorosAlertPanel.runInformational(title: NSLocalizedString("Failure", comment: ""),
                                                     message: NSLocalizedString("Operation has failed. Horos will restart and try to restore your database.", comment: ""),
                                                     defaultButton: NSLocalizedString("Restart", comment: ""), alternateButton: nil, otherButton: nil)

                    self.window?.orderOut(self)
                    NSApp.stopModal()

                    self.relaunch()

                    return
                }

                let newDatabasePath = "\(nosyncPath)/\((databasePath as NSString).lastPathComponent)"

                error = nil
                do {
                    try FileManager.default.moveItem(atPath: databasePath, toPath: newDatabasePath)
                } catch let e {
                    error = e
                }
                if error != nil {
                    try? FileManager.default.removeItem(atPath: newDatabasePath)

                    HorosAlertPanel.runInformational(title: NSLocalizedString("Failure", comment: ""),
                                                     message: NSLocalizedString("Operation has failed. Horos will restart and try to restore your database.", comment: ""),
                                                     defaultButton: NSLocalizedString("Restart", comment: ""), alternateButton: nil, otherButton: nil)

                    self.window?.orderOut(self)
                    NSApp.stopModal()

                    self.relaunch()

                    return
                }

                UserDefaults.standard.set(newDatabasePath, forKey: "DEFAULT_DATABASELOCATIONURL")
                UserDefaults.standard.set(1, forKey: "DEFAULT_DATABASELOCATION")

                UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "DEFAULT_DATABASELOCATION"), forKey: "DATABASELOCATION")
                UserDefaults.standard.set(UserDefaults.standard.string(forKey: "DEFAULT_DATABASELOCATIONURL"), forKey: "DATABASELOCATIONURL")

                UserDefaults.standard.synchronize()

                // Loading this static var to be used byt tge swizzling below
                purgedDatabasePath = databasePath

                // Swizzling to avoid creation of old database path directories when terminating - (NSString*)confirmDirectoryAtPath:(NSString*)dirPath;

                let theClass: AnyClass = FileManager.self

                let originalSelector_confirmDirectoryAtPath = NSSelectorFromString("confirmDirectoryAtPath:")
                let swizzledSelector_confirmDirectoryAtPath = NSSelectorFromString("restricted_confirmDirectoryAtPath:")

                let originalMethod_confirmDirectoryAtPath = class_getInstanceMethod(theClass, originalSelector_confirmDirectoryAtPath)
                let swizzledMethod_confirmDirectoryAtPath = class_getInstanceMethod(theClass, swizzledSelector_confirmDirectoryAtPath)

                if let originalMethod_confirmDirectoryAtPath = originalMethod_confirmDirectoryAtPath,
                   let swizzledMethod_confirmDirectoryAtPath = swizzledMethod_confirmDirectoryAtPath {
                    let didAddMethod =
                        class_addMethod(theClass,
                                        originalSelector_confirmDirectoryAtPath,
                                        method_getImplementation(swizzledMethod_confirmDirectoryAtPath),
                                        method_getTypeEncoding(swizzledMethod_confirmDirectoryAtPath))

                    if didAddMethod {
                        class_replaceMethod(theClass,
                                            swizzledSelector_confirmDirectoryAtPath,
                                            method_getImplementation(originalMethod_confirmDirectoryAtPath),
                                            method_getTypeEncoding(originalMethod_confirmDirectoryAtPath))
                    } else {
                        method_exchangeImplementations(originalMethod_confirmDirectoryAtPath, swizzledMethod_confirmDirectoryAtPath)
                    }
                }

                self.window?.orderOut(self)
                NSApp.stopModal()

                self.relaunch()
            }
        }
    }

    @IBAction @objc(keepSync:)
    public func keepSync(_ sender: Any!) {
        UserDefaults.standard.set(NSNumber(value: 1), forKey: "ICLOUD_DRIVE_SYNC_RISK_USER_IGNORED")
        UserDefaults.standard.synchronize()

        self.window?.close()
    }
}
