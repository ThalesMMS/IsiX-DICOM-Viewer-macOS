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

private let CURRENTVERSION: Int32 = 1

/// The Routing preference pane: the autorouting rules in AUTOROUTINGDICTIONARY.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors,
/// the outlets and the bindings of OSIAutoroutingPreferencePanePref.xib
/// are those of the former class.
@objc(OSIAutoroutingPreferencePanePref)
public final class OSIAutoroutingPreferencePanePref: NSPreferencePane, NSTableViewDelegate, NSTableViewDataSource {
    /// Retained by the former -initWithBundle:, released in -dealloc: a strong outlet.
    @IBOutlet var newRoute: NSWindow?
    @IBOutlet var routesTable: NSTableView?

    @IBOutlet var newName: NSTextField?
    @IBOutlet var addressAndPort: NSTextField?
    @IBOutlet var newFilter: NSTextField?
    @IBOutlet var newDescription: NSTextField?
    @IBOutlet var serverPopup: NSPopUpButton?

    @IBOutlet var previousPopup: NSPopUpButton?
    @IBOutlet var previousModality: NSButton?
    @IBOutlet var previousDescription: NSButton?
    @IBOutlet var cfindTest: NSButton?

    @IBOutlet var failurePopup: NSPopUpButton?

    private var routesArray: NSMutableArray?
    private var serversArray: NSArray?
    @objc public dynamic var filterType: Int32 = 0
    @objc public dynamic var imagesOnly: Bool = false

    @IBOutlet var mainWindow: NSWindow?

    @objc public dynamic var deleteAfterTransference: Bool = false

    //Schedule attributes

    @objc public dynamic var scheduleType: Int32 = 0
    @IBOutlet var delayTime: NSTextField?
    @IBOutlet var fromTimePicker: NSDatePicker?
    @IBOutlet var toTimePicker: NSDatePicker?

    /// The nib's top-level objects, kept for the pane's lifetime.
    private var _tlos: NSArray?

    /// A file-level static of the former file: shared by every instance.
    private static var newRouteMode = false

    /// -init as the former class inherited it: a pane without its nib.
    public override init() {
        super.init()
    }

    @objc(initWithBundle:)
    public override init(bundle: Bundle) {
        // The former -initWithBundle: called [super init], not [super initWithBundle:].
        super.init()

        let nib = NSNib(nibNamed: "OSIAutoroutingPreferencePanePref", bundle: nil)
        var topLevelObjects: NSArray?
        nib?.instantiate(withOwner: self, topLevelObjects: &topLevelObjects)
        _tlos = topLevelObjects

        if let view = mainWindow?.contentView {
            self.mainView = view
        }
        self.mainViewDidLoad()
    }

    public override func mainViewDidLoad() {
        let defaults = UserDefaults.standard

        routesArray = (defaults.array(forKey: "AUTOROUTINGDICTIONARY") as NSArray?)?.mutableCopy() as? NSMutableArray
        if routesArray == nil { routesArray = NSMutableArray(capacity: 0) }

        var i = 0
        while i < (routesArray?.count ?? 0) {
            let newDict = NSMutableDictionary(dictionary: unsafeBitCast(routesArray!.object(at: i) as AnyObject, to: NSDictionary.self) as! [AnyHashable: Any])

            if newDict.value(forKey: "activated") == nil {
                newDict.setValue(NSNumber(value: true), forKey: "activated")
            }

            if objcIntValue(newDict.value(forKey: "version")) < 1 {
                if objcIntValue(newDict.value(forKey: "filterType")) != 0 {
                    newDict.setValue("", forKey: "filter")
                }

                newDict.setValue(NSNumber(value: CURRENTVERSION), forKey: "version")
            }

            if newDict.value(forKey: "imagesOnly") == nil {
                newDict.setValue(NSNumber(value: false), forKey: "imagesOnly")
            }

            if newDict.value(forKey: "scheduleType") == nil {
                newDict.setValue("0", forKey: "scheduleType")
            }

            routesArray?.replaceObject(at: i, with: newDict)
            i += 1
        }

        routesTable?.reloadData()

        routesTable?.delegate = self
        routesTable?.doubleAction = #selector(editRoute(_:))
        routesTable?.target = self
    }

