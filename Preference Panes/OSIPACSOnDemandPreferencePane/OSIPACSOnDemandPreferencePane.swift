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

/// The date matrix of the pane's nib, read by DateEnumTransformer. Retained,
/// as the former static was.
// Main actor: set and cleared by the pane and read by the value transformer its
// bindings use, on the main thread.
@MainActor private var gDateMatrix: NSMatrix? = nil

/// The former `[x intValue]` on a value of the smart albums' dictionaries,
/// which hold the date as NSString or NSNumber: nil gives 0.
private func intValue(_ value: Any?) -> Int32 {
    if let number = value as? NSNumber { return number.int32Value }
    if let string = value as? NSString { return string.intValue }
    return 0
}

/// The former `[x boolValue]`: nil gives NO.
private func boolValue(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

/// The former `[x tag]` on the sender: 0 for nil.
@MainActor private func tag(of sender: Any?) -> Int {
    if let view = sender as? NSView { return view.tag }
    if let item = sender as? NSMenuItem { return item.tag }
    if let cell = sender as? NSCell { return cell.tag }
    return 0
}

/// The former `[a isEqualToString: b]`: NO when either is nil or not a string.
private func isEqualString(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a as? NSString, let b = b as? NSString else { return false }
    return a.isEqual(to: b as String)
}

/// What the former `%@` printed for `value`: its description, "(null)" for nil.
private func objectDescription(_ value: Any?) -> String {
    guard let value = value else { return "(null)" }
    return String(format: "%@", value as AnyObject as! CVarArg)
}

/// The former `+[NSMutableDictionary dictionaryWithObjectsAndKeys:]`, which
/// stops at the first nil object.
private func dictionaryWithObjectsAndKeys(_ pairs: [(Any?, String)]) -> NSMutableDictionary {
    let dictionary = NSMutableDictionary()
    for (object, key) in pairs {
        guard let object = object else { break }
        dictionary.setObject(object, forKey: key as NSString)
    }
    return dictionary
}

/// The former `[array containsObject: object]`: NO for a nil object.
private func containsObject(_ array: Any?, _ object: Any?) -> Bool {
    guard let array = array as? NSArray, let object = object else { return false }
    return array.contains(object)
}

/// Lists the modalities of a smart album: named by the xib (NSValueTransformerName).
@objc(ArrayToListTransformer)
public final class ArrayToListTransformer: ValueTransformer {
    public override class func allowsReverseTransformation() -> Bool {
        return false
    }

    public override class func transformedValueClass() -> AnyClass {
        return NSString.self
    }

    public override func transformedValue(_ array: Any?) -> Any? {
        let string = NSMutableString()
        let array = array as? NSArray
        for case let modality as NSString in array ?? NSArray() {
            string.append(modality as String)
            if modality !== (array?.lastObject as AnyObject?) {
                string.append(", ")
            }
        }
        return string
    }
}

/// Names the date of a smart album by the date matrix's cell of that tag:
/// named by the xib (NSValueTransformerName).
@objc(DateEnumTransformer)
public final class DateEnumTransformer: ValueTransformer {
    public override class func allowsReverseTransformation() -> Bool {
        return false
    }

    public override class func transformedValueClass() -> AnyClass {
        return NSNumber.self
    }

    public override func transformedValue(_ number: Any?) -> Any? {
        // The pane's bindings ask for it on the main thread, where the matrix is.
        let tag = Int(intValue(number))
        let title: String? = MainActor.assumeIsolated { gDateMatrix?.cell(withTag: tag)?.title }
        return title
    }
}

/// The On-Demand preference pane.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors,
/// the xib outlets and bindings and
/// <Horos/OSIPACSOnDemandPreferencePane.h> are those of the former class.
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSIPACSOnDemandPreferencePane)
public final class OSIPACSOnDemandPreferencePane: NSPreferencePane {
    @IBOutlet var mainWindow: NSWindow?

    /// An instance variable in the former class, bound by the xib as
    /// `self.sourcesArray` and announced with will/didChangeValueForKey:.
    @objc var sourcesArray: NSMutableArray?
    @IBOutlet var sourcesTable: sourcesTableView?

