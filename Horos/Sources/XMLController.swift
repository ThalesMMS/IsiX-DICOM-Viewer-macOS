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
import UniformTypeIdentifiers

private let XMLToolbarIdentifier = "XML Toolbar Identifier"
private let ExportToolbarItemIdentifier = "Export.icns"
private let ExportTextToolbarItemIdentifier = "ExportText"
private let ExpandAllItemsToolbarItemIdentifier = "add-large"
private let CollapseAllItemsToolbarItemIdentifier = "minus-large"
private let SearchToolbarItemIdentifier = "Search"
private let EditingToolbarItemIdentifier = "Editing"
private let SortSeriesToolbarItemIdentifier = "SortSeries"
private let VerifyToolbarItemIdentifier = "Validator"

@MainActor private var showWarning = true

/// The exception an HorosObjCException.perform error carries.
private func exception(_ error: Error) -> NSException? {
    return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
}

/// +[NSArray arrayWithObject:], which raises for nil as the former code did.
private func arrayWithObject(_ object: Any?) -> NSArray {
    return (NSArray.self as AnyObject).perform(NSSelectorFromString("arrayWithObject:"), with: object)!.takeUnretainedValue() as! NSArray
}

/// +[NSArray arrayWithObjects:a, b, nil], which stops at the first nil.
private func arrayWithObjects(_ objects: Any?...) -> NSArray {
    let array = NSMutableArray()
    for object in objects {
        guard let object = object else { break }
        array.add(object)
    }
    return NSArray(array: array)
}

/// -[NSMutableArray addObject:], which raises for nil as the former code did.
private func addObject(_ array: NSMutableArray?, _ object: Any?) {
    _ = array?.perform(#selector(NSMutableArray.add(_:)), with: object)
}

/// -[NSString isEqualToString:]: literal comparison, and NO for nil.
private func isEqualToString(_ string: String?, _ other: String?) -> Bool {
    guard let string = string, let other = other else {
        return false
    }
    return (string as NSString).isEqual(to: other)
}

/// -stringValue of the XML attribute `name` of an outline item, which is nil
/// for an item that is no element, as a message to it was.
private func attribute(_ item: Any?, _ name: String) -> String? {
    return (item as? XMLElement)?.attribute(forName: name)?.stringValue
}

/// -objectValue of the XML attribute `name` of an outline item.
private func attributeObjectValue(_ item: Any?, _ name: String) -> Any? {
    return (item as? XMLElement)?.attribute(forName: name)?.objectValue
}

/// -tag of the sender of an action.
@MainActor private func senderTag(_ sender: Any?) -> Int {
    if let control = sender as? NSControl { return control.tag }
    if let item = sender as? NSMenuItem { return item.tag }
    if let cell = sender as? NSCell { return cell.tag }
    return 0
}

/// A message without argument nor result, sent by its selector:
/// -[NSView setNeedsDisplay], which AppKit implements and does not declare.
private func send(_ target: NSObject?, _ name: String) {
    guard let target = target else { return }
    typealias Message = @convention(c) (AnyObject, Selector) -> Void
    let selector = NSSelectorFromString(name)
    unsafeBitCast(target.method(for: selector), to: Message.self)(target, selector)
}

/// -[NSMutableArray replaceObjectAtIndex:withObject:], which raises for nil as
/// the former code did.
private func replaceObject(_ array: NSMutableArray, _ index: Int, _ object: Any?) {
    guard let object = object else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM replaceObjectAtIndex:withObject:]: object cannot be nil", userInfo: nil).raise()
        return
    }
    array.replaceObject(at: index, with: object)
}

/// -[NSString intValue]: the leading integer, 0 if there is none.
private func intValue(_ string: String) -> Int32 {
    return (string as NSString).intValue
}

/// -[NSFileManager attributesOfItemAtPath:error:] NSFileSize in kilobytes, as
/// `int fileSize = [...longLongValue] / 1024L` computed it.
private func fileSizeInKB(_ path: String?) -> Int32 {
    let attributes = path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0) }
    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    return Int32(truncatingIfNeeded: size / 1024)
}

/// Window Controller for XML parsing: the meta-data window of a file.
///
/// Implemented in Swift since #828: the Objective-C name, the selectors and
/// <Horos/XMLController.h> are those of the former class, the File's Owner of
/// XMLViewer.xib. Its superclass, OSIWindowController, stays in Objective-C,
/// and so does XMLControllerDCMTKCategory, whose messages the class sends
/// through XMLController+CAPI.m.
@objc(XMLController)
public final class XMLController: OSIWindowController, NSToolbarDelegate, NSWindowDelegate {
    @IBOutlet private var table: NSOutlineView?
    @IBOutlet private var tableScrollView: NSScrollView?
    @IBOutlet private var search: NSSearchField?
    @IBOutlet private var searchView: NSView?
    @IBOutlet private var dicomEditingView: NSView?

    private var xmlDcmData: NSMutableArray? = nil
    private var tree: NSMutableArray? = nil
    private var xmlData: NSData? = nil
    private var toolbar: NSToolbar? = nil
    private var srcFile: String? = nil
    private var xmlDocument: XMLDocument? = nil
    private var dcmDocument: DCMObject? = nil
    private var _imObj: DicomImage? = nil
    /// The DICOM dictionary's tags and names, which -prepareDictionaryArray of
    /// XMLControllerDCMTKCategory fills through this selector.
    @objc(horos_dictionaryArray) private(set) var dictionaryArray: NSMutableArray? = nil

    private var _viewer: ViewerController? = nil

    private var isDICOM = false, dontClose = false
    private var _editingActivated = false
    private var allowSelectionChange = false

    /// The level the edits apply to, which XMLViewer.xib binds by key.
    @objc private dynamic var editingLevel: Int32 = 0

    @IBOutlet private var addWindow: NSWindow?
    @IBOutlet private var dicomFieldsCombo: NSComboBox?
    @IBOutlet private var addGroup: NSTextField?
    @IBOutlet private var addElement: NSTextField?
    @IBOutlet private var addValue: NSTextField?

    @IBOutlet private var validatorWindow: NSWindow?
    @IBOutlet private var validatorText: NSTextView?

    private var dontListenToIndexChange = false
    private var modificationsToApplyArray: NSMutableArray? = nil, modifiedFields: NSMutableArray? = nil, modifiedValues: NSMutableArray? = nil

    @objc public var imObj: NSManagedObject! {
        return _imObj
    }

    @objc public var viewer: ViewerController! {
        return _viewer
    }

    @objc public dynamic var editingActivated: Bool {
        get { return _editingActivated }
        set { _editingActivated = newValue }
    }

    // To be 'compatible' with TileWindows in AppController
    /////////////////////////////////////////////////
    @objc(setWindowFrame:showWindow:animate:)
    func setWindowFrame(_ rect: NSRect, showWindow: Bool, animate: Bool) {
        AppController.resizeWindow(withAnimation: self.window, newSize: rect)

        let wasAlreadyVisible = self.window?.isVisible ?? false

        if showWindow && wasAlreadyVisible {
            self.window?.orderFront(self)
        }
    }

    @objc(fileList)
    func fileList() -> NSArray {
        return arrayWithObject(_imObj)
    }

    /////////////////////////////////////////////////

    @objc(getPath:)
    func getPath(_ node: Any?) -> String {
        let result = NSMutableString()

        var parent = node as? XMLNode
        var child: XMLNode? = nil
        var first = true

        repeat {
            if isEqualToString(parent?.parent?.className, "NSXMLElement") {
                if let group = attribute(parent, "group"), let element = attribute(parent, "element") {
                    var subString = String(format: "(%@,%@)", group, element)

                    if first == false && attribute(child, "group") != nil && attribute(child, "element") != nil {
                        subString = subString.appending(".")
                    }

                    result.insert(subString, at: 0)
                } else {
                    let index = parent.flatMap { (parent?.parent?.children as NSArray?)?.index(of: $0) } ?? 0
                    var subString = String(format: "[%d]", Int32(truncatingIfNeeded: index))

                    if first == false {
                        subString = subString.appending(".")
                    }

                    result.insert(subString, at: 0)
                }
            }

            child = parent
            first = false
            parent = parent?.parent
        } while parent != nil

        // Example (0008,1111)[0].(0010,0010)

        return result as String
    }