    public override func willSelect() {
        serversArray = UserDefaults.standard.array(forKey: "SERVERS") as NSArray?

        var i = 0
        while i < (routesArray?.count ?? 0) {
            NSLog("%@", objcFormatArgument((routesArray!.object(at: i) as AnyObject).value(forKey: "server")))

            var found = false
            var x = 0
            while x < (serversArray?.count ?? 0) {
                if objcBoolValue((serversArray!.object(at: x) as AnyObject).value(forKey: "Activated")) &&
                    objcStringEquals((serversArray!.object(at: x) as AnyObject).value(forKey: "Description"), (routesArray!.object(at: i) as AnyObject).value(forKey: "server")) {
                    found = true
                }
                x += 1
            }

            if found == false {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Unknown Server", comment: ""), message: String(format: NSLocalizedString("This server doesn't exist in the Locations list: %@", comment: ""), objcFormatArgument((routesArray!.object(at: i) as AnyObject).value(forKey: "server"))), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
            i += 1
        }
    }

    public override func willUnselect() {
        mainView.window?.makeFirstResponder(nil)

        UserDefaults.standard.set(routesArray, forKey: "AUTOROUTINGDICTIONARY")
    }

    deinit {
        NSLog("dealloc OSIAutoroutingPreferencePanePref")
    }

    @IBAction public func syntaxHelpButtons(_ sender: Any?) {
        if objcTag(sender) == 0 {
            try? FileManager.default.removeItem(atPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("OsiriXTables.pdf"))
            if let source = Bundle.main.path(forResource: "OsiriXTables", ofType: "pdf") {
                try? FileManager.default.copyItem(atPath: source, toPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("OsiriXTables.pdf"))
            }
            NSWorkspace.shared.openFile((NSTemporaryDirectory() as NSString).appendingPathComponent("OsiriXTables.pdf"))
        }

        if objcTag(sender) == 1 {
            if let url = NSURL(string: "https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/Predicates/AdditionalChapters/Introduction.html#//apple_ref/doc/uid/TP40001798-SW1") as URL? {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @IBAction public func endNewRoute(_ sender: Any?) {
        if objcTag(sender) == 1 {
            let server = serversArray.map { ($0.object(at: serverPopup?.indexOfSelectedItem ?? 0) as AnyObject).object(forKey: "Description") } ?? nil
            let route = dictionaryWithObjectsAndKeys([
                (newName?.stringValue, "name"),
                (NSNumber(value: true), "activated"),
                (newDescription?.stringValue, "description"),
                (newFilter?.stringValue, "filter"),
                (server, "server"),
                (NSNumber(value: Int32(truncatingIfNeeded: previousPopup?.selectedTag() ?? 0)), "previousStudies"),
                (NSNumber(value: (previousModality?.state.rawValue ?? 0) != 0), "previousModality"),
                (NSNumber(value: (previousDescription?.state.rawValue ?? 0) != 0), "previousDescription"),
                (NSNumber(value: Int32(truncatingIfNeeded: failurePopup?.selectedTag() ?? 0)), "failureRetry"),
                (NSNumber(value: (cfindTest?.state.rawValue ?? 0) != 0), "cfindTest"),
                (NSNumber(value: filterType), "filterType"),
                (NSNumber(value: scheduleType), "scheduleType"),
                (NSNumber(value: delayTime?.integerValue ?? 0), "delayTime"),
                (fromTimePicker?.stringValue, "fromTime"),
                (toTimePicker?.stringValue, "toTime"),
                (NSNumber(value: Int32(imagesOnly ? 1 : 0)), "imagesOnly"),
                (NSNumber(value: CURRENTVERSION), "version"),
            ], mutable: true)
            routesArray?.replaceObject(at: routesTable?.selectedRow ?? 0, with: route)
        } else {
            if OSIAutoroutingPreferencePanePref.newRouteMode {
                routesArray?.removeObject(at: routesTable?.selectedRow ?? 0)
            }
        }

        routesTable?.reloadData()
        newRoute?.orderOut(sender)
        if let newRoute {
            NSApp.endSheet(newRoute, returnCode: objcTag(sender))
        }
    }

    @IBAction public func selectPrevious(_ sender: Any?) {
        if ((sender as? NSPopUpButton)?.selectedTag() ?? 0) != 0 {
            previousModality?.isEnabled = true
            previousDescription?.isEnabled = true
        } else {
            previousModality?.isEnabled = false
            previousDescription?.isEnabled = false
        }
    }

    @IBAction public func selectServer(_ sender: Any?) {
        let i = Int(Int32(truncatingIfNeeded: (sender as? NSPopUpButton)?.indexOfSelectedItem ?? 0))

        let server = serversArray?.object(at: i) as AnyObject?
        setObjCStringValue(addressAndPort, String(format: "%@ : %@", objcFormatArgument(server?.object(forKey: "Address")), objcFormatArgument(server?.object(forKey: "Port"))))
    }

    @IBAction func editRoute(_ sender: Any?) {
        OSIAutoroutingPreferencePanePref.newRouteMode = false

        if (serversArray?.count ?? 0) == 0 {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("New Route", comment: ""), message: NSLocalizedString("No destination servers exist. Create at least one destination in the Locations preferences.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        } else {
            let selectedRoute = routesArray?.object(at: routesTable?.selectedRow ?? 0) as AnyObject?

            if let selectedRoute {
                var i = 0
                serverPopup?.removeAllItems()
                i = 0
                while i < serversArray!.count {
                    let server = serversArray!.object(at: i) as AnyObject
                    var name = String(format: "%@ - %@", objcFormatArgument(server.object(forKey: "AETitle")), objcFormatArgument(server.object(forKey: "Description")))

                    while serverPopup?.item(withTitle: name) != nil {
                        name = name + " "
                    }

                    serverPopup?.addItem(withTitle: name)
                    i += 1
                }

                setObjCStringValue(newName, selectedRoute.value(forKey: "name"))
                setObjCStringValue(newDescription, selectedRoute.value(forKey: "description"))
                setObjCStringValue(newFilter, selectedRoute.value(forKey: "filter"))
                previousPopup?.selectItem(withTag: Int(objcIntValue(selectedRoute.value(forKey: "previousStudies"))))
                previousModality?.state = objcBoolValue(selectedRoute.value(forKey: "previousModality")) ? .on : .off
                previousDescription?.state = objcBoolValue(selectedRoute.value(forKey: "previousDescription")) ? .on : .off
                cfindTest?.state = objcBoolValue(selectedRoute.value(forKey: "cfindTest")) ? .on : .off
                failurePopup?.selectItem(withTag: Int(objcIntValue(selectedRoute.value(forKey: "failureRetry"))))

                self.filterType = objcIntValue(selectedRoute.value(forKey: "filterType"))
                self.imagesOnly = objcBoolValue(selectedRoute.value(forKey: "imagesOnly"))

                self.scheduleType = objcIntValue(selectedRoute.value(forKey: "scheduleType"))
                if self.scheduleType == 1 {
                    delayTime?.integerValue = objcIntegerValue(selectedRoute.value(forKey: "delayTime"))
                } else if self.scheduleType == 2 {
                    setObjCStringValue(fromTimePicker, selectedRoute.value(forKey: "fromTime"))
                    setObjCStringValue(toTimePicker, selectedRoute.value(forKey: "toTime"))
                }

                var count = 0
                i = 0
                while i < serversArray!.count {
                    if objcStringEquals((serversArray!.object(at: i) as AnyObject).object(forKey: "Description"), selectedRoute.value(forKey: "server")) {
                        serverPopup?.selectItem(at: i)
                        count += 1
                    }
                    i += 1
                }

                if count > 1 {
                    _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Multiples Servers", comment: ""), message: String(format: NSLocalizedString("Warning, multiples destination servers have the same name: %@. Each destination should have a unique name.", comment: ""), objcFormatArgument(selectedRoute.value(forKey: "server"))), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }

                self.selectServer(serverPopup)

                if let newRoute, let window = mainView.window {
                    NSApp.beginSheet(newRoute, modalFor: window, modalDelegate: self, didEnd: nil, contextInfo: nil)
                }
            }
        }
    }

    @IBAction public func newRoute(_ sender: Any?) {
        let server = (serversArray?.object(at: 0) as AnyObject?)?.object(forKey: "Description")
        routesArray?.add(dictionaryWithObjectsAndKeys([
            ("new route", "name"), ("", "description"), ("(series.study.modality contains[c] \"CT\")", "filter"),
            (server, "server"), ("20", "failureRetry"), ("0", "filterType"), (NSNumber(value: false), "imagesOnly"), ("0", "scheduleType"),
            ("2", "delayTime"), ("21:00", "fromTime"), ("06:00", "toTime"),
        ], mutable: false))

        routesTable?.reloadData()

        routesTable?.selectRowIndexes(IndexSet(integer: (routesArray?.count ?? 0) - 1), byExtendingSelection: false)

        self.editRoute(self)

        OSIAutoroutingPreferencePanePref.newRouteMode = true
    }

    @objc(deleteSelectedRow:)
    public func deleteSelectedRow(_ sender: Any?) {
        if objcTag(sender) == 0 {
            routesArray?.removeObject(at: routesTable?.selectedRow ?? 0)
            routesTable?.reloadData()
        }
    }

    public func numberOfRows(in aTableView: NSTableView) -> Int {
        if aTableView.tag == 0 { return routesArray?.count ?? 0 }

        return 0
    }

    public func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        if tableView.tag == 0 {
            routesArray?.sort(using: routesTable?.sortDescriptors ?? [])
            routesTable?.reloadData()
        }
    }

    public func tableView(_ aTableView: NSTableView, objectValueFor aTableColumn: NSTableColumn?, row rowIndex: Int) -> Any? {
        if aTableView.tag == 0 {
            // NSParameterAssert(rowIndex >= 0 && rowIndex < [routesArray count]): -objectAtIndex:
            // below raises for the same rows.
            let theRecord = routesArray?.object(at: rowIndex) as AnyObject?

            guard let identifier = aTableColumn?.identifier.rawValue else { return nil }
            return theRecord?.object(forKey: identifier)
        }

        return nil
    }

    public func tableView(_ aTableView: NSTableView, setObjectValue anObject: Any?, for aTableColumn: NSTableColumn?, row rowIndex: Int) {
        if aTableColumn?.identifier.rawValue == "activated" {
            (routesArray?.object(at: rowIndex) as AnyObject?)?.setValue(anObject, forKey: aTableColumn!.identifier.rawValue)
        }
    }

    public func tableView(_ aTableView: NSTableView, shouldEdit aTableColumn: NSTableColumn?, row rowIndex: Int) -> Bool {
        return true
    }
}

/// +dictionaryWithObjectsAndKeys: stops at the first nil object; so does this.
fileprivate func dictionaryWithObjectsAndKeys(_ objectsAndKeys: [(Any?, String)], mutable: Bool) -> NSDictionary {
    let dictionary = NSMutableDictionary()
    for (object, key) in objectsAndKeys {
        guard let object else { break }
        dictionary.setObject(object, forKey: key as NSString)
    }
    return mutable ? dictionary : dictionary.copy() as! NSDictionary
}

/// -setStringValue: with the id the former code passed, nil and non-strings included.
fileprivate func setObjCStringValue(_ control: NSControl?, _ value: Any?) {
    _ = control?.perform(#selector(setter: NSControl.stringValue), with: value)
}

/// [value intValue] on an id: 0 for nil.
fileprivate func objcIntValue(_ value: Any?) -> Int32 {
    guard let value = value as AnyObject? else { return 0 }
    return value.intValue ?? 0
}

/// [value integerValue] on an id: 0 for nil.
fileprivate func objcIntegerValue(_ value: Any?) -> Int {
    guard let value = value as AnyObject? else { return 0 }
    return value.integerValue ?? 0
}

/// [value boolValue] on an id: NO for nil.
fileprivate func objcBoolValue(_ value: Any?) -> Bool {
    guard let value = value as AnyObject? else { return false }
    return value.boolValue ?? false
}

/// [sender tag] on an id: 0 for nil.
fileprivate func objcTag(_ sender: Any?) -> Int {
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
