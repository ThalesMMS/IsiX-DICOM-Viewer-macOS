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
import PreferencePanes

/// The Protocols preference pane: hanging protocols per modality, kept in the
/// HANGINGPROTOCOLS default.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors and
/// the xib's outlets, actions and bindings are those of the former class.
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSIHangingPreferencePanePref)
public final class OSIHangingPreferencePanePref: NSPreferencePane {
    // Stored properties are object references or scalars only, hence NSString
    // rather than String: tools/probe-hanging-protocols.m makes the pane with
    // class_createInstance, which zeroes them without running an initializer,
    // and reads the `hangingProtocols` instance variable by name.

    /// The copy of HANGINGPROTOCOLS the pane edits (#618).
    private var hangingProtocols: NSMutableDictionary?
    /// What is stored cannot be edited, so it is not written back.
    private var hangingProtocolsUnusable = false

    @IBOutlet var mainWindow: NSWindow?
    @IBOutlet var windowsTilingPopup: NSMenu?
    @IBOutlet var imageTilingPopup: NSMenu?
    @IBOutlet var WLWWPopup: NSMenu?
    @IBOutlet var arrayController: NSArrayController?

    /// Retained by the former class as well, so the sheet outlives the nib's array.
    @IBOutlet var addWLWWWindow: NSWindow?
    @IBOutlet var newHangingProtocolButton: NSButton?

    private var currentWLWWProtocol: NSMutableDictionary?
    /// The nib's top-level objects.
    private var _tlos: NSArray?

    /// Bound in the xib; its setter also announces `currentHangingProtocol`.
    @objc public dynamic var modalityForHangingProtocols: NSString? {
        willSet {
            _ = paneWindow?.makeFirstResponder(nil)
            willChangeValue(forKey: "currentHangingProtocol")
        }
        didSet {
            didChangeValue(forKey: "currentHangingProtocol")
        }
    }

    /// Atomic and retained in the former header.
    @objc public dynamic var WLWWNewName: NSString?
    @objc public dynamic var WLnew: NSNumber?
    @objc public dynamic var WWnew: NSNumber?

    public override init(bundle: Bundle) {
        // The former -initWithBundle: called -[super init]: the pane loads its
        // nib from the main bundle.
        super.init()
        assumeMainActor(self) { $0.finishInitOnMainActor() }
    }

    private func finishInitOnMainActor() {
        let nib = NSNib(nibNamed: "OSIHangingPreferencePanePref", bundle: nil)
        var topLevelObjects: NSArray?
        nib?.instantiate(withOwner: self, topLevelObjects: &topLevelObjects)
        _tlos = topLevelObjects

        if let contentView = mainWindow?.contentView {
            mainView = contentView
        }
        mainViewDidLoad()

        // Windows/Image/WLWW menus
        let tilingMenu = AppController.shared()?.imageTilingMenu()

        windowsTilingPopup?.removeAllItems()
        imageTilingPopup?.removeAllItems()

        for item in tilingMenu?.items ?? [] {
            windowsTilingPopup?.addItem(item.copy() as! NSMenuItem)
            imageTilingPopup?.addItem(item.copy() as! NSMenuItem)
        }

        windowsTilingPopup?.addItem(NSMenuItem.separator())
        windowsTilingPopup?.addItem(withTitle: NSLocalizedString("All series", comment: ""), action: nil, keyEquivalent: "")
        windowsTilingPopup?.items.last?.tag = 1000

        for item in windowsTilingPopup?.items ?? [] {
            item.action = nil
        }

        for item in imageTilingPopup?.items ?? [] {
            item.action = nil
        }

        buildWLWWMenu()
    }

    deinit {
        NSLog("dealloc OSIHangingPreferencePanePref")
    }

    /// The pane's window. `mainView` is declared nonnull, but it is nil in a
    /// pane made without its nib (tools/probe-hanging-protocols.m).
    private var paneWindow: NSWindow? {
        let view: NSView? = mainView
        return view?.window
    }

    // MARK: - WL/WW menu tags

    @objc(convertWLWWToMenuTag:)
    public class func convertWLWWToMenuTag(_ hangingProtocol: NSMutableDictionary?) {
        guard let hangingProtocol else { return }

        if floatValue(hangingProtocol.object(forKey: "WL")) == 0 && floatValue(hangingProtocol.object(forKey: "WW")) == 0 {
            hangingProtocol.setObject(NSNumber(value: Int32(100)), forKey: "WLWW" as NSString) // Default
            return
        }