    @objc(arrayOfFiles)
    func arrayOfFiles() -> NSArray? {
        let result = editingLevel

        UserDefaults.standard.set(Int(editingLevel), forKey: "editingLevel")

        switch result {
        case 0:
            NSLog("image level")
            return arrayWithObject(_imObj)

        case 1:
            NSLog("series level")

            let series = _imObj?.value(forKey: "series")

            let images = BrowserController.currentBrowser()?.childrenArray(series) as NSArray?

            return images

        case 2:
            NSLog("study level")

            let allSeries = BrowserController.currentBrowser()?.childrenArray(_imObj?.value(forKeyPath: "series.study")) as NSArray?
            let result = NSMutableArray()

            for loopItem in allSeries ?? [] {
                result.addObjects(from: BrowserController.currentBrowser()?.childrenArray(loopItem) ?? [])
            }

            return result

        case 3:
            NSLog("patient level")

            let result = NSMutableArray()
            let context = BrowserController.currentBrowser()?.database?.managedObjectContext
            N2ManagedObjectContextPerformAndWait(context) {
            let patientID = _imObj?.value(forKeyPath: "series.study.patientID")
            let predicate = patientID.map { NSPredicate(format: "(patientID == %@)", argumentArray: [$0]) } ?? NSPredicate(format: "(patientID == nil)")
            let dbRequest = NSFetchRequest<NSFetchRequestResult>()
            dbRequest.entity = BrowserController.currentBrowser()?.database?.managedObjectModel?.entitiesByName["Study"]
            dbRequest.predicate = predicate

            var studiesArray: NSArray? = nil

            do {
                try HorosObjCException.perform {
                    studiesArray = (try? BrowserController.currentBrowser()?.database?.managedObjectContext?.fetch(dbRequest)) as NSArray?
                }
            } catch {
                if let e = exception(error) { _N2LogExceptionImpl(e, true, "-[XMLController arrayOfFiles]") }
            }


            if (studiesArray?.count ?? 0) > 0 {
                for s in studiesArray! {
                    let allSeries = BrowserController.currentBrowser()?.childrenArray(s) as NSArray?

                    for w in allSeries ?? [] {
                        result.addObjects(from: BrowserController.currentBrowser()?.childrenArray(w) ?? [])
                    }
                }
            }

            }

            return result

        default:
            break
        }

        return nil
    }

    @objc(updateDB:objects:)
    @discardableResult
    func updateDB(_ files: NSArray?, objects: NSArray?) -> NSArray? {
        DCMPix.purgeCachedDictionaries()

        dontClose = true

        var addedObjects = BrowserController.currentBrowser()?.database?.addFiles(atPaths: files as? [Any], postNotifications: true, dicomOnly: true, rereadExistingItems: true, generatedByOsiriX: false, importedFiles: false, returnArray: true) as NSArray?

        addedObjects = BrowserController.currentBrowser()?.database?.objects(withIDs: addedObjects as? [Any]) as NSArray?

        if let objects = objects {
            let previousSeries = NSMutableArray()
            let newSeries = NSMutableArray()

            for image in objects {
                if previousSeries.contains((image as AnyObject).value(forKey: "series") as Any) == false {
                    addObject(previousSeries, (image as AnyObject).value(forKey: "series"))
                }
            }

            for image in addedObjects ?? [] {
                if newSeries.contains((image as AnyObject).value(forKey: "series") as Any) == false {
                    addObject(newSeries, (image as AnyObject).value(forKey: "series"))
                }
            }

            for series in newSeries {
                if previousSeries.contains(series) == false {
                    previousSeries.removeAllObjects()
                    break
                }
            }

            if previousSeries.count != newSeries.count {
                // The database structure changed because of these modifications -> Delete the previous objects WITHOUT deleting the files : we have the SAME original files

                for image in objects {
                    (image as AnyObject).setValue(NSNumber(value: false), forKey: "inDatabaseFolder")
                }

                BrowserController.currentBrowser()?.proceedDelete(objects as? [Any])

                self.updateDB(files, objects: nil)

                self.window?.close()
            }
        }

        dontClose = false

        return addedObjects
    }

