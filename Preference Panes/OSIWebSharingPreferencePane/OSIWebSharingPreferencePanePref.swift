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

import Cocoa
import PreferencePanes
import SecurityInterface

/// The former `[x integerValue]` on a bound value: NSNumber and NSString
/// answer it, nil gives 0.
private func integerValue(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? NSString { return string.integerValue }
    return 0
}

/// The former `[sender tag]`: 0 for nil.
@MainActor private func tag(of sender: Any?) -> Int {
    if let view = sender as? NSView { return view.tag }
    if let item = sender as? NSMenuItem { return item.tag }
    if let cell = sender as? NSCell { return cell.tag }
    return 0
}

/// Shows seconds as minutes: named by the xib (NSValueTransformerName).
@objc(SecondsToMinutesTransformer)
public final class SecondsToMinutesTransformer: ValueTransformer {
    public override class func allowsReverseTransformation() -> Bool {
        return true
    }

    public override class func transformedValueClass() -> AnyClass {
        return NSNumber.self
    }

    public override func transformedValue(_ number: Any?) -> Any? {
        return NSNumber(value: Int32(truncatingIfNeeded: integerValue(number) / 60))
    }

    public override func reverseTransformedValue(_ number: Any?) -> Any? {
        return NSNumber(value: Int32(truncatingIfNeeded: integerValue(number) * 60))
    }
}

/// The Web Server preference pane.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors,
/// the xib outlets and bindings and
/// <Horos/OSIWebSharingPreferencePanePref.h> are those of the former class.
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSIWebSharingPreferencePanePref)
public final class OSIWebSharingPreferencePanePref: NSPreferencePane {
    @IBOutlet var studiesArrayController: NSArrayController?
    @IBOutlet var userArrayController: NSArrayController?

    @IBOutlet var TLSChooseCertificateButton: NSButton?
    @IBOutlet var TLSCertificateButton: NSButton?

    @IBOutlet var addressTextField: NSTextField?
    @IBOutlet var portTextField: NSTextField?

    /// Retained by the former class on top of the nib's reference.
    @IBOutlet var usersPanel: NSPanel?

    @IBOutlet var mainWindow: NSWindow?

    @IBOutlet var usersTable: NSTableView?

    private var _tlos: NSArray?

    /// Bound by the xib (the certificate button's title). Atomic and retained
    /// in the former header.
    @objc(TLSAuthenticationCertificate)
    public dynamic var TLSAuthenticationCertificate: String?

    /// Observer of WebPortalUsernameChanged.
    @objc(usernameChanged:)
    func usernameChanged(_ notification: Notification) {
        let user = notification.object as AnyObject?

        if user === (userArrayController?.selectedObjects as NSArray?)?.lastObject as AnyObject? {
            HorosAlertPanel.runInformational(title: NSLocalizedString("User's name", comment: ""),
                                             message: String(format: NSLocalizedString("User's name changed. The password has been reset to a new password: %@", comment: ""), objectDescription((user as? WebPortalUser)?.password)),
                                             defaultButton: NSLocalizedString("OK", comment: ""),
                                             alternateButton: nil,
                                             otherButton: nil)
        }
    }

    /// -init, which the former class inherited from NSObject: a pane without
    /// its nib, as before.
    public override init() {
        super.init()
    }

    @objc(initWithBundle:)
    public override init(bundle: Bundle) {
        // The former -initWithBundle: called -[super init]: the pane keeps no bundle.
        super.init()
        assumeMainActor(self) { $0.finishInitOnMainActor() }
    }