        if floatValue(hangingProtocol.object(forKey: "WL")) == 1 && floatValue(hangingProtocol.object(forKey: "WW")) == 1 {
            hangingProtocol.setObject(NSNumber(value: Int32(101)), forKey: "WLWW" as NSString) // Full Dynamic
            return
        }

        let wlwwDict = UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?
        let sortedKeys = sortedPresetNames(wlwwDict)

        for case let key as NSString in sortedKeys {
            let a = wlwwDict?.object(forKey: key) as? NSArray

            if floatValue(hangingProtocol.object(forKey: "WL")) == floatValue(a?.object(at: 0))
                && floatValue(hangingProtocol.object(forKey: "WW")) == floatValue(a?.object(at: 1)) {
                hangingProtocol.setObject(NSNumber(value: UInt(sortedKeys.index(of: key) + 1)), forKey: "WLWW" as NSString)
                return
            }
        }

        hangingProtocol.setObject(NSNumber(value: Int32(0)), forKey: "WLWW" as NSString)
    }

    @objc(convertMenuTagToWLWW:)
    public class func convertMenuTagToWLWW(_ hangingProtocol: NSMutableDictionary?) {
        guard let hangingProtocol, hangingProtocol.object(forKey: "WLWW") != nil else { return }

        let tag = intValue(hangingProtocol.object(forKey: "WLWW"))

        if tag == 100 || tag == 0 {
            hangingProtocol.setObject(NSNumber(value: Int32(0)), forKey: "WL" as NSString) // Default
            hangingProtocol.setObject(NSNumber(value: Int32(0)), forKey: "WW" as NSString)
            hangingProtocol.removeObject(forKey: "WLWW")
            return
        }

        if tag == 101 {
            hangingProtocol.setObject(NSNumber(value: Int32(1)), forKey: "WL" as NSString) // Full
            hangingProtocol.setObject(NSNumber(value: Int32(1)), forKey: "WW" as NSString)
            hangingProtocol.removeObject(forKey: "WLWW")
            return
        }

        let wlwwDict = UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?
        let sortedKeys = sortedPresetNames(wlwwDict)

        if tag > 0 && Int(tag) <= sortedKeys.count {
            let key = sortedKeys.object(at: Int(tag) - 1)
            let a = wlwwDict?.object(forKey: key) as? NSArray

            // A preset that is not an array made the former -setObject:forKey:
            // raise on nil; WL and WW are left as they are instead.
            if let a {
                hangingProtocol.setObject(a.object(at: 0), forKey: "WL" as NSString)
                hangingProtocol.setObject(a.object(at: 1), forKey: "WW" as NSString)
            }
            hangingProtocol.removeObject(forKey: "WLWW")
            return
        }

        hangingProtocol.removeObject(forKey: "WLWW")
    }

    @objc(AddCurrentWLWW:)
    public func AddCurrentWLWW(_ sender: NSMutableDictionary?) {
        WLWWNewName = NSLocalizedString("Unnamed", comment: "") as NSString

        currentWLWWProtocol = sender

        // Swift cannot pass a nil window; the pane always has one once it is shown.
        if let addWLWWWindow, let window = paneWindow {
            window.beginSheet(addWLWWWindow, completionHandler: nil)
        }
    }

