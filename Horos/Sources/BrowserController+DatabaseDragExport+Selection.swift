/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXDICOMDataset
import UniformTypeIdentifiers
import IsiXDatabase

// The second half of the "database drag export" block of
// BrowserController (from -databasePressed: to -saveDBListAs:) is implemented
// in Swift: an extension of BrowserController, with the selectors of the
// former methods. The state it uses is read through the class's accessors
// (BrowserController+StateAccess.swift). Printing the selection is
// PrintSelection's, finding and loading series from a viewer is the
// browser's ViewerOpener's, and the lists exported are StudyListExport's: the
// selectors stay here for the nib, the menus, the viewers, scripting and the
// plugins.
//
// A message to nil is optional chaining with the Objective-C default (nil, 0,
// NO).

/// `[object selector]` of a method returning an object, nil for a nil object
/// or one that does not answer: the list also holds surgical records.
fileprivate func objcSend(_ object: Any?, _ selector: String) -> Any? {
    guard let object = object as? NSObject, object.responds(to: NSSelectorFromString(selector)) else { return nil }
    return object.perform(NSSelectorFromString(selector))?.takeUnretainedValue()
}

/// `[object isDistant]`, NO for nil: DicomStudy, DicomSeries, DicomImage and
/// the DCMTK query nodes all answer it.
fileprivate func objcIsDistant(_ object: Any?) -> Bool {
    guard let object else { return false }
    return (object as AnyObject).isDistant?() ?? false
}

/// `[object intValue]` of an NSNumber or an NSString, 0 for nil.
fileprivate func objcIntValue(_ object: Any?) -> Int32 {
    if let number = object as? NSNumber { return number.int32Value }
    if let string = object as? NSString { return string.intValue }
    return 0
}

/// `[[object valueForKey:@"type"] isEqualToString:type]`, NO for nil.
fileprivate func objcIsType(_ object: Any?, _ type: String) -> Bool {
    guard let object = object as? NSObject else { return false }
    return (object.value(forKey: "type") as? NSString)?.isEqual(to: type) ?? false
}

public extension BrowserController {

    // MARK: - database drag export

    @objc(databasePressed:)
    func databasePressed(_ sender: Any!) {
        resetROIsAndKeysButton()
    }

    @objc(print:)
    func print(_ sender: Any!) {
        printDatabaseSelection(sender)
    }

    @objc(printDatabaseSelection:)
    func printDatabaseSelection(_ sender: Any!) {
        PrintSelection.printSelection(of: self, sender: sender)
    }

    @objc(printDatabaseSpool:)
    func printDatabaseSpool(_ object: Any!) {
        PrintSelection.printSpool(object as? PrintSpool)
    }

    @objc(databaseDoublePressed:)
    func databaseDoublePressed(_ sender: Any!) {
        if ((sender as? NSTableView)?.clickedRow ?? 0) != -1 {
            let databaseOutline = horos_databaseOutline
            let clickedRow = databaseOutline?.clickedRow ?? 0
            let item = databaseOutline?.item(atRow: clickedRow != -1 ? clickedRow : databaseOutline?.selectedRow ?? 0)

            // A surgical record has no images, here or on a node, to open or ask for.
            if item is SurgicalProcedureOutlineRow { return }

            if objcIntValue(objcSend(item, "numberOfImages")) != 0 {
                if objcIsDistant(item) {
                    var study = item

                    if item is DCMTKSeriesQueryNode {
                        study = (item as? DCMTKSeriesQueryNode)?.study
                    }

                    // Check to see if already in retrieving mode, if not download it
                    retrieveComparativeStudy(study as? DCMTKStudyQueryNode, select: true, open: false)
                } else {
                    databaseOpenStudy(item as? NSManagedObject)
                }
            } else {
                querySelectedStudy(self)
            }
        }
    }

    @objc(outlineView:shouldEditTableColumn:item:)
    func outlineView(_ outlineView: NSOutlineView!, shouldEdit tableColumn: NSTableColumn!, item: Any!) -> Bool {
        if database?.isReadOnly ?? false {
            return false
        }

        let identifier = tableColumn?.identifier.rawValue
        if identifier == "comment" || identifier == "comment2" || identifier == "comment3" || identifier == "comment4" {
            horos_DatabaseIsEdited = true
            return true
        } else {
            horos_DatabaseIsEdited = false
            return false
        }
    }

