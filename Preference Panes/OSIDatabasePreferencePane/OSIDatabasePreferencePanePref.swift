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
import IsiXDICOMFile
import IsiXPreferences

/// The Database preference pane.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// the xib's outlets, actions and bindings are those of the former class. The
/// defaults keys and the types written are the former ones.
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSIDatabasePreferencePanePref)
public final class OSIDatabasePreferencePanePref: NSPreferencePane {
    @IBOutlet var locationMatrix: NSMatrix?
    @IBOutlet var locationPathField: NSPathControl?
    @IBOutlet var seriesOrderMatrix: NSMatrix?
    @IBOutlet var reportsMode: NSPopUpButton?

    private var DICOMFieldsArray: NSArray?
    @IBOutlet var dicomFieldsMenu: NSPopUpButton?

    @IBOutlet var commentsDeleteMatrix: NSMatrix?
    @IBOutlet var commentsDeleteText: NSTextField?

    @IBOutlet var commentsGroup: NSTextField?
    @IBOutlet var commentsElement: NSTextField?

    // Auto-Cleaning

    @IBOutlet var older: NSButton?
    @IBOutlet var deleteOriginal: NSButton?
    @IBOutlet var olderType: NSMatrix?
    @IBOutlet var olderThanProduced: NSPopUpButton?
    @IBOutlet var olderThanOpened: NSPopUpButton?

    @IBOutlet var mainWindow: NSWindow?

    /// The nib's top-level objects.
    private var _tlos: NSArray?

    /// Bound in the xib. Setting it shows the group and element of that
    /// auto-fill slot.
    @objc public dynamic var currentCommentsAutoFill: Int32 = 0 {
        didSet {
            let (group, element) = commentsKeys

            if intValue(UserDefaults.standard.string(forKey: group)) > 0 {
                commentsGroup?.stringValue = String(format: "0x%04X", intValue(UserDefaults.standard.string(forKey: group)))
                commentsElement?.stringValue = String(format: "0x%04X", intValue(UserDefaults.standard.string(forKey: element)))
            } else {
                commentsGroup?.stringValue = ""
                commentsElement?.stringValue = ""
            }
        }
    }

    /// Bound in the xib. Setting it stores the comment field auto-fill writes.
    @objc public dynamic var currentCommentsField: Int32 = 0 {
        didSet {
            if currentCommentsField == 1 { UserDefaults.standard.set("comment", forKey: "commentFieldForAutoFill") }
            if currentCommentsField == 2 { UserDefaults.standard.set("comment2", forKey: "commentFieldForAutoFill") }
            if currentCommentsField == 3 { UserDefaults.standard.set("comment3", forKey: "commentFieldForAutoFill") }
            if currentCommentsField == 4 { UserDefaults.standard.set("comment4", forKey: "commentFieldForAutoFill") }
        }
    }

    // Atomic in the former header; bound in the xib and written by the pane,
    // so dynamic for the bindings to see the pane's own changes.
    @objc public dynamic var newUsePatientIDForUID = false
    @objc public dynamic var newUsePatientBirthDateForUID = false
    @objc public dynamic var newUsePatientNameForUID = false

    public override init(bundle: Bundle) {
        // The former -initWithBundle: called -[super init]: the pane loads its
        // nib from the main bundle.
        super.init()
        assumeMainActor(self) { $0.finishInitOnMainActor() }
    }

    private func finishInitOnMainActor() {
        let nib = NSNib(nibNamed: "OSIDatabasePreferencePanePref", bundle: nil)
        var topLevelObjects: NSArray?
        nib?.instantiate(withOwner: self, topLevelObjects: &topLevelObjects)
        _tlos = topLevelObjects

        if let contentView = mainWindow?.contentView {
            mainView = contentView
        }
        mainViewDidLoad()

        NSUserDefaultsController.shared.addObserver(self, forKeyPath: "values.dbFontSize", options: .new, context: nil)
    }

    deinit {
        NSLog("dealloc OSIDatabasePreferencePanePref")

        NSUserDefaultsController.shared.removeObserver(self, forKeyPath: "values.dbFontSize")
    }

