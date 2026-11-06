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
import IsiXDatabase

// The database drag and the opening of a study, as the nib, the outline's
// delegate, the matrix and the plugins reach them: the file promises are
// DatabaseFilePromiseWriter's, the opening is the browser's ViewerOpener's.

/// `[item isDistant]` of an `id`: NO for nil.
@MainActor private func isDistantItem(_ item: Any?) -> Bool {
    (item as AnyObject?)?.isDistant?() ?? false
}

/// `[[item XID] length]` of an `id`: 0 for nil.
@MainActor private func xidLength(_ item: Any?) -> Int {
    guard let xid = (item as AnyObject?)?.xid?() else { return 0 }
    return (xid as NSString?)?.length ?? 0
}

public extension BrowserController {

    // MARK: database drag export

    // A report a person would want as a PDF, as opposed to the application's own SRs.
    @objc(isReportSeriesForFileExport:)
    nonisolated class func isReportSeries(forFileExport series: DicomSeries!) -> Bool {
        return BatchExportPlan.isReportSeries(name: series?.name, sopClassUID: series?.seriesSOPClassUID, modality: series?.modality)
    }

    // Every database object identifier on the pasteboard: one item per dragged row.
    @objc(databaseObjectXIDsOnPasteboard:)
    class func databaseObjectXIDs(on pasteboard: NSPasteboard!) -> [Any]! {
        guard let pasteboard else { return [] }
        return PasteboardObjectIdentifiers.identifiers(on: pasteboard, types: BrowserController.databaseObjectXIDsPasteboardTypes() ?? [])
    }

    @objc(filePromiseForDatabaseObjects:)
    func filePromise(forDatabaseObjects items: [Any]!) -> (any NSPasteboardWriting)! {
        return self.filePromise(forDatabaseObjects: items, asJPEG: false)
    }

    @objc(filePromiseForDatabaseObjects:asJPEG:)
    func filePromise(forDatabaseObjects items: [Any]!, asJPEG jpeg: Bool) -> (any NSPasteboardWriting)! {
        DatabaseFilePromiseWriter(browser: self, preferences: PreferencesSource.process.preferences).promise(forDatabaseObjects: items, asJPEG: jpeg)
    }

    @objc(filePromiseForJPEGData:name:)
    func filePromise(forJPEGData data: Data!, name: String!) -> (any NSPasteboardWriting)! {
        DatabaseFilePromiseWriter.promise(forJPEGData: data, name: name)
    }

    // A row is a promise for the folder it exports; a series under a selected
    // study is already inside that study's promise.
    @objc(outlineView:pasteboardWriterForItem:)
    func outlineView(_ outlineView: NSOutlineView!, pasteboardWriterForItem item: Any!) -> (any NSPasteboardWriting)! {
        guard let item, !isDistantItem(item), xidLength(item) > 0 else { return nil }
        let parent = outlineView?.parent(forItem: item)
        let parentRow = parent != nil ? (outlineView?.row(forItem: parent) ?? 0) : -1
        if parentRow >= 0 && (outlineView?.isRowSelected(parentRow) ?? false) { return nil }
        return self.filePromise(forDatabaseObjects: [item], asJPEG: NSApp.currentEvent?.modifierFlags.contains(NSEvent.ModifierFlags.option) ?? false)
    }

    @objc(outlineViewItemWillCollapse:)
    func outlineViewItemWillCollapse(_ notification: Notification!) {
        let object = notification?.userInfo?["NSObject"]

        if isDistantItem(object) == false {
            (object as? NSObject)?.setValue(NSNumber(value: false), forKey: "expanded")
        }

        if let image = self.horos_matrixViewArray?.first as? DicomImage, isRowType(image, "Image") {
            _ = self.findAndSelectFile(nil, image: image, shouldExpand: false)
        }
    }

    @objc(outlineViewItemWillExpand:)
    func outlineViewItemWillExpand(_ notification: Notification!) {
        let object = notification?.userInfo?["NSObject"]

        if isDistantItem(object) == false {
            (object as? NSObject)?.setValue(NSNumber(value: true), forKey: "expanded")
        }
    }

    // MARK: Opening a study

    @objc(isUsingExternalViewer:)
    func `is`(usingExternalViewer item: NSManagedObject!) -> Bool {
        viewerOpener.isUsingExternalViewer(item)
    }

    @objc(databaseOpenStudy:withProtocol:)
    func databaseOpen(_ currentStudy: DicomStudy!, withProtocol currentHangingProtocol: [AnyHashable: Any]!) {
        viewerOpener.open(currentStudy, withProtocol: currentHangingProtocol)
    }

    @objc(displayWaitWindowIfNecessary)
    func displayWaitWindowIfNecessary() {
        viewerOpener.showWaitWindow()
    }

    @objc(closeWaitWindowIfNecessary)
    func closeWaitWindowIfNecessary() {
        viewerOpener.closeWaitWindow()
    }

    @objc(databaseOpenStudy:)
    func databaseOpenStudy(_ item: NSManagedObject!) {
        viewerOpener.openStudy(item)
    }
}