    @objc(outlineView:shouldTrackCell:forTableColumn:item:)
    func outlineView(_ outlineView: NSOutlineView!, shouldTrackCell cell: NSCell!, for tableColumn: NSTableColumn!, item: Any!) -> Bool {
        if database?.isReadOnly ?? false {
            return false
        }

        return true
    }

    @objc(displayImagesOfSeries:)
    func displayImagesOfSeries(_ sender: Any!) {
        let dicomFiles = NSMutableArray()
        let oMatrix = horos_oMatrix
        let databaseOutline = horos_databaseOutline

        if isThumbnailMenuItem(sender) || window?.firstResponder === oMatrix {
            let matrixViewArray = horos_matrixViewArray as NSArray?
            // NSUInteger > NSInteger: the tag is compared as unsigned.
            if UInt(matrixViewArray?.count ?? 0) > UInt(bitPattern: oMatrix?.selectedCell()?.tag ?? 0) {
                let curObj = matrixViewArray?.object(at: oMatrix?.selectedCell()?.tag ?? 0) as? NSObject

                if objcIsType(curObj, "Image") {
                    _ = files(forDatabaseMatrixSelection: dicomFiles)

                    if databaseOutline?.isItemExpanded(curObj?.value(forKeyPath: "series.study")) ?? false {
                        databaseOutline?.collapseItem(curObj?.value(forKeyPath: "series.study"))
                    }

                } else {
                    _ = files(forDatabaseMatrixSelection: dicomFiles)
                    _ = findAndSelectFile(nil, image: dicomFiles.object(at: 0) as? DicomImage, shouldExpand: true)
                }
            }
        }
    }

    @objc(findAndSelectFile:image:shouldExpand:)
    func findAndSelectFile(_ path: String!, image curImage: DicomImage!, shouldExpand expand: Bool) -> Bool {
        return findAndSelectFile(path, image: curImage, shouldExpand: expand, extendingSelection: false)
    }

    @objc(findAndSelectFile:image:shouldExpand:extendingSelection:)
    func findAndSelectFile(_ path: String!, image curImage: DicomImage!, shouldExpand expand: Bool, extendingSelection: Bool) -> Bool {
        viewerOpener.findAndSelectFile(path, image: curImage, expand: expand, extendingSelection: extendingSelection)
    }

    @objc(displayStudy:object:command:)
    func display(_ study: DicomStudy!, object element: NSManagedObject!, command execute: String!) -> Bool {
        viewerOpener.display(study, object: element, command: execute)
    }

