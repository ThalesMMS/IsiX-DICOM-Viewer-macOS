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
import Darwin
import PreferencePanes
import SecurityInterface

//char *GetPrivateIP()
//{
//	struct			hostent *h;
//	char			hostname[100];
//	gethostname(hostname, 99);
//	if ((h=gethostbyname(hostname)) == NULL)
//	{
//        perror("Error: ");
//        return (char*)"(Error locating Private IP Address)";
//    }
//
//    return (char*) inet_ntoa(*((struct in_addr *)h->h_addr));
//}

/// The Listener preference pane: the DICOM listener and its TLS sheet.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors, the
/// outlets and the bindings of OSIListenerPreferencePanePref.xib are those
/// of the former class. The user defaults it reads and writes (AETITLE,
/// AEPORT, DICOMTimeout and the TLSStoreSCP* keys) keep their names and
/// stored types (#184).
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSIListenerPreferencePanePref)
public final class OSIListenerPreferencePanePref: NSPreferencePane {
    @IBOutlet var ipField: NSTextField?
    @IBOutlet var nameField: NSTextField?

    @IBOutlet var sharingNameField: NSTextField?

    @IBOutlet var preferredSyntaxPopUpButton: NSPopUpButton?

    /// Retained by the former -initWithBundle:, released in -dealloc: a strong outlet.
    @IBOutlet var TLSSettingsWindow: NSWindow?
    @objc public dynamic var TLSAuthenticationCertificate: String?
    @IBOutlet var TLSChooseCertificateButton: NSButton?
    @IBOutlet var TLSCertificateButton: NSButton?
    /// The rows of the cipher suite table: mutable dictionaries that
    /// -selectAllSuites: and -deselectAllSuites: change in place.
    @objc public dynamic var TLSSupportedCipherSuite: NSArray?
    @objc public dynamic var TLSUseDHParameterFileURL: Bool = false
    @objc public dynamic var TLSDHParameterFileURL: URL?

    @objc public dynamic var TLSCertificateVerification: TLSCertificateVerificationType = RequirePeerCertificate

    @objc public dynamic var TLSUseSameAETITLE: Bool = false
    @objc public dynamic var TLSStoreSCPAETITLE: String?
    @IBOutlet var TLSStoreSCPAETITLEIsDefaultAETButton: NSButton?
    @objc public dynamic var TLSStoreSCPAETITLEIsDefaultAET: Bool = false

    @IBOutlet var TLSAETitleTextField: NSTextField?
    @IBOutlet var TLSPortTextField: NSTextField?
    @IBOutlet var TLSPreferredSyntaxTextField: NSTextField?

    @IBOutlet var mainWindow: NSWindow?

    /// The nib's top-level objects, kept for the pane's lifetime.
    private var _tlos: NSArray?

    /// -init as the former class inherited it: a pane without its nib.
    public override init() {
        super.init()
    }

    @objc(initWithBundle:)
    public override init(bundle: Bundle) {
        // The former -initWithBundle: called [super init], not [super initWithBundle:].
        super.init()
        assumeMainActor(self) { $0.finishInitOnMainActor() }
    }

    private func finishInitOnMainActor() {
        let nib = NSNib(nibNamed: "OSIListenerPreferencePanePref", bundle: nil)
        var topLevelObjects: NSArray?
        nib?.instantiate(withOwner: self, topLevelObjects: &topLevelObjects)
        _tlos = topLevelObjects

        if let view = mainWindow?.contentView {
            self.mainView = view
        }
        self.mainViewDidLoad()
    }

    @objc(IPv4Address)
    func IPv4Address() -> NSArray {
        let r = NSMutableArray()

        for addr in DefaultsOsiriX.currentHost()?.addresses ?? [] {
            if (addr as NSString).components(separatedBy: ".").count == 4 && addr != "127.0.0.1" {
                r.add(addr)
            }
        }

        if r.count == 0 { r.add(String(format: "127.0.0.1")) }

        return r
    }

    /// The nib sends -awakeFromNib to its owner too. The former method did not call super.
    public override func awakeFromNib() {
        assumeMainActor(self) { $0.awakeFromNibOnMainActor() }
    }

