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
 OsiriX project.
 
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
import UniformTypeIdentifiers
import PreferencePanes
import SecurityInterface

/************ Transfer Syntaxes *******************
	"Explicit Little Endian"
	"JPEG 2000 Lossless"
	"JPEG 2000 Lossy 10:1"
	"JPEG 2000 Lossy 20:1"
	"JPEG 2000 Lossy 50:1"
	"JPEG Lossless"
	"JPEG High Quality (9)"
	"JPEG Medium High Quality (8)"
	"JPEG Medium Quality (7)"
	"Implicit"
	"RLE"
*************************************************/

/// The Locations preference pane: DICOM nodes, OsiriX databases, local paths,
/// and each node's WADO and TLS sheets.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors,
/// the outlets and the bindings of OSILocationsPreferencePanePref.xib are
/// those of the former class.
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSILocationsPreferencePanePref)
public final class OSILocationsPreferencePanePref: NSPreferencePane {
    @IBOutlet var characterSetPopup: NSPopUpButton?
    @IBOutlet var addServerDICOM: NSButton?
    @IBOutlet var addServerSharing: NSButton?
    @IBOutlet var searchDICOMBonjourNodes: NSButton?
    @IBOutlet var verifyPing: NSButton?
    @IBOutlet var addLocalPath: NSButton?
    @IBOutlet var loadNodes: NSButton?
    private var stringEncoding: String?

    @IBOutlet var localPaths: DNDArrayController?
    @IBOutlet var osiriXServers: DNDArrayController?
    @IBOutlet var dicomNodes: DNDArrayController?
    /// The DICOMweb nodes of DICOMWEB_SERVERS, in their own area below the DIMSE nodes (#799).
    @IBOutlet var dicomwebNodes: DICOMwebNodesController?

    // WADO
    /// Retained by the former -initWithBundle:, released in -dealloc: a strong outlet.
    @IBOutlet var WADOSettings: NSWindow?
    @objc public dynamic var WADOPort: Int32 = 0
    @objc public dynamic var WADOTransferSyntax: Int32 = 0
    @objc public dynamic var WADOhttps: Int32 = 0
    @objc public dynamic var WADOUrl: String?
    @objc public dynamic var WADOUsername: String?
    @objc public dynamic var WADOPassword: String?
    /// The sheet opened without the stored password: the Keychain did not answer.
    private var wadoPasswordUnavailable = false
    /// The node's limit of requests at once, 1 to 16, shared by its retrieves.
    @objc public dynamic var WADOMaxRequests: Int32 = 10
    /// The order the node's series are asked for in, a `RetrieveOrder`.
    @objc public dynamic var WADOSeriesOrder: Int32 = 0
    /// The node's series exclusion rules, as the sheet shows them: comma-separated.
    @objc public dynamic var WADOExcludeSeries: String?
    /// The node's automatic request limit.
    @objc public dynamic var WADOAdaptiveRequests = false

    // TLS
    /// Retained by the former -initWithBundle:, released in -dealloc: a strong outlet.
    @IBOutlet var TLSSettings: NSWindow?
    @objc public dynamic var TLSEnabled: Bool = false
    @objc public dynamic var TLSAuthenticated: Bool = false
    @objc public dynamic var TLSAuthenticationCertificate: String?
    @IBOutlet var TLSChooseCertificateButton: NSButton?
    @IBOutlet var TLSCertificateButton: NSButton?
    @IBOutlet var TLSCipherSuitesArrayController: DNDArrayController?
    /// The rows of the cipher suite table: mutable dictionaries that
    /// -selectAllSuites: and -deselectAllSuites: change in place.
    @objc public dynamic var TLSSupportedCipherSuite: NSArray?
    @objc public dynamic var TLSUseDHParameterFileURL: Bool = false
    @objc public dynamic var TLSDHParameterFileURL: URL?
    @objc public dynamic var TLSCertificateVerification: TLSCertificateVerificationType = RequirePeerCertificate

    @IBOutlet var mainWindow: NSWindow?
    /// Atomic in the former header. -testThread: writes it from the verification
    /// thread and the nib observes it; a single BOOL store stays a single store.
    @objc public dynamic var testingNodes: Bool = false

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
        let nib = NSNib(nibNamed: "OSILocationsPreferencePanePref", bundle: nil)
        var topLevelObjects: NSArray?
        nib?.instantiate(withOwner: self, topLevelObjects: &topLevelObjects)
        _tlos = topLevelObjects