    @IBAction public func endNameWLWW(_ sender: Any?) {
        _ = addWLWWWindow?.makeFirstResponder(nil)

        let tag = (sender as? NSView)?.tag ?? (sender as? NSMenuItem)?.tag ?? 0

        if tag != 0 { // User clicks OK Button
            guard let WLnew, let WWnew else {
                _ = runAlertPanel(.critical, NSLocalizedString("WL / WW Error", comment: ""), NSLocalizedString("Provide values for WL and WW.", comment: ""), NSLocalizedString("OK", comment: ""), nil)
                return
            }

            let iwl = WLnew.floatValue
            var iww = WWnew.floatValue
            if iww < 1 { iww = 1 }

            if let name = WLWWNewName, name.length > 0 {
                let presetsDict = (UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?)?.mutableCopy() as? NSMutableDictionary

                if presetsDict?.value(forKey: name as String) != nil {
                    if runAlertPanel(.informational, NSLocalizedString("WL / WW", comment: ""), NSLocalizedString("Another WL/WW setting with this name already exists. Are you sure you want to replace it with this one?", comment: ""), NSLocalizedString("OK", comment: ""), NSLocalizedString("Cancel", comment: "")) != alertDefaultReturn {
                        return
                    }
                }

                presetsDict?.setObject(NSArray(objects: NSNumber(value: iwl), NSNumber(value: iww)), forKey: name)
                UserDefaults.standard.set(presetsDict, forKey: "WLWW3")

                buildWLWWMenu()

                currentWLWWProtocol?.setValue(NSNumber(value: iwl), forKey: "WL")
                currentWLWWProtocol?.setValue(NSNumber(value: iww), forKey: "WW")

                let sortedKeys = OSIHangingPreferencePanePref.sortedPresetNames(presetsDict)

                for case let key as NSString in sortedKeys {
                    let a = presetsDict?.object(forKey: key) as? NSArray

                    if floatValue(currentWLWWProtocol?.object(forKey: "WL")) == floatValue(a?.object(at: 0))
                        && floatValue(currentWLWWProtocol?.object(forKey: "WW")) == floatValue(a?.object(at: 1)) {
                        currentWLWWProtocol?.setObject(NSNumber(value: UInt(sortedKeys.index(of: key) + 1)), forKey: "WLWW" as NSString)
                        break
                    }
                }
            } else {
                _ = runAlertPanel(.critical, NSLocalizedString("WL / WW Error", comment: ""), NSLocalizedString("Provide a name for this setting.", comment: ""), NSLocalizedString("OK", comment: ""), nil)
                return
            }
        } else {
            currentWLWWProtocol?.setValue(NSNumber(value: Int32(0)), forKey: "WL")
            currentWLWWProtocol?.setValue(NSNumber(value: Int32(0)), forKey: "WW")
            currentWLWWProtocol?.setValue(NSNumber(value: Int32(100)), forKey: "WLWW") // Default
        }

        addWLWWWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        currentWLWWProtocol = nil
    }

    /// Bound in the xib (`self.currentHangingProtocol`): the protocols of the
    /// selected modality, the very array the pane edits.
    @objc public var currentHangingProtocol: NSArray? {
        guard let modality = modalityForHangingProtocols else { return nil }
        let a = hangingProtocols?.object(forKey: modality) as? NSArray

        for case let d as NSMutableDictionary in a ?? NSArray() {
            if intValue(d.value(forKey: "NumberOfComparativeToDisplay")) <= 0 {
                d.setValue(NSNumber(value: Int32(1)), forKey: "NumberOfComparativeToDisplay")
            }
        }

        return a
    }

    @objc public func buildWLWWMenu() {
        WLWWPopup?.removeAllItems()

        let sortedKeys = OSIHangingPreferencePanePref.sortedPresetNames(UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?)

        WLWWPopup?.addItem(withTitle: NSLocalizedString("Default WL & WW", comment: ""), action: nil, keyEquivalent: "")
        lastWLWWItem?.tag = 100

        WLWWPopup?.addItem(withTitle: NSLocalizedString("Full dynamic", comment: ""), action: nil, keyEquivalent: "")
        lastWLWWItem?.tag = 101

        WLWWPopup?.addItem(withTitle: NSLocalizedString("Other", comment: ""), action: nil, keyEquivalent: "")
        lastWLWWItem?.tag = 0

        WLWWPopup?.addItem(NSMenuItem.separator())

        for i in 0..<sortedKeys.count {
            WLWWPopup?.addItem(withTitle: String(format: "%@", sortedKeys.object(at: i) as! CVarArg), action: nil, keyEquivalent: "")
            lastWLWWItem?.tag = i + 1
        }
    }

    private var lastWLWWItem: NSMenuItem? {
        guard let WLWWPopup else { return nil }
        return WLWWPopup.item(at: WLWWPopup.items.count - 1)
    }