    private func awakeFromNibOnMainActor() {
        (sharingNameField?.cell as? NSTextFieldCell)?.placeholderString = UserDefaults.defaultBonjourSharingName()
    }

    deinit {
        NSLog("dealloc OSIListenerPreferencePanePref")
    }

    @objc(installPortFormattersInView:)
    func installPortFormattersInView(_ view: NSView) {
        if let textField = view as? NSTextField {
            let key = textField.infoForBinding(.value)?[.observedKeyPath] as? String
            if let key, ["values.AEPORT", "values.TLSStoreSCPAEPORT", "values.httpXMLRPCServerPort"].contains(key) {
                let formatter = DICOMNodeFormatter(field: "Port")
                textField.formatter = formatter
            }
        }
        for child in view.subviews { installPortFormattersInView(child) }
    }

    public override func mainViewDidLoad() {
        assumeMainActor(self) { $0.mainViewDidLoadOnMainActor() }
    }

    private func mainViewDidLoadOnMainActor() {
        if let view = mainWindow?.contentView { installPortFormattersInView(view) }
        if let view = TLSSettingsWindow?.contentView { installPortFormattersInView(view) }
        // The XML-RPC interface answers loopback only unless the user says
        // otherwise, and saying otherwise needs a password. That does not fit the
        // remaining space in the nib, so the button beside the port field opens a
        // sheet for it. Resolved at runtime, like the port formatters above.
        if let view = mainWindow?.contentView { XMLRPCRemoteAccessPanel.install(in: view) }
        let defaults = UserDefaults.standard

        if defaults.integer(forKey: "DICOMTimeout") < 1 {
            defaults.set("1", forKey: "DICOMTimeout")
        }

        if defaults.integer(forKey: "DICOMTimeout") > 480 {
            defaults.set("480", forKey: "DICOMTimeout")
        }

        //setup GUI

//	NSString *ip = [NSString stringWithUTF8String:GetPrivateIP()];
        let ip = IPv4Address().componentsJoined(by: ", ")
        var hostname = [CChar](repeating: 0, count: Int(_POSIX_HOST_NAME_MAX) + 1)
        gethostname(&hostname, Int(_POSIX_HOST_NAME_MAX))
        let name = NSString(utf8String: hostname)

        ipField?.stringValue = ip
        setObjCStringValue(nameField, name)

        getTLSCertificate()
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        mainView.window?.makeFirstResponder(nil)

        if UserDefaults.standard.integer(forKey: "DICOMTimeout") < 1 {
            UserDefaults.standard.set("1", forKey: "DICOMTimeout")
        }

        if UserDefaults.standard.integer(forKey: "DICOMTimeout") > 480 {
            UserDefaults.standard.set("480", forKey: "DICOMTimeout")
        }
    }

    @IBAction func smartAlbumHelpButton(_ sender: Any?) {
        if objcTag(sender) == 0 {
            try? FileManager.default.removeItem(atPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("OsiriXTables.pdf"))
            if let source = Bundle.main.path(forResource: "OsiriXTables", ofType: "pdf") {
                try? FileManager.default.copyItem(atPath: source, toPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("OsiriXTables.pdf"))
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("OsiriXTables.pdf")))
        }

