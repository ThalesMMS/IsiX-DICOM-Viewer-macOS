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

import Cocoa

/// Offers, at startup, to import the database of an OsiriX installation
/// (~/Documents/OsiriX Data/DATABASE.noindex), and remembers the answer in
/// O2H_MIGRATION_USER_ACTION.
///
/// Implemented in Swift: the Objective-C name, the selectors
/// and <Horos/O2HMigrationAssistant.h> are those of the former class.
@objc(O2HMigrationAssistant)
public final class O2HMigrationAssistant: NSWindowController {

    // The values stored in O2H_MIGRATION_USER_ACTION, as NSNumber integers.
    private static let migrationDenied = 1
    private static let migrationPostponed = 2
    private static let migrationAccepted = 3

    private static let userActionKey = "O2H_MIGRATION_USER_ACTION"

    /// `assign` in the former header. The browser outlives the assistant, which
    /// it opens and whose window is modal; weak rather than unowned(unsafe), so
    /// a browser gone meanwhile reads as nil, as a message to nil did.
    @objc public weak var browserController: BrowserController!

    private static var osirixDatabasePath: String {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true) as NSArray
        return String(format: "%@/OsiriX Data/DATABASE.noindex", paths.object(at: 0) as! NSString)
    }

    @objc public class func isOsiriXInstalled() -> Bool {
        let osirixPath = osirixDatabasePath

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: osirixPath, isDirectory: &isDirectory) && isDirectory.boolValue {
            return true
        }

        return false
    }

    @objc(performStartupO2HTasks:)
    public class func performStartupO2HTasks(_ browserController: BrowserController!) {
        //Check if user already said NO or YES before
        let o2hMigrationUserAction = UserDefaults.standard.object(forKey: userActionKey) as? NSNumber

        if let action = o2hMigrationUserAction, action.intValue == migrationDenied {
            return
        }

        if let action = o2hMigrationUserAction, action.intValue == migrationAccepted {
            return
        }

        //Open Assistant if OsiriX is installed
        if O2HMigrationAssistant.isOsiriXInstalled() {
            //Launch the assistant
            let migrationAssistant = O2HMigrationAssistant(windowNibName: "O2HMigrationAssistant")
            migrationAssistant.browserController = browserController

            // The former code kept the reference from +alloc until
            // -windowWillClose: autoreleased it; this retain is that one.
            _ = Unmanaged.passRetained(migrationAssistant)

            if NSApp.isHidden {
                migrationAssistant.window?.makeKeyAndOrderFront(self)
            } else if let window = migrationAssistant.window {
                NSApp.runModal(for: window)
            }
        }
    }

    public override func windowDidLoad() {
        super.windowDidLoad()

        // Implement this method to handle any initialization after your window controller's window has been loaded from its nib file.
    }

    // The former -awakeFromNib did not call super either (NSObject's does nothing).
    public override func awakeFromNib() {
        MainActor.assumeIsolated {
            let browserControllerWindow = browserController?.window
            let browserFrame = browserControllerWindow?.frame ?? .zero
            let frame = window?.frame ?? .zero

            let xPos = browserFrame.origin.x + browserFrame.size.width / 2 - frame.size.width / 2
            let yPos = browserFrame.origin.y + browserFrame.size.height / 2 - frame.size.height / 2
            window?.makeKeyAndOrderFront(self)
            window?.setFrame(NSMakeRect(xPos, yPos, NSWidth(window?.frame ?? .zero),
                                        NSHeight(window?.frame ?? .zero)), display: true)
        }
    }

    /// The window's delegate, connected in the nib.
    @objc(windowWillClose:)
    public func windowWillClose(_ notification: Notification!) {
        let defaults = UserDefaults.standard
        let o2hMigrationUserAction = defaults.object(forKey: O2HMigrationAssistant.userActionKey)

        if o2hMigrationUserAction == nil {
            defaults.set(NSNumber(value: O2HMigrationAssistant.migrationPostponed), forKey: O2HMigrationAssistant.userActionKey)
            defaults.synchronize()
        }

        if NSApp.isHidden {
            window?.orderOut(self)
        } else {
            NSApp.stopModal()
        }

        // The former [self autorelease]: balances the retain taken in
        // +performStartupO2HTasks:, once the current autorelease pool drains.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    @IBAction @objc(doNotMigrateFromOsiriX:)
    public func doNotMigrateFromOsiriX(_ sender: Any!) {
        UserDefaults.standard.set(NSNumber(value: O2HMigrationAssistant.migrationDenied), forKey: O2HMigrationAssistant.userActionKey)
        UserDefaults.standard.synchronize()

        window?.close()
    }

    @IBAction @objc(askMeLaterToMigrateFromOsiriX:)
    public func askMeLaterToMigrateFromOsiriX(_ sender: Any!) {
        UserDefaults.standard.set(NSNumber(value: O2HMigrationAssistant.migrationPostponed), forKey: O2HMigrationAssistant.userActionKey)
        UserDefaults.standard.synchronize()

        window?.close()
    }

    @IBAction @objc(doMigrationFromOsiriX:)
    public func doMigrationFromOsiriX(_ sender: Any!) {
        UserDefaults.standard.set(NSNumber(value: O2HMigrationAssistant.migrationAccepted), forKey: O2HMigrationAssistant.userActionKey)
        UserDefaults.standard.synchronize()

        DispatchQueue.main.async {
            let osirixPath = O2HMigrationAssistant.osirixDatabasePath

            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: osirixPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                let defaults = UserDefaults.standard
                let COPYDATABASE = defaults.bool(forKey: "COPYDATABASE")
                let COPYDATABASEMODE = Int32(truncatingIfNeeded: defaults.integer(forKey: "COPYDATABASEMODE")) // an int before

                defaults.set(NSNumber(value: true), forKey: "COPYDATABASE")
                defaults.set(NSNumber(value: always), forKey: "COPYDATABASEMODE") // AppController.h: always = 0
                defaults.synchronize()

                self.browserController?.subSelectFilesAndFolders(toAdd: [osirixPath])

                defaults.set(NSNumber(value: COPYDATABASE), forKey: "COPYDATABASE")
                defaults.set(NSNumber(value: Int(COPYDATABASEMODE)), forKey: "COPYDATABASEMODE")
                defaults.synchronize()
            }

            self.window?.close()
        }
    }
}