    @available(*, deprecated)
    @objc(findObject:table:execute:elements:)
    func findObject(_ request: String!, table: String!, execute: String!, elements: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Int32 { // __deprecated
        elements?.pointee = nil
        let found = viewerOpener.findObject(request, table: table, execute: execute)
        if let answer = found.elements { elements?.pointee = answer as NSString }
        return found.code
    }

    @objc(loadNextPatient::::keyImagesOnly:)
    func loadNextPatient(_ curImage: NSManagedObject!, _ direction: Int, _ viewer: ViewerController!, _ firstViewer: Bool, keyImagesOnly keyImages: Bool) {
        viewerOpener.loadNextPatient(curImage, direction: direction, viewer: viewer)
    }

    @objc(loadNextSeries::::keyImagesOnly:)
    func loadNextSeries(_ curImage: NSManagedObject!, _ direction: Int, _ viewer: ViewerController!, _ firstViewer: Bool, keyImagesOnly keyImages: Bool) {
        viewerOpener.loadNextSeries(curImage, direction: direction, viewer: viewer, firstViewer: firstViewer, keyImagesOnly: keyImages)
    }

    @objc(loadSeries:::keyImagesOnly:)
    func loadSeries(_ series: NSManagedObject!, _ viewer: ViewerController!, _ firstViewer: Bool, keyImagesOnly keyImages: Bool) -> ViewerController! {
        viewerOpener.loadSeries(series, viewer: viewer, keyImagesOnly: keyImages)
    }

    @objc(exportDBListOnlySelected:)
    func exportDBListOnlySelected(_ onlySelected: Bool) -> String! {
        StudyListExport(browser: self).databaseList(onlySelected: onlySelected)
    }


    /// The image of the clipboard into the database shown (ClipboardImagePaste).
    @objc(pasteImageForSourceFile:)
    func pasteImage(forSourceFile sourceFile: String!) {
        ClipboardImagePaste(browser: self).paste(sourceFile: sourceFile, into: database)
    }

    @objc(paste:)
    func paste(_ sender: Any!) {
        pasteImage(forSourceFile: nil)
    }

    @objc(copy:)
    func copy(_ sender: Any!) {
        let pb = NSPasteboard.general

        pb.declareTypes([.string], owner: self)

        let string: String?
        let databaseOutline = horos_databaseOutline

        if (databaseOutline?.selectedRowIndexes.count ?? 0) == 1 {
            string = (databaseOutline?.item(atRow: databaseOutline?.selectedRowIndexes.first ?? NSNotFound) as? NSObject)?.value(forKey: "name") as? String
        } else {
            string = exportDBListOnlySelected(true)
        }

        // -setString:nil still fulfilled the declared type, with empty data.
        pb.setString(string ?? "", forType: .string)
    }

    // The item is built here, not in a nib, because there is one nib per language
    // and it belongs beside the export that already exists.
    @objc(buildMetadataExportMenuItem)
    func buildMetadataExportMenuItem() {
        guard let existing = BrowserController.item(in: NSApp.mainMenu, withAction: #selector(BrowserController.saveDBListAs(_:))) else { return }

        let title = NSLocalizedString("Export Study Metadata as CSV...", comment: "")
        if (existing.menu?.indexOfItem(withTitle: title) ?? 0) >= 0 { return }

        let item = NSMenuItem(title: title,
                              action: #selector(BrowserController.exportStudyMetadataAsCSV(_:)),
                              keyEquivalent: "")
        item.target = nil                              // through the responder chain, like its neighbour
        existing.menu?.insertItem(item, at: (existing.menu?.index(of: existing) ?? 0) + 1)

        let byList = NSMenuItem(title: NSLocalizedString("Export Studies by Identifier List...", comment: ""),
                                action: #selector(BrowserController.exportStudiesByIdentifierList(_:)),
                                keyEquivalent: "")
        byList.target = nil
        existing.menu?.insertItem(byList, at: (existing.menu?.index(of: item) ?? 0) + 1)

        // Goes to whichever 2D viewer is in front, like the other export commands.
        let cropped = NSMenuItem(title: NSLocalizedString("Export Cropped Series...", comment: ""),
                                 action: NSSelectorFromString("exportCroppedSeries:"),
                                 keyEquivalent: "")
        cropped.target = nil
        existing.menu?.insertItem(cropped, at: (existing.menu?.index(of: byList) ?? 0) + 1)
    }

    @objc(itemInMenu:withAction:)
    class func item(in menu: NSMenu!, withAction action: Selector!) -> NSMenuItem! {
        for item in menu?.items ?? [] {
            if item.action == action { return item }
            if let submenu = item.submenu {
                let found = BrowserController.item(in: submenu, withAction: action)
                if let found { return found }
            }
        }
        return nil
    }

    @objc(aFileOfStudy:)
    func aFile(of study: DicomStudy!) -> String! {
        StudyListExport.aFile(of: study)
    }

    @objc(exportStudiesByIdentifierList:)
    func exportStudiesByIdentifierList(_ sender: Any!) {
        StudyListExport(browser: self).exportStudiesByIdentifierList()
    }

    @objc(exportStudiesForIdentifiers:toDirectory:dryRun:)
    func exportStudies(forIdentifiers identifiers: [Any]!, toDirectory directory: String!, dryRun: Bool) -> String! {
        StudyListExport(browser: self).exportStudies(identifiers: (identifiers ?? []).compactMap { $0 as? String },
                                                     to: directory ?? "", dryRun: dryRun)
    }

    @objc(exportStudyMetadataAsCSV:)
    func exportStudyMetadataAsCSV(_ sender: Any!) {
        StudyListExport(browser: self).exportStudyMetadataAsCSV()
    }

    @objc(metadataCSVForColumns:onlySelected:)
    func metadataCSV(forColumns columns: [Any]!, onlySelected: Bool) -> String! {
        StudyListExport(browser: self).metadataCSV(columns: (columns as? [String]) ?? [], onlySelected: onlySelected)
    }

    @objc(saveDBListAs:)
    func saveDBListAs(_ sender: Any!) {
        StudyListExport(browser: self).saveDatabaseList()
    }
}