    private func finishInitOnMainActor() {
        let nib = NSNib(nibNamed: "OSIWebSharingPreferencePanePref", bundle: nil)
        nib?.instantiate(withOwner: self, topLevelObjects: &_tlos)

        if let contentView = mainWindow?.contentView {
            self.mainView = contentView
        }
        self.mainViewDidLoad()

        NotificationCenter.default.addObserver(self, selector: #selector(usernameChanged(_:)), name: NSNotification.Name("WebPortalUsernameChanged"), object: nil)
    }

    public override func awakeFromNib() {
        assumeMainActor(self) { $0.awakeFromNibOnMainActor() }
    }

    private func awakeFromNibOnMainActor() {
        (addressTextField?.cell as? NSTextFieldCell)?.placeholderString = UserDefaults.defaultWebPortalAddress()
        (portTextField?.cell as? NSTextFieldCell)?.placeholderString = NSNumber(value: UserDefaults.webPortalPortNumber()).stringValue

        usersTable?.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))]
    }

    @objc(UniqueLabelForSelectedServer)
    func UniqueLabelForSelectedServer() -> String {
        return "org.horosproject.horoswebserver"
    }

    @objc(getTLSCertificate)
    func getTLSCertificate() {
        let label = self.UniqueLabelForSelectedServer()
        var name = DDKeychain.certificateName(forLabel: label)
        let icon = DDKeychain.certificateIcon(forLabel: label)

        if name == nil {
            name = NSLocalizedString("No certificate selected.", comment: "No certificate selected.")
            TLSCertificateButton?.isHidden = true
            TLSChooseCertificateButton?.title = NSLocalizedString("Choose", comment: "Choose")
        } else {
            TLSCertificateButton?.isHidden = false
            TLSCertificateButton?.image = icon
            TLSChooseCertificateButton?.title = NSLocalizedString("Change", comment: "Change")
        }

        self.TLSAuthenticationCertificate = name
    }

    @objc(chooseTLSCertificate:)
    @IBAction public func chooseTLSCertificate(_ sender: Any?) {
        let certificates = (DDKeychain.keychainAccessCertificatesList() ?? []) as [Any]

        if certificates.count > 0 {
            SFChooseIdentityPanel.shared().setAlternateButtonTitle(NSLocalizedString("Cancel", comment: "Cancel"))
            let clickedButton = SFChooseIdentityPanel.shared().runModal(forIdentities: certificates, message: NSLocalizedString("Choose a certificate from the following list.", comment: "Choose a certificate from the following list."))

            if clickedButton == NSApplication.ModalResponse.OK.rawValue {
                if let identity = SFChooseIdentityPanel.shared().identity() {
                    DDKeychain.keychainAccessSetPreferredIdentity(identity.takeUnretainedValue(), forName: self.UniqueLabelForSelectedServer(), keyUse: Int32(bitPattern: UInt32(CSSM_KEYUSE_ANY)))
                    self.getTLSCertificate()
                }
            } else if clickedButton == NSApplication.ModalResponse.cancel.rawValue {
                return
            }
        } else {
            let clickedButton = HorosAlertPanel.runCritical(title: NSLocalizedString("No Valid Certificate", comment: ""),
                                                            message: NSLocalizedString("Your Keychain does not contain any valid certificate.", comment: ""),
                                                            defaultButton: NSLocalizedString("Help", comment: ""),
                                                            alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                            otherButton: nil)

            if clickedButton == NSApplication.ModalResponse.OK.rawValue {
                if let url = URL(string: URL_HOROS_DOC_SECURITY) {
                    NSWorkspace.shared.open(url)
                }
            }

            return
        }
    }

    @objc(viewTLSCertificate:)
    @IBAction public func viewTLSCertificate(_ sender: Any?) {
        let label = self.UniqueLabelForSelectedServer()
        DDKeychain.openCertificatePanel(forLabel: label)
    }

    /// Bound by the xib (the users' array controller).
    @objc(managedObjectContext)
    public var managedObjectContext: NSManagedObjectContext? {
        return WebPortal.default()?.database?.managedObjectContext
    }