        if objcTag(sender) == 1 {
            if let url = NSURL(string: "http://developer.apple.com/documentation/Cocoa/Conceptual/Predicates/Articles/pSyntax.html#//apple_ref/doc/uid/TP40001795") as URL? {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @IBAction func openKeyChainAccess(_ sender: Any?) {
        if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
            NSWorkspace.shared.openApplication(at: path, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { NSLog("Unable to open Keychain Access: %@", error.localizedDescription) }
            }
        }
    }

    @IBAction public func editAddresses(_ sender: Any?) {
        let script = NSAppleScript(source:
            "tell application \"System Preferences\"\n" +
            "activate\n" +
            "set current pane to pane \"com.apple.preference.network\"\n" +
            "end tell\n")
        _ = script?.run(withArguments: nil, error: nil)
    }

    @IBAction public func editHostname(_ sender: Any?) {
        let script = NSAppleScript(source:
            "tell application \"System Preferences\"\n" +
            "activate\n" +
            "set current pane to pane \"com.apple.preferences.sharing\"\n" +
            "end tell\n")
        _ = script?.run(withArguments: nil, error: nil)
    }

    // MARK: TLS

    @IBAction public func editTLS(_ sender: Any?) {
        let selectedCipherSuites = UserDefaults.standard.value(forKey: "TLSStoreSCPCipherSuites") as AnyObject?

        if (selectedCipherSuites?.count ?? 0) > 0 {
            let mutableSelectedCipherSuites = NSMutableArray()
            for suite in selectedCipherSuites as! NSArray {
                mutableSelectedCipherSuites.add((suite as! NSObject).mutableCopy())
            }
            self.TLSSupportedCipherSuite = mutableSelectedCipherSuites
        } else {
            self.TLSSupportedCipherSuite = DICOMTLS.defaultCipherSuites() as NSArray?
        }

        self.TLSUseDHParameterFileURL = objcBoolValue(UserDefaults.standard.value(forKey: "TLSStoreSCPUseDHParameterFileURL"))
        var dhParameterFileURL = UserDefaults.standard.value(forKey: "TLSStoreSCPDHParameterFileURL") as? String
        if dhParameterFileURL == nil {
            dhParameterFileURL = NSHomeDirectory()
        }
        self.TLSDHParameterFileURL = NSURL(fileURLWithPath: dhParameterFileURL!) as URL

        if UserDefaults.standard.value(forKey: "TLSStoreSCPCertificateVerification") != nil {
            self.TLSCertificateVerification = TLSCertificateVerificationType(rawValue: UInt32(bitPattern: objcIntValue(UserDefaults.standard.value(forKey: "TLSStoreSCPCertificateVerification"))))
        } else {
            self.TLSCertificateVerification = IgnorePeerCertificate
        }

        self.TLSUseSameAETITLE = objcBoolValue(UserDefaults.standard.value(forKey: "TLSUseSameAETITLE"))
        self.TLSStoreSCPAETITLE = UserDefaults.standard.value(forKey: "TLSStoreSCPAETITLE") as? String

        updateTLSStoreSCPAETITLEIsDefaultAETButton()

        setObjCStringValue(TLSPreferredSyntaxTextField, preferredSyntaxPopUpButton?.selectedItem?.title)

        if (self.TLSStoreSCPAETITLE?.utf16.count ?? 0) <= 0 {
            self.TLSUseSameAETITLE = true
            self.TLSStoreSCPAETITLE = UserDefaults.standard.object(forKey: "AETITLE") as? String
        }

        if UserDefaults.standard.integer(forKey: "TLSStoreSCPAEPORT") <= 0 {
            UserDefaults.standard.set(DICOMNodeFormatter.alternativePort(to: UserDefaults.standard.integer(forKey: "AEPORT")), forKey: "TLSStoreSCPAEPORT")
        }

        guard let sheet = TLSSettingsWindow else { return }
        if let window = mainView.window {
            window.beginSheet(sheet, completionHandler: nil)
        }

        let result = NSApp.runModal(for: sheet)
        sheet.makeFirstResponder(nil)

        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(self)

        if result == .stop {
            if (self.TLSStoreSCPAETITLE?.utf16.count ?? 0) <= 0 {
                self.TLSUseSameAETITLE = true
                self.TLSStoreSCPAETITLE = UserDefaults.standard.object(forKey: "AETITLE") as? String
            }

            if UserDefaults.standard.integer(forKey: "TLSStoreSCPAEPORT") <= 0 {
                UserDefaults.standard.set(DICOMNodeFormatter.alternativePort(to: UserDefaults.standard.integer(forKey: "AEPORT")), forKey: "TLSStoreSCPAEPORT")
            }

            UserDefaults.standard.set(self.TLSSupportedCipherSuite, forKey: "TLSStoreSCPCipherSuites")
            UserDefaults.standard.set(NSNumber(value: self.TLSUseDHParameterFileURL), forKey: "TLSStoreSCPUseDHParameterFileURL")
            UserDefaults.standard.set((self.TLSDHParameterFileURL as NSURL?)?.path, forKey: "TLSStoreSCPDHParameterFileURL")
            UserDefaults.standard.set(NSNumber(value: Int32(bitPattern: self.TLSCertificateVerification.rawValue)), forKey: "TLSStoreSCPCertificateVerification")
            UserDefaults.standard.set(NSNumber(value: self.TLSUseSameAETITLE), forKey: "TLSUseSameAETITLE")
            UserDefaults.standard.set(self.TLSStoreSCPAETITLE, forKey: "TLSStoreSCPAETITLE")
            UserDefaults.standard.set(NSNumber(value: self.TLSStoreSCPAETITLEIsDefaultAET), forKey: "TLSStoreSCPAETITLEIsDefaultAET")
        }
    }

    @IBAction public func cancel(_ sender: Any?) {
        NSApp.abortModal()
    }

    @IBAction public func ok(_ sender: Any?) {
        NSApp.stopModal()
    }

    @IBAction public func selectAllSuites(_ sender: Any?) {
        for suite in self.TLSSupportedCipherSuite ?? [] {
            objcMutableDictionary(suite).setObject(NSNumber(value: true), forKey: "Supported" as NSString)
        }
    }

    @IBAction public func deselectAllSuites(_ sender: Any?) {
        for suite in self.TLSSupportedCipherSuite ?? [] {
            objcMutableDictionary(suite).setObject(NSNumber(value: false), forKey: "Supported" as NSString)
        }
    }

    @IBAction public func chooseTLSCertificate(_ sender: Any?) {
        let certificates = DDKeychain.keychainAccessCertificatesList()

        if (certificates?.count ?? 0) > 0 {
            SFChooseIdentityPanel.shared().setAlternateButtonTitle(NSLocalizedString("Cancel", comment: ""))
            let clickedButton = SFChooseIdentityPanel.shared().runModal(forIdentities: certificates, message: NSLocalizedString("Choose a certificate from the following list.", comment: ""))

            if clickedButton == NSApplication.ModalResponse.OK.rawValue {
                if let identity = SFChooseIdentityPanel.shared().identity() {
                    DDKeychain.keychainAccessSetPreferredIdentity(identity.takeUnretainedValue(), forName: TLS_KEYCHAIN_IDENTITY_NAME_SERVER, keyUse: Int32(truncatingIfNeeded: CSSM_KEYUSE_ANY))
                    getTLSCertificate()
                }
            } else if clickedButton == NSApplication.ModalResponse.cancel.rawValue {
                return
            }
        } else {
            let clickedButton = HorosAlertPanel.runCritical(title: NSLocalizedString("No Valid Certificate", comment: ""), message: NSLocalizedString("Your Keychain does not contain any valid certificate.", comment: ""), defaultButton: NSLocalizedString("Help", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)

            if clickedButton == NSApplication.ModalResponse.OK.rawValue {
                if let url = NSURL(string: URL_HOROS_DOC_SECURITY) as URL? {
                    NSWorkspace.shared.open(url)
                }
            }

            return
        }
    }

    @IBAction public func viewTLSCertificate(_ sender: Any?) {
        DDKeychain.openCertificatePanel(forLabel: TLS_KEYCHAIN_IDENTITY_NAME_SERVER)
    }

    @objc public func getTLSCertificate() {
        var name = DDKeychain.certificateName(forLabel: TLS_KEYCHAIN_IDENTITY_NAME_SERVER)
        let icon = DDKeychain.certificateIcon(forLabel: TLS_KEYCHAIN_IDENTITY_NAME_SERVER)

        if name == nil {
            name = NSLocalizedString("No certificate selected.", comment: "")
            TLSCertificateButton?.isHidden = true
            TLSChooseCertificateButton?.title = NSLocalizedString("Choose", comment: "")
        } else {
            TLSCertificateButton?.isHidden = false
            TLSCertificateButton?.image = icon
            TLSChooseCertificateButton?.title = NSLocalizedString("Change", comment: "")
        }

        self.TLSAuthenticationCertificate = name
    }

    @IBAction public func useSameAETitleForTLSListener(_ sender: Any?) {
        let aet: String?
        if (sender as? NSButton)?.state == .on {
            aet = UserDefaults.standard.object(forKey: "AETITLE") as? String
            self.TLSStoreSCPAETITLE = aet
            updateTLSStoreSCPAETITLEIsDefaultAETButton()
        }
    }

    @IBAction public func activateDICOMTLSListenerAction(_ sender: Any?) {
        updateTLSStoreSCPAETITLEIsDefaultAETButton()
    }

    @objc public func updateTLSStoreSCPAETITLEIsDefaultAETButton() {
        // default state
        TLSStoreSCPAETITLEIsDefaultAETButton?.isEnabled = false
        TLSStoreSCPAETITLEIsDefaultAETButton?.state = .off

        if UserDefaults.standard.bool(forKey: "STORESCP")
            && UserDefaults.standard.bool(forKey: "STORESCPTLS")
            && !objcStringEquals(TLSAETitleTextField?.stringValue, UserDefaults.standard.object(forKey: "AETITLE")) {
            TLSStoreSCPAETITLEIsDefaultAETButton?.isEnabled = true
            let state: NSControl.StateValue = UserDefaults.standard.bool(forKey: "TLSStoreSCPAETITLEIsDefaultAET") ? .on : .off
            TLSStoreSCPAETITLEIsDefaultAETButton?.state = state
        }
    }

    // MARK: NSControl Delegate Methods

    @objc(controlTextDidEndEditing:)
    public func controlTextDidEndEditing(_ aNotification: Notification) {
        let textField = aNotification.object as AnyObject?
        if let textField = textField as? NSTextField, textField === TLSPortTextField {
            let submittedPortString = textField.stringValue
            let portString = UserDefaults.standard.object(forKey: "AEPORT")
            let submittedPort = (submittedPortString as NSString).intValue
            let port = objcIntValue(portString)

            if submittedPort == port {
                let newPort = Int32(truncatingIfNeeded: DICOMNodeFormatter.alternativePort(to: Int(submittedPort)))

                let newStr = String(format: "%d", newPort)

                textField.stringValue = newStr
                UserDefaults.standard.set(NSNumber(value: newPort), forKey: "TLSStoreSCPAEPORT")

                let msg = String(format: NSLocalizedString("The port %d is already use by the standard DICOM Listener. The port %d was automatically chosen instead.", comment: ""), submittedPort, newPort)
                _ = HorosAlertPanel.run(title: NSLocalizedString("Port already in use", comment: ""), message: msg, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }
    }

    @objc(controlTextDidChange:)
    public func controlTextDidChange(_ aNotification: Notification) {
        let textField = aNotification.object as AnyObject?
        if let textField, textField === TLSAETitleTextField {
            updateTLSStoreSCPAETITLEIsDefaultAETButton()
        }
    }
}

/// An element the former code typed NSMutableDictionary*: a static cast, with
/// no runtime check, so a message to it does what the Objective-C message did.
fileprivate func objcMutableDictionary(_ object: Any) -> NSMutableDictionary {
    return unsafeBitCast(object as AnyObject, to: NSMutableDictionary.self)
}

/// -setStringValue: with the id the former code passed, nil included.
fileprivate func setObjCStringValue(_ control: NSControl?, _ value: Any?) {
    _ = control?.perform(#selector(setter: NSControl.stringValue), with: value)
}

/// [value intValue] on an id: 0 for nil.
fileprivate func objcIntValue(_ value: Any?) -> Int32 {
    guard let value = value as AnyObject? else { return 0 }
    return value.intValue ?? 0
}

/// [value boolValue] on an id: NO for nil.
fileprivate func objcBoolValue(_ value: Any?) -> Bool {
    guard let value = value as AnyObject? else { return false }
    return value.boolValue ?? false
}

/// [sender tag] on an id: 0 for nil.
@MainActor fileprivate func objcTag(_ sender: Any?) -> Int {
    return (sender as AnyObject?)?.tag ?? 0
}

/// [a isEqualToString: b]: NO when a is nil or either is not a string.
fileprivate func objcStringEquals(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a as? NSString, let b = b as? String else { return false }
    return a.isEqual(to: b)
}
