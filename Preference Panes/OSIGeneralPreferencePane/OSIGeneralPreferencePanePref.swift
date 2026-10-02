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
import PreferencePanes

/// Enables the quality slider of a compression row for JPEG 2000 (3) and JPEG-LS (4).
@objc(IsQualityEnabled)
final class IsQualityEnabled: ValueTransformer {
    override class func transformedValueClass() -> AnyClass {
        return NSNumber.self
    }

    override class func allowsReverseTransformation() -> Bool {
        return false
    }

    override func transformedValue(_ item: Any?) -> Any? {
        // -intValue of whatever the row holds, 0 for nil.
        let value = (item as? NSNumber)?.int32Value ?? (item as? NSString)?.intValue ?? 0
        if value == 3 || value == 4 {
            return NSNumber(value: true)
        } else {
            return NSNumber(value: false)
        }
    }
}

/// The General preferences pane.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors
/// and OSIGeneralPreferencePanePref.h are those of the former class. Its
/// xib connects the outlets by name.
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSIGeneralPreferencePanePref)
public final class OSIGeneralPreferencePanePref: NSPreferencePane, NSTableViewDelegate {
    /// What -willUnselect left for +applyLanguagesIfNeeded, when quitting.
    // Set by the pane's languages table and applied by AppController when it
    // quits, on the main thread.
    private static var languagesToMoveWhenQuitting: NSArray?

    /// +initialize registered the transformer on the first message to the
    /// class; Swift has no +initialize, so every entry point runs this once.
    nonisolated private static let registerTransformers: Void = {
        let a = IsQualityEnabled()
        ValueTransformer.setValueTransformer(a, forName: NSValueTransformerName("IsQualityEnabled"))
    }()

    @IBOutlet var compressionSettingsWindow: NSWindow?
    private var compressionSettingsCopy: [Any]?
    private var compressionSettingsLowResCopy: [Any]?
    @IBOutlet var mainWindow: NSWindow?
    @IBOutlet var CheckUpdatesOnOff: NSButton?

    /// Retained, as it was; the xib's language table binds to self.languages.
    @objc public dynamic var languages: NSMutableArray?

    private var topLevelObjects: NSArray?

    /// -[NSPreferencePane init]: no nib, as the inherited initializer did.
    public override init() {
        _ = OSIGeneralPreferencePanePref.registerTransformers
        super.init()
    }

    public override init(bundle: Bundle) {
        _ = OSIGeneralPreferencePanePref.registerTransformers
        // The former initializer called -[super init], not -initWithBundle:.
        super.init()
        assumeMainActor(self) { $0.finishInitOnMainActor() }
    }