    /// The pane's window. `mainView` is declared nonnull, but a pane whose nib
    /// did not load has none.
    private var paneWindow: NSWindow? {
        let view: NSView? = mainView
        return view?.window
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // The defaults controller reports a default on the thread that wrote it.
        let fromDefaults = (object as AnyObject?) === NSUserDefaultsController.shared
        onMainActor {
            if fromDefaults {
                if keyPath == "values.dbFontSize" {
                    // -refreshMatrix: does not read its sender, formerly the pane.
                    if let browser = BrowserController.currentBrowser() {
                        browser.setTableViewRowHeight()
                        browser.refreshMatrix(browser)
                        browser.window?.display()
                    }
                }
            }
        }
    }

    /// Bound in the xib. Displayed in DB window.
    @objc public var ListOfMediaSOPClassUID: NSArray {
        let l = NSMutableArray()

        l.add(NSLocalizedString("Displayed SOP Class UIDs", comment: ""))

        for case let s as String in sortedSyntaxes(DICOMSOPClass.imageSyntaxes()) {
            l.add(String(format: "%@ - %@", s, BrowserController.compressionString(s) ?? "(null)"))
        }

        return l
    }

    /// Bound in the xib.
    @objc public var ListOfMediaSOPClassUIDStored: NSArray {
        let l = NSMutableArray()

        l.add(NSLocalizedString("Stored SOP Class UIDs", comment: ""))

        for case let s as String in sortedSyntaxes(DICOMSOPClass.allSupportedSyntaxes()) {
            l.add(String(format: "%@ - %@", s, BrowserController.compressionString(s) ?? "(null)"))
        }

        return l
    }