    /// The end of the sheet that confirms a preset's removal. `contextInfo` is
    /// the preset's name, retained by the caller as the former class did.
    @objc(deleteWLWW:returnCode:contextInfo:)
    public func deleteWLWW(_ sheet: NSWindow?, returnCode: Int32, contextInfo: UnsafeMutableRawPointer?) {
        guard let contextInfo else { return }
        let name = Unmanaged<NSString>.fromOpaque(contextInfo).takeRetainedValue()

        if returnCode == 1 {
            let presetsDict = (UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?)?.mutableCopy() as? NSMutableDictionary

            let index = OSIHangingPreferencePanePref.sortedPresetNames(presetsDict).index(of: name)

            presetsDict?.removeObject(forKey: name)
            UserDefaults.standard.set(presetsDict, forKey: "WLWW3")

            buildWLWWMenu()

            // The former comparison was of an int with an NSUInteger + 1.
            let wanted = UInt(bitPattern: index) &+ 1
            for (_, list) in hangingProtocols ?? NSDictionary() {
                for case let p as NSMutableDictionary in (list as? NSArray) ?? NSArray() {
                    if UInt(bitPattern: Int(intValue(p.value(forKey: "WLWW")))) == wanted {
                        p.setValue(NSNumber(value: Int32(0)), forKey: "WL")
                        p.setValue(NSNumber(value: Int32(0)), forKey: "WW")
                        p.setValue(NSNumber(value: Int32(100)), forKey: "WLWW")
                    }
                }
            }
        }
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        assumeMainActor((self, keyPath, object, change, context)) { $0.0.observeValueOnMainActor(forKeyPath: $0.1, of: $0.2, change: $0.3, context: $0.4) }
    }

    private func observeValueOnMainActor(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "arrangedObjects.WLWW" {
            for case let d as NSMutableDictionary in arrayController?.selectedObjects ?? [] {
                let tag = intValue(d.value(forKey: "WLWW"))

                if tag == 0 {
                    AddCurrentWLWW(d)
                }

                if tag != 0 && tag != 100 && tag != 101 {
                    if NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) ?? false { // Delete
                        let wlwwDict = UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?
                        let sortedKeys = OSIHangingPreferencePanePref.sortedPresetNames(wlwwDict)

                        let name = sortedKeys.object(at: Int(tag) - 1) as! NSString

                        beginDeleteSheet(name)
                    }
                }
            }
        }