    @IBAction @objc(executeAdd:)
    func executeAdd(_ sender: Any?) {
        if senderTag(sender) != 0 {
            var hexscanner: Scanner

            var group: UInt32 = 0, element: UInt32 = 0

            hexscanner = Scanner(string: addGroup?.stringValue ?? "")
            group = UInt32(clamping: hexscanner.scanUInt64(representation: .hexadecimal) ?? 0)

            hexscanner = Scanner(string: addElement?.stringValue ?? "")
            element = UInt32(clamping: hexscanner.scanUInt64(representation: .hexadecimal) ?? 0)

            if group > 0 {
                let groupsAndElements = NSMutableArray()

                let path = String(format: "(%@,%@)", String(format: "%04x", group), String(format: "%04x", element))

                let encoding = NSString.encoding(forDICOMCharacterSet: (DicomFile.getEncodingArray(forFile: srcFile) as NSArray?)?.object(at: 0) as? String)

                let value = (addValue?.stringValue as NSString?)?.data(using: encoding, allowLossyConversion: true).flatMap { NSString(data: $0, encoding: encoding) }
                groupsAndElements.addObjects(from: arrayWithObjects("-i", String(format: "%@=%@", path, value ?? "(null)")) as! [Any])

                let params = NSMutableArray(array: arrayWithObjects("dcmodify", "--verbose", "--ignore-errors") as! [Any])
                params.addObjects(from: groupsAndElements as! [Any])

                if modificationsToApplyArray == nil {
                    modificationsToApplyArray = NSMutableArray()
                }

                if modifiedFields == nil {
                    modifiedFields = NSMutableArray()
                }

                if modifiedValues == nil {
                    modifiedValues = NSMutableArray()
                }

                self.willChangeValue(forKey: "modificationsToApply")
                modificationsToApplyArray?.addObjects(from: groupsAndElements as! [Any])

                let tag = DCMAttributeTag.tag(withGroup: Int32(bitPattern: group), element: Int32(bitPattern: element)) as? DCMAttributeTag
                let dcmAttribute = DCMAttribute.attribute(with: tag) as? DCMAttribute
                dcmAttribute?.values = NSMutableArray(array: arrayWithObject(addValue?.stringValue) as! [Any])

                dcmDocument?.setAttribute(dcmAttribute)
                self.didChangeValue(forKey: "modificationsToApply")

                self.reloadFromDCMDocument()

                // The outline row carries the tag as DCMAttributeTag writes it, in
                // upper case. This was formatted in lower case and compared with
                // isEqualToString:, so a tag containing a hex letter - 0008,103E,
                // Series Description among them - never matched any row, the edit
                // was never recorded, and Apply wrote nothing. The document had
                // already been changed in memory, so the field appeared in the
                // editor and was gone again after saving and reopening. Asking the
                // tag for its own string keeps the two sides the same by
                // construction.
                let searchGpEl = tag?.stringValue

                var i = 0
                while i < (table?.numberOfRows ?? 0) {
                    if isEqualToString(attribute(table?.item(atRow: i), "attributeTag"), searchGpEl) {
                        table?.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)

                        if modifiedFields?.contains(self.getPath(table?.item(atRow: i))) ?? false {
                            let index = modifiedFields!.index(of: self.getPath(table?.item(atRow: i)))

                            modifiedFields?.removeObject(at: index)
                            modifiedValues?.removeObject(at: index)
                        }

                        addObject(modifiedFields, self.getPath(table?.item(atRow: i)))
                        addObject(modifiedValues, addValue?.stringValue)
                    }
                    i += 1
                }

                table?.reloadData()
            } else {
                HorosAlertPanel.run(title: NSLocalizedString("Add DICOM Field", comment: ""), message: NSLocalizedString("Illegal group / element values", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            }
        }

        if let addWindow = addWindow {
            addWindow.sheetParent?.endSheet(addWindow, returnCode: NSApplication.ModalResponse(rawValue: senderTag(sender)))
        }
        addWindow?.orderOut(sender)
    }

    @IBAction @objc(addDICOMField:)
    func addDICOMField(_ sender: Any?) {
        self.setGroupElement(self)
        if let addWindow = addWindow, let window = self.window {
            window.beginSheet(addWindow, completionHandler: nil)
        }
    }

    /// The expanded rows of the outline, by their path.
    private func previousOutline() -> NSMutableDictionary {
        let previousOutline = NSMutableDictionary()

        var i = 1
        while i < (table?.numberOfRows ?? 0) {
            let item = table?.item(atRow: i)

            if table?.isExpandable(item) ?? false {
                previousOutline.setValue(NSNumber(value: table?.isItemExpanded(item) ?? false), forKey: self.getPath(item))
            }
            i += 1
        }
        return previousOutline
    }

    /// The same rows expanded again, the selection, the scroll position and
    /// the first responder restored.
    private func restoreOutline(_ previousOutline: NSMutableDictionary, selectedRow: Int, origin: NSPoint) {
        table?.reloadData()
        table?.expandItem(table?.item(atRow: 0), expandChildren: false)

        var i = 1
        while i < (table?.numberOfRows ?? 0) {
            let item = table?.item(atRow: i)

            if table?.isExpandable(item) ?? false {
                let num = previousOutline.value(forKey: self.getPath(item)) as? NSNumber

                if num?.boolValue ?? false { table?.expandItem(item) }
            }
            i += 1
        }

        table?.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        tableScrollView?.contentView.scroll(to: origin)
        if let contentView = tableScrollView?.contentView {
            tableScrollView?.reflectScrolledClipView(contentView)
        }
        send(table, "setNeedsDisplay")
        self.window?.makeFirstResponder(table)
    }

    @objc(reloadFromDCMDocument)
    public func reloadFromDCMDocument() {
        let previousOutline = self.previousOutline()

        xmlDocument = dcmDocument?.xmlDocument

        let selectedRow = Int(Int32(truncatingIfNeeded: table?.selectedRow ?? 0))

        let origin = table?.superview?.bounds.origin ?? NSZeroPoint

        restoreOutline(previousOutline, selectedRow: selectedRow, origin: origin)
    }

    @objc(reload:)
    public func reload(_ sender: Any?) { // reloadFromFile
        let previousOutline = self.previousOutline()

        dcmDocument = DCMObject.object(withContentsOfFile: srcFile, decodingPixelData: false) as? DCMObject
        xmlDocument = dcmDocument?.xmlDocument

        let selectedRow = Int(Int32(truncatingIfNeeded: table?.selectedRow ?? 0))

        let origin = table?.superview?.bounds.origin ?? NSZeroPoint

        restoreOutline(previousOutline, selectedRow: selectedRow, origin: origin)

        _viewer?.checkEverythingLoaded()

        let fileSize = fileSizeInKB(srcFile)

        if _viewer != nil {
            self.window?.title = String(format: NSLocalizedString("Meta-Data: %@ (%d KB)", comment: ""), (_viewer?.window?.title ?? "(null)") as NSString, fileSize)
        } else {
            self.window?.title = String(format: NSLocalizedString("Meta-Data: %@ (%d KB)", comment: ""), (srcFile ?? "(null)") as NSString, fileSize)
        }

        dontClose = false
    }

    @objc(exportXML:)
    func exportXML(_ sender: Any?) {
        let panel = NSSavePanel()

        panel.canSelectHiddenExtension = false
        panel.allowedContentTypes = [UTType(filenameExtension: "xml")!]

        panel.nameFieldStringValue = String(format: "%@ - %@", (_imObj?.series?.study?.name ?? "(null)") as NSString, (_imObj?.series?.study?.studyName ?? "(null)") as NSString)

        panel.begin { result in
            if result != NSApplication.ModalResponse.OK {
                return
            }

            _ = try? self.xmlDocument?.xmlString.write(toFile: panel.url?.path ?? "", atomically: false, encoding: .utf8)
        }
    }

    @objc(exportText:)
    func exportText(_ sender: Any?) {
        let panel = NSSavePanel()

        panel.canSelectHiddenExtension = false
        panel.allowedContentTypes = [UTType(filenameExtension: "txt")!]

        panel.nameFieldStringValue = String(format: "%@ - %@", (_imObj?.series?.study?.name ?? "(null)") as NSString, (_imObj?.series?.study?.studyName ?? "(null)") as NSString)

        panel.begin { result in
            if result != NSApplication.ModalResponse.OK {
                return
            }

            _ = try? self.dcmDocument?.description.write(toFile: panel.url?.path ?? "", atomically: false, encoding: .utf8)
        }
    }

    @objc(windowForViewer:)
    public class func window(for v: ViewerController!) -> XMLController! {
        // Check if we have already a window displaying this ManagedObject

        let winList = NSApp.windows

        for w in winList {
            if let controller = w.windowController as? XMLController {
                if controller.viewer === v {
                    return controller
                }
            }
        }

        return nil
    }

    @objc(changeImageObject:)
    public func changeImageObject(_ image: DicomImage!) {
        if image === _imObj { return }

        let selectedRow = Int(Int32(truncatingIfNeeded: table?.selectedRow ?? 0))
        let origin = table?.superview?.bounds.origin ?? NSZeroPoint

        table?.deselectAll(self)

        _imObj = image

        srcFile = image?.value(forKey: "completePath") as? String

        xmlDocument = nil
        dcmDocument = nil

        if DicomFile.isDICOMFile(srcFile) {
            dcmDocument = DCMObject.object(withContentsOfFile: srcFile, decodingPixelData: false) as? DCMObject
            xmlDocument = dcmDocument?.xmlDocument

            isDICOM = true
        }
        // #ifndef OSIRIX_LIGHT (compiled)
        else if DicomFile.isFVTiffFile(srcFile) {
            xmlDocument = XMLControllerCAPIXMLFromFVTiff(srcFile)
        } else if DicomFile.isNIfTIFile(srcFile) {
            xmlDocument = DicomFile.getNIfTIXML(srcFile)
        }
        // #endif
        else {
            dcmDocument = DCMObject.object(withContentsOfFile: srcFile, decodingPixelData: false) as? DCMObject

            if let dcmDocument = dcmDocument {
                xmlDocument = dcmDocument.xmlDocument
                isDICOM = true
            } else {
                let rootElement = XMLElement(name: "Unsupported Meta-Data")
                xmlDocument = XMLDocument(rootElement: rootElement)
            }
        }

        table?.reloadData()
        table?.expandItem(table?.item(atRow: 0), expandChildren: false)

        table?.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        tableScrollView?.contentView.scroll(to: origin)
        if let contentView = tableScrollView?.contentView {
            tableScrollView?.reflectScrolledClipView(contentView)
        }
        send(table, "setNeedsDisplay")
        self.window?.makeFirstResponder(table)

        if validatorWindow?.isVisible ?? false {
            self.verify(self)
        }
    }

    @objc(refresh:)
    func refresh(_ notif: NSNotification) {
        let view = notif.object as? DCMView

        if dontListenToIndexChange { return }

        if (view?.is2DViewer() ?? false) && (view?.windowController() as AnyObject?) === _viewer {
            self.changeImageObject(_viewer?.currentImage())
        }
    }

    /// nil when there is no image, as the former -init returned.
    @objc(initWithImage:windowName:viewer:)
    public convenience init?(image: DicomImage!, windowName name: String!, viewer v: ViewerController!) {
        if image == nil {
            return nil
        }

        self.init(windowNibName: "XMLViewer")

        self.setMagnetic(true)

        allowSelectionChange = true
        editingLevel = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "editingLevel"))

        _viewer = v

        self.changeImageObject(image)

        let fileSize = fileSizeInKB(srcFile)

        if _viewer != nil {
            self.window?.title = String(format: NSLocalizedString("Meta-Data: %@ (%d KB)", comment: ""), (_viewer?.window?.title ?? "(null)") as NSString, fileSize)
        } else {
            self.window?.title = String(format: NSLocalizedString("Meta-Data: %@ (%d KB)", comment: ""), (srcFile ?? "(null)") as NSString, fileSize)
        }

        self.window?.setFrameAutosaveName("XMLWindow")
        self.window?.delegate = self

        table?.expandItem(table?.item(atRow: 0), expandChildren: false)

        search?.recentsAutosaveName = "xml meta data search"

        self.window?.representedFilename = srcFile ?? ""

        dictionaryArray = NSMutableArray()

        NotificationCenter.default.addObserver(self, selector: #selector(CloseViewerNotification(_:)), name: NSNotification.Name.OsirixCloseViewer, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh(_:)), name: NSNotification.Name.OsirixDCMViewIndexChanged, object: nil)

        self.setupToolbar()
    }

    @objc(CloseViewerNotification:)
    func CloseViewerNotification(_ note: NSNotification) {
        if dontClose { return }

        if (note.object as AnyObject?) === _viewer {
            _viewer = nil
        }
    }

    isolated deinit {
        NSObject.cancelPreviousPerformRequests(withTarget: self)

        NotificationCenter.default.removeObserver(self)

        _viewer = nil
        dictionaryArray = nil
        _imObj = nil
        srcFile = nil

        xmlDcmData = nil

        xmlData = nil

        xmlDocument = nil
        dcmDocument = nil
        toolbar?.delegate = nil
        toolbar = nil

        modificationsToApplyArray = nil
        modifiedFields = nil
        modifiedValues = nil
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if _editingActivated == true && (modifiedValues?.count ?? 0) > 0 {
            if HorosAlertPanel.runInformational(title: NSLocalizedString("Cancel modifications", comment: ""), message: NSLocalizedString("Are you sure you want to close the window? The modifications to DICOM fields have not been applied. The DICOM files will NOT be modified.", comment: ""), defaultButton: NSLocalizedString("Close Window", comment: ""), alternateButton: NSLocalizedString("Continue Editing", comment: ""), otherButton: nil) == HorosAlertPanel.defaultResponse {
                return true
            } else {
                return false
            }
        }

        return true
    }

