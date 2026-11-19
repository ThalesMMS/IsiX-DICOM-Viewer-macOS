//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The commands of the thumbnails' context menu, the less frequent ones
/// in submenus titled as those of the database list's menu.
@MainActor
enum BrowserThumbnailMenu {
    static func make() -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("Tools", comment: ""))

        func addGroup(_ title: String) -> NSMenu {
            let group = NSMenu(title: title)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = group
            menu.addItem(item)
            return group
        }
        var group: NSMenu

        menu.addItem(withTitle: NSLocalizedString("Open Images", comment: ""), action: #selector(BrowserController.viewerDICOM(_:)), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Open Images in 4D", comment: ""), action: #selector(BrowserController.movieViewerDICOM(_:)), keyEquivalent: "")
        group = addGroup(NSLocalizedString("Open Special", comment: ""))
        group.addItem(withTitle: NSLocalizedString("Sub-Selection", comment: ""), action: #selector(BrowserController.viewerSubSeriesDICOM(_:)), keyEquivalent: "")
        group.addItem(withTitle: NSLocalizedString("Reparsed Series", comment: ""), action: #selector(BrowserController.viewerReparsedSeries(_:)), keyEquivalent: "")
        group.addItem(withTitle: NSLocalizedString("Merged Selection", comment: ""), action: #selector(BrowserController.viewerDICOMMergeSelection(_:)), keyEquivalent: "")
        group.addItem(NSMenuItem.separator())
        group.addItem(withTitle: NSLocalizedString("Key Images", comment: ""), action: #selector(BrowserController.viewerDICOMKeyImages(_:)), keyEquivalent: "")
        group.addItem(withTitle: NSLocalizedString("ROIs Images", comment: ""), action: #selector(BrowserController.viewerDICOMROIsImages(_:)), keyEquivalent: "")
        group.addItem(withTitle: NSLocalizedString("ROIs and Key Images", comment: ""), action: #selector(BrowserController.viewerKeyImagesAndROIsImages(_:)), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Reveal In Finder", comment: ""), action: #selector(BrowserController.revealInFinder(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        group = addGroup(NSLocalizedString("Export", comment: ""))
        group.addItem(withTitle: NSLocalizedString("DICOM Network Node", comment: "") + "\u{2026}", action: #selector(BrowserController.export2PACS(_:)), keyEquivalent: "")
        group.addItem(withTitle: NSLocalizedString("DICOM File(s)", comment: "") + "\u{2026}", action: #selector(BrowserController.exportDICOMFile(_:)), keyEquivalent: "")
        group.addItem(NSMenuItem.separator())
        group.addItem(withTitle: NSLocalizedString("Movie", comment: "") + "\u{2026}", action: #selector(BrowserController.exportQuicktime(_:)), keyEquivalent: "")
        group.addItem(withTitle: NSLocalizedString("JPEG", comment: "") + "\u{2026}", action: #selector(BrowserController.exportJPEG(_:)), keyEquivalent: "")
        group.addItem(withTitle: NSLocalizedString("TIFF", comment: "") + "\u{2026}", action: #selector(BrowserController.exportTIFF(_:)), keyEquivalent: "")
        group.addItem(NSMenuItem.separator())
        group.addItem(withTitle: NSLocalizedString("ROI and Key Images as a DICOM Series", comment: ""), action: #selector(BrowserController.exportROIAndKeyImagesAsDICOMSeries(_:)), keyEquivalent: "")
        group.addItem(NSMenuItem.separator())
        group.addItem(withTitle: NSLocalizedString("Burn to Disc", comment: "") + "\u{2026}", action: #selector(BrowserController.burnDICOM(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: NSLocalizedString("Toggle Images/Series Displaying", comment: ""), action: #selector(BrowserController.displayImagesOfSeries(_:)), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Merge Selected Series", comment: ""), action: #selector(BrowserController.mergeSeries(_:)), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Anonymize", comment: ""), action: #selector(BrowserController.anonymizeDICOM(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: NSLocalizedString("Compress DICOM files", comment: ""), action: #selector(BrowserController.compressSelectedFiles(_:)), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Decompress DICOM files", comment: ""), action: #selector(BrowserController.decompressSelectedFiles(_:)), keyEquivalent: "")
        group = addGroup(NSLocalizedString("Files & Maintenance", comment: ""))
        group.addItem(withTitle: NSLocalizedString("Rebuild Selected Thumbnails", comment: ""), action: #selector(BrowserController.rebuildThumbnails(_:)), keyEquivalent: "")
        group.addItem(withTitle: NSLocalizedString("Copy Linked Files to Database Folder", comment: ""), action: #selector(BrowserController.copyToDBFolder(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: NSLocalizedString("Query Selected Patient from Q&R Window...", comment: ""), action: #selector(BrowserController.querySelectedStudy(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: NSLocalizedString("Delete", comment: ""), action: #selector(BrowserController.delItem(_:)), keyEquivalent: "")

        return menu
    }
}