    @IBOutlet var smartAlbumsTable: NSTableView?

    private var albumDBArray: NSArray?

    /// Retained by the former class on top of the nib's reference.
    @IBOutlet var smartAlbumsEditWindow: NSWindow?
    @IBOutlet var dateMatrix: NSMatrix?

    private var _tlos: NSArray?

    /// Bound by the xib. Retained and atomic in the former header; like it,
    /// it holds whatever array it is given, mutable or not (bindings and
    /// -editSmartAlbumFilter: set immutable ones).
    @objc(smartAlbumsArray)
    public dynamic var smartAlbumsArray: NSMutableArray?
    @objc(smartAlbumModality)
    public dynamic var smartAlbumModality: NSMutableArray?
    @objc(smartAlbumFilter)
    public dynamic var smartAlbumFilter: String?
    @objc(smartAlbumDate)
    public dynamic var smartAlbumDate: CInt = 0

    // The array controller of the sources table edits `self.sourcesArray`
    // (drag and drop, delete) through -mutableArrayValueForKey:. The former
    // instance variable had no setter, so the proxy changed the array in
    // place; these indexed accessors keep it so, with the same KVO changes.
    @objc(insertObject:inSourcesArrayAtIndex:)
    func insertObject(_ object: Any, inSourcesArrayAt index: Int) {
        sourcesArray?.insert(object, at: index)
    }

    @objc(removeObjectFromSourcesArrayAtIndex:)
    func removeObjectFromSourcesArray(at index: Int) {
        sourcesArray?.removeObject(at: index)
    }

    @objc(selectUniqueSource:)
    func selectUniqueSource(_ sender: Any?) {
        self.willChangeValue(forKey: "sourcesArray")

        let selectedRow = (sender as? NSTableView)?.selectedRow ?? 0
        var i = 0
        while i < (sourcesArray?.count ?? 0) {
            let source = (sourcesArray!.object(at: i) as! NSDictionary).mutableCopy() as! NSMutableDictionary

            if selectedRow == i { source.setObject(NSNumber(value: true), forKey: "activated" as NSString) }
            else { source.setObject(NSNumber(value: false), forKey: "activated" as NSString) }

            sourcesArray!.replaceObject(at: i, with: source)
            i += 1
        }

        self.didChangeValue(forKey: "sourcesArray")
    }

    @objc(findCorrespondingServer:inServers:)
    func findCorrespondingServer(_ savedServer: NSDictionary?, inServers servers: NSArray?) -> NSDictionary? {
        for i in 0..<(servers?.count ?? 0) {
            var found: NSDictionary? = nil
            do {
                try HorosObjCException.perform {
                    let server = servers!.object(at: i) as! NSObject
                    if isEqualString(savedServer?.object(forKey: "AETitle"), (server as? NSDictionary)?.object(forKey: "AETitle")) &&
                        isEqualString(savedServer?.object(forKey: "name"), (server as? NSDictionary)?.object(forKey: "Description")) &&
                        isEqualString(savedServer?.object(forKey: "AddressAndPort"), String(format: "%@:%@", objectDescription(server.value(forKey: "Address")), objectDescription(server.value(forKey: "Port")))) {
                        found = server as? NSDictionary
                    }
                }
            } catch {
            }
            if let found = found {
                return found
            }
        }

        return nil
    }