//  - (void) enableControls: (BOOL) val
//  {
//  ///	[[NSUserDefaults standardUserDefaults] setBool: val forKey: @"authorizedToEdit"];
//  }

    isolated deinit {
        NSLog("dealloc OSIWebSharingPreferencePanePref")

        studiesArrayController?.removeObserver(self, forKeyPath: "selection")

        usersPanel = nil

        _tlos = nil
    }

    public override func mainViewDidLoad() {
        assumeMainActor(self) { $0.mainViewDidLoadOnMainActor() }
    }

    private func mainViewDidLoadOnMainActor() {
        studiesArrayController?.addObserver(self, forKeyPath: "selection", options: [.new], context: nil)

        self.getTLSCertificate()
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // Off the main thread it did nothing, and still does not.
        guard Thread.isMainThread, keyPath == "selection" else { return }
        assumeMainActor(self) { $0.selectionDidChange() }
    }

    private func selectionDidChange() {
        let study = (studiesArrayController?.selectedObjects as NSArray?)?.lastObject as? DicomStudy
        // Automatically display the selected study in the main DB window
        if let study = study {
            _ = BrowserController.currentBrowser()?.display(study, object: study, command: "Select")
        }
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        self.mainView.window?.makeFirstResponder(nil)

        _ = WebPortal.default()?.database?.save()

        BrowserController.currentBrowser()?.testPredicate = nil
        BrowserController.currentBrowser()?.outlineViewRefresh()

        NotificationCenter.default.removeObserver(self)
    }

    @objc(smartAlbumHelpButton:)
    @IBAction public func smartAlbumHelpButton(_ sender: Any?) {
        if tag(of: sender) == 0 {
            try? FileManager.default.removeItem(atPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("OsiriXTables.pdf"))
            if let source = Bundle.main.path(forResource: "OsiriXTables", ofType: "pdf") {
                try? FileManager.default.copyItem(atPath: source, toPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("OsiriXTables.pdf"))
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("OsiriXTables.pdf")))
        }

        if tag(of: sender) == 1 {
            if let url = URL(string: "http://developer.apple.com/documentation/Cocoa/Conceptual/Predicates/Articles/pSyntax.html#//apple_ref/doc/uid/TP40001795") {
                NSWorkspace.shared.open(url)
            }
        }

        if tag(of: sender) == 2 {
            self.mainView.window?.makeFirstResponder(nil)

            do {
                try HorosObjCException.perform {
                    let filter = ((self.userArrayController?.selectedObjects as NSArray?)?.lastObject as? NSObject)?.value(forKey: "studyPredicate") as? String
                    BrowserController.currentBrowser()?.testPredicate = DicomDatabase.predicate(forSmartAlbumFilter: filter)
                    BrowserController.currentBrowser()?.outlineViewRefresh()
                    BrowserController.currentBrowser()?.testPredicate = nil
                    HorosAlertPanel.runInformational(title: NSLocalizedString("Study Filter", comment: ""),
                                                     message: NSLocalizedString("The result is now displayed in the Database Window.", comment: ""),
                                                     defaultButton: NSLocalizedString("OK", comment: ""),
                                                     alternateButton: nil,
                                                     otherButton: nil)
                }
            } catch {
                let e = (error as NSError).userInfo[HorosObjCExceptionKey]
                HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                            message: String(format: NSLocalizedString("This filter is NOT working: %@", comment: ""), objectDescription(e)),
                                            defaultButton: NSLocalizedString("OK", comment: ""),
                                            alternateButton: nil,
                                            otherButton: nil)
            }
        }
    }

    @objc(openKeyChainAccess:)
    @IBAction public func openKeyChainAccess(_ sender: Any?) {
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess")

        if let path = path {
            NSWorkspace.shared.openApplication(at: path, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { NSLog("Unable to open Keychain Access: %@", error.localizedDescription) }
            }
        }
    }

    @objc(copyMissingCustomizedFiles:)
    @IBAction public func copyMissingCustomizedFiles(_ sender: Any?) {
        let source = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("WebServicesHTML")
        #if MACAPPSTORE
        FileManager.default.copyItem(atPath: source, toPath: ("~/Library/Application Support/Horos App/WebServicesHTML" as NSString).expandingTildeInPath, byReplacingExisting: false, error: nil)
        #else
        FileManager.default.copyItem(atPath: source, toPath: ("~/Library/Application Support/Horos/WebServicesHTML" as NSString).expandingTildeInPath, byReplacingExisting: false, error: nil)
        #endif
    }

    @objc(editUsers:)
    @IBAction public func editUsers(_ sender: Any?) {
        guard let usersPanel = usersPanel, let window = self.mainView.window else { return }
        window.beginSheet(usersPanel) { response in
            self.editUsersSheetDidEnd(usersPanel, returnCode: response.rawValue, contextInfo: nil)
        }
    }

    @objc(exitEditUsers:)
    @IBAction public func exitEditUsers(_ sender: Any?) {
        usersPanel?.makeFirstResponder(nil)
        if let usersPanel = usersPanel {
            usersPanel.sheetParent?.endSheet(usersPanel)
        }
    }

    @objc(editUsersSheetDidEnd:returnCode:contextInfo:)
    func editUsersSheetDidEnd(_ sheet: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        sheet.orderOut(nil)

        try? self.managedObjectContext?.save()
    }
}

/// What the former `%@` printed for `value`: its description, "(null)" for nil.
private func objectDescription(_ value: Any?) -> String {
    guard let value = value else { return "(null)" }
    return String(format: "%@", value as AnyObject as! CVarArg)
}