        if keyPath == "arrangedObjects.Study Description" {
            for case let d as NSMutableDictionary in arrayController?.selectedObjects ?? [] {
                if (arrayController?.arrangedObjects as? NSArray)?.index(of: d) == 0 {
                    let description = d.value(forKey: "Study Description")
                    if !isEqualString(description, NSLocalizedString("Default", comment: "")) && !isEqualString(description, "Default") {
                        _ = runAlertPanel(.critical, NSLocalizedString("Default Protocol", comment: ""), NSLocalizedString("Default protocol cannot be renamed", comment: ""), NSLocalizedString("OK", comment: ""), nil)

                        d.setValue(NSLocalizedString("Default", comment: ""), forKey: "Study Description")
                    }
                }
            }
        }
    }

    /// NSBeginAlertSheet(…, self, @selector(deleteWLWW:returnCode:contextInfo:), NULL, [name retain], …),
    /// which Swift cannot call: it is variadic.
    private func beginDeleteSheet(_ name: NSString) {
        let alert = legacyAlert(.warning, NSLocalizedString("Remove a WL/WW preset", comment: ""),
                                String(format: NSLocalizedString("Are you sure you want to delete preset : '%@'?", comment: ""), name),
                                NSLocalizedString("Delete", comment: ""), NSLocalizedString("Cancel", comment: ""))
        let contextInfo = Unmanaged.passRetained(name).toOpaque()
        if let window = paneWindow {
            alert.beginSheetModal(for: window) { response in
                self.deleteWLWW(alert.window, returnCode: legacyReturn(response), contextInfo: contextInfo)
            }
        } else {
            deleteWLWW(nil, returnCode: legacyReturn(alert.runModal()), contextInfo: contextInfo)
        }
    }

    public override func mainViewDidLoad() {
    }

    @IBAction public func newHangingProtocol(_ sender: Any?) {
        let modality = modalityForHangingProtocols
        let list = modality.flatMap { hangingProtocols?.object(forKey: $0) } as? NSMutableArray

        let hangingProtocol = NSMutableDictionary()
        hangingProtocol.setObject(String(format: "%@ %d", NSLocalizedString("Character String", comment: ""), Int32(truncatingIfNeeded: list?.count ?? 0)), forKey: "Study Description" as NSString)
        hangingProtocol.setObject(NSNumber(value: Int32(0)), forKey: "WindowsTiling" as NSString)
        hangingProtocol.setObject(NSNumber(value: Int32(0)), forKey: "ImageTiling" as NSString)
        hangingProtocol.setObject(NSNumber(value: true), forKey: "Sync" as NSString)
        hangingProtocol.setObject(NSNumber(value: true), forKey: "Propagate" as NSString)
        hangingProtocol.setObject(NSNumber(value: Int32(0)), forKey: "WL" as NSString) // Default WL/WW
        hangingProtocol.setObject(NSNumber(value: Int32(0)), forKey: "WW" as NSString)
        hangingProtocol.setObject(NSNumber(value: Int32(100)), forKey: "WLWW" as NSString)
        hangingProtocol.setObject(NSNumber(value: Int32(1)), forKey: "NumberOfComparativeToDisplay" as NSString)

        willChangeValue(forKey: "currentHangingProtocol")
        list?.add(hangingProtocol)
        didChangeValue(forKey: "currentHangingProtocol")
    }

    @objc(deleteSelectedRow:)
    public func deleteSelectedRow(_ sender: Any?) {
        if runAlertPanel(.informational, NSLocalizedString("Delete Protocol", comment: ""), NSLocalizedString("Are you sure you want to delete the selected protocol?", comment: ""), NSLocalizedString("OK", comment: ""), NSLocalizedString("Cancel", comment: "")) == alertDefaultReturn {
            let modality = modalityForHangingProtocols
            let list = modality.flatMap { hangingProtocols?.object(forKey: $0) } as? NSMutableArray

            willChangeValue(forKey: "currentHangingProtocol")
            list?.removeObject(at: (sender as? NSTableView)?.selectedRow ?? 0)
            didChangeValue(forKey: "currentHangingProtocol")
        }
    }

    public override func willSelect() {
        assumeMainActor(self) { $0.willSelectOnMainActor() }
    }

    private func willSelectOnMainActor() {
        // The protocols are edited in a copy that is mutable at every level and shares
        // nothing with what NSUserDefaults holds (#618). It was made by a recursive
        // copy in Nitrogen; Core Foundation makes the same copy of a property list.
        // The copy of the previous visit is released here: the pane lives as long as
        // the application, and each return to it kept one more.
        hangingProtocols = nil
        hangingProtocolsUnusable = false

        let saved = UserDefaults.standard.object(forKey: "HANGINGPROTOCOLS")
        if let saved = saved as? NSDictionary {
            hangingProtocols = OSIHangingPreferencePanePref.mutableDeepCopy(saved)
        }
        if hangingProtocols == nil {
            // Missing, not a dictionary, or not a property list the copy can take: a
            // value this pane cannot have written. It is shown as the registered
            // protocols and is not written back, so leaving the pane does not replace
            // it (the old copy raised on it or wrote it over).
            if let saved {
                NSLog("---- HANGINGPROTOCOLS holds %@, which the Protocols pane cannot edit; it is left as it is", NSStringFromClass(type(of: saved as AnyObject)))
                hangingProtocolsUnusable = true
            }
            let registered = (UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain) as NSDictionary).object(forKey: "HANGINGPROTOCOLS")
            if let registered = registered as? NSDictionary {
                hangingProtocols = OSIHangingPreferencePanePref.mutableDeepCopy(registered)
            }
            if hangingProtocols == nil {
                hangingProtocols = NSMutableDictionary()
            }
        }

        for (_, list) in hangingProtocols ?? NSDictionary() {
            let list = list as? NSArray
            for case let hangingProtocol as NSMutableDictionary in list ?? NSArray() {
                OSIHangingPreferencePanePref.convertWLWWToMenuTag(hangingProtocol)

                if list?.index(of: hangingProtocol) == 0 {
                    hangingProtocol.setValue(NSLocalizedString("Default", comment: ""), forKey: "Study Description")
                }

                if hangingProtocol.object(forKey: "Sync") == nil {
                    hangingProtocol.setObject(NSNumber(value: true), forKey: "Sync" as NSString)
                }

                if hangingProtocol.object(forKey: "Propagate") == nil {
                    hangingProtocol.setObject(NSNumber(value: true), forKey: "Propagate" as NSString)
                }

                if integerValue(hangingProtocol.object(forKey: "NumberOfSeriesPerComparative")) < 1 {
                    hangingProtocol.setObject(NSNumber(value: Int32(1)), forKey: "NumberOfSeriesPerComparative" as NSString)
                }
            }
        }
        modalityForHangingProtocols = "CR" as NSString

        arrayController?.addObserver(self, forKeyPath: "arrangedObjects.WLWW", options: [], context: nil)
        arrayController?.addObserver(self, forKeyPath: "arrangedObjects.Study Description", options: [], context: nil)
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        _ = paneWindow?.makeFirstResponder(nil)

        arrayController?.removeObserver(self, forKeyPath: "arrangedObjects.WLWW")
        arrayController?.removeObserver(self, forKeyPath: "arrangedObjects.Study Description")

        for (_, list) in hangingProtocols ?? NSDictionary() {
            for case let hangingProtocol as NSMutableDictionary in (list as? NSArray) ?? NSArray() {
                OSIHangingPreferencePanePref.convertMenuTagToWLWW(hangingProtocol)

                hangingProtocol.setObject(NSNumber(value: WindowLayoutManager.windowsRows(forHangingProtocol: hangingProtocol as? [AnyHashable: Any])), forKey: "Rows" as NSString)
                hangingProtocol.setObject(NSNumber(value: WindowLayoutManager.windowsColumns(forHangingProtocol: hangingProtocol as? [AnyHashable: Any])), forKey: "Columns" as NSString)

                hangingProtocol.setObject(NSNumber(value: WindowLayoutManager.imagesRows(forHangingProtocol: hangingProtocol as? [AnyHashable: Any])), forKey: "Image Rows" as NSString)
                hangingProtocol.setObject(NSNumber(value: WindowLayoutManager.imagesColumns(forHangingProtocol: hangingProtocol as? [AnyHashable: Any])), forKey: "Image Columns" as NSString)
            }
        }
        if !hangingProtocolsUnusable {
            UserDefaults.standard.set(hangingProtocols, forKey: "HANGINGPROTOCOLS")
            UserDefaults.standard.synchronize()
        }
    }

    // MARK: - Helpers

    /// CFPropertyListCreateDeepCopy with mutable containers; nil when the value
    /// is not a property list the copy can take.
    private static func mutableDeepCopy(_ value: NSDictionary) -> NSMutableDictionary? {
        let copy: CFPropertyList? = CFPropertyListCreateDeepCopy(kCFAllocatorDefault, value,
                                                                 CFOptionFlags(CFPropertyListMutabilityOptions.mutableContainers.rawValue))
        return copy as? NSMutableDictionary
    }

    /// The WLWW3 preset names in menu order.
    private static func sortedPresetNames(_ presets: NSDictionary?) -> NSArray {
        (presets?.allKeys as NSArray?)?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray? ?? NSArray()
    }
}