    @objc(refreshSources)
    func refreshSources() {
        UserDefaults.standard.set(sourcesArray, forKey: "comparativeSearchDICOMNodes")

        let serversArray = ((DCMNetServiceDelegate.dicomServersList() as NSArray?)?.mutableCopy() as? NSMutableArray)
        let savedArray = UserDefaults.standard.array(forKey: "comparativeSearchDICOMNodes") as NSArray?

        self.willChangeValue(forKey: "sourcesArray")

        sourcesArray?.removeAllObjects()

        for i in 0..<(savedArray?.count ?? 0) {
            let saved = savedArray!.object(at: i) as AnyObject
            let server = self.findCorrespondingServer(saved as? NSDictionary, inServers: serversArray)

            //if( server && ([[server valueForKey:@"QR"] boolValue] == YES || [server valueForKey:@"QR"] == nil ))
            sourcesArray?.add(dictionaryWithObjectsAndKeys([
                ((saved as? NSObject)?.value(forKey: "activated"), "activated"),
                (server?.value(forKey: "Description"), "name"),
                (server?.value(forKey: "AETitle"), "AETitle"),
                (String(format: "%@:%@", objectDescription(server?.value(forKey: "Address")), objectDescription(server?.value(forKey: "Port"))), "AddressAndPort"),
                (server, "server"),
            ]))

            if let server = server {
                serversArray?.remove(server)
            }
        }

        for i in 0..<(serversArray?.count ?? 0) {
            let server = serversArray!.object(at: i) as? NSDictionary

            //if( ([[server valueForKey:@"QR"] boolValue] == YES || [server valueForKey:@"QR"] == nil ))

            sourcesArray?.add(dictionaryWithObjectsAndKeys([
                (NSNumber(value: false), "activated"),
                (server?.value(forKey: "Description"), "name"),
                (server?.value(forKey: "AETitle"), "AETitle"),
                (String(format: "%@:%@", objectDescription(server?.value(forKey: "Address")), objectDescription(server?.value(forKey: "Port"))), "AddressAndPort"),
                (server, "server"),
            ]))
        }

        sourcesTable?.reloadData()

        self.didChangeValue(forKey: "sourcesArray")
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
        let nib = NSNib(nibNamed: "OSIPACSOnDemand", bundle: nil)
        nib?.instantiate(withOwner: self, topLevelObjects: &_tlos)

        if let contentView = mainWindow?.contentView {
            self.mainView = contentView
        }

        gDateMatrix = dateMatrix

        self.mainViewDidLoad()
    }

    @objc(setActivated:)
    @IBAction func setActivated(_ sender: Any?) {
        // Check that activated smart albums have at least date or modality filters
        for case let d as NSDictionary in smartAlbumsArray ?? NSMutableArray() {
            if boolValue(d.object(forKey: "activated")) {
                if intValue(d.object(forKey: "date")) == 0 && ((d.object(forKey: "modality") as? NSArray)?.count ?? 0) == 0 {
                    HorosAlertPanel.runInformational(title: NSLocalizedString("Filter", comment: ""),
                                                     message: String(format: NSLocalizedString("The Smart Album filter (%@) needs to have at least one parameter defined to be activated: date or modality.", comment: ""), objectDescription(d.object(forKey: "name"))),
                                                     defaultButton: NSLocalizedString("OK", comment: ""),
                                                     alternateButton: nil,
                                                     otherButton: nil)

                    self.willChangeValue(forKey: "smartAlbumsArray")
                    d.setValue(NSNumber(value: false), forKey: "activated")
                    self.didChangeValue(forKey: "smartAlbumsArray")
                }
            }
        }
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        self.mainView.window?.makeFirstResponder(nil)

        // Save DICOM Nodes

        let srcArray = NSMutableArray()
        for src in sourcesArray ?? NSMutableArray() {
            if boolValue((src as? NSObject)?.value(forKey: "activated")) == true {
                srcArray.add(src)
            }
        }
        if srcArray.count == 0 {
            UserDefaults.standard.set(false, forKey: "searchForComparativeStudiesOnDICOMNodes")
        }

        UserDefaults.standard.setValue(srcArray, forKey: "comparativeSearchDICOMNodes")

        // Save Smart Albums
        self.setActivated(self)
        UserDefaults.standard.set(smartAlbumsArray, forKey: "smartAlbumStudiesDICOMNodes")

        // Refresh Smart Albums
        BrowserController.currentBrowser()?.refreshAlbums()
        BrowserController.currentBrowser()?.refreshComparativeStudiesIfNeeded(nil)
        BrowserController.currentBrowser()?.outlineViewRefresh()
    }

    isolated deinit {
        NSLog("dealloc OSIPACSOnDemandPreferencePane")

        gDateMatrix = nil

        _tlos = nil
    }

    public override func willSelect() {
        assumeMainActor(self) { $0.willSelectOnMainActor() }
    }