        if let view = mainWindow?.contentView {
            self.mainView = view
        }
        self.mainViewDidLoad()
    }

    func checkUniqueAETitle() {
        let serverList = arrangedObjects(dicomNodes)

        var x = 0
        while x < serverList.count {
            if (serverList.object(at: x) as AnyObject).value(forKey: "Activated") == nil {
                (serverList.object(at: x) as AnyObject).setValue(NSNumber(value: true), forKey: "Activated")
            }

            let currentAETitle = (serverList.object(at: x) as AnyObject).value(forKey: "AETitle")

            var i = 0
            while i < serverList.count {
                if i != x {
                    if objcStringEquals(currentAETitle, (serverList.object(at: i) as AnyObject).value(forKey: "AETitle")) {
                        if UserDefaults.standard.bool(forKey: "HideSameAETitleAlert") == false {
                            let alert = NSAlert()
                            alert.messageText = NSLocalizedString("Same AETitle", comment: "")
                            alert.informativeText = String(format: NSLocalizedString("This AETitle is not unique: %@. AETitles should be unique, otherwise Q&R (C-Move SCP/SCU) can fail.", comment: ""), objcFormatArgument(currentAETitle))
                            alert.showsSuppressionButton = true
                            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))

                            alert.runModal()

                            if alert.suppressionButton?.state == .on {
                                UserDefaults.standard.set(true, forKey: "HideSameAETitleAlert")
                            }

                            i = serverList.count
                            x = serverList.count
                        }
                    }
                }
                i += 1
            }
            x += 1
        }
        // Check for unique description
        x = 0
        while x < serverList.count {
            let description = (serverList.object(at: x) as AnyObject).value(forKey: "Description")

            var i = 0
            while i < serverList.count {
                if i != x {
                    if objcStringEquals(description, (serverList.object(at: i) as AnyObject).value(forKey: "Description")) {
                        if UserDefaults.standard.bool(forKey: "HideSameNameAlert") == false {
                            let alert = NSAlert()
                            alert.messageText = NSLocalizedString("Same name", comment: "")
                            alert.informativeText = String(format: NSLocalizedString("This server name is not unique: %@. Server names should be unique, otherwise autorouting rules can fail.", comment: ""), objcFormatArgument(description))
                            alert.showsSuppressionButton = true
                            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))

                            alert.runModal()

                            if alert.suppressionButton?.state == .on {
                                UserDefaults.standard.set(true, forKey: "HideSameNameAlert")
                            }

                            i = serverList.count
                            x = serverList.count
                        }
                    }
                }
                i += 1
            }
            x += 1
        }
    }

    @objc(echoAddress:port:AET:)
    func echoAddress(_ address: String?, port: Int32, AET aet: String?) -> Int32 {
        let parameters: NSDictionary = ["Address": address ?? "", "Port": NSNumber(value: port),
                                        "AETitle": aet ?? ""]
        return type(of: self).echoServer(parameters) ? 0 : -1
    }

    /// The Verify button's C-ECHO, run by the application's query stack
    /// (+[DCMTKQueryNode verifyDICOMServer:]), which this pane reaches by name.
    @objc(echoServer:)
    nonisolated public class func echoServer(_ serverParameters: NSDictionary?) -> Bool {
        var verified = false
        do {
            try HorosObjCException.perform {
                let selector = NSSelectorFromString("verifyDICOMServer:")
                guard let queryClass: AnyClass = NSClassFromString("DCMTKQueryNode"),
                      let method = class_getClassMethod(queryClass, selector) else {
                    NSLog("DICOM verification unavailable: application query stack is missing")
                    verified = false
                    return
                }
                typealias VerifyDICOMServer = @convention(c) (AnyClass, Selector, NSDictionary?) -> Bool
                let verifyDICOMServer = unsafeBitCast(method_getImplementation(method), to: VerifyDICOMServer.self)
                verified = verifyDICOMServer(queryClass, selector, serverParameters)
            }
        } catch {
            if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(exception, false, "+[OSILocationsPreferencePanePref echoServer:]")
            }
            return false
        }
        return verified
    }

    func enableControls(_ val: Bool) {
//	[[NSUserDefaults standardUserDefaults] setBool: val forKey: @"preferencesModificationsEnabled"];
//	[[NSUserDefaults standardUserDefaults] setBool: [[NSUserDefaults standardUserDefaults] boolForKey:@"syncDICOMNodes"] forKey: @"syncDICOMNodes"];
    }

    public override func mainViewDidLoad() {
        assumeMainActor(self) { $0.mainViewDidLoadOnMainActor() }
    }

    private func mainViewDidLoadOnMainActor() {
        for field in ["Address", "AETitle", "Port"] {
            let column = dicomNodes?.tableView()?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(field))
            let formatter = DICOMNodeFormatter(field: field)
            (column?.dataCell as? NSCell)?.formatter = formatter
        }
        let defaults = UserDefaults.standard

        stringEncoding = defaults.string(forKey: "STRINGENCODING")
        var tag = 0
        if stringEncoding == "ISO_IR 192" {	//UTF8
            tag = 0
        } else if stringEncoding == "ISO_IR 100" {
            tag = 1
        } else if stringEncoding == "ISO_IR 101" {
            tag = 2
        } else if stringEncoding == "ISO_IR 109" {
            tag = 3
        } else if stringEncoding == "ISO_IR 110" {
            tag = 4
        } else if stringEncoding == "ISO_IR 127" {
            tag = 5
        } else if stringEncoding == "ISO_IR 144" {
            tag = 6
        } else if stringEncoding == "ISO_IR 126" {
            tag = 7
        } else if stringEncoding == "ISO_IR 138" {
            tag = 8
        } else if stringEncoding == "GB18030" {
            tag = 9
        } else if stringEncoding == "ISO 2022 IR 149" {
            tag = 10
        } else if stringEncoding == "ISO 2022 IR 13" {
            tag = 11
        } else if stringEncoding == "ISO_IR 13" {
            tag = 12
        } else if stringEncoding == "ISO 2022 IR 87" {
            tag = 13
        } else if stringEncoding == "ISO_IR 1166" {
            tag = 14
        } else {
            UserDefaults.standard.set("ISO_IR 100", forKey: "STRINGENCODING")
            tag = 1
        }

        characterSetPopup?.selectItem(at: -1)
        characterSetPopup?.selectItem(at: tag)

        var i = 0
        while i < arrangedObjects(dicomNodes).count {
            let aServer = arrangedObjects(dicomNodes).object(at: i) as AnyObject
            if aServer.value(forKey: "Send") == nil {
                aServer.setValue(NSNumber(value: true), forKey: "Send")
            }
            i += 1
        }
    }

    public override func willSelect() {
        assumeMainActor(self) { $0.willSelectOnMainActor() }
    }

    private func willSelectOnMainActor() {
        checkUniqueAETitle()
        resetTest()
        dicomwebNodes?.reload()
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        mainView.window?.makeFirstResponder(nil)
    }

    deinit {
        NSLog("dealloc OSILocationsPreferencePanePref")
    }

    @IBAction public func newServer(_ sender: Any?) {
        let aServer = NSMutableDictionary()
        aServer.setObject("127.0.0.1", forKey: "Address" as NSString)
        aServer.setObject("PACS", forKey: "AETitle" as NSString)
        aServer.setObject("11112", forKey: "Port" as NSString)
        aServer.setObject(NSNumber(value: true), forKey: "QR" as NSString)
        aServer.setObject(NSNumber(value: true), forKey: "Send" as NSString)
        aServer.setObject("Description", forKey: "Description" as NSString)
        aServer.setObject(NSNumber(value: 0 as Int32), forKey: "TransferSyntax" as NSString)
        aServer.setObject(NSNumber(value: 0 as Int32), forKey: "retrieveMode" as NSString) // CMove
        aServer.setObject(NSNumber(value: 8080 as Int32), forKey: "WADOPort" as NSString)
        aServer.setObject(NSNumber(value: -1 as Int32), forKey: "WADOTransferSyntax" as NSString) // Original Syntax: transferSyntax=* and legacy useOrig=true
        aServer.setObject(NSNumber(value: 0 as Int32), forKey: "WADOhttps" as NSString)
        aServer.setObject("wado", forKey: "WADOUrl" as NSString)

        aServer.setObject(NSNumber(value: false), forKey: "TLSEnabled" as NSString)
        aServer.setObject(NSNumber(value: false), forKey: "TLSAuthenticated" as NSString)

        dicomNodes?.addObject(aServer)

        dicomNodes?.tableView()?.scrollRowToVisible(selectedRow(dicomNodes))

        resetTest()
    }

    @IBAction public func osirixNewServer(_ sender: Any?) {
        let aServer = NSMutableDictionary()
        aServer.setObject("osirix.hcuge.ch", forKey: "Address" as NSString)
        aServer.setObject("PACS Server", forKey: "Description" as NSString)

        osiriXServers?.addObject(aServer)

        osiriXServers?.tableView()?.scrollRowToVisible(selectedRow(osiriXServers))

        mainView.window?.makeKeyAndOrderFront(self)
    }

    @IBAction public func cancel(_ sender: Any?) {
        NSApp.abortModal()
    }

    @IBAction public func ok(_ sender: Any?) {
        NSApp.stopModal()
    }

    /// This pane lives in a separate bundle; use the application's shared policy.
    static func wadoSyntaxQuery(_ syntax: Int32) -> String? {
        let selector = NSSelectorFromString("syntaxStringFor:imageQuality:")
        guard let queryClass = NSClassFromString("DCMTKQueryNode"),
              let method = class_getClassMethod(queryClass, selector) else { return nil }
        typealias SyntaxQuery = @convention(c) (AnyClass, Selector, Int32, UnsafeMutablePointer<Int32>) -> Unmanaged<NSString>
        let query = unsafeBitCast(method_getImplementation(method), to: SyntaxQuery.self)
        var quality: Int32 = 100
        return query(queryClass, selector, syntax, &quality).takeUnretainedValue() as String
    }

    @IBAction public func testWADOUrl(_ sender: Any?) {
        let `protocol` = WADOhttps != 0 ? "https" : "http"

        let aServer = arrangedObjects(dicomNodes).object(at: selectedRow(dicomNodes)) as AnyObject

        // The credential goes in the Authorization header, as a retrieve sends it,
        // never in the URL.
        let baseURL = String(format: "%@://%@:%d/%@?requestType=WADO", `protocol`, objcFormatArgument(aServer.value(forKey: "Address")), WADOPort, objcFormatArgument(WADOUrl))

        guard let syntax = Self.wadoSyntaxQuery(WADOTransferSyntax) else {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("URL download Error", comment: ""), message: NSLocalizedString("WADO transfer syntax verification is unavailable.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        let url = NSURL(string: baseURL.appendingFormat("&studyUID=%@&seriesUID=%@&objectUID=%@&contentType=application/dicom%@", "1", "1", "1", syntax)) as URL?

        // An https server is trusted the way the system trusts it, as the
        // retrieval itself does: a private CA is added to the Keychain, not
        // waived here (docs/wado-https-trust.md).

        guard let url else {
            // -[NSData dataWithContentsOfURL:options:error:] raised on a nil URL,
            // which ended the action before any panel.
            NSLog("*** -[_NSPlaceholderData initWithContentsOfURL:options:maxLength:error:]: nil URL argument")
            return
        }
        // The sheet's fields, saved or not: the password was read from the Keychain when it opened.
        let authorization = WADOCredentials.basicAuthorization(username: WADOUsername, password: WADOPassword)
        if let error = WADODownload.probe(url, authorization: authorization, timeout: 30) {
            let message = WADODownload.untrustedServerReason(error, host: url.host) ?? error.localizedDescription
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("URL download Error", comment: ""), message: message, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        } else {
            _ = HorosAlertPanel.runInformational(title: NSLocalizedString("URL download Succeeded", comment: ""), message: NSLocalizedString("The endpoint responded to the selected transfer syntax with test UIDs. Retrieve a known instance to verify its encoding and pixels.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    /// The WADO sheet's "Parallel Requests", "Series Order" and "Exclude
    /// Series" rows, made once below its Retrieve Syntax row, the same in every
    /// localized pane: the sheet grows by three rows and what is above the
    /// syntax moves up.
    private func addWADORetrieveRows(to sheet: NSWindow) {
        guard let content = sheet.contentView,
              !content.subviews.contains(where: { $0.identifier?.rawValue == "WADOMaxRequests" }),
              let syntax = content.subviews.compactMap({ $0 as? NSPopUpButton })
                .first(where: { ($0.infoForBinding(.selectedTag)?[.observedKeyPath] as? String) == "WADOTransferSyntax" })
        else { return }
        let row: CGFloat = 30
        // Where everything was, before growing the sheet moves its views by
        // their autoresizing: the syntax row and what is above it go up by three
        // rows, what is below stays, and the new rows take the syntax row's place.
        let frames = content.subviews.map { ($0, $0.frame) }
        let syntaxFrame = syntax.frame
        var frame = sheet.frame
        frame.size.height += 3 * row
        frame.origin.y -= 3 * row
        sheet.setFrame(frame, display: false)
        for (view, original) in frames {
            view.frame = original.minY >= syntaxFrame.minY - 4 ? original.offsetBy(dx: 0, dy: 3 * row) : original
        }
        func addLabel(_ title: String, help: String, beside control: NSView) {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.toolTip = help
            label.sizeToFit()
            // Its own width: SheetLabelColumn widens the column to the longest label.
            let right = syntaxFrame.minX - 4
            label.frame = NSRect(x: right - label.frame.width, y: control.frame.midY - label.frame.height / 2,
                                 width: label.frame.width, height: label.frame.height)
            content.addSubview(label)
        }
        func addRow(_ title: String, key: String, help: String, width: CGFloat, y: CGFloat, items: [(String, Int)]) {
            let popup = NSPopUpButton(frame: NSRect(x: syntaxFrame.minX, y: y, width: width, height: syntaxFrame.height), pullsDown: false)
            popup.identifier = NSUserInterfaceItemIdentifier(key)
            for (title, tag) in items {
                popup.addItem(withTitle: title)
                popup.lastItem?.tag = tag
            }
            popup.toolTip = help
            popup.bind(.selectedTag, to: self, withKeyPath: key, options: nil)
            content.addSubview(popup)
            addLabel(title, help: help, beside: popup)
        }
        // As wide as the syntax popup, within the sheet.
        let wide = max(80, min(syntaxFrame.width, content.bounds.width - syntaxFrame.minX - 8))
        addRow(NSLocalizedString("Parallel Requests:", comment: "per-node request limit"), key: "WADOMaxRequests",
               help: DICOMwebNodesController.maximumRequestsHelp, width: 80, y: syntaxFrame.minY + 2 * row,
               items: (NodeRequestLimiter.minimum...NodeRequestLimiter.maximum).map { (String($0), $0) })
        // The automatic mode, beside the limit it moves under.
        let automatic = NSButton(checkboxWithTitle: NSLocalizedString("Automatic Limit", comment: "automatic request limit"), target: nil, action: nil)
        automatic.identifier = NSUserInterfaceItemIdentifier("WADOAdaptiveRequests")
        automatic.sizeToFit()
        automatic.frame.origin = NSPoint(x: syntaxFrame.minX + 88, y: syntaxFrame.minY + 2 * row + (syntaxFrame.height - automatic.frame.height) / 2)
        automatic.toolTip = NodeRequestLimiter.adaptiveHelp
        automatic.bind(.value, to: self, withKeyPath: "WADOAdaptiveRequests", options: nil)
        content.addSubview(automatic)
        addRow(NSLocalizedString("Series Order:", comment: "series retrieve order"), key: "WADOSeriesOrder",
               help: RetrievePlan.orderHelp, width: wide, y: syntaxFrame.minY + row,
               items: RetrievePlan.orderTitles.enumerated().map { ($0.element, $0.offset) })
        let field = NSTextField(frame: NSRect(x: syntaxFrame.minX + 3, y: syntaxFrame.minY + (syntaxFrame.height - 22) / 2, width: wide - 6, height: 22))
        field.identifier = NSUserInterfaceItemIdentifier("WADOExcludeSeries")
        // The binding shows its null placeholder when there are no rules.
        let example = NSLocalizedString("e.g. scout, localizer", comment: "series exclusion rules example")
        field.toolTip = RetrievePlan.exclusionHelp
        field.bind(.value, to: self, withKeyPath: "WADOExcludeSeries", options: [.continuouslyUpdatesValue: true, .nullPlaceholder: example])
        content.addSubview(field)
        addLabel(NSLocalizedString("Exclude Series:", comment: "series exclusion rules"), help: RetrievePlan.exclusionHelp, beside: field)
    }

    @IBAction public func editWADO(_ sender: Any?) {
        let aServer = objcMutableDictionary(arrangedObjects(dicomNodes).object(at: selectedRow(dicomNodes)))

        self.WADOPort = objcIntValue(aServer.value(forKey: "WADOPort"))
        self.WADOUrl = aServer.value(forKey: "WADOUrl") as? String
        // The password is the Keychain's; one still in the entry is moved there on OK.
        let stored = WADOCredentials.password(forServer: aServer)
        self.WADOPassword = stored.password
        self.wadoPasswordUnavailable = stored.unavailable
        self.WADOUsername = aServer.value(forKey: "WADOUsername") as? String
        self.WADOTransferSyntax = objcIntValue(aServer.value(forKey: "WADOTransferSyntax"))
        self.WADOhttps = objcIntValue(aServer.value(forKey: "WADOhttps"))
        self.WADOMaxRequests = Int32(NodeRequestLimiter.wadoLimit(forServer: aServer as? [AnyHashable: Any], defaults: .standard))
        self.WADOSeriesOrder = Int32(RetrievePlan.order(forStoredValue: aServer.value(forKey: RetrievePlan.wadoKey)).rawValue)
        self.WADOAdaptiveRequests = NodeRequestLimiter.adaptive(forStoredValue: aServer.value(forKey: NodeRequestLimiter.wadoAdaptiveKey))
        self.WADOExcludeSeries = RetrievePlan.text(forExclusionRules: RetrievePlan.exclusionRules(forStoredValue: aServer.value(forKey: RetrievePlan.wadoExclusionKey)))

        guard let sheet = WADOSettings else { return }
        addWADORetrieveRows(to: sheet)
        // The labels' column, as wide as the longest label in this language.
        if let syntax = sheet.contentView?.subviews.compactMap({ $0 as? NSPopUpButton })
            .first(where: { ($0.infoForBinding(.selectedTag)?[.observedKeyPath] as? String) == "WADOTransferSyntax" }) {
            SheetLabelColumn.fit(sheet, controlColumn: syntax.frame.minX)
        }
        if let window = mainView.window {
            window.beginSheet(sheet, completionHandler: nil)
        }

        let result = NSApp.runModal(for: sheet)
        sheet.makeFirstResponder(nil)

        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(self)

        if result == .stop {
            aServer.setObject(NSNumber(value: 2 as Int32), forKey: "retrieveMode" as NSString) // WADORetrieveMode
            aServer.setObject(NSNumber(value: WADOPort), forKey: "WADOPort" as NSString)
            aServer.setObject(NSNumber(value: WADOTransferSyntax), forKey: "WADOTransferSyntax" as NSString)
            aServer.setObject(NSNumber(value: WADOhttps), forKey: "WADOhttps" as NSString)
            aServer.setObject(NSNumber(value: NodeRequestLimiter.limit(forStoredValue: NSNumber(value: WADOMaxRequests), fallback: 10)),
                              forKey: NodeRequestLimiter.wadoKey as NSString)
            aServer.setObject(NSNumber(value: RetrievePlan.order(forStoredValue: NSNumber(value: WADOSeriesOrder)).rawValue),
                              forKey: RetrievePlan.wadoKey as NSString)
            aServer.setObject(NSNumber(value: WADOAdaptiveRequests), forKey: NodeRequestLimiter.wadoAdaptiveKey as NSString)
            let rules = RetrievePlan.exclusionRules(forStoredValue: WADOExcludeSeries)
            if rules.isEmpty { aServer.removeObject(forKey: RetrievePlan.wadoExclusionKey) }
            else { aServer.setObject(rules, forKey: RetrievePlan.wadoExclusionKey as NSString) }
            if let WADOUrl {
                aServer.setObject(WADOUrl, forKey: "WADOUrl" as NSString)
            }
            if let WADOUsername {
                aServer.setObject(WADOUsername, forKey: "WADOUsername" as NSString)
            }
            do {
                try WADOCredentials.save(username: WADOUsername, password: WADOPassword, in: aServer,
                                         keepStoredPassword: wadoPasswordUnavailable)
            } catch {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: error.localizedDescription, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }

            // TLSEnabled used to be cleared here. It is not a WADO setting: it secures
            // the DIMSE association this node is queried over, and a node still answers
            // C-FIND on that association whatever it retrieves with. Saving the WADO
            // sheet therefore turned a TLS only node into one that could no longer be
            // queried, and threw away its authentication and certificate settings.
            // WADO has its own transport switch, WADOhttps, edited on this same sheet.

            UserDefaults.standard.set(dicomNodes?.arrangedObjects, forKey: "SERVERS")
        }
    }

    @objc public func resetTest() {
        var i = 0
        while i < arrangedObjects(dicomNodes).count {
            let aServer = objcMutableDictionary(arrangedObjects(dicomNodes).object(at: i))
            aServer.removeObject(forKey: "test")
            i += 1
        }
    }

    @IBAction public func OsiriXDBsaveAs(_ sender: Any?) {
        let sPanel = NSSavePanel()

        sPanel.allowedContentTypes = [UTType(filenameExtension: "plist")!]
        sPanel.nameFieldStringValue = NSLocalizedString("OsiriXDB.plist", comment: "")

        sPanel.begin { result in
            if result != .OK {
                return
            }

            if let url = sPanel.url {
                self.arrangedObjects(self.osiriXServers).write(to: url, atomically: true)
            }
        }
    }

    @IBAction public func refreshNodesOsiriXDB(_ sender: Any?) {
        if UserDefaults.standard.bool(forKey: "syncOsiriXDB") {
            let url = objcURL(UserDefaults.standard.value(forKey: "syncOsiriXDBURL"))

            if let url {
                let r = NSArray(contentsOf: url)

                if let r {
                    osiriXServers?.remove(contentsOf: arrangedObjects(osiriXServers) as! [Any])
                    osiriXServers?.add(contentsOf: r as! [Any])
                } else {
                    _ = HorosAlertPanel.runInformational(title: NSLocalizedString("URL Invalid", comment: ""), message: NSLocalizedString("Cannot download data from this URL.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
            } else {
                _ = HorosAlertPanel.runInformational(title: NSLocalizedString("URL Invalid", comment: ""), message: NSLocalizedString("This URL is invalid. Check syntax.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }
    }

    @IBAction public func OsiriXDBloadFrom(_ sender: Any?) {
        let sPanel = NSOpenPanel()

        resetTest()

        sPanel.allowedContentTypes = [UTType(filenameExtension: "plist")!]

        sPanel.begin { result in
            if result != .OK {
                return
            }

            guard let url = sPanel.url, let r = NSArray(contentsOf: url) else { return }

            if HorosAlertPanel.runInformational(title: NSLocalizedString("Load locations", comment: ""), message: NSLocalizedString("Should I add or replace this locations list? If you choose 'replace', the current list will be deleted.", comment: ""), defaultButton: NSLocalizedString("Add", comment: ""), alternateButton: NSLocalizedString("Replace", comment: ""), otherButton: nil) == HorosAlertPanel.defaultResponse {

            } else {
                self.osiriXServers?.remove(contentsOf: self.arrangedObjects(self.osiriXServers) as! [Any])
            }

            self.osiriXServers?.add(contentsOf: r as! [Any])

            var i = 0
            while i < self.arrangedObjects(self.osiriXServers).count {
                let server = self.arrangedObjects(self.osiriXServers).object(at: i) as AnyObject

                var x = 0
                while x < self.arrangedObjects(self.osiriXServers).count {
                    let c = self.arrangedObjects(self.osiriXServers).object(at: x) as AnyObject

                    if c !== server {
                        if objcStringEquals(server.value(forKey: "Address"), c.value(forKey: "Address")) &&
                            objcStringEquals(server.value(forKey: "Description"), c.value(forKey: "Description")) {
                            self.osiriXServers?.remove(atArrangedObjectIndex: i)
                            i -= 1
                            x = self.arrangedObjects(self.osiriXServers).count
                        }
                    }
                    x += 1
                }
                i += 1
            }
        }
    }

    @IBAction public func saveAs(_ sender: Any?) {
        let sPanel = NSSavePanel()

        sPanel.allowedContentTypes = [UTType(filenameExtension: "plist")!]

        resetTest()

        sPanel.nameFieldStringValue = NSLocalizedString("DICOMNodes.plist", comment: "")

        sPanel.begin { result in
            if result != .OK {
                return
            }

            if let url = sPanel.url {
                self.arrangedObjects(self.dicomNodes).write(to: url, atomically: true)
            }
        }
    }

    @IBAction public func refreshNodesListURL(_ sender: Any?) {
        if UserDefaults.standard.bool(forKey: "syncDICOMNodes") {
            let url = objcURL(UserDefaults.standard.value(forKey: "syncDICOMNodesURL"))

            if let url {
                /*NSString* err = nil;
                NSData* data = [NSData dataWithContentsOfURL:url];
                NSArray* arr = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListImmutable format:0 errorDescription:&err];
                NSLog(@"Error: %@ - %@", err, arr);*/

                let r = NSArray(contentsOf: url)

                if let r {
                    dicomNodes?.remove(contentsOf: arrangedObjects(dicomNodes) as! [Any])
                    dicomNodes?.add(contentsOf: r as! [Any])
                } else {
                    _ = HorosAlertPanel.runInformational(title: NSLocalizedString("URL Invalid", comment: ""), message: NSLocalizedString("Cannot download data from this URL.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
            } else {
                _ = HorosAlertPanel.runInformational(title: NSLocalizedString("URL Invalid", comment: ""), message: NSLocalizedString("This URL is invalid. Check syntax.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }
    }

    @IBAction public func loadFrom(_ sender: Any?) {
        let sPanel = NSOpenPanel()

        resetTest()

        sPanel.allowedContentTypes = [UTType(filenameExtension: "plist")!]

        sPanel.begin { result in
            if result != .OK {
                self.resetTest()
                return
            }

            let r = sPanel.url.flatMap { NSArray(contentsOf: $0) }

            if let r {
                if HorosAlertPanel.runInformational(title: NSLocalizedString("Load locations", comment: ""), message: NSLocalizedString("Should I add or replace this locations list? If you choose 'replace', the current list will be deleted.", comment: ""), defaultButton: NSLocalizedString("Add", comment: ""), alternateButton: NSLocalizedString("Replace", comment: ""), otherButton: nil) == HorosAlertPanel.defaultResponse {

                } else {
                    self.dicomNodes?.remove(contentsOf: self.arrangedObjects(self.dicomNodes) as! [Any])
                }

                self.dicomNodes?.add(contentsOf: r as! [Any])

                var i = 0
                while i < self.arrangedObjects(self.dicomNodes).count {
                    let server = self.arrangedObjects(self.dicomNodes).object(at: i) as AnyObject

                    var x = 0
                    while x < self.arrangedObjects(self.dicomNodes).count {
                        let c = self.arrangedObjects(self.dicomNodes).object(at: x) as AnyObject

                        if c !== server {
                            if objcStringEquals(server.value(forKey: "AETitle"), c.value(forKey: "AETitle")) &&
                                objcStringEquals(server.value(forKey: "Address"), c.value(forKey: "Address")) &&
                                objcIntValue(server.value(forKey: "Port")) == objcIntValue(c.value(forKey: "Port")) {
                                self.dicomNodes?.remove(atArrangedObjectIndex: i)
                                i -= 1
                                x = self.arrangedObjects(self.dicomNodes).count
                            }
                        }
                        x += 1
                    }
                    i += 1
                }
            }

            self.resetTest()
        }
    }

    /// Runs on the thread -test: detaches: the C-ECHO blocks. The flag and the
    /// table belong to the main thread, where -test: raised the flag.
    @objc(testThread:)
    nonisolated func testThread(_ serverList: NSArray) {
        autoreleasepool {
            for element in NSArray(array: serverList as! [Any]) {
                let aServer = objcMutableDictionary(element)
                let status: Int32

                if objcBoolValue(aServer.object(forKey: "Activated")) && OSILocationsPreferencePanePref.echoServer(aServer) {
                    status = 0
                } else {
                    status = -1
                }

                aServer.setObject(NSNumber(value: status), forKey: "test" as NSString)

                performSelector(onMainThread: #selector(showTestResults), with: nil, waitUntilDone: false)
            }

            performSelector(onMainThread: #selector(testDidEnd), with: nil, waitUntilDone: false)
        }
    }

    @objc private func showTestResults() {
        dicomNodes?.tableView()?.display()
    }

    @objc private func testDidEnd() {
        testingNodes = false
    }

    @IBAction public func test(_ sender: Any?) {
        if self.testingNodes {
            return
        }

        for server in arrangedObjects(dicomNodes) {
            objcMutableDictionary(server).setObject(NSNumber(value: 0 as Int32), forKey: "test" as NSString)
        }

        dicomNodes?.tableView()?.display()

        // Raised here, before the thread starts, so that a second click cannot
        // start a second test.
        self.testingNodes = true
        Thread.detachNewThreadSelector(#selector(testThread(_:)), toTarget: self, with: arrangedObjects(dicomNodes))
    }

    @IBAction func activateAllNone(_ sender: Any?) {
        for aServer in arrangedObjects(dicomNodes) {
            objcMutableDictionary(aServer).setObject(NSNumber(value: objcTag(sender) != 0), forKey: "Activated" as NSString)
        }
        UserDefaults.standard.set(dicomNodes?.arrangedObjects, forKey: "SERVERS")
    }

    @IBAction public func setStringEncoding(_ sender: Any?) {
        let encoding: String

        switch (sender as AnyObject?)?.selectedItem??.tag ?? 0 {
        case 0: encoding = "ISO_IR 192"
        case 1: encoding = "ISO_IR 100"
        case 2: encoding = "ISO_IR 101"
        case 3: encoding = "ISO_IR 109"
        case 4: encoding = "ISO_IR 110"
        case 5: encoding = "ISO_IR 127"
        case 6: encoding = "ISO_IR 144"
        case 7: encoding = "ISO_IR 126"
        case 8: encoding = "ISO_IR 138"
        case 9: encoding = "GB18030"
        case 10: encoding = "ISO 2022 IR 149"
        case 11: encoding = "ISO 2022 IR 13"
        case 12: encoding = "ISO_IR 13"
        case 13: encoding = "ISO 2022 IR 87"
        case 14: encoding = "ISO_IR 1166"
        default: encoding = "ISO_IR 100"
        }
        UserDefaults.standard.set(encoding, forKey: "STRINGENCODING")
        stringEncoding = encoding
    }

    @IBAction public func addPath(_ sender: Any?) {
        let oPanel = NSOpenPanel()

        oPanel.canChooseFiles = true
        oPanel.canChooseDirectories = true

        oPanel.allowedContentTypes = [UTType(filenameExtension: "sql")!]

        oPanel.begin { result in
            if result != .OK {
                return
            }

            if var location = oPanel.url?.path {
                if DatabaseLocation.isDataDirectoryName((location as NSString).lastPathComponent) {
                    location = (location as NSString).deletingLastPathComponent
                }

                if (location as NSString).lastPathComponent == "DATABASE" && DatabaseLocation.isDataDirectoryName(((location as NSString).deletingLastPathComponent as NSString).lastPathComponent) {
                    location = ((location as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                }

                var isDirectory: ObjCBool = false

                if FileManager.default.fileExists(atPath: location, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        let dict = NSDictionary(objects: [location, (location as NSString).lastPathComponent + NSLocalizedString(" DB", comment: "DB = DataBase")], forKeys: ["Path" as NSString, "Description" as NSString])

                        self.localPaths?.addObject(dict)

                        self.localPaths?.tableView()?.scrollRowToVisible(self.selectedRow(self.localPaths))
                    }
                }
            }

            self.mainView.window?.makeKeyAndOrderFront(self)
        }
    }

    // MARK: DICOM TLS Support

    @IBAction public func editTLS(_ sender: Any?) {
        let aServer = objcMutableDictionary(arrangedObjects(dicomNodes).object(at: selectedRow(dicomNodes)))

        self.TLSEnabled = objcBoolValue(aServer.value(forKey: "TLSEnabled"))
        self.TLSAuthenticated = objcBoolValue(aServer.value(forKey: "TLSAuthenticated"))

        getTLSCertificate()

        let selectedCipherSuites = aServer.value(forKey: "TLSCipherSuites") as AnyObject?

        if (selectedCipherSuites?.count ?? 0) > 0 {
            self.TLSSupportedCipherSuite = selectedCipherSuites as? NSArray
        } else {
            self.TLSSupportedCipherSuite = DICOMTLS.defaultCipherSuites() as NSArray?
        }

        self.TLSUseDHParameterFileURL = objcBoolValue(aServer.value(forKey: "TLSUseDHParameterFileURL"))
        var dhParameterFileURL = aServer.value(forKey: "TLSDHParameterFileURL") as? String
        if dhParameterFileURL == nil {
            dhParameterFileURL = NSHomeDirectory()
        }
        self.TLSDHParameterFileURL = NSURL(fileURLWithPath: dhParameterFileURL!) as URL

        if aServer.value(forKey: "TLSCertificateVerification") != nil {
            self.TLSCertificateVerification = TLSCertificateVerificationType(rawValue: UInt32(bitPattern: objcIntValue(aServer.value(forKey: "TLSCertificateVerification"))))
        } else {
            self.TLSCertificateVerification = IgnorePeerCertificate
        }

        guard let sheet = TLSSettings else { return }
        if let window = mainView.window {
            window.beginSheet(sheet, completionHandler: nil)
        }

        let result = NSApp.runModal(for: sheet)
        sheet.makeFirstResponder(nil)

        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(self)

        if result == .stop {
            aServer.setObject(NSNumber(value: self.TLSEnabled), forKey: "TLSEnabled" as NSString)

            if self.TLSEnabled {
                aServer.setObject(NSNumber(value: self.TLSAuthenticated), forKey: "TLSAuthenticated" as NSString)

                // -setObject:forKey: raised on a nil value, which ended the action here
                // and left SERVERS unwritten; stopping here keeps that.
                guard let cipherSuites = self.TLSSupportedCipherSuite else { return }
                aServer.setObject(cipherSuites, forKey: "TLSCipherSuites" as NSString)

                aServer.setObject(NSNumber(value: self.TLSUseDHParameterFileURL), forKey: "TLSUseDHParameterFileURL" as NSString)
                guard let dhParameterFilePath = (self.TLSDHParameterFileURL as NSURL?)?.path else { return }
                aServer.setObject(dhParameterFilePath, forKey: "TLSDHParameterFileURL" as NSString)

                aServer.setObject(NSNumber(value: Int32(bitPattern: self.TLSCertificateVerification.rawValue)), forKey: "TLSCertificateVerification" as NSString)
            }

            UserDefaults.standard.set(dicomNodes?.arrangedObjects, forKey: "SERVERS")
        }
    }

    @IBAction public func chooseTLSCertificate(_ sender: Any?) {
        let certificates = DDKeychain.keychainAccessCertificatesList()

        if (certificates?.count ?? 0) > 0 {
            SFChooseIdentityPanel.shared().setAlternateButtonTitle(NSLocalizedString("Cancel", comment: "Cancel"))
            let clickedButton = SFChooseIdentityPanel.shared().runModal(forIdentities: certificates, message: NSLocalizedString("Choose a certificate from the following list.", comment: ""))

            if clickedButton == NSApplication.ModalResponse.OK.rawValue {
                if let identity = SFChooseIdentityPanel.shared().identity() {
                    DDKeychain.keychainAccessSetPreferredIdentity(identity.takeUnretainedValue(), forName: self.DICOMTLSUniqueLabelForSelectedServer(), keyUse: Int32(truncatingIfNeeded: CSSM_KEYUSE_ANY))
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
        let label = self.DICOMTLSUniqueLabelForSelectedServer()
        DDKeychain.openCertificatePanel(forLabel: label)
    }

    @objc public func getTLSCertificate() {
        let label = self.DICOMTLSUniqueLabelForSelectedServer()
        var name = DDKeychain.certificateName(forLabel: label)
        let icon = DDKeychain.certificateIcon(forLabel: label)

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

    @objc(DICOMTLSUniqueLabelForSelectedServer)
    public func DICOMTLSUniqueLabelForSelectedServer() -> String? {
        let aServer = arrangedObjects(dicomNodes).object(at: selectedRow(dicomNodes)) as AnyObject
        return DICOMTLS.uniqueLabel(forServerAddress: aServer.value(forKey: "Address") as? String, port: String(format: "%d", objcIntValue(aServer.value(forKey: "Port"))), aeTitle: aServer.value(forKey: "AETitle") as? String)
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

    // MARK: Objective-C messaging on untyped values

    /// -[NSArrayController arrangedObjects] of a controller outlet; empty when the outlet is nil.
    private func arrangedObjects(_ controller: NSArrayController?) -> NSArray {
        return (controller?.arrangedObjects as? NSArray) ?? NSArray()
    }

    /// The selected row of a DNDArrayController's table; 0 when there is none to ask, as a message to nil returned.
    private func selectedRow(_ controller: DNDArrayController?) -> Int {
        return controller?.tableView()?.selectedRow ?? 0
    }
}

/// An element the former code typed NSMutableDictionary*: a static cast, with
/// no runtime check, so a message to it does what the Objective-C message did.
fileprivate func objcMutableDictionary(_ object: Any) -> NSMutableDictionary {
    return unsafeBitCast(object as AnyObject, to: NSMutableDictionary.self)
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

/// What %@ printed for an id: its description, "(null)" for nil.
fileprivate func objcFormatArgument(_ value: Any?) -> NSObject {
    return (value as AnyObject?) as? NSObject ?? ("(null)" as NSString)
}

/// [NSURL URLWithString: value] on a user default: nil for nil or a non-string.
fileprivate func objcURL(_ value: Any?) -> URL? {
    guard let string = value as? String else { return nil }
    return NSURL(string: string) as URL?
}

/// Returns 0 when the value is 2 (WADO) or 3 (the former DICOMweb mode), otherwise 1.
@objc(NotWADOValueTransformer)
public final class NotWADOValueTransformer: ValueTransformer {
    public override class func transformedValueClass() -> AnyClass {
        return NSNumber.self
    }

    public override class func allowsReverseTransformation() -> Bool {
        return false
    }

    public override func transformedValue(_ value: Any?) -> Any? {
        if value != nil {
            let retrieveMode = Float(objcIntValue(value)) // this should be the tag of the retrieve mode
            if retrieveMode == 2 || retrieveMode == 3 {
                return NSNumber(value: 0 as Int32)
            }
            return NSNumber(value: 1 as Int32)
        }
        return NSNumber(value: 1 as Int32)
    }
}