// MARK: - The former messages to `id`

/// -floatValue, -intValue and -integerValue sent to a property list value: 0
/// for nil, as a message to nil was.
private func floatValue(_ value: Any?) -> Float {
    if let number = value as? NSNumber { return number.floatValue }
    if let string = value as? NSString { return string.floatValue }
    return 0
}

private func intValue(_ value: Any?) -> Int32 {
    if let number = value as? NSNumber { return number.int32Value }
    if let string = value as? NSString { return string.intValue }
    return 0
}

private func integerValue(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? NSString { return string.integerValue }
    return 0
}

/// -isEqualToString: sent to a value that may be nil.
private func isEqualString(_ value: Any?, _ string: String) -> Bool {
    (value as? NSString)?.isEqual(to: string) ?? false
}

// MARK: - NSRunAlertPanel and its variants

/// NSAlertDefaultReturn, NSAlertAlternateReturn and NSAlertOtherReturn.
private let alertDefaultReturn = 1

/// The NSAlert the NSRunAlertPanel family builds: title, message, a default and
/// an optional alternate button, in the style of the variant.
@MainActor private func legacyAlert(_ style: NSAlert.Style, _ title: String, _ message: String, _ defaultButton: String, _ alternateButton: String?) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: defaultButton)
    if let alternateButton { alert.addButton(withTitle: alternateButton) }
    return alert
}

/// The legacy answer: 1 for the default button, 0 for the alternate, -1 for the other.
private func legacyReturn(_ response: NSApplication.ModalResponse) -> Int32 {
    switch response {
    case .alertFirstButtonReturn: return 1
    case .alertSecondButtonReturn: return 0
    default: return -1
    }
}

/// NSRunAlertPanel (.warning), NSRunInformationalAlertPanel (.informational)
/// and NSRunCriticalAlertPanel (.critical) are variadic, which Swift cannot
/// call. The messages passed here have no format arguments.
@MainActor private func runAlertPanel(_ style: NSAlert.Style, _ title: String, _ message: String, _ defaultButton: String, _ alternateButton: String?) -> Int {
    Int(legacyReturn(legacyAlert(style, title, message, defaultButton, alternateButton).runModal()))
}