    private func willSelectOnMainActor() {
        // Smart Albums
        let savedSmartAlbums = NSMutableArray()

        // Create mutable version...
        for case let d as NSDictionary in (UserDefaults.standard.object(forKey: "smartAlbumStudiesDICOMNodes") as? NSArray) ?? NSArray() {
            savedSmartAlbums.add(NSMutableDictionary(dictionary: d))
        }

        self.willChangeValue(forKey: "smartAlbumsArray")

        self.smartAlbumsArray = savedSmartAlbums

        do {
            try HorosObjCException.perform {
                let dbRequest = NSFetchRequest<NSFetchRequestResult>()
                dbRequest.entity = DicomDatabase.activeLocal()?.entity(forName: "Album")
                dbRequest.predicate = NSPredicate(format: "smartAlbum == YES")

                self.albumDBArray = nil

                self.albumDBArray = (try? DicomDatabase.activeLocal()?.managedObjectContext?.fetch(dbRequest)) as NSArray?
                self.albumDBArray = self.albumDBArray?.sortedArray(using: [NSSortDescriptor(key: "name", ascending: true)]) as NSArray?

                // Add mising smart albums
                for case let album as DicomAlbum in self.albumDBArray ?? NSArray() {
                    if containsObject(self.smartAlbumsArray?.value(forKey: "name"), album.name) == false {
                        // Is it a 'known' album : pre-fill it

                        if isEqualString(album.name, NSLocalizedString("Just Acquired (last hour)", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("101", "date"), (NSArray(), "modality")]))
                        }

                        else if isEqualString(album.name, NSLocalizedString("Today MR", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("1", "date"), (NSArray(object: "MR"), "modality")]))
                        } else if isEqualString(album.name, NSLocalizedString("Today CT", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("1", "date"), (NSArray(object: "CT"), "modality")]))
                        } else if isEqualString(album.name, NSLocalizedString("Today US", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("1", "date"), (NSArray(object: "US"), "modality")]))
                        } else if isEqualString(album.name, NSLocalizedString("Today MG", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("1", "date"), (NSArray(object: "MG"), "modality")]))
                        } else if isEqualString(album.name, NSLocalizedString("Today CR", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("1", "date"), (NSArray(object: "CR"), "modality")]))
                        } else if isEqualString(album.name, NSLocalizedString("Today XA", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("1", "date"), (NSArray(object: "XA"), "modality")]))
                        } else if isEqualString(album.name, NSLocalizedString("Today RF", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("1", "date"), (NSArray(object: "RF"), "modality")]))
                        }

                        else if isEqualString(album.name, NSLocalizedString("Yesterday MR", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("2", "date"), (NSArray(object: "MR"), "modality")]))
                        } else if isEqualString(album.name, NSLocalizedString("Yesterday CT", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("2", "date"), (NSArray(object: "CT"), "modality")]))
                        } else if isEqualString(album.name, NSLocalizedString("Yesterday US", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("2", "date"), (NSArray(object: "US"), "modality")]))
                        } else if isEqualString(album.name, NSLocalizedString("Yesterday MG", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("2", "date"), (NSArray(object: "MG"), "modality")]))
                        } else if isEqualString(album.name, NSLocalizedString("Yesterday CR", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("2", "date"), (NSArray(object: "CR"), "modality")]))
                        } else if isEqualString(album.name, NSLocalizedString("Yesterday XA", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("2", "date"), (NSArray(object: "XA"), "modality")]))
                        } else if isEqualString(album.name, NSLocalizedString("Yesterday RF", comment: "")) {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: true), "activated"), (album.name, "name"), ("2", "date"), (NSArray(object: "RF"), "modality")]))
                        }

                        else {
                            self.smartAlbumsArray?.add(dictionaryWithObjectsAndKeys([(NSNumber(value: false), "activated"), (album.name, "name"), ("0", "date"), (NSArray(), "modality")]))
                        }
                    }
                }

                // Delete unavailble smart albums preferences
                let toBeRemoved = NSMutableArray()
                for album in self.smartAlbumsArray ?? NSMutableArray() {
                    if containsObject(self.albumDBArray?.value(forKey: "name"), (album as? NSDictionary)?.object(forKey: "name")) == false {
                        toBeRemoved.add(album)
                    }
                }

                self.smartAlbumsArray?.removeObjects(in: toBeRemoved as! [Any])
            }
        } catch {
            if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(e, true, "-[OSIPACSOnDemandPreferencePane willSelect]")
            }
        }
        self.didChangeValue(forKey: "smartAlbumsArray")

        // History
        sourcesArray = (UserDefaults.standard.object(forKey: "comparativeSearchDICOMNodes") as AnyObject?)?.mutableCopy() as? NSMutableArray
        if sourcesArray == nil {
            sourcesArray = NSMutableArray()
        }

        self.refreshSources()
    }

    public override func mainViewDidLoad() {
        assumeMainActor(self) { $0.mainViewDidLoadOnMainActor() }
    }

    private func mainViewDidLoadOnMainActor() {
        smartAlbumsTable?.doubleAction = #selector(editSmartAlbumFilter(_:))
        smartAlbumsTable?.target = self

        sourcesTable?.doubleAction = #selector(selectUniqueSource(_:))

        for i in 0..<(sourcesArray?.count ?? 0) {
            if boolValue((sourcesArray!.object(at: i) as? NSObject)?.value(forKey: "activated")) == true {
                sourcesTable?.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                sourcesTable?.scrollRowToVisible(i)
                break
            }
        }
    }

    @objc(endEditSmartAlbumFilter:)
    @IBAction func endEditSmartAlbumFilter(_ sender: Any?) {
        if tag(of: sender) == 1 { // OK
            self.willChangeValue(forKey: "smartAlbumsArray")

            let dict = smartAlbumsArray?.object(at: smartAlbumsTable?.selectedRow ?? 0) as? NSMutableDictionary

            dict?.setObject(NSNumber(value: self.smartAlbumDate), forKey: "date" as NSString)

            if let modality = self.smartAlbumModality {
                dict?.setObject(modality, forKey: "modality" as NSString)
            } else {
                dict?.setObject(NSArray(), forKey: "modality" as NSString)
            }

            self.didChangeValue(forKey: "smartAlbumsArray")
        } else { // Cancel
        }

        smartAlbumsEditWindow?.orderOut(sender)
        if let smartAlbumsEditWindow = smartAlbumsEditWindow {
            smartAlbumsEditWindow.sheetParent?.endSheet(smartAlbumsEditWindow, returnCode: NSApplication.ModalResponse(rawValue: tag(of: sender)))
        }
    }

    @objc(editSmartAlbumFilter:)
    @IBAction func editSmartAlbumFilter(_ sender: Any?) {
        if (smartAlbumsArray?.count ?? 0) == 0 {
            HorosAlertPanel.runCritical(title: NSLocalizedString("New Route", comment: ""),
                                        message: NSLocalizedString("No smart album exists.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""),
                                        alternateButton: nil,
                                        otherButton: nil)
        } else {
            let selectedAlbum = smartAlbumsArray!.object(at: smartAlbumsTable?.selectedRow ?? 0) as? NSDictionary

            if let selectedAlbum = selectedAlbum {
                // The former property held the dictionary's array as it was, immutable or not.
                self.smartAlbumModality = (selectedAlbum.object(forKey: "modality") as AnyObject?).map { unsafeDowncast($0, to: NSMutableArray.self) }
                self.smartAlbumDate = intValue(selectedAlbum.object(forKey: "date"))

                if let albumDBArray = albumDBArray {
                    let name = selectedAlbum.object(forKey: "name")
                    let index = name.map { (albumDBArray.value(forKey: "name") as! NSArray).index(of: $0) } ?? NSNotFound
                    self.smartAlbumFilter = (albumDBArray.object(at: index) as? NSObject)?.value(forKey: "predicateString") as? String
                } else {
                    self.smartAlbumFilter = nil
                }

                if let smartAlbumsEditWindow = smartAlbumsEditWindow, let window = self.mainView.window {
                    window.beginSheet(smartAlbumsEditWindow, completionHandler: nil)
                }
            }
        }
    }
}