    private func finishInitOnMainActor() {
        // Localization resources remain inside the signed bundle.
        languages = HorosLanguageRows(Bundle.main, UserDefaults.standard)

        let nib = NSNib(nibNamed: "OSIGeneralPreferencePanePref", bundle: nil)
        nib?.instantiate(withOwner: self, topLevelObjects: &topLevelObjects)

        // mainView is declared nonnull, but a missing nib left it nil and the
        // preferences window reports that pane instead of showing it.
        perform(#selector(setter: NSPreferencePane.mainView), with: mainWindow?.contentView)
        mainViewDidLoad()
    }

    @objc(tableView:viewForTableColumn:row:)
    public func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        _ = OSIGeneralPreferencePanePref.registerTransformers
        guard let column = column else { return nil }
        if let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView {
            return cell
        }

        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: column.width, height: tableView.rowHeight))
        cell.identifier = column.identifier
        let control: NSControl
        var binding = NSBindingName.value
        if column.identifier.rawValue == "quality" {
            // NSSliderCell alone draws against the table's bounds on recent AppKit.
            // A real slider view keeps both drawing and tracking inside this row.
            control = NSSlider(frame: .zero)
            control.cell = (column.dataCell as AnyObject).copy() as? NSCell
            control.bind(.enabled, to: cell, withKeyPath: "objectValue.compression",
                         options: [.valueTransformerName: "IsQualityEnabled"])
        } else if column.identifier.rawValue == "compression" {
            control = NSPopUpButton(frame: .zero, pullsDown: false)
            control.cell = (column.dataCell as AnyObject).copy() as? NSCell
            binding = .selectedTag
        } else {
            let text = NSTextField(labelWithString: "")
            text.alignment = .center
            text.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            cell.textField = text
            control = text
        }
        control.target = self
        control.action = #selector(changeCompressionSetting(_:))
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setAccessibilityLabel(column.headerCell.stringValue)
        cell.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            control.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            control.heightAnchor.constraint(equalToConstant: 20),
        ])
        // The existing table content binding supplies the row dictionary. Binding
        // through objectValue also follows reuse and preserves defaults persistence.
        control.bind(binding, to: cell, withKeyPath: "objectValue." + column.identifier.rawValue, options: nil)
        return cell
    }

    @objc(changeCompressionSetting:)
    func changeCompressionSetting(_ sender: NSControl) {
        var view = sender.superview
        while let v = view, !(v is NSTableView) { view = v.superview }
        guard let table = view else { return }

        guard let controller = table.infoForBinding(.content)?[.observedObject] as? NSArrayController else { return }
        guard let binding = controller.infoForBinding(.contentArray) else { return }
        // The control binding has updated this row's dictionary. Defaults stores
        // the array as a compound value, so write that value back after the edit.
        if let observed = binding[.observedObject] as? NSObject, let keyPath = binding[.observedKeyPath] as? String {
            observed.setValue(controller.content, forKeyPath: keyPath)
        }
    }

    @IBAction @objc(resetPreferences:)
    public func resetPreferences(_ sender: Any?) {
        let result = HorosAlertPanel.runInformational(
            title: NSLocalizedString("Reset Preferences", comment: ""),
            message: NSLocalizedString("Are you sure you want to reset ALL preferences of Isis DICOM Viewer? All the preferences will be reseted to their default values.", comment: ""),
            defaultButton: NSLocalizedString("Cancel", comment: ""), alternateButton: NSLocalizedString("OK", comment: ""), otherButton: nil)

        if result == HorosAlertPanel.alternateResponse {
            for k in UserDefaults.standard.dictionaryRepresentation().keys {
                UserDefaults.standard.removeObject(forKey: k)
            }

            UserDefaults.standard.synchronize()
        }
    }

    @IBAction @objc(savePreferences:)
    func savePreferences(_ sender: Any?) {
        UserDefaults.standard.synchronize()

        let save = NSSavePanel()

        save.allowedContentTypes = [UTType(filenameExtension: "plist")!]
        save.nameFieldStringValue = "Isis-DICOM-Viewer-Preferences.plist"

        if save.runModal() == .OK {
            let defaultsPreferences = DefaultsOsiriX.getDefaults()
            let customizedPreferences = NSMutableDictionary()

            for k in UserDefaults.standard.dictionaryRepresentation().keys {
                let value = UserDefaults.standard.object(forKey: k)
                let defaultValue = defaultsPreferences?.object(forKey: k)
                if let value = value, defaultValue == nil || !(value as AnyObject).isEqual(defaultValue) {
                    customizedPreferences.setObject(value, forKey: k as NSString)
                }
            }

            if let url = save.url {
                customizedPreferences.write(to: url, atomically: true)
            }
        }
    }

    @objc(errorMessage:)
    class func errorMessage(_ url: URL?) {
        _ = HorosAlertPanel.run(
            title: NSLocalizedString("Preferences", comment: ""),
            message: String(format: NSLocalizedString("Failed to download and synchronize preferences from this URL: %@", comment: ""),
                            url?.absoluteString ?? "(null)"),
            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    /// Also run on a thread of its own (the URL sync, and AppController at
    /// launch): it only writes the user defaults and reports on the main thread.
    @objc(addPreferencesFromURL:)
    nonisolated class func addPreferences(from url: URL?) {
        _ = registerTransformers
        autoreleasepool {
            var succeed = false

            if let url = url {
                NSLog("--- loading preferences from URL: %@", url as NSURL)

                do {
                    try HorosObjCException.perform {
                        var activated = false
                        if !Thread.isMainThread {
                            activated = UserDefaults.standard.bool(forKey: "SyncPreferencesFromURL")
                        }

                        if let customizedPreferences = NSDictionary(contentsOf: url) {
                            for (key, value) in customizedPreferences {
                                // A property list's keys are strings.
                                guard let key = key as? String else { continue }
                                UserDefaults.standard.set(value, forKey: key)
                            }

                            succeed = true

                            if !Thread.isMainThread {
                                UserDefaults.standard.set(url.absoluteString, forKey: "SyncPreferencesURL")
                                UserDefaults.standard.set(activated, forKey: "SyncPreferencesFromURL")
                            }
                        }
                    }
                } catch {
                    if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                        _N2LogExceptionImpl(exception, false, "+[OSIGeneralPreferencePanePref addPreferencesFromURL:]")
                    }
                }
                NSLog("--- loading preferences from URL: %@ - DONE", url as NSURL)
            }

            if !succeed {
                (OSIGeneralPreferencePanePref.self as AnyObject).performSelector(
                    onMainThread: #selector(errorMessage(_:)), with: url, waitUntilDone: false)
            }
        }
    }

    @IBAction @objc(refreshPreferencesURLSync:)
    func refreshPreferencesURLSync(_ sender: Any?) {
        mainView.window?.makeFirstResponder(nil)

        // +[NSURL URLWithString:] answered nil for a nil string.
        if UserDefaults.standard.string(forKey: "SyncPreferencesURL").flatMap({ NSURL(string: $0) }) == nil {
            _ = HorosAlertPanel.runInformational(
                title: NSLocalizedString("Sync Preferences", comment: ""),
                message: NSLocalizedString("The provided URL doesn't seem correct. Check it's validity.", comment: ""),
                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        } else {
            let result = HorosAlertPanel.runInformational(
                title: NSLocalizedString("Sync Preferences", comment: ""),
                message: NSLocalizedString("Are you sure you want to replace  current preferences with the preferences stored at this URL? You cannot undo this operation.", comment: ""),
                defaultButton: NSLocalizedString("Cancel", comment: ""), alternateButton: NSLocalizedString("OK", comment: ""), otherButton: nil)

            if result == HorosAlertPanel.alternateResponse {
                Thread.detachNewThreadSelector(#selector(OSIGeneralPreferencePanePref.addPreferences(from:)),
                                               toTarget: OSIGeneralPreferencePanePref.self,
                                               with: UserDefaults.standard.string(forKey: "SyncPreferencesURL").flatMap { NSURL(string: $0) })
            }
        }
    }

    @IBAction @objc(loadPreferences:)
    func loadPreferences(_ sender: Any?) {
        UserDefaults.standard.synchronize()

        let open = NSOpenPanel()

        open.canChooseFiles = true
        open.canChooseDirectories = false
        open.canCreateDirectories = false
        open.allowsMultipleSelection = false
        open.message = NSLocalizedString("Select the preferences file (plist) to load:", comment: "")

        if open.runModal() == .OK {
            let result = HorosAlertPanel.runInformational(
                title: NSLocalizedString("Load Preferences", comment: ""),
                message: NSLocalizedString("Are you sure you want to replace  current preferences with the preferences stored in this file? You cannot undo this operation.", comment: ""),
                defaultButton: NSLocalizedString("Cancel", comment: ""), alternateButton: NSLocalizedString("OK", comment: ""), otherButton: nil)

            if result == HorosAlertPanel.alternateResponse {
                OSIGeneralPreferencePanePref.addPreferences(from: open.url)
            }
        }

        UserDefaults.standard.synchronize()
    }

    deinit {
        NSLog("dealloc OSIGeneralPreferencePanePref")
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        mainView.window?.makeFirstResponder(nil)

        var enabled = false

        for d in languages ?? [] {
            if ((d as AnyObject).value(forKey: "active") as? NSNumber)?.boolValue == true {
                enabled = true
            }
        }

        // At least one language must be active !
        if !enabled, let languages = languages, languages.count > 0 {
            (languages.object(at: 0) as AnyObject).setValue(NSNumber(value: true), forKey: "active")
        }

        OSIGeneralPreferencePanePref.languagesToMoveWhenQuitting = languages?.copy() as? NSArray
    }

    @objc public class func applyLanguagesIfNeeded() {
        _ = registerTransformers
        HorosApplyLanguageRows(languagesToMoveWhenQuitting as? [Any], UserDefaults.standard)
        languagesToMoveWhenQuitting = nil
    }

    @IBAction @objc(endEditCompressionSettings:)
    public func endEditCompressionSettings(_ sender: Any?) {
        let tag = OSIGeneralPreferencePanePref.tag(of: sender)
        compressionSettingsWindow?.orderOut(sender)
        if let window = compressionSettingsWindow {
            window.sheetParent?.endSheet(window, returnCode: NSApplication.ModalResponse(rawValue: tag))
        }

        if tag == 1 {
        } else {
            UserDefaults.standard.set(compressionSettingsCopy, forKey: "CompressionSettings")
            UserDefaults.standard.set(compressionSettingsLowResCopy, forKey: "CompressionSettingsLowRes")
        }

        compressionSettingsCopy = nil
        compressionSettingsLowResCopy = nil
    }

    @IBAction @objc(editCompressionSettings:)
    public func editCompressionSettings(_ sender: Any?) {
        if (UserDefaults.standard.array(forKey: "CompressionSettings")?.count ?? 0) < 14 {
            NSLog("*** reset compression settings")
            UserDefaults.standard.removeObject(forKey: "CompressionSettings")
        }

        if (UserDefaults.standard.array(forKey: "CompressionSettingsLowRes")?.count ?? 0) < 14 {
            NSLog("*** reset compression settings")
            UserDefaults.standard.removeObject(forKey: "CompressionSettingsLowRes")
        }

        compressionSettingsCopy = UserDefaults.standard.array(forKey: "CompressionSettings")
        compressionSettingsLowResCopy = UserDefaults.standard.array(forKey: "CompressionSettingsLowRes")

        // The button sending this is in mainView, so it has a window.
        if let window = compressionSettingsWindow, let docWindow = mainView.window {
            docWindow.beginSheet(window, completionHandler: nil)
        }
    }

    /// -[sender tag], 0 for nil.
    private static func tag(of sender: Any?) -> Int {
        if let view = sender as? NSView { return view.tag }
        if let item = sender as? NSMenuItem { return item.tag }
        return 0
    }
}