    public func windowWillClose(_ notification: Notification) {
        table?.dataSource = nil
        table?.delegate = nil

        self.window?.acceptsMouseMovedEvents = false

        // Released as the former [self autorelease] did: the viewer or the
        // browser that made this controller does not keep it.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    @objc(scanThrough:forString:)
    func scanThrough(_ main: Any?, forString s: String?) -> Any? {
        let main = main as? XMLNode
        var i = 0
        while i < (main?.childCount ?? 0) {
            let item = main?.child(at: i)

            if (item?.childCount ?? 0) > 0 {
                let subItem = self.scanThrough(item, forString: s)
                if subItem != nil {
                    addObject(tree, item)
                    return subItem
                }
            }

            if self.item(item, containsString: s) {
                return item
            }
            i += 1
        }

        return nil
    }

    @IBAction @objc(setSearchString:)
    public func setSearchString(_ sender: Any?) {
        table?.reloadData()

        if (search?.stringValue as NSString?)?.length ?? 0 > 0 {
            tree = NSMutableArray()

            let item = self.scanThrough(xmlDocument, forString: search?.stringValue)

            if let item = item {
                if (tree?.count ?? 0) > 0 {
                    var i = (tree?.count ?? 0) - 1
                    while i >= 0 {
                        table?.expandItem(tree?.object(at: i))
                        i -= 1
                    }
                }

                if (table?.row(forItem: item) ?? 0) >= 0 {
                    table?.scrollRowToVisible(table?.row(forItem: item) ?? 0)
                } else if (table?.row(forItem: (item as? XMLNode)?.parent) ?? 0) >= 0 {
                    table?.scrollRowToVisible(table?.row(forItem: (item as? XMLNode)?.parent) ?? 0)
                } else {
                    for item in tree ?? [] {
                        if (table?.row(forItem: (item as? XMLNode)?.parent) ?? 0) >= 0 {
                            table?.scrollRowToVisible(table?.row(forItem: (item as? XMLNode)?.parent) ?? 0)
                            break
                        }
                    }
                }
            }
            tree = nil
        }
    }

    @objc(outlineView:shouldSelectItem:)
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any?) -> Bool {
        return true
    }