    private func sortedSyntaxes(_ syntaxes: [Any]?) -> NSArray {
        ((syntaxes ?? []) as NSArray).sortedArray(using: #selector(NSString.compare(_:))) as NSArray
    }

    /// Tag of the reports menu's label over the report plugins in every localized
    /// nib. The label is found by this tag, not by position or title: the nib puts
    /// a separator before it, and its title is translated.
    private static let reportPluginsLabelTag = -1

    /// Fills the reports menu with the installed report plugins, below the nib's
    /// separator and "Plugins" label. Each plugin item carries its plugin name as
    /// represented object, which is what `setReportMode:` saves; the label is
    /// disabled and only names the group. Without plugins the label and its
    /// separator are taken out.
    @objc public func buildPluginsMenu() {
        guard let reportsMode, let menu = reportsMode.menu else { return }
        for item in menu.items where item.representedObject is String {
            menu.removeItem(item)
        }
        guard let label = menu.items.first(where: { $0.tag == Self.reportPluginsLabelTag && !$0.isSeparatorItem }) else { return }
        let labelIndex = menu.index(of: label)
        let separator = labelIndex > 0 ? menu.items[labelIndex - 1] : nil

        let names = (PluginManager.reportPlugins()?.allKeys ?? [])
            .compactMap { $0 as? String }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        if names.isEmpty {
            menu.removeItem(label)
            if let separator, separator.isSeparatorItem {
                menu.removeItem(separator)
            }
            return
        }

        if names.count == 1 {
            label.title = NSLocalizedString("Plugin", comment: "Reports menu label over a single report plugin")
        }
        reportsMode.autoenablesItems = false
        label.isEnabled = false
        label.target = nil
        label.action = nil

        // Items are added directly: -addItemWithTitle: would first remove an
        // existing item of the same title, such as one of the editors above.
        for name in names {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.indentationLevel = 1
            item.representedObject = name
            menu.addItem(item)
        }
    }

    /// Selects the report choice saved in the preferences: the saved plugin's item
    /// for mode 3, otherwise the item whose tag is the mode.
    private func selectSavedReportMode() {
        let defaults = UserDefaults.standard
        let mode = Int(intValue(defaults.string(forKey: "REPORTSMODE")))
        if mode == 3 {
            // A plugin that is no longer installed leaves nothing selected.
            let plugin = defaults[DatabasePreferences.reportsPlugin]
            reportsMode?.select(reportsMode?.itemArray.first { item in
                (item.representedObject as? String).map { $0 == plugin } ?? false
            })
        } else {
            reportsMode?.selectItem(withTag: mode)
        }
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        var recompute = false

        if newUsePatientBirthDateForUID == false && newUsePatientNameForUID == false && newUsePatientIDForUID == false {
            _ = runAlertPanel(.critical, NSLocalizedString("Patient UID", comment: ""), NSLocalizedString("At least one parameter has to be selected to generate a valid Patient UID. Patient ID will be used.", comment: ""), NSLocalizedString("OK", comment: ""))

            newUsePatientIDForUID = true
        }

        if newUsePatientBirthDateForUID != UserDefaults.standard.bool(forKey: "UsePatientBirthDateForUID") {
            recompute = true
        }

        if newUsePatientNameForUID != UserDefaults.standard.bool(forKey: "UsePatientNameForUID") {
            recompute = true
        }

        if newUsePatientIDForUID != UserDefaults.standard.bool(forKey: "UsePatientIDForUID") {
            recompute = true
        }

        if recompute {
            UserDefaults.standard.set(newUsePatientBirthDateForUID, forKey: "UsePatientBirthDateForUID")
            UserDefaults.standard.set(newUsePatientNameForUID, forKey: "UsePatientNameForUID")
            UserDefaults.standard.set(newUsePatientIDForUID, forKey: "UsePatientIDForUID")

            let wait = WaitRendering(NSLocalizedString("Recomputing Patient UIDs...", comment: ""))
            wait?.showWindow(self)
            wait?.start()

            DicomFile.setDefaults()

            for case let d as DicomDatabase in DicomDatabase.allDatabases() ?? [] {
                DicomDatabase.recomputePatientUIDs(in: d.managedObjectContext)
            }

            BrowserController.currentBrowser()?.refreshDatabase(self)

            wait?.end()
            wait?.close()
        }

        _ = paneWindow?.makeFirstResponder(nil)
    }

    public override func mainViewDidLoad() {
        assumeMainActor(self) { $0.mainViewDidLoadOnMainActor() }
    }

    private func mainViewDidLoadOnMainActor() {
        let defaults = UserDefaults.standard

        //setup GUI

        let locationValue = defaults.integer(forKey: "DEFAULT_DATABASELOCATION")

        locationMatrix?.selectCell(withTag: locationValue)
        let locationPath = defaults.string(forKey: "DEFAULT_DATABASELOCATIONURL") ?? ""
        locationPathField?.url = locationPath.isEmpty ? nil : URL(fileURLWithPath: locationPath)

        seriesOrderMatrix?.selectCell(withTag: defaults.integer(forKey: "SERIESORDER"))

        // COMMENTS
        currentCommentsAutoFill = 0

        if isEqualString(UserDefaults.standard.string(forKey: "commentFieldForAutoFill"), "comment") { currentCommentsField = 1 }
        if isEqualString(UserDefaults.standard.string(forKey: "commentFieldForAutoFill"), "comment2") { currentCommentsField = 2 }
        if isEqualString(UserDefaults.standard.string(forKey: "commentFieldForAutoFill"), "comment3") { currentCommentsField = 3 }
        if isEqualString(UserDefaults.standard.string(forKey: "commentFieldForAutoFill"), "comment4") { currentCommentsField = 4 }

        // REPORTS
        buildPluginsMenu()
        selectSavedReportMode()

        // DATABASE AUTO-CLEANING

        older?.state = defaults.bool(forKey: "AUTOCLEANINGDATE") ? .on : .off
        deleteOriginal?.state = defaults.bool(forKey: "AUTOCLEANINGDELETEORIGINAL") ? .on : .off
        olderType?.cell(withTag: 0)?.state = defaults.bool(forKey: "AUTOCLEANINGDATEPRODUCED") ? .on : .off
        olderType?.cell(withTag: 1)?.state = defaults.bool(forKey: "AUTOCLEANINGDATEOPENED") ? .on : .off
        olderType?.cell(withTag: 2)?.state = defaults.bool(forKey: "AUTOCLEANINGCOMMENTS") ? .on : .off

        commentsDeleteText?.stringValue = defaults.string(forKey: "AUTOCLEANINGCOMMENTSTEXT") ?? ""
        commentsDeleteMatrix?.selectCell(withTag: Int(intValue(defaults.string(forKey: "AUTOCLEANINGDONTCONTAIN"))))
        olderThanProduced?.selectItem(withTag: Int(intValue(defaults.string(forKey: "AUTOCLEANINGDATEPRODUCEDDAYS"))))
        olderThanOpened?.selectItem(withTag: Int(intValue(defaults.string(forKey: "AUTOCLEANINGDATEOPENEDDAYS"))))

        newUsePatientBirthDateForUID = UserDefaults.standard.bool(forKey: "UsePatientBirthDateForUID")
        newUsePatientNameForUID = UserDefaults.standard.bool(forKey: "UsePatientNameForUID")
        newUsePatientIDForUID = UserDefaults.standard.bool(forKey: "UsePatientIDForUID")
    }

    public override func didSelect() {
        assumeMainActor(self) { $0.didSelectOnMainActor() }
    }

    private func didSelectOnMainActor() {
        DICOMFieldsArray = (paneWindow?.windowController as? PreferencesWindowController)?.prepareDICOMFieldsArrays() as NSArray?

        guard let DICOMFieldsMenu = dicomFieldsMenu?.menu else { return }
        DICOMFieldsMenu.autoenablesItems = false
        dicomFieldsMenu?.removeAllItems()

        var item = NSMenuItem()
        item.title = NSLocalizedString("DICOM Fields", comment: "")
        item.isEnabled = false
        DICOMFieldsMenu.addItem(item)
        for field in DICOMFieldsArray ?? NSArray() {
            item = NSMenuItem()
            item.title = (field as? CIADICOMField)?.title() ?? ""
            item.representedObject = field
            DICOMFieldsMenu.addItem(item)
        }
        dicomFieldsMenu?.menu = DICOMFieldsMenu
    }

    @IBAction public func setReportMode(_ sender: Any?) {
        // report mode int value
        // 0 : Microsoft Word
        // 1 : TextEdit
        // 2 : Pages
        // 3 : Plugin
        // 4 : DICOM SR
        // 5 : OO

        let defaults = UserDefaults.standard
        guard let selected = reportsMode?.selectedItem else { return }

        if let plugin = selected.representedObject as? String {
            defaults.set(3, forKey: "REPORTSMODE")
            defaults.set(plugin, for: DatabasePreferences.reportsPlugin)
        } else if selected.tag == Self.reportPluginsLabelTag || selected.isSeparatorItem {
            // The label only names the plugins below it and is never a choice:
            // nothing is saved and the saved choice is shown again.
            selectSavedReportMode()
            return
        } else {
            defaults.set(selected.tag, forKey: "REPORTSMODE")
        }
        NotificationCenter.default.post(name: NSNotification.Name("reportModeChanged"), object: nil)
    }

    @IBAction public func regenerateAutoComments(_ sender: Any?) {
        BrowserController.currentBrowser()?.regenerateAutoComments(nil) // nil == all studies
    }

    /// COMMENTSGROUP/COMMENTSELEMENT for the first auto-fill slot, with the
    /// slot's number after it for the others.
    private var commentsKeys: (group: String, element: String) {
        if currentCommentsAutoFill > 0 {
            return (String(format: "COMMENTSGROUP%d", currentCommentsAutoFill + 1), String(format: "COMMENTSELEMENT%d", currentCommentsAutoFill + 1))
        }
        return ("COMMENTSGROUP", "COMMENTSELEMENT")
    }

    @IBAction public func setAutoComments(_ sender: Any?) {
        // COMMENTS

        let (group, element) = commentsKeys

        var val: UInt32 = 0
        var hexscanner = Scanner(string: commentsGroup?.stringValue ?? "")
        val = UInt32(clamping: hexscanner.scanUInt64(representation: .hexadecimal) ?? 0)

        if val > 0 {
            UserDefaults.standard.set(Int(val), forKey: group)

            val = 0
            hexscanner = Scanner(string: commentsElement?.stringValue ?? "")
            val = UInt32(clamping: hexscanner.scanUInt64(representation: .hexadecimal) ?? 0)
            UserDefaults.standard.set(Int(val), forKey: element)
        } else {
            UserDefaults.standard.set(nil as Any?, forKey: element)
            UserDefaults.standard.set(nil as Any?, forKey: group)
        }

        let slot = currentCommentsAutoFill
        currentCommentsAutoFill = slot
    }

    @IBAction public func setDICOMFieldMenu(_ sender: Any?) {
        let title = ((sender as? NSPopUpButton)?.selectedItem?.title ?? "") as NSString
        commentsGroup?.stringValue = title.substring(with: NSRange(location: 1, length: 6))
        commentsElement?.stringValue = title.substring(with: NSRange(location: 8, length: 6))

        setAutoComments(sender)
    }

    /// Switching the kiosk mode on deletes the whole database at the next
    /// start, so it asks first.
    @IBAction public func eraseEntireDatabaseChanged(_ sender: Any?) {
        guard let button = sender as? NSButton, button.state == .on else { return }
        let answer = HorosAlertPanel.runInformational(
            title: NSLocalizedString("Delete the Entire Database at Each Startup?", comment: "Kiosk mode confirmation"),
            message: NSLocalizedString("Every time IsiX DICOM Viewer starts, all the studies in the default database will be deleted. This cannot be undone.",
                                       comment: "Kiosk mode confirmation"),
            defaultButton: NSLocalizedString("Cancel", comment: ""), alternateButton: NSLocalizedString("OK", comment: ""), otherButton: nil)
        if answer != HorosAlertPanel.alternateResponse {
            button.state = .off
            UserDefaults.standard.set(false, forKey: "eraseEntireDBAtStartup")
        }
    }

    @IBAction public func databaseCleaning(_ sender: Any?) {
        let defaults = UserDefaults.standard

        if (olderType?.cell(withTag: 0)?.state ?? .off) == .off && (olderType?.cell(withTag: 1)?.state ?? .off) == .off {
            older?.state = .off
        }

        defaults.set(isSet(older?.state), forKey: "AUTOCLEANINGDATE")
        defaults.set(isSet(deleteOriginal?.state), forKey: "AUTOCLEANINGDELETEORIGINAL")

        defaults.set(isSet(olderType?.cell(withTag: 0)?.state), forKey: "AUTOCLEANINGDATEPRODUCED")
        defaults.set(isSet(olderType?.cell(withTag: 1)?.state), forKey: "AUTOCLEANINGDATEOPENED")
        defaults.set(isSet(olderType?.cell(withTag: 2)?.state), forKey: "AUTOCLEANINGCOMMENTS")

        defaults.set(commentsDeleteMatrix?.selectedCell()?.tag ?? 0, forKey: "AUTOCLEANINGDONTCONTAIN")
        defaults.set(commentsDeleteText?.stringValue, forKey: "AUTOCLEANINGCOMMENTSTEXT")

        defaults.set(olderThanProduced?.selectedItem?.tag ?? 0, forKey: "AUTOCLEANINGDATEPRODUCEDDAYS")
        defaults.set(olderThanOpened?.selectedItem?.tag ?? 0, forKey: "AUTOCLEANINGDATEOPENEDDAYS")
    }

    @IBAction public func setSeriesOrder(_ sender: Any?) {
        UserDefaults.standard.set((sender as? NSControl)?.selectedCell()?.tag ?? 0, forKey: "SERIESORDER")
    }

    @IBAction public func setLocation(_ sender: Any?) {
        let control = sender as? NSControl

        if control?.selectedCell()?.tag == 1 {
            if isEqualString(UserDefaults.standard.string(forKey: "DEFAULT_DATABASELOCATIONURL"), "") { setLocationURL(self) }

            if !isEqualString(UserDefaults.standard.string(forKey: "DEFAULT_DATABASELOCATIONURL"), "") {
                var isDir: ObjCBool = false

                if !FileManager.default.fileExists(atPath: UserDefaults.standard.string(forKey: "DEFAULT_DATABASELOCATIONURL") ?? "", isDirectory: &isDir) {
                    _ = runAlertPanel(.warning, "IsiX DICOM Viewer Database Location", "This location is not valid. Select another location.", "OK")

                    locationMatrix?.selectCell(withTag: 0)
                }
            }
        }

        UserDefaults.standard.set(control?.selectedCell()?.tag ?? 0, forKey: "DEFAULT_DATABASELOCATION")

        UserDefaults.standard.synchronize()

        (paneWindow?.windowController as? PreferencesWindowController)?.reopenDatabase()

        paneWindow?.makeKeyAndOrderFront(self)

        // TODO - It may be appropriate to request user to restart Horos, or upon trying to set a new location warn on iCloud Sync Issue.
        // This should be done before setting the new path

        // Workaround (weak)
        // On Horos initialization this will make Horos to check if local database folder is being synchronized over iCloud
        UserDefaults.standard.set(nil as Any?, forKey: "ICLOUD_DRIVE_SYNC_RISK_USER_IGNORED")
        UserDefaults.standard.synchronize()
    }

    @IBAction public func resetDate(_ sender: Any?) {
        let dateFormat = DateFormatter()
        dateFormat.dateStyle = .short
        dateFormat.timeStyle = .short
        UserDefaults.standard.set(dateFormat.dateFormat, forKey: "DBDateFormat2")
    }

    @IBAction public func resetDateOfBirth(_ sender: Any?) {
        let dateFormat = DateFormatter()
        dateFormat.dateStyle = .short
        UserDefaults.standard.set(dateFormat.dateFormat, forKey: "DBDateOfBirthFormat2")
    }

    @IBAction public func setLocationURL(_ sender: Any?) {
        let oPanel = NSOpenPanel()

        oPanel.canChooseFiles = false
        oPanel.canChooseDirectories = true

        oPanel.begin { result in
            if result == .OK {
                guard let selected = oPanel.url, SandboxFileAccess.remember(selected) else { return }
                // A Horos database becomes the location only after the user has
                // read what that does to it, and then as itself; importing or
                // cancelling keeps the location as it was.
                guard let confirmed = ForeignDatabaseChoice.confirmedPath(forChosenPath: selected.path) else { return }
                var location = confirmed as NSString

                #if !MACAPPSTORE
                if DatabaseLocation.isOwnDataDirectoryName(location.lastPathComponent) {
                    NSLog("%@", location.lastPathComponent)
                    location = location.deletingLastPathComponent as NSString
                }

                if location.lastPathComponent == "DATABASE" && DatabaseLocation.isOwnDataDirectoryName((location.deletingLastPathComponent as NSString).lastPathComponent) {
                    NSLog("%@", location.lastPathComponent)
                    location = ((location.deletingLastPathComponent as NSString).deletingLastPathComponent) as NSString
                }

                #endif
                self.locationPathField?.url = NSURL.fileURL(withPath: location as String)
                UserDefaults.standard.set(location, forKey: "DEFAULT_DATABASELOCATIONURL")
                UserDefaults.standard.set(1, forKey: "DEFAULT_DATABASELOCATION")
                self.locationMatrix?.selectCell(withTag: 1)
            } else {
                self.locationPathField?.url = nil
                UserDefaults.standard.set("", forKey: "DEFAULT_DATABASELOCATIONURL")
                UserDefaults.standard.set(0, forKey: "DEFAULT_DATABASELOCATION")
                self.locationMatrix?.selectCell(withTag: 0)
            }

            UserDefaults.standard.synchronize()

            (self.paneWindow?.windowController as? PreferencesWindowController)?.reopenDatabase()

            self.paneWindow?.makeKeyAndOrderFront(self)

            // TODO - It may be appropriate to request user to restart Horos, or upon trying to set a new location warn on iCloud Sync Issue.
            // This should be done before setting the new path

            // Workaround (weak)
            // On Horos initialization this will make Horos to check if local database folder is being synchronized over iCloud
            UserDefaults.standard.set(nil as Any?, forKey: "ICLOUD_DRIVE_SYNC_RISK_USER_IGNORED")
            UserDefaults.standard.synchronize()
        }
    }

    /// Bound in the xib.
    @objc public var useSeriesDescription: Bool {
        get { UserDefaults.standard.bool(forKey: "useSeriesDescription") }
        set { UserDefaults.standard.set(newValue, forKey: "useSeriesDescription") }
    }

    /// Bound in the xib.
    @objc public var splitMultiEchoMR: Bool {
        get { UserDefaults.standard.bool(forKey: "splitMultiEchoMR") }
        set { UserDefaults.standard.set(newValue, forKey: "splitMultiEchoMR") }
    }
}

// MARK: - The former messages to `id`

/// -intValue sent to a string that may be nil.
private func intValue(_ value: String?) -> Int32 {
    (value as NSString?)?.intValue ?? 0
}

/// -isEqualToString: sent to a string that may be nil.
private func isEqualString(_ value: String?, _ string: String) -> Bool {
    (value as NSString?)?.isEqual(to: string) ?? false
}

/// A control state as the BOOL the former -setBool:forKey: received: any
/// non-zero state is YES.
private func isSet(_ state: NSControl.StateValue?) -> Bool {
    (state?.rawValue ?? 0) != 0
}

// MARK: - NSRunAlertPanel and its variants

/// NSRunAlertPanel (.warning) and NSRunCriticalAlertPanel (.critical) are
/// variadic, which Swift cannot call. They build this alert, with a single
/// button here, and answered NSAlertDefaultReturn (1). The messages passed
/// have no format arguments.
@MainActor private func runAlertPanel(_ style: NSAlert.Style, _ title: String, _ message: String, _ defaultButton: String) -> Int {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: defaultButton)
    return alert.runModal() == .alertFirstButtonReturn ? 1 : -1
}