    @objc(outlineView:numberOfChildrenOfItem:)
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return xmlDocument?.childCount ?? 0
        } else {
            return (item as? XMLNode)?.childCount ?? 0
        }
    }

    @objc(outlineView:isItemExpandable:)
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any?) -> Bool {
        let node = item as? XMLNode
        if isEqualToString(node?.value(forKey: "name") as? String, "value") {
            return false
        } else {
            if node?.childCount == 1 && isEqualToString((node?.children?.first)?.value(forKey: "name") as? String, "value") {
                return false
            } else if node?.childCount == 1 && node?.children?.first?.kind == .text {
                return false
            } else if (node?.childCount ?? 0) == 0 {
                return false
            } else {
                return true
            }
        }
    }

    @objc(outlineView:child:ofItem:)
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any? {
        if item == nil {
            return xmlDocument?.child(at: index)
        } else {
            return (item as? XMLNode)?.child(at: index)
        }
    }

    /// The value of `key` of an outline item, as a string searched as the former
    /// code did; nil when the item has no value for it, and nil after the
    /// exception that -valueForKey: or -rangeOfString:options: raised in its @try.
    private func contains(_ item: Any?, key: String, _ s: String?) -> Bool {
        var found = false
        do {
            try HorosObjCException.perform {
                if let value = (item as AnyObject?)?.value(forKey: key) {
                    let range = (value as AnyObject).range(of: s ?? "", options: .caseInsensitive)
                    if range.location != NSNotFound {
                        found = true
                    }
                }
            }
        } catch {
        }
        return found
    }

    @objc(item:containsString:)
    public func item(_ item: Any?, containsString s: String?) -> Bool {
        var found = false

        if found == false {
            found = contains(item, key: "name", s)
        }

        if found == false {
            found = contains(item, key: "attributeTag", s)
        }

        if found == false {
            found = contains(item, key: "stringValue", s)
        }

        if found == false {
            found = contains(item, key: "objectValue", s)
        }

        return found
    }

    @objc(outlineView:willDisplayCell:forTableColumn:item:)
    func outlineView(_ outlineView: NSOutlineView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, item: Any) {
        let searching = ((search?.stringValue as NSString?)?.length ?? 0) != 0
        let found = searching && self.item(item, containsString: search?.stringValue)
        let modified = modifiedFields?.contains(self.getPath(item)) ?? false
        let row = outlineView.row(forItem: item)
        let selected = row >= 0 && outlineView.selectedRowIndexes.contains(row)
        var color: NSColor? = NSColor.textColor
        if selected { color = NSColor.selectedControlTextColor }
        else if modified { color = NSColor.systemRed.blended(withFraction: 0.25, of: NSColor.textColor) }
        // Nonmatches remain readable; bold matches distinguish search results without
        // reducing text contrast on alternating rows, especially in Light appearance.
        (cell as? NSTextFieldCell)?.textColor = color
        (cell as? NSCell)?.font = (found || modified) ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 12)
        (cell as? NSCell)?.lineBreakMode = .byTruncatingMiddle
    }

    @objc(traverse:string:)
    public func traverse(_ node: XMLNode!, string: NSMutableString!) {
        // The separator goes before every value but the first one appended,
        // not whenever the string is still empty: an empty first value was
        // dropped, \B\C read as B\C, and the index of a value row went
        // past the values -setObject: and -keyDown: split from it (#873).
        var first = string.length == 0
        self.appendLeafValues(node, to: string, first: &first)
    }

    private func appendLeafValues(_ node: XMLNode!, to string: NSMutableString!, first: inout Bool) {
        var i = 0

        while i < (node?.childCount ?? 0) {
            if let value = node.child(at: i)?.stringValue, node.child(at: i)?.childCount == 0 {
                if !first { string.appendFormat("\\%@", value as NSString) }
                else { string.append(value) }
                first = false
            }

            if (node.child(at: i)?.childCount ?? 0) > 0 {
                self.appendLeafValues(node.child(at: i), to: string, first: &first)
            }
            i += 1
        }
    }

    @objc(stringsSeparatedForNode:)
    public func stringsSeparated(for node: XMLNode!) -> String! {
        if (node?.childCount ?? 0) == 0 { return node?.value(forKey: "stringValue") as? String }

        let string = NSMutableString()

        self.traverse(node, string: string)

        return string as String
    }

    @objc(outlineView:objectValueForTableColumn:byItem:)
    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        let identifier = tableColumn?.identifier.rawValue

        if isEqualToString(identifier, "attributeTag") {
            if let group = (item as? XMLElement)?.attribute(forName: "group"), let element = (item as? XMLElement)?.attribute(forName: "element") {
                return String(format: "%@,%@", (group.stringValue ?? "(null)") as NSString, (element.stringValue ?? "(null)") as NSString)
            }
        } else if isEqualToString(identifier, "stringValue") {
            if outlineView.row(forItem: item) != 0 {
                if modifiedFields?.contains(self.getPath(item)) ?? false {
                    return modifiedValues?.object(at: modifiedFields!.index(of: self.getPath(item)))
                } else {
                    return self.stringsSeparated(for: item as? XMLNode)
                }
            }
        } else {
            if modifiedFields?.contains(self.getPath(item)) ?? false {
                if (modifiedValues?.object(at: modifiedFields!.index(of: self.getPath(item))) as AnyObject?) === NSNull() {
                    return String(format: NSLocalizedString("%@ (to be deleted)", comment: ""), ((item as AnyObject?)?.value(forKey: identifier ?? "") as? NSObject) ?? ("(null)" as NSString))
                }
            }

            return (item as AnyObject?)?.value(forKey: identifier ?? "")
        }
        return nil
    }

    @objc(outlineView:shouldEditTableColumn:item:)
    func outlineView(_ outlineView: NSOutlineView, shouldEdit tableColumn: NSTableColumn?, item: Any) -> Bool {
        return true
        /*
        if( [[NSUserDefaults standardUserDefaults] boolForKey:@"ALLOWDICOMEDITING"] == NO) return NO;

        if( isDICOM == NO) return NO;

        if( [[NSFileManager defaultManager] isWritableFileAtPath: [imObj valueForKey:@"completePath"]] == NO) return NO;

        if( self.editingActivated == NO) return NO;

        if( [[tableColumn identifier] isEqualToString: @"stringValue"])
        {
            if( [xmlDocument rootElement] == [item parent]) // Only elements at root level
            {
                if( [item attributeForName:@"group"] && [item attributeForName:@"element"])
                {
                    if( [[[item attributeForName:@"group"] stringValue] intValue] != 0)	//[[[item attributeForName:@"group"] stringValue] intValue] != 2 &&
                    {
                        return YES;
                    }
                }
                else if( [[[[item children] objectAtIndex: 0] children] count] == 0)	// A multiple value
                {
                    return YES;
                }
                else NSLog( @"Sequence");
            }

            return NO;
        }
        else
            return NO;
         */
    }

    /// -[NSFileManager isWritableFileAtPath:] of the image's file.
    private func isImageWritable() -> Bool {
        guard let path = _imObj?.value(forKey: "completePath") as? String else {
            return false
        }
        return FileManager.default.isWritableFile(atPath: path)
    }

    @IBAction @objc(switchEditing:)
    func switchEditing(_ sender: Any?) {
        if self.editingActivated == false {
            if isImageWritable() == false {
                HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Editing", comment: ""), message: NSLocalizedString("This file is not editable. It is a read-only file.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                _editingActivated = false
            } else if UserDefaults.standard.bool(forKey: "ALLOWDICOMEDITING") == false {
                HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Editing", comment: ""), message: NSLocalizedString("DICOM editing is deactivated.\r\rSee General - Preferences to activate it.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                _editingActivated = false
            } else if isDICOM == false {
                HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Editing", comment: ""), message: NSLocalizedString("DICOM editing is allowed only on DICOM files.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)

                _editingActivated = false
            } else {
                if showWarning {
                    let exampleAlertSuppress = "DICOM Editing Warning"
                    let defaults = UserDefaults.standard
                    if defaults.bool(forKey: exampleAlertSuppress) {
                    } else {
                        let alert = NSAlert()
                        alert.messageText = NSLocalizedString("DICOM Editing", comment: "")
                        alert.informativeText = NSLocalizedString("DICOM editing is now activated. You can edit any DICOM fields.\r\rSelect at which level you want to apply the changes (this image only, this series or the entire study.\r\rWarning !\rModifying DICOM fields can corrupt the DICOM files!\r\"With Great Power, Comes Great Responsibility\"", comment: "")
                        alert.showsSuppressionButton = true
                        alert.runModal()
                        if alert.suppressionButton?.state == .on {
                            defaults.set(true, forKey: exampleAlertSuppress)
                        }
                    }

                    showWarning = false
                }

                _editingActivated = !_editingActivated
            }
        } else if _editingActivated == true && (modifiedValues?.count ?? 0) > 0 {
            if HorosAlertPanel.runInformational(title: NSLocalizedString("Cancel modifications", comment: ""), message: NSLocalizedString("Are you sure you want to stop editing the fields? The modifications have not been applied. The DICOM files will NOT be modified.", comment: ""), defaultButton: NSLocalizedString("Cancel Modifications", comment: ""), alternateButton: NSLocalizedString("Continue Editing", comment: ""), otherButton: nil) == HorosAlertPanel.defaultResponse {
                modificationsToApplyArray?.removeAllObjects()
                modifiedValues?.removeAllObjects()
                modifiedFields?.removeAllObjects()

                self.reload(self)

                _editingActivated = !_editingActivated
            } else {
                _editingActivated = true
            }
        } else {
            _editingActivated = !_editingActivated
        }

        (sender as? NSButton)?.state = _editingActivated ? .on : .off

        self.willChangeValue(forKey: "editingActivated")
        self.didChangeValue(forKey: "editingActivated")
    }

    /// The path of a value of a multi-valued element and its index: the
    /// element's path, and the number between its last brackets. Reading only
    /// the digit before the closing bracket read (0020,0037)[10] as value 0
    /// of an element addressed as "(0020,0037)[".
    private func valuePathAndIndex(_ path: String) -> (path: String, index: Int32) {
        let string = path as NSString
        let open = string.range(of: "[", options: .backwards)

        guard open.location != NSNotFound, string.hasSuffix("]") else {
            return (path, 0)
        }

        let index = intValue(string.substring(with: NSMakeRange(open.location + 1, string.length - open.location - 2)))

        return (string.substring(to: open.location), index)
    }

    /// The value row of a multi-valued element - a `value` under an attribute -
    /// and that attribute; nil for any other row.
    private func valueRow(_ node: XMLNode?) -> (value: XMLElement, element: XMLElement)? {
        guard let value = node as? XMLElement, isEqualToString(value.name, "value"),
              let element = value.parent as? XMLElement,
              attribute(element, "group") != nil, attribute(element, "element") != nil else {
            return nil
        }
        return (value, element)
    }

    /// The outline items whose address is one of `paths`.
    private func nodes(atPaths paths: Set<String>) -> [String: XMLNode] {
        var found: [String: XMLNode] = [:]

        func visit(_ node: XMLNode) {
            let path = self.getPath(node)
            if paths.contains(path) && found[path] == nil {
                found[path] = node
            }
            for child in node.children ?? [] where child.kind == .element {
                visit(child)
            }
        }

        for child in xmlDocument?.children ?? [] {
            visit(child)
        }
        return found
    }

    /// What to write for the rows recorded as edited or deleted that are values
    /// of a multi-valued element, such as (0008,0008)[1]: the element's address
    /// and all its values, the edited ones replaced and the deleted ones
    /// removed, the same for every row of that element. The writer replaces an
    /// element, not one of its values: handing it the row as it was recorded
    /// wrote the element with the edited value alone, or deleted the whole
    /// element for one deleted value. The indexes are those of the file as
    /// read, which the rows keep until the edits are applied. nil for a row of
    /// an element whose own row is also edited or deleted, which decides it.
    private func multiValuedElementEdits() -> [String: (path: String, value: String)?] {
        let fields = (modifiedFields as? [String]) ?? []
        let candidates = Set(fields.filter { $0.hasSuffix("]") })

        if candidates.isEmpty {
            return [:]
        }

        let nodes = self.nodes(atPaths: candidates)
        var elements: [String: (element: XMLElement, rows: [(field: String, index: Int, value: Any?)])] = [:]

        for (i, field) in fields.enumerated() where candidates.contains(field) {
            guard let row = valueRow(nodes[field]),
                  let index = row.element.children?.firstIndex(where: { $0 === row.value }) else {
                continue
            }
            let path = self.getPath(row.element)
            var entry = elements[path] ?? (row.element, [])
            entry.rows.append((field, index, modifiedValues?.object(at: i)))
            elements[path] = entry
        }

        var edits: [String: (path: String, value: String)?] = [:]

        for (path, entry) in elements {
            if fields.contains(path) {
                for row in entry.rows { edits[row.field] = .some(nil) }
                continue
            }

            var values: [String?] = (entry.element.children ?? []).map { $0.stringValue ?? "" }
            for row in entry.rows {
                if (row.value as AnyObject?) === NSNull() {
                    values[row.index] = nil
                } else {
                    values[row.index] = (row.value as? String) ?? ""
                }
            }

            let value = values.compactMap { $0 }.joined(separator: "\\")
            for row in entry.rows { edits[row.field] = .some((path, value)) }
        }
        return edits
    }

    @objc(setObject:)
    func setObject(_ array: NSArray) {
        let groupsAndElements = NSMutableArray()

        let item = array.object(at: 0)
        var object: Any? = array.object(at: 1)

        let encoding = NSString.encoding(forDICOMCharacterSet: (DicomFile.getEncodingArray(forFile: srcFile) as NSArray?)?.object(at: 0) as? String)

        object = (object as? NSString)?.data(using: encoding, allowLossyConversion: true).flatMap { NSString(data: $0, encoding: encoding) }

        if (table?.row(forItem: item) ?? 0) > 0 {
            var path = self.getPath(item)

            if attribute(item, "group") != nil && attribute(item, "element") != nil {
                groupsAndElements.addObjects(from: arrayWithObjects("-i", String(format: "%@=%@", path, (object as? NSObject) ?? ("(null)" as NSString))) as! [Any])
            } else { // A multiple value or a sequence, not an element
                if ((item as? XMLNode)?.children?.first?.children?.count ?? 0) == 0 {
                    let (valuePath, index) = valuePathAndIndex(path)

                    path = valuePath

                    NSLog("%@", path)
                    NSLog("%d", index)

                    let values = NSMutableArray(array: (self.stringsSeparated(for: (item as? XMLNode)?.parent) as NSString?)?.components(separatedBy: "\\") ?? [])

                    replaceObject(values, Int(index), object)

                    groupsAndElements.addObjects(from: arrayWithObjects("-i", String(format: "%@=%@", path, values.componentsJoined(by: "\\"))) as! [Any])
                } else {
                    NSLog("A sequence: not editable")
                }
            }
        }

        if groupsAndElements.count > 0 {
            if modificationsToApplyArray == nil {
                modificationsToApplyArray = NSMutableArray()
            }

            if modifiedFields == nil {
                modifiedFields = NSMutableArray()
            }

            if modifiedValues == nil {
                modifiedValues = NSMutableArray()
            }

            self.willChangeValue(forKey: "modificationsToApply")
            modificationsToApplyArray?.addObjects(from: groupsAndElements as! [Any])

            if modifiedFields?.contains(self.getPath(item)) ?? false {
                let index = modifiedFields!.index(of: self.getPath(item))

                modifiedFields?.removeObject(at: index)
                modifiedValues?.removeObject(at: index)
            }

            addObject(modifiedFields, self.getPath(item))
            addObject(modifiedValues, object)
            self.didChangeValue(forKey: "modificationsToApply")

            table?.reloadData()
        }

        allowSelectionChange = true
    }

    @objc(modificationsToApply)
    public func modificationsToApply() -> Bool {
        if (modificationsToApplyArray?.count ?? 0) > 0 {
            return true
        } else {
            return false
        }
    }

    @IBAction @objc(applyModifications:)
    func applyModifications(_ sender: Any?) {
        if (modificationsToApplyArray?.count ?? 0) > 0 {

            let objects = self.arrayOfFiles()
            let files: NSMutableArray? = NSMutableArray(array: (objects?.value(forKey: "completePath") as? [Any]) ?? [])

            if let files = files {
                files.removeDuplicatedStrings()


                var wait: WaitRendering? = nil
                if files.count > 1 {
                    wait = WaitRendering(NSLocalizedString("Updating Files...", comment: ""))
                    wait?.showWindow(self)
                }

                // Kept alive through the edit, as [self retain] / [self autorelease] did.
                _ = Unmanaged.passUnretained(self).retain()

                do {
                    try HorosObjCException.perform {



                        let tagAndValues = NSMutableArray()
                        let multiValued = self.multiValuedElementEdits()
                        var writtenElements = Set<String>()

                        var i = 0
                        while i < (self.modifiedFields?.count ?? 0) {
                            var field = self.modifiedFields!.object(at: i) as! String
                            var value = self.modifiedValues!.object(at: i)

                            // A value of a multi-valued element is written as the
                            // whole element, once, with its other values.
                            if let edit = multiValued[field] {
                                guard let edit = edit, writtenElements.insert(edit.path).inserted else {
                                    i += 1
                                    continue
                                }
                                field = edit.path
                                value = edit.value
                            }

                            // The row's address, not its first tag. -[DCMAttributeTag
                            // initWithTagString:] scans the first (gggg,eeee) and drops
                            // the rest, so an edit inside a sequence -
                            // (0054,0016)[0].(0018,1074) - was addressed to the
                            // sequence element and never reached the value.
                            var tag: Any? = DICOMTagPath.path(with: field)

                            if tag == nil {
                                tag = DCMAttributeTag.tag(withTagString: field)
                            }

                            if tag == nil {
                                i += 1
                                continue
                            }

                            // Delete marks the row with NSNull and shows it as "to be
                            // deleted". That marker used to be handed to the writer as
                            // if it were a value: it is not a string, so the edit was
                            // dropped and reported as a file that could not be written,
                            // and the tag stayed in the file. An entry of one element
                            // is a removal; two is a replacement, and an empty string
                            // there empties the element without removing it.
                            if (value as AnyObject) === NSNull() {
                                tagAndValues.add(arrayWithObject(tag))
                            } else {
                                tagAndValues.add(arrayWithObjects(tag, value))
                            }
                            i += 1
                        }

                        // The result was discarded, so a file that could not be written
                        // looked exactly like a successful edit.
                        var reasons: NSArray? = nil
                        if XMLControllerCAPIModifyDicom(tagAndValues as? [Any], files as? [Any], &reasons) == false {
                            var detail = String(format: NSLocalizedString("Some requested edits could not be applied to the %d selected files. Review the results below before retrying.", comment: ""), Int32(truncatingIfNeeded: files.count))

                            // Naming the fields that were refused, and why, is the
                            // difference between a dead end and a fixable mistake.
                            if (reasons?.count ?? 0) > 0 {
                                detail = detail.appendingFormat("\n\n%@", reasons!.componentsJoined(by: "\n"))
                            }

                            HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Editing", comment: ""),
                                                        message: detail, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                        }



                        for loopItem in files {
                            try? FileManager.default.removeItem(atPath: (loopItem as! NSString).appending(".bak"))
                        }

                        self.updateDB(files, objects: objects)
                    }
                } catch {
                    NSLog("xml setObject: %@", (exception(error) as NSObject?) ?? (error as NSError))
                }
                wait?.close()
                wait = nil

                if self.window?.isVisible ?? false { // If DB fields were modified : the database window will close the XML editor
                    self.reload(self)
                }

                _ = Unmanaged.passUnretained(self).autorelease()
            }

            modificationsToApplyArray?.removeAllObjects()
            modifiedFields?.removeAllObjects()
            modifiedValues?.removeAllObjects()
        }
    }

    @objc(selectionShouldChangeInOutlineView:)
    func selectionShouldChange(in outlineView: NSOutlineView) -> Bool {
        return allowSelectionChange
    }

    @objc(outlineView:setObjectValue:forTableColumn:byItem:)
    func outlineView(_ outlineView: NSOutlineView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, byItem item: Any?) {
        let previousValue = self.outlineView(outlineView, objectValueFor: tableColumn, byItem: item)

        if isEqualToString(tableColumn?.identifier.rawValue, "stringValue") == false {
            if (previousValue as AnyObject?)?.isEqual(object) != true {
                HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Editing", comment: ""), message: NSLocalizedString("You can only edit the 'Content' column.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }

            return
        }

        if (previousValue as AnyObject?)?.isEqual(object) != true {
            if UserDefaults.standard.bool(forKey: "ALLOWDICOMEDITING") && isDICOM && self.editingActivated && isImageWritable() {
                allowSelectionChange = false
                self.perform(#selector(setObject(_:)), with: arrayWithObjects(item, object), afterDelay: 0)
            } else {
                if UserDefaults.standard.bool(forKey: "ALLOWDICOMEDITING") == false || self.editingActivated == false {
                    HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Editing", comment: ""), message: NSLocalizedString("Activate DICOM editing to change the values.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                } else {
                    HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Editing", comment: ""), message: NSLocalizedString("DICOM editing not possible for this file.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
            }
        }
    }

    @IBAction @objc(validatorWebSite:)
    public func validatorWebSite(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "http://www.dclunie.com/dicom3tools/dciodvfy.html")!)
    }

    @IBAction @objc(verify:)
    public func verify(_ sender: Any?) {
        if isDICOM == false {
            HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Validator", comment: ""), message: NSLocalizedString("DICOM Validator requires a DICOM file.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        // The validator reports on stderr and exits non-zero when it finds problems,
        // which is a normal result. The bundled helper is arm64; an Intel leftover
        // is named and is not launched under Rosetta. The command stays in Resources.
        let validator = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("/dciodvfy")
        let archReason = HorosArchitectureAudit.helperDiagnosis(at: validator)
        if (archReason as NSString?)?.length ?? 0 > 0 {
            HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Validator", comment: ""),
                                        message: archReason!, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        var options = HorosBoundedTaskOptions()
        options.timeout = 30.0
        options.capturesStandardError = true
        options.allowsFailureStatus = true
        var taskError: NSError? = nil
        let resData = HorosRunBoundedTaskWithOptions(validator, [srcFile as Any], options, &taskError)

        var resString: String? = nil

        if let resData = resData {
            resString = String(data: resData, encoding: .utf8)

            if resString == nil {
                resString = NSString(data: resData, encoding: String.Encoding.ascii.rawValue) as String?
            }
        }

        if (resString as NSString?)?.length ?? 0 == 0 {
            var reason = taskError?.localizedDescription ?? NSLocalizedString("The validator produced no output.", comment: "")

            if FileManager.default.isExecutableFile(atPath: validator) == false {
                reason = NSLocalizedString("The validator is missing from the application bundle.", comment: "")
            }

            HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Validator", comment: ""),
                                        message: String(format: NSLocalizedString("The DICOM validator could not check this file: %@", comment: ""), reason as NSString), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        validatorText?.string = resString!

        validatorWindow?.makeKeyAndOrderFront(self)
        validatorWindow?.title = srcFile ?? ""
    }

    @IBAction @objc(sortSeries:)
    func sortSeries(_ sender: Any?) {
        let selectedRowIndexes = table?.selectedRowIndexes ?? IndexSet()

        if selectedRowIndexes.count != 1 {
            HorosAlertPanel.run(title: NSLocalizedString("Sort Series Images", comment: ""), message: NSLocalizedString("Select an element to use to sort the images of the series.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        let index = Int32(truncatingIfNeeded: selectedRowIndexes.first ?? NSNotFound)
        let item = table?.item(atRow: Int(index))

        if index > 0 && item != nil && attributeObjectValue(item, "group") != nil && attributeObjectValue(item, "element") != nil {
            if HorosAlertPanel.runInformational(title: NSLocalizedString("Sort Series Images", comment: ""), message: NSLocalizedString("Are you sure you want to re-sort the series images according to this field?", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) == HorosAlertPanel.defaultResponse {
                var gr: UInt32 = 0, el: UInt32 = 0

                dontListenToIndexChange = true

                do {
                    try HorosObjCException.perform {
                        gr = UInt32(clamping: Scanner(string: attributeObjectValue(item, "group") as! String).scanUInt64(representation: .hexadecimal) ?? 0)
                        el = UInt32(clamping: Scanner(string: attributeObjectValue(item, "element") as! String).scanUInt64(representation: .hexadecimal) ?? 0)

                        if gr > 0 {
                            NSLog("Sort by 0x%04X / 0x%04X", gr, el)
                            _ = self._viewer?.sortSeries(byDICOMGroup: Int32(bitPattern: gr), element: Int32(bitPattern: el))
                        }
                    }
                } catch {
                    NSLog("%@", (exception(error) as NSObject?) ?? (error as NSError))
                    HorosAlertPanel.run(title: NSLocalizedString("Sort Series Images", comment: ""), message: NSLocalizedString("Select an element to use to sort the images of the series.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }

                dontListenToIndexChange = false
            }
        } else {
            HorosAlertPanel.run(title: NSLocalizedString("Sort Series Images", comment: ""), message: NSLocalizedString("Select an element to use to sort the images of the series.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    public override func keyDown(with event: NSEvent) {
        if ((event.characters as NSString?)?.length ?? 0) == 0 { return }

        let c = Int((event.characters! as NSString).character(at: 0))

        if self.editingActivated && isImageWritable() && UserDefaults.standard.bool(forKey: "ALLOWDICOMEDITING") && isDICOM && (c == NSDeleteFunctionKey || c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteCharFunctionKey) {
            if HorosAlertPanel.runInformational(title: NSLocalizedString("DICOM Editing", comment: ""), message: NSLocalizedString("Are you sure you want to delete selected field(s)?", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) == HorosAlertPanel.defaultResponse {
                let selectedRowIndexes = (table?.selectedRowIndexes ?? IndexSet()) as NSIndexSet

                var index = selectedRowIndexes.firstIndex
                while 1 &+ selectedRowIndexes.lastIndex != index {
                    if selectedRowIndexes.contains(index) {
                        let item = table?.item(atRow: index)

                        if index > 0 {
                            let groupsAndElements = NSMutableArray()
                            var path = self.getPath(item)

                            if attribute(item, "group") != nil && attribute(item, "element") != nil {
                                groupsAndElements.addObjects(from: arrayWithObjects("-e", path) as! [Any])
                            } else { // A multiple value or a sequence, not an element
                                if ((item as? XMLNode)?.children?.first?.children?.count ?? 0) == 0 {
                                    let (valuePath, index) = valuePathAndIndex(path)

                                    path = valuePath

                                    NSLog("%@", path)
                                    NSLog("%d", index)

                                    let values = NSMutableArray(array: (self.stringsSeparated(for: (item as? XMLNode)?.parent) as NSString?)?.components(separatedBy: "\\") ?? [])

                                    values.removeObject(at: Int(index))

                                    groupsAndElements.addObjects(from: arrayWithObjects("-i", String(format: "%@=%@", path, values.componentsJoined(by: "\\"))) as! [Any])
                                } else {
                                    NSLog("A sequence : not editable")
                                }
                            }

                            if groupsAndElements.count > 0 {
                                if modificationsToApplyArray == nil {
                                    modificationsToApplyArray = NSMutableArray()
                                }

                                if modifiedFields == nil {
                                    modifiedFields = NSMutableArray()
                                }

                                if modifiedValues == nil {
                                    modifiedValues = NSMutableArray()
                                }

                                self.willChangeValue(forKey: "modificationsToApply")
                                modificationsToApplyArray?.addObjects(from: groupsAndElements as! [Any])

                                if modifiedFields?.contains(self.getPath(item)) ?? false {
                                    let index = modifiedFields!.index(of: self.getPath(item))

                                    modifiedFields?.removeObject(at: index)
                                    modifiedValues?.removeObject(at: index)
                                }

                                addObject(modifiedFields, self.getPath(item))
                                modifiedValues?.add(NSNull())
                                self.didChangeValue(forKey: "modificationsToApply")

                                table?.reloadData()
                            }
                        }
                    }
                    index += 1
                }
            }
        } else {
            super.keyDown(with: event)
        }
    }

    @objc(copy:)
    func copy(_ sender: Any?) {
        let selectedRowIndexes = (table?.selectedRowIndexes ?? IndexSet()) as NSIndexSet
        let copyString = NSMutableString()

        var index = selectedRowIndexes.firstIndex
        while 1 &+ selectedRowIndexes.lastIndex != index {
            if selectedRowIndexes.contains(index) {
                let item = table?.item(atRow: index)

                if copyString.length > 0 { copyString.append("\r") }

                if let group = attribute(item, "group"), let element = attribute(item, "element") {
                    copyString.appendFormat("%@ (%@,%@) %@", ((item as AnyObject?)?.value(forKey: "name") as? NSObject) ?? ("(null)" as NSString), group as NSString, element as NSString, (self.stringsSeparated(for: item as? XMLNode) ?? "(null)") as NSString)
                } else {
                    copyString.appendFormat("%@ %@", ((item as AnyObject?)?.value(forKey: "name") as? NSObject) ?? ("(null)" as NSString), (self.stringsSeparated(for: item as? XMLNode) ?? "(null)") as NSString)
                }

                NSLog("%@", ((item as AnyObject?)?.description ?? "(null)") as NSString)

                NSLog("---")

                NSLog("%@", ((item as AnyObject?)?.value(forKey: "name") as? NSObject) ?? ("(null)" as NSString))

                NSLog("%@", (attribute(item, "group") ?? "(null)") as NSString)
                NSLog("%@", (attribute(item, "element") ?? "(null)") as NSString)

                NSLog("%@", (attribute(item, "attributeTag") ?? "(null)") as NSString)

                NSLog("%@", ((item as AnyObject?)?.value(forKey: "stringValue") as? NSObject) ?? ("(null)" as NSString))

                NSLog("---")

                NSLog("%@", (self.stringsSeparated(for: item as? XMLNode) ?? "(null)") as NSString)
            }
            index += 1
        }

        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: self)
        pb.setString(copyString as String, forType: .string)
    }

    // ============================================================
    // NSToolbar Related Methods
    // ============================================================

    @objc(setupToolbar)
    public func setupToolbar() {
        // Create a new toolbar instance, and attach it to our document window
        toolbar = NSToolbar(identifier: XMLToolbarIdentifier)

        // Set up toolbar properties: Allow customization, give a default display mode, and remember state in user defaults
        toolbar?.allowsUserCustomization = true
        toolbar?.autosavesConfiguration = true
        // We are the delegate
        toolbar?.delegate = self

        // Attach the toolbar to the document window
        self.window?.toolbar = toolbar
        self.window?.showsToolbarButton = false
        self.window?.toolbar?.isVisible = true
        ToolbarPolicy.adopt(toolbar: toolbar, in: self.window)

    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let itemIdent = itemIdentifier.rawValue
        // Required delegate method:  Given an item identifier, this method returns an item
        // The toolbar will use this method to obtain toolbar items that can be displayed in the customization sheet, or in the toolbar itself
        if let spaceItem = ToolbarPolicy.spaceItem(for: itemIdent) {
            return spaceItem
        }

        var toolbarItem: NSToolbarItem? = NSToolbarItem(itemIdentifier: itemIdentifier)

        if isEqualToString(itemIdent, ExportToolbarItemIdentifier) {
            toolbarItem?.label = NSLocalizedString("Export XML", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Export XML", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Export these XML Data in a XML File", comment: "")
            toolbarItem?.image = NSImage(named: "Export")
            toolbarItem?.target = self
            toolbarItem?.action = #selector(exportXML(_:))
        } else if isEqualToString(itemIdent, EditingToolbarItemIdentifier) {
            toolbarItem?.label = NSLocalizedString("DICOM Editing", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("DICOM Editing", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("DICOM Editing", comment: "")

            toolbarItem?.view = dicomEditingView
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: dicomEditingView), maximum: ToolbarPolicy.designedSize(of: dicomEditingView))
        } else if isEqualToString(itemIdent, SearchToolbarItemIdentifier) {
            toolbarItem?.label = NSLocalizedString("Search", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Search", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Search", comment: "")

            toolbarItem?.view = searchView
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: searchView), maximum: ToolbarPolicy.designedSize(of: searchView))
        } else if isEqualToString(itemIdent, ExportTextToolbarItemIdentifier) {
            toolbarItem?.label = NSLocalizedString("Export Text", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Export Text", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Export these XML Data in a Text File", comment: "")
            toolbarItem?.image = NSImage(named: "Export")
            toolbarItem?.target = self
            toolbarItem?.action = #selector(exportText(_:))
        } else if isEqualToString(itemIdent, ExpandAllItemsToolbarItemIdentifier) {
            toolbarItem?.label = NSLocalizedString("Expand All", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Expand All Items", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Expand All Items", comment: "")
            toolbarItem?.image = NSImage(named: ExpandAllItemsToolbarItemIdentifier)
            toolbarItem?.target = self
            toolbarItem?.action = #selector(deepExpandAllItems(_:))
        } else if isEqualToString(itemIdent, CollapseAllItemsToolbarItemIdentifier) {
            toolbarItem?.label = NSLocalizedString("Collapse All", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Collapse All Items", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Collapse All Items", comment: "")
            toolbarItem?.image = NSImage(named: CollapseAllItemsToolbarItemIdentifier)
            toolbarItem?.target = self
            toolbarItem?.action = #selector(deepCollapseAllItems(_:))
        } else if isEqualToString(itemIdent, SortSeriesToolbarItemIdentifier) {
            toolbarItem?.label = NSLocalizedString("Sort Images", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Sort Images", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Sort Series Images by selected element", comment: "")
            toolbarItem?.image = NSImage(named: "Revert.tif")
            toolbarItem?.target = self
            toolbarItem?.action = #selector(sortSeries(_:))
        } else if isEqualToString(itemIdent, VerifyToolbarItemIdentifier) {
            toolbarItem?.label = NSLocalizedString("Validator", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Validator", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Validate the DICOM format", comment: "")
            toolbarItem?.image = NSImage(named: "NSInfo")
            toolbarItem?.target = self
            toolbarItem?.action = #selector(verify(_:))
        } else {
            toolbarItem = nil
        }

        for (_, plugin) in (PluginManager.plugins() as NSDictionary?) ?? NSDictionary() {
            if (plugin as AnyObject).responds(to: #selector(PluginFilter.toolbarItem(forItemIdentifier:forViewer:))) {
                let item = (plugin as AnyObject).toolbarItem?(forItemIdentifier: itemIdent, forViewer: self) ?? nil

                if let item = item {
                    toolbarItem = item
                }
            }
        }

        if toolbarItem != nil {
            ToolbarPolicy.prepare(toolbarItem)
        }

        return toolbarItem
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Required delegate method:  Returns the ordered list of items to be shown in the toolbar by default
        // If during the toolbar's initialization, no overriding values are found in the user defaults, or if the
        // user chooses to revert to the default items this set will be used
        return [NSToolbarItem.Identifier(ExportToolbarItemIdentifier),
                NSToolbarItem.Identifier(ExportTextToolbarItemIdentifier),
                NSToolbarItem.Identifier(ExpandAllItemsToolbarItemIdentifier),
                NSToolbarItem.Identifier(CollapseAllItemsToolbarItemIdentifier),
                .flexibleSpace,
                NSToolbarItem.Identifier(EditingToolbarItemIdentifier),
                NSToolbarItem.Identifier(SortSeriesToolbarItemIdentifier),
                NSToolbarItem.Identifier(VerifyToolbarItemIdentifier),
                .flexibleSpace,
                NSToolbarItem.Identifier(SearchToolbarItemIdentifier)]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Required delegate method:  Returns the list of all allowed items by identifier.  By default, the toolbar
        // does not assume any items are allowed, even the separator.  So, every allowed item must be explicitly listed
        // The set of allowed items is used to construct the customization palette
        let array = NSMutableArray(array: [NSToolbarItem.Identifier.flexibleSpace.rawValue,
                                           ToolbarPolicy.spaceItemIdentifier,
                                           ExportToolbarItemIdentifier,
                                           ExportTextToolbarItemIdentifier,
                                           ExpandAllItemsToolbarItemIdentifier,
                                           CollapseAllItemsToolbarItemIdentifier,
                                           EditingToolbarItemIdentifier,
                                           SortSeriesToolbarItemIdentifier,
                                           VerifyToolbarItemIdentifier,
                                           SearchToolbarItemIdentifier])

        for (_, plugin) in (PluginManager.plugins() as NSDictionary?) ?? NSDictionary() {
            if (plugin as AnyObject).responds(to: #selector(PluginFilter.toolbarAllowedIdentifiers(forViewer:))) {
                array.addObjects(from: ((plugin as AnyObject).toolbarAllowedIdentifiers?(forViewer: self) ?? nil) ?? [])
            }
        }

        return array.compactMap { ($0 as? String).map { NSToolbarItem.Identifier($0) } }
    }

    @objc(validateToolbarItem:)
    func validateToolbarItem(_ toolbarItem: NSToolbarItem) -> Bool {
        // Optional method:  This message is sent to us since we are the target of some toolbar item actions
        // (for example:  of the save items action)

        var enable = true

        if isEqualToString(toolbarItem.itemIdentifier.rawValue, SortSeriesToolbarItemIdentifier) {
            if _viewer != nil { enable = true }
        }

        return enable
    }

    @objc(expandAllItems:)
    public func expandAllItems(_ sender: Any?) {
        self.expandAll(false)
    }

    @objc(deepExpandAllItems:)
    public func deepExpandAllItems(_ sender: Any?) {
        self.expandAll(true)
    }

    @objc(expandAll:)
    public func expandAll(_ deep: Bool) {
        var i: Int32 = 0
        while i < Int32(truncatingIfNeeded: table?.numberOfRows ?? 0) {
            table?.expandItem(table?.item(atRow: Int(i)), expandChildren: deep)
            i += 1
        }
    }

    @objc(collapseAllItems:)
    public func collapseAllItems(_ sender: Any?) {
        self.collapseAll(false)
    }

    @objc(deepCollapseAllItems:)
    public func deepCollapseAllItems(_ sender: Any?) {
        self.collapseAll(true)
    }

    @objc(collapseAll:)
    public func collapseAll(_ deep: Bool) {
        var i: Int32 = 1
        while i < Int32(truncatingIfNeeded: table?.numberOfRows ?? 0) { // starting from 1, so the DICOMObject is not collapsed
            table?.collapseItem(table?.item(atRow: Int(i)), collapseChildren: deep)
            i += 1
        }
    }

    @IBAction @objc(setGroupElement:)
    public func setGroupElement(_ sender: Any?) {
        if (dictionaryArray?.count ?? 0) == 0 { XMLControllerCAPIPrepareDictionaryArray(self) }

        var hexscanner: Scanner

        var group: UInt32 = 0, element: UInt32 = 0

        hexscanner = Scanner(string: addGroup?.stringValue ?? "")
        group = UInt32(clamping: hexscanner.scanUInt64(representation: .hexadecimal) ?? 0)

        hexscanner = Scanner(string: addElement?.stringValue ?? "")
        element = UInt32(clamping: hexscanner.scanUInt64(representation: .hexadecimal) ?? 0)

        addGroup?.stringValue = String(format: "0x%04x", group)
        addElement?.stringValue = String(format: "0x%04x", element)

        let string = String(format: "(0x%04x,0x%04x)", group, element)


        for loopItem in dictionaryArray ?? [] {
            let loopItem = loopItem as! NSString
            if isEqualToString(loopItem.substring(to: 15), string) {
                NSLog("%@", loopItem)
                dicomFieldsCombo?.stringValue = loopItem.substring(from: 16)

                return
            }
        }

        dicomFieldsCombo?.stringValue = ""
    }

    @IBAction @objc(setTagName:)
    public func setTagName(_ sender: Any?) {
        if (dictionaryArray?.count ?? 0) == 0 { XMLControllerCAPIPrepareDictionaryArray(self) }

        var string = ((sender as? NSControl)?.stringValue as NSString?) ?? ""

        if string.length > 0 {
            if string.character(at: 0) == UInt16(UInt8(ascii: "(")) {
                string = string.substring(from: 16) as NSString
            }

            (sender as? NSControl)?.stringValue = string as String

            var gp: Int32 = 0, el: Int32 = 0

            if XMLControllerCAPIGetGroupAndElementForName(self, string as String, &gp, &el) == 0 {
                addGroup?.stringValue = String(format: "0x%04x", gp)
                addElement?.stringValue = String(format: "0x%04x", el)
            } else {
                addGroup?.stringValue = ""
                addElement?.stringValue = ""
            }
        }
    }

    @objc(comboBox:completedString:)
    func comboBox(_ aComboBox: NSComboBox, completedString uncompletedString: String) -> String? {
        if (dictionaryArray?.count ?? 0) == 0 { XMLControllerCAPIPrepareDictionaryArray(self) }

        if (uncompletedString as NSString).length == 0 { return nil }


        for loopItem in dictionaryArray ?? [] {
            let loopItem = loopItem as! NSString
            if (loopItem.substring(from: 16) as NSString).uppercased.hasPrefix((uncompletedString as NSString).uppercased) {
                return loopItem.substring(from: 16)
            }
        }

        return nil
    }

    @objc(numberOfItemsInComboBox:)
    func numberOfItems(in aComboBox: NSComboBox) -> Int {
        if (dictionaryArray?.count ?? 0) == 0 { XMLControllerCAPIPrepareDictionaryArray(self) }

        return dictionaryArray?.count ?? 0
    }

    @objc(comboBox:objectValueForItemAtIndex:)
    func comboBox(_ aComboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        if (dictionaryArray?.count ?? 0) == 0 { XMLControllerCAPIPrepareDictionaryArray(self) }

        return dictionaryArray?.object(at: index)
    }
}

// The class methods of XMLControllerDCMTKCategory, for Swift callers, which
// cannot see the category: they send the same messages.
extension XMLController {
    // Runs dcmodify on the calling thread: the entities call it from any thread.
    @nonobjc @discardableResult
    public nonisolated class func modifyDicom(_ tagAndValues: [Any]!, dicomFiles: [Any]!) -> Bool {
        return XMLControllerCAPIModifyDicom(tagAndValues, dicomFiles, nil)
    }
}
