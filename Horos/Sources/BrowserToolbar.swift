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
import IsiXDICOMNetwork
import IsiXPreferences

// The database window's toolbar and menus: the toolbar is built in code, so
// its delegate is BrowserToolbar, which makes the items, lists the
// identifiers, follows the customization and validates the items; it also
// builds the list's and the albums' contextual menus and the Help menu, and
// validates the browser's commands, which also titles Delete and Merge after
// the selection. The items' and the menus' target stays the browser, which
// keeps the selectors the nib, AppKit and the former plugins send and hands
// their work here. What decides without the app's classes is IsiXDatabase's
// BrowserMenuValidation.
//
// The toolbar's identifier and the items' identifiers are the texts the
// former Objective-C class used: the customization a person saved is kept
// under them.

/// `[value boolValue]` of an Info.plist or a row's value: NO for nil and for
/// what is neither a number nor a string.
private func boolValue(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

/// The rows of a selection in order: the position in the selection, the row.
private func rows(_ selection: IndexSet) -> [Int] {
    Array(selection)
}

fileprivate let DatabaseToolbarIdentifier = "DicomDatabase Toolbar Identifier"
fileprivate let ImportToolbarItemIdentifier = "Import.pdf"
fileprivate let QTSaveToolbarItemIdentifier = "QTExport.pdf"
fileprivate let ExportToolbarItemIdentifier = "Export.pdf"
fileprivate let ExportROIAndKeyImagesToolbarItemIdentifier = "ExportROIAndKeyImages.tif"
fileprivate let AnonymizerToolbarItemIdentifier = "Anonymizer.pdf"
fileprivate let QueryToolbarItemIdentifier = "QueryRetrieve.pdf"
fileprivate let SendToolbarItemIdentifier = "Send.pdf"
fileprivate let ViewerToolbarItemIdentifier = "Viewer.pdf"
fileprivate let MovieToolbarItemIdentifier = "Movie.pdf"
fileprivate let TrashToolbarItemIdentifier = "trash.icns"
fileprivate let ReportToolbarItemIdentifier = "Report.icns"
fileprivate let BurnerToolbarItemIdentifier = "Burner.icns"
fileprivate let ToggleDrawerToolbarItemIdentifier = "StartupDisk.tif"
fileprivate let SearchToolbarItemIdentifier = "Search"
fileprivate let TimeIntervalToolbarItemIdentifier = "TimeInterval"
fileprivate let ModalityFilterToolbarItemIdentifier = "ModalityFilter"
fileprivate let XMLToolbarItemIdentifier = "XML.icns"
fileprivate let MailToolbarItemIdentifier = "Mail.icns"
fileprivate let OpenKeyImagesAndROIsToolbarItemIdentifier = "ROIsAndKeys.tif"
fileprivate let OpenKeyImagesToolbarItemIdentifier = "Keys.tif"
fileprivate let OpenROIsToolbarItemIdentifier = "ROIs.tif"
fileprivate let ViewersToolbarItemIdentifier = "windows.tif"
fileprivate let WebServerSingleNotification = "Safari.tif"
fileprivate let AddStudiesToUserItemIdentifier = "NSUserAccounts"
fileprivate let ResetSplitViewsItemIdentifier = "Reset.pdf"
fileprivate let HorosMigrationAssistantIdentifier = "O2HMigrationAssistant.png"

/// What the browser's menu validation asks, read from the window when asked.
@MainActor private struct BrowserMenuState {
    let browser: BrowserController
    let item: NSMenuItem
    let preferences: any PreferenceStore
    let selection: [Int]

    init(browser: BrowserController, item: NSMenuItem, preferences: any PreferenceStore) {
        self.browser = browser
        self.item = item
        self.preferences = preferences
        self.selection = rows(browser.horos_databaseOutline?.selectedRowIndexes ?? IndexSet())
    }

    func object(at position: Int) -> NSObject? {
        browser.horos_databaseOutline?.item(atRow: selection[position]) as? NSObject
    }
}

extension BrowserMenuState: @MainActor BrowserMenuFacts {
    func selectedCount() -> Int { selection.count }
    func selectedType(at position: Int) -> Any? { object(at: position)?.value(forKey: "type") }
    func selectedLocked(at position: Int) -> Any? { object(at: position)?.value(forKey: "lockedStudy") }
    func databaseIsLocal() -> Bool { browser.horos_databaseIvar?.isLocal() ?? false }
    func databaseIsReadOnly() -> Bool { browser.horos_databaseIvar?.isReadOnly ?? false }

    /// [databaseOutline itemAtRow: [[databaseOutline selectedRowIndexes] firstIndex]].
    private func firstSelected() -> NSObject? {
        guard let first = selection.first else { return nil }
        return browser.horos_databaseOutline?.item(atRow: first) as? NSObject
    }

    func firstSelectedHasItem() -> Bool { firstSelected() != nil }

    func firstSelectedStudyHasReport() -> Bool {
        guard let item = firstSelected() else { return false }
        let isStudy = (item.value(forKey: "type") as? NSString)?.isEqual(to: "Study") ?? false
        let study = isStudy ? item : item.value(forKey: "study") as? NSObject
        return study?.value(forKey: "reportURL") != nil
    }

    func isImageTileMenu() -> Bool { item.menu === browser.horos_imageTileMenu }
    func mainWindowIsViewer() -> Bool { NSApp.mainWindow?.windowController is ViewerController }
    func commentsAutoFill() -> Bool { preferences[DatabasePreferences.commentsAutoFill] }
    func roiImageCount() -> Int { browser.roiImages(item)?.count ?? 0 }
    func roisAndKeyImageCount() -> Int { browser.roisAndKeyImages(item)?.count ?? 0 }
    func keyImageCount() -> Int { browser.keyImages(item)?.count ?? 0 }
    func isThumbnailMenuItem() -> Bool { browser.isThumbnailMenuItem(item) }

    func selectionHasLinkedFiles(fromThumbnails: Bool) -> Bool {
        let objects = NSMutableArray()
        let files = fromThumbnails ? browser.files(forDatabaseMatrixSelection: objects, onlyImages: false)
            : browser.files(forDatabaseOutlineSelection: objects, onlyImages: false)
        files?.removeDuplicatedStrings(inSyncWithThisArray: objects)
        for case let image as NSObject in objects where !boolValue(image.value(forKey: "inDatabaseFolder")) {
            return true
        }
        return false
    }

    // Compared as the former pointers were: two nils are the same.
    func firstResponderIsThumbnails() -> Bool { browser.window?.firstResponder === browser.horos_oMatrix }
    func isListMenuItem() -> Bool { item.menu === browser.horos_databaseOutline?.menu }
    func firstResponderIsList() -> Bool { browser.window?.firstResponder === browser.horos_databaseOutline }
    func firstResponderIsHistory() -> Bool { browser.window?.firstResponder === browser.horos_comparativeTable }
    func selectedThumbnailCount() -> Int { browser.horos_oMatrix?.selectedCells.count ?? 0 }
    func itemTag() -> Int { item.tag }
    func annotationsMode() -> Int { preferences[ViewerPreferences.annotations] }
}

@MainActor final class BrowserToolbar: NSObject, NSToolbarDelegate {

    private let browser: BrowserController
    private let processGraph: ProcessGraph
    private let preferences: any PreferenceStore

    init(browser: BrowserController, processGraph: ProcessGraph, preferences: any PreferenceStore) {
        self.browser = browser
        self.processGraph = processGraph
        self.preferences = preferences
    }

    // MARK: - The toolbar

    /// Makes the window's toolbar, with this object as its delegate. AppKit
    /// saves its customization under the toolbar's identifier.
    func install() {
        // Create a new toolbar instance, and attach it to our document window
        let toolbar = NSToolbar(identifier: DatabaseToolbarIdentifier)
        browser.horos_toolbar = toolbar

        // Set up toolbar properties: Allow customization, give a default display mode, and remember state in user defaults
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        // A row of its own: in the title bar, the window title and the
        // database folder's icon took room from the items.
        browser.window?.toolbarStyle = .expanded

        // The toolbar holds its delegate weakly: the browser keeps this object.
        toolbar.delegate = self

        // Attach the toolbar to the document window
        browser.window?.toolbar = toolbar
        browser.window?.showsToolbarButton = false
        browser.window?.toolbar?.isVisible = true
        ToolbarPolicy.adopt(toolbar: toolbar, in: browser.window)

        // The EXPORTTOOLBARITEM branch (a screenshot of every item), disabled, is left out.
    }

    /// The modifier keys changed: the ROIs and keys items show the key images
    /// (Option), the ROI images (Shift) or both, and the preview follows the
    /// selection again.
    func modifierFlagsChanged(_ event: NSEvent?) {
        let modifierFlags: NSEvent.ModifierFlags = event?.modifierFlags ?? []

        if browser.horos_previousFlags == modifierFlags.rawValue {
            return
        }

        for toolbarItem in browser.horos_toolbar?.items ?? [] {
            if toolbarItem.itemIdentifier.rawValue == OpenKeyImagesAndROIsToolbarItemIdentifier {
                if modifierFlags.contains(.option) {
                    toolbarItem.image = NSImage.toolbarImageNamed(OpenKeyImagesToolbarItemIdentifier)
                    toolbarItem.action = #selector(BrowserController.viewerDICOMKeyImages(_:))

                    toolbarItem.label = NSLocalizedString("Keys", comment: "")
                    toolbarItem.paletteLabel = NSLocalizedString("Keys", comment: "")
                    toolbarItem.toolTip = NSLocalizedString("View all Key Images", comment: "")
                } else if modifierFlags.contains(.shift) {
                    toolbarItem.image = NSImage.toolbarImageNamed(OpenROIsToolbarItemIdentifier)
                    toolbarItem.action = #selector(BrowserController.viewerDICOMROIsImages(_:))

                    toolbarItem.label = NSLocalizedString("ROIs", comment: "")
                    toolbarItem.paletteLabel = NSLocalizedString("ROIs", comment: "")
                    toolbarItem.toolTip = NSLocalizedString("View all ROIs Images", comment: "")
                } else {
                    toolbarItem.image = NSImage.toolbarImageNamed(OpenKeyImagesAndROIsToolbarItemIdentifier)
                    toolbarItem.action = #selector(BrowserController.viewerKeyImagesAndROIsImages(_:))

                    toolbarItem.label = NSLocalizedString("ROIs & Keys", comment: "")
                    toolbarItem.paletteLabel = NSLocalizedString("ROIs & Keys", comment: "")
                    toolbarItem.toolTip = NSLocalizedString("View all Key Images and ROIs", comment: "")
                }
            }

            if toolbarItem.itemIdentifier.rawValue == ExportROIAndKeyImagesToolbarItemIdentifier {
                if modifierFlags.contains(.option) {
                    toolbarItem.image = NSImage.toolbarImageNamed(ExportROIAndKeyImagesToolbarItemIdentifier)
                    toolbarItem.action = #selector(BrowserController.exportROIAndKeyImagesAsDICOMSeries(_:))

                    toolbarItem.label = NSLocalizedString("Export Keys", comment: "")
                    toolbarItem.paletteLabel = NSLocalizedString("Export Keys", comment: "")
                    toolbarItem.toolTip = NSLocalizedString("Export Key images of selected study/series as a DICOM Series", comment: "")
                } else if modifierFlags.contains(.shift) {
                    toolbarItem.image = NSImage.toolbarImageNamed(ExportROIAndKeyImagesToolbarItemIdentifier)
                    toolbarItem.action = #selector(BrowserController.exportROIAndKeyImagesAsDICOMSeries(_:))

                    toolbarItem.label = NSLocalizedString("Export ROIs", comment: "")
                    toolbarItem.paletteLabel = NSLocalizedString("Export ROIs", comment: "")
                    toolbarItem.toolTip = NSLocalizedString("Export ROI images of selected study/series as a DICOM Series", comment: "")
                } else {
                    toolbarItem.image = NSImage.toolbarImageNamed(ExportROIAndKeyImagesToolbarItemIdentifier)
                    toolbarItem.action = #selector(BrowserController.exportROIAndKeyImagesAsDICOMSeries(_:))

                    toolbarItem.label = NSLocalizedString("Export ROIs & Keys", comment: "")
                    toolbarItem.paletteLabel = NSLocalizedString("Export ROIs & Keys", comment: "")
                    toolbarItem.toolTip = NSLocalizedString("Export ROI and Key images of selected study/series as a DICOM Series", comment: "")
                }
            }
        }

        // Modifier keys used while typing must not rebuild the preview selection:
        // matrixPressed: would move first responder away from the field editor.
        if (browser.horos_databaseOutline?.editedRow ?? 0) == -1 {
            browser.outlineViewSelectionDidChange(nil)
        } else {
            browser.horos_refreshDeferredWhileEditing = true
        }

        browser.horos_previousFlags = modifierFlags.rawValue
    }

    // MARK: - The items

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let itemIdent = itemIdentifier.rawValue
        if let spaceItem = ToolbarPolicy.spaceItem(for: itemIdent) {
            return spaceItem
        }

        let newItem = NSToolbarItem(itemIdentifier: itemIdentifier)
        var toolbarItem: NSToolbarItem? = newItem

        if itemIdent == ImportToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Import", comment: "")
            newItem.paletteLabel = NSLocalizedString("Import", comment: "")
            newItem.toolTip = NSLocalizedString("Import a DICOM file or folder", comment: "Import a DICOM file or folder")
            newItem.image = NSImage.toolbarImageNamed(ImportToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.selectFilesAndFoldersToAdd(_:))
        } else if itemIdent == QTSaveToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Movie Export", comment: "")
            newItem.paletteLabel = NSLocalizedString("Movie Export", comment: "")
            newItem.image = NSImage.toolbarImageNamed(QTSaveToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.exportQuicktime(_:))
        } else if itemIdent == WebServerSingleNotification {
            newItem.label = NSLocalizedString("Notification", comment: "")
            newItem.paletteLabel = NSLocalizedString("Notification", comment: "")
            newItem.image = NSImage.toolbarImageNamed(WebServerSingleNotification)
            newItem.target = browser
            newItem.action = #selector(BrowserController.sendEmailNotification(_:))
        } else if itemIdent == AddStudiesToUserItemIdentifier {
            newItem.label = NSLocalizedString("Add Studies", comment: "")
            newItem.paletteLabel = NSLocalizedString("Add Studies", comment: "")
            newItem.image = NSImage.toolbarImageNamed(AddStudiesToUserItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.addStudiesToUser(_:))
        } else if itemIdent == MailToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Email", comment: "")
            newItem.paletteLabel = NSLocalizedString("Email", comment: "")
            newItem.image = NSImage.toolbarImageNamed(MailToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.sendMail(_:))
        } else if itemIdent == ExportToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Export", comment: "")
            newItem.paletteLabel = NSLocalizedString("Export", comment: "")
            newItem.toolTip = NSLocalizedString("Export selected study/series to a DICOM folder", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ExportToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.exportDICOMFile(_:))
        } else if itemIdent == ExportROIAndKeyImagesToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Export ROIs & Keys", comment: "")
            newItem.paletteLabel = NSLocalizedString("Export ROIs & Keys", comment: "")
            newItem.toolTip = NSLocalizedString("Export ROI and Key images of selected study/series as a DICOM Series", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ExportROIAndKeyImagesToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.exportROIAndKeyImagesAsDICOMSeries(_:))
        } else if itemIdent == ViewersToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Viewers", comment: "")
            newItem.paletteLabel = NSLocalizedString("Viewers", comment: "")
            newItem.toolTip = NSLocalizedString("Bring Viewers windows to the front", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ViewersToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.tileWindows(_:))
        } else if itemIdent == AnonymizerToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Anonymize", comment: "")
            newItem.paletteLabel = NSLocalizedString("Anonymize", comment: "")
            newItem.toolTip = NSLocalizedString("Anonymize selected study/series to a DICOM folder", comment: "")
            newItem.image = NSImage.toolbarImageNamed(AnonymizerToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.anonymizeDICOM(_:))
        } else if itemIdent == QueryToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Query", comment: "")
            newItem.paletteLabel = NSLocalizedString("Query", comment: "")
            newItem.toolTip = NSLocalizedString("Query and retrieve a DICOM study from a DICOM node\rShift + click to query selected patient.", comment: "")
            newItem.image = NSImage.toolbarImageNamed(QueryToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.queryDICOM(_:))
            newItem.tag = 0
        } else if itemIdent == SendToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Send", comment: "")
            newItem.paletteLabel = NSLocalizedString("Send", comment: "")
            newItem.toolTip = NSLocalizedString("Send selected study/series to a DICOM node", comment: "Send selected study/series to a DICOM node")
            newItem.image = NSImage.toolbarImageNamed(SendToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.export2PACS(_:))
        } else if itemIdent == ViewerToolbarItemIdentifier {
            newItem.label = NSLocalizedString("2D Viewer", comment: "")
            newItem.paletteLabel = NSLocalizedString("2D Viewer", comment: "")
            newItem.toolTip = NSLocalizedString("View selected study/series", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ViewerToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.viewerDICOM(_:))
        } else if itemIdent == MovieToolbarItemIdentifier {
            newItem.label = NSLocalizedString("4D Viewer", comment: "")
            newItem.paletteLabel = NSLocalizedString("4D Viewer", comment: "")
            newItem.toolTip = NSLocalizedString("Load multiple series into an animated 4D series", comment: "")
            newItem.image = NSImage.toolbarImageNamed(MovieToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.movieViewerDICOM(_:))
        } else if itemIdent == TrashToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Delete", comment: "")
            newItem.paletteLabel = NSLocalizedString("Delete", comment: "")
            newItem.toolTip = NSLocalizedString("Delete selected images from the database", comment: "")
            newItem.image = NSImage.toolbarImageNamed(TrashToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.delItem(_:))
        } else if itemIdent == ReportToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Report", comment: "")
            newItem.paletteLabel = NSLocalizedString("Report", comment: "")
            newItem.toolTip = NSLocalizedString("Create/Open a report for selected study", comment: "")
            browser.reports.setToolbarIcon(for: newItem)
            newItem.target = browser
            newItem.action = #selector(BrowserController.generateReport(_:))
        } else if itemIdent == OpenKeyImagesAndROIsToolbarItemIdentifier {
            newItem.label = NSLocalizedString("ROIs & Keys", comment: "")
            newItem.paletteLabel = NSLocalizedString("ROIs & Keys", comment: "")
            newItem.toolTip = NSLocalizedString("View all Key Images and ROIs", comment: "")
            newItem.image = NSImage.toolbarImageNamed(OpenKeyImagesAndROIsToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.viewerKeyImagesAndROIsImages(_:))
        } else if itemIdent == XMLToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Meta-Data", comment: "")
            newItem.paletteLabel = NSLocalizedString("Meta-Data", comment: "")
            newItem.toolTip = NSLocalizedString("View meta-data of this image", comment: "")
            newItem.image = NSImage.toolbarImageNamed(XMLToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.viewXML(_:))
        } else if itemIdent == BurnerToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Burn", comment: "")
            newItem.paletteLabel = NSLocalizedString("Burn", comment: "")
            newItem.toolTip = NSLocalizedString("Burn a DICOM-compatible CD or DVD", comment: "Burn a DICOM-compatible CD or DVD")
            newItem.image = NSImage.toolbarImageNamed(BurnerToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.burnDICOM(_:))
        } else if itemIdent == ToggleDrawerToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Albums & Sources", comment: "")
            newItem.paletteLabel = NSLocalizedString("Albums & Sources", comment: "")
            newItem.toolTip = NSLocalizedString("Toggle Albums & Sources drawer", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ToggleDrawerToolbarItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.drawerToggle(_:))
        } else if itemIdent == SearchToolbarItemIdentifier {
            // A custom search field cannot be edited from the overflow menu.
            newItem.visibilityPriority = .high
            newItem.label = NSLocalizedString("Search by All Fields", comment: "")
            newItem.paletteLabel = NSLocalizedString("Search", comment: "")
            newItem.toolTip = NSLocalizedString("Search", comment: "")

            // Use a custom view, a text field, for the search item
            newItem.view = browser.horos_searchView
        } else if itemIdent == TimeIntervalToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Time Interval", comment: "")
            newItem.paletteLabel = NSLocalizedString("Time Interval", comment: "")
            newItem.toolTip = NSLocalizedString("Time Interval", comment: "")

            // Use a custom view, a text field, for the search item
            newItem.view = browser.horos_timeIntervalView
        } else if itemIdent == ModalityFilterToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Modality", comment: "")
            newItem.paletteLabel = NSLocalizedString("Modality", comment: "")
            newItem.toolTip = NSLocalizedString("Modality", comment: "")

            // Use a custom view, a text field, for the search item
            newItem.view = browser.horos_modalityFilterView
        } else if itemIdent == ResetSplitViewsItemIdentifier {
            newItem.label = NSLocalizedString("Restore Views", comment: "")
            newItem.paletteLabel = NSLocalizedString("Restore Views", comment: "")
            newItem.toolTip = NSLocalizedString("Restore Views To Original State", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ResetSplitViewsItemIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.restoreWindowState(_:))
        } else if itemIdent == HorosMigrationAssistantIdentifier {
            newItem.label = NSLocalizedString("Migration Assistant", comment: "")
            newItem.paletteLabel = NSLocalizedString("Migration Assistant", comment: "")
            newItem.toolTip = NSLocalizedString("Open IsiX DICOM Viewer Migration Assistant", comment: "")
            newItem.image = NSImage.toolbarImageNamed(HorosMigrationAssistantIdentifier)
            newItem.target = browser
            newItem.action = #selector(BrowserController.openHorosMigrationAssistant(_:))
        } else {
            // Is it a plugin menu item?
            if PluginManager.pluginsDict()?.object(forKey: itemIdent) != nil {
                let bundle = PluginManager.pluginsDict()?.object(forKey: itemIdent) as? Bundle
                let info = bundle?.infoDictionary

                newItem.label = itemIdent
                newItem.paletteLabel = itemIdent
                if let toolTips = info?["ToolbarToolTips"] as? [String: Any] {
                    newItem.toolTip = toolTips[itemIdent] as? String
                } else {
                    newItem.toolTip = itemIdent
                }

                var image = (info?["ToolbarIcon"] as? String)
                    .flatMap { bundle?.pathForImageResource($0) }
                    .flatMap { NSImage(contentsOfFile: $0) }
                if image == nil, let bundlePath = bundle?.bundlePath {
                    image = NSWorkspace.shared.icon(forFile: bundlePath)
                }
                if let current = image {
                    let imageSize = current.size
                    if imageSize.width > 32 || imageSize.height > 32 {
                        if let resized = current.copy() as? NSImage {
                            image = resized
                            resized.size = NSSize(width: 32, height: 32)
                        }
                    }
                }
                newItem.image = image

                newItem.target = browser
                newItem.action = #selector(BrowserController.executeFilterFromToolbar(_:))
            }

            let pluginToolbarItemSelector = #selector(HorosPluginFilterMessages.toolbarItem(forItemIdentifier:forBrowserController:))
            for key in PluginManager.plugins()?.allKeys ?? [] {
                let plugin = PluginManager.plugins()?.object(forKey: key) as AnyObject?
                if plugin?.responds(to: pluginToolbarItemSelector) == true {
                    let item: NSToolbarItem? = plugin?.toolbarItem?(forItemIdentifier: itemIdent, forBrowserController: browser) ?? nil

                    if let item {
                        toolbarItem = item
                    }
                }
            }
        }

        if let toolbarItem {
            ToolbarPolicy.prepare(toolbarItem) // +[HorosToolbarPolicy prepareItem:]
        }

        return toolbarItem
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            //          ToggleDrawerToolbarItemIdentifier, // removed from default items because we have a dedicated button on the bottom left of this window
            ImportToolbarItemIdentifier,
            ExportToolbarItemIdentifier,
            MailToolbarItemIdentifier,
            QTSaveToolbarItemIdentifier,
            QueryToolbarItemIdentifier,
            SendToolbarItemIdentifier,
            AnonymizerToolbarItemIdentifier,
            BurnerToolbarItemIdentifier,
            XMLToolbarItemIdentifier,
            TrashToolbarItemIdentifier,
            NSToolbarItem.Identifier.flexibleSpace.rawValue,
            ViewersToolbarItemIdentifier,
            ViewerToolbarItemIdentifier,
            OpenKeyImagesAndROIsToolbarItemIdentifier,
            MovieToolbarItemIdentifier,
            ReportToolbarItemIdentifier,
            NSToolbarItem.Identifier.flexibleSpace.rawValue,
            TimeIntervalToolbarItemIdentifier,
            ModalityFilterToolbarItemIdentifier,
            SearchToolbarItemIdentifier,
        ].map { NSToolbarItem.Identifier($0) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [Any] = [
            ViewersToolbarItemIdentifier,
            SearchToolbarItemIdentifier,
            TimeIntervalToolbarItemIdentifier,
            ModalityFilterToolbarItemIdentifier,
            NSToolbarItem.Identifier.flexibleSpace.rawValue,
            ToolbarPolicy.spaceItemIdentifier,
            ImportToolbarItemIdentifier,
            //			 CDRomToolbarItemIdentifier,
            MailToolbarItemIdentifier,
            WebServerSingleNotification,
            AddStudiesToUserItemIdentifier,
            QTSaveToolbarItemIdentifier,
            QueryToolbarItemIdentifier,
            ExportToolbarItemIdentifier,
            ExportROIAndKeyImagesToolbarItemIdentifier,
            AnonymizerToolbarItemIdentifier,
            SendToolbarItemIdentifier,
            ViewerToolbarItemIdentifier,
            OpenKeyImagesAndROIsToolbarItemIdentifier,
            MovieToolbarItemIdentifier,
            BurnerToolbarItemIdentifier,
            XMLToolbarItemIdentifier,
            TrashToolbarItemIdentifier,
            ReportToolbarItemIdentifier,
            ToggleDrawerToolbarItemIdentifier,
            ResetSplitViewsItemIdentifier,
            HorosMigrationAssistantIdentifier,
        ]

        // The database plugins that ask for an icon; a set, in the order the
        // former code added them in.
        let allPlugins = PluginManager.pluginsDict()?.allKeys ?? []
        let pluginsItems = NSMutableSet(capacity: allPlugins.count)

        for case let plugin as String in allPlugins {
            if plugin == "(-" {
                continue
            }

            let bundle = PluginManager.pluginsDict()?.object(forKey: plugin) as? Bundle
            let info = bundle?.infoDictionary

            if (info?["pluginType"] as? String) == "Database" {
                if let allowToolbarIcon = info?["allowToolbarIcon"], boolValue(allowToolbarIcon) {
                    if let toolbarNames = info?["ToolbarNames"] as? [Any] {
                        if toolbarNames.contains(where: { ($0 as AnyObject).isEqual(plugin) }) {
                            pluginsItems.add(plugin)
                        }
                    } else {
                        pluginsItems.add(plugin)
                    }
                }
            }
        }

        identifiers.append(contentsOf: pluginsItems.allObjects)

        let pluginAllowedIdentifiersSelector = #selector(HorosPluginFilterMessages.toolbarAllowedIdentifiers(forBrowserController:))
        for key in PluginManager.plugins()?.allKeys ?? [] {
            let plugin = PluginManager.plugins()?.object(forKey: key) as AnyObject?
            if plugin?.responds(to: pluginAllowedIdentifiersSelector) == true {
                let pluginIdentifiers: [Any]? = plugin?.toolbarAllowedIdentifiers?(forBrowserController: browser) ?? nil
                if let pluginIdentifiers {
                    identifiers.append(contentsOf: pluginIdentifiers)
                }
            }
        }

        // The toolbar only takes strings: anything else a plugin returned is left out.
        return identifiers.compactMap { ($0 as? String).map { NSToolbarItem.Identifier($0) } }
    }

    func toolbarWillAddItem(_ notification: Notification) {
        // The search item is kept to title it after the search field's menu.
        let addedItem = notification.userInfo?["item"] as? NSToolbarItem

        if addedItem?.itemIdentifier.rawValue == SearchToolbarItemIdentifier {
            browser.horos_toolbarSearchItem = addedItem
        }
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        let removedItem = notification.userInfo?["item"] as? NSToolbarItem

        if removedItem?.itemIdentifier.rawValue == SearchToolbarItemIdentifier {
            browser.horos_toolbarSearchItem = nil
        }
    }

    // MARK: - Validating the items

    /// Whether a toolbar item of the browser is enabled: AppKit asks the
    /// browser, the items' target.
    func validate(_ toolbarItem: NSToolbarItem?) -> Bool {
        // The EXPORTTOOLBARITEM branch (every item enabled), disabled, is left out.

        var containsDistantStudy = false

        if (browser.horos_databaseOutline?.selectedRowIndexes.count ?? 0) > 0 {
            var idx = browser.horos_databaseOutline?.selectedRowIndexes.first

            while let row = idx {
                let object = browser.horos_databaseOutline?.item(atRow: row) as AnyObject?

                if object?.isDistant?() ?? false {
                    containsDistantStudy = true
                    break
                }

                idx = browser.horos_databaseOutline?.selectedRowIndexes.integerGreaterThan(row)
            }
        }

        let itemIdentifier = toolbarItem?.itemIdentifier.rawValue
        let action = toolbarItem?.action

        if browser.database?.isReadOnly ?? false {
            if itemIdentifier == ImportToolbarItemIdentifier ||
                itemIdentifier == WebServerSingleNotification ||
                itemIdentifier == AddStudiesToUserItemIdentifier ||
                itemIdentifier == AnonymizerToolbarItemIdentifier ||
                itemIdentifier == TrashToolbarItemIdentifier ||
                itemIdentifier == ReportToolbarItemIdentifier || // TODO: if report already exists, allow user to view it
                itemIdentifier == BurnerToolbarItemIdentifier ||
                itemIdentifier == AddStudiesToUserItemIdentifier ||
                itemIdentifier == QueryToolbarItemIdentifier
            {
                return false
            }
        }

        if containsDistantStudy {
            if itemIdentifier == WebServerSingleNotification ||
                itemIdentifier == AddStudiesToUserItemIdentifier ||
                itemIdentifier == AnonymizerToolbarItemIdentifier ||
                itemIdentifier == TrashToolbarItemIdentifier ||
                itemIdentifier == ReportToolbarItemIdentifier ||
                itemIdentifier == BurnerToolbarItemIdentifier ||
                itemIdentifier == AddStudiesToUserItemIdentifier
            {
                return false
            }
        }

        if (browser.horos_databaseOutline?.selectedRowIndexes.count ?? 0) < 1 || containsDistantStudy { // No Database Selection
            if containsDistantStudy == true && action == #selector(BrowserController.querySelectedStudy(_:)) {
                return true
            }

            if action == #selector(BrowserController.rebuildThumbnails(_:)) ||
                action == #selector(BrowserController.searchForCurrentPatient(_:)) ||
                action == #selector(BrowserController.viewerDICOM(_:)) ||
                action == #selector(BrowserController.viewerSubSeriesDICOM(_:)) ||
                action == #selector(BrowserController.viewerReparsedSeries(_:)) ||
                action == #selector(BrowserController.movieViewerDICOM(_:)) ||
                action == #selector(BrowserController.viewerDICOMMergeSelection(_:)) ||
                action == #selector(BrowserController.revealInFinder(_:)) ||
                action == #selector(BrowserController.export2PACS(_:)) ||
                action == #selector(BrowserController.exportQuicktime(_:)) ||
                action == #selector(BrowserController.exportJPEG(_:)) ||
                action == #selector(BrowserController.exportTIFF(_:)) ||
                action == #selector(BrowserController.exportDICOMFile(_:)) ||
                action == #selector(BrowserController.exportROIAndKeyImagesAsDICOMSeries(_:)) ||
                action == #selector(BrowserController.sendMail(_:)) ||
                action == #selector(BrowserController.addStudiesToUser(_:)) ||
                action == #selector(BrowserController.sendEmailNotification(_:)) ||
                action == #selector(BrowserController.compressSelectedFiles(_:)) ||
                action == #selector(BrowserController.decompressSelectedFiles(_:)) ||
                action == #selector(BrowserController.generateReport(_:)) ||
                action == #selector(BrowserController.deleteReport(_:)) ||
                action == #selector(BrowserController.convertReportToPDF(_:)) ||
                action == #selector(BrowserController.convertReportToDICOMSR(_:)) ||
                action == #selector(BrowserController.delItem(_:)) ||
                action == #selector(BrowserController.querySelectedStudy(_:)) ||
                action == #selector(BrowserController.burnDICOM(_:)) ||
                action == #selector(BrowserController.viewXML(_:)) ||
                action == #selector(BrowserController.anonymizeDICOM(_:)) ||
                action == #selector(BrowserController.applyRoutingRule(_:)) ||
                action == #selector(BrowserController.viewerSubSeriesDICOM(_:)) ||
                action == #selector(BrowserController.viewerReparsedSeries(_:))
            {
                return false
            }
        }

        if !(browser.database?.isLocal() ?? false) {
            if itemIdentifier == ImportToolbarItemIdentifier { return false }
            if itemIdentifier == TrashToolbarItemIdentifier { return false }
            if itemIdentifier == QueryToolbarItemIdentifier { return false }
        }

        if itemIdentifier == OpenKeyImagesAndROIsToolbarItemIdentifier {
            if containsDistantStudy {
                return false
            }

            return browser.horos_ROIsAndKeyImagesButtonAvailable
        }

        if itemIdentifier == ExportROIAndKeyImagesToolbarItemIdentifier {
            if containsDistantStudy {
                return false
            }

            return browser.horos_ROIsAndKeyImagesButtonAvailable
        }

        if itemIdentifier == ViewersToolbarItemIdentifier {
            if ViewerController.numberOf2DViewer() >= 1 { return true }
            else { return false }
        }

        if itemIdentifier == WebServerSingleNotification {
            if containsDistantStudy {
                return false
            }

            if preferences[NetworkPreferences.webServer] == false || preferences[WebPortalPreferences.requiresAuthentication] == false {
                return false
            }
        }

        if itemIdentifier == AddStudiesToUserItemIdentifier {
            if containsDistantStudy {
                return false
            }

            if preferences[NetworkPreferences.webServer] == false || preferences[WebPortalPreferences.requiresAuthentication] == false {
                return false
            }
        }

        return true
    }

    // MARK: - The toolbar's own commands

    /// Opens the Migration Assistant again, as if its question had never been
    /// answered.
    func openMigrationAssistant() {
        preferences.remove(DatabasePreferences.o2hMigrationUserAction)

        if O2HMigrationAssistant.isOsiriXInstalled() == false {
            HorosAlertPanel.runInformational(title: NSLocalizedString("IsiX DICOM Viewer Migration Assistant", comment: ""),
                                             message: NSLocalizedString("It seems you don't have OsiriX installed.", comment: ""),
                                             defaultButton: NSLocalizedString("Return", comment: ""),
                                             alternateButton: nil,
                                             otherButton: nil)
            return
        }

        O2HMigrationAssistant.performStartupO2HTasks(browser)
    }

    // MARK: - Restore Views

    private static let splitDrawerHidden = PreferenceKey<Bool>("SplitDrawerHidden")
    private static let splitComparativeHidden = PreferenceKey<Bool>("SplitComparativeHidden")
    private static let sidebarWidth = PreferenceKey<Double>(DatabaseBrowserLayout.sidebarWidthDefaultsKey)

    /// Shows every pane of a split view, at the same size.
    func spaceEvenly(_ splitView: NSSplitView?) {
        let subviews = splitView?.subviews ?? []
        let count = subviews.count
        guard count != 0, let splitView else { return }

        splitView.isHidden = false
        let vertical = splitView.isVertical
        let bounds = splitView.bounds
        let divider = splitView.dividerThickness
        let extent = vertical ? bounds.size.width : bounds.size.height
        let size = max(0, extent - CGFloat(count - 1) * divider) / CGFloat(count)
        var position: CGFloat = 0
        for view in subviews {
            view.isHidden = false
            let start = position.rounded(), end = (position + size).rounded()
            view.frame = vertical ? NSMakeRect(start, 0, end - start, bounds.size.height)
                                  : NSMakeRect(0, start, bounds.size.width, end - start)
            position += size + divider
        }
        splitView.adjustSubviews()
    }

    /// The window's panes back to their first layout.
    func restoreViews() {
        // Restore only presentation: keep the database, selected source and albums intact.
        self.spaceEvenly(browser.horos_splitDrawer)
        if let splitDrawer = browser.horos_splitDrawer {
            // The side columns come back to their default width, not half the window.
            splitDrawer.subviews.first?.setFrameSize(NSMakeSize(DatabaseBrowserLayout.defaultColumnWidth, splitDrawer.bounds.size.height))
            preferences.set(Double(DatabaseBrowserLayout.defaultColumnWidth), for: Self.sidebarWidth)
            splitDrawer.resizeSubviews(withOldSize: splitDrawer.bounds.size)
        }
        self.spaceEvenly(browser.horos_splitAlbums)
        if let splitAlbums = browser.horos_splitAlbums {
            DatabaseBrowserLayout.layoutSidebar(splitAlbums)
        }
        self.spaceEvenly(browser.horos_splitViewHorz)
        self.spaceEvenly(browser.horos_splitComparative)
        if let splitComparative = browser.horos_splitComparative {
            if !BrowserController.horizontalHistory(), splitComparative.subviews.count > 1 {
                splitComparative.subviews[1].setFrameSize(NSMakeSize(DatabaseBrowserLayout.defaultColumnWidth, splitComparative.bounds.size.height))
                preferences.set(Double(DatabaseBrowserLayout.defaultColumnWidth), for: DatabasePreferences.databaseHistoryWidth)
            }
            splitComparative.resizeSubviews(withOldSize: splitComparative.bounds.size)
        }
        browser.horos_splitViewVertDividerRatio = 0.5
        self.spaceEvenly(browser.horos_splitViewVert)

        browser.horos_splitDrawer?.saveDefault("SplitDrawer")
        browser.horos_splitAlbums?.saveDefault("SplitAlbums")
        browser.horos_splitViewHorz?.saveDefault("SplitHorz2")
        browser.horos_splitComparative?.saveDefault("SplitComparative")
        browser.horos_splitViewVert?.saveDefault("SplitVert2")
        preferences.set(false, for: Self.splitDrawerHidden)
        preferences.set(false, for: Self.splitComparativeHidden)
    }

    // MARK: - Contextual menus

    /// The list's contextual menu and the albums' (the columns menu has its
    /// own): built again each time it opens, after the selection and the
    /// database.
    func menuWillOpen(_ menu: NSMenu) {
        if menu === browser.horos_columnsMenu {
            browser.columnsMenuWillOpen()
            return
        }

        menu.removeAllItems()

        let isWritable = !(browser.database?.isReadOnly ?? false)

        if let albums = browser.horos_albumTable?.menu, menu === albums {
            if browser.database?.isLocal() ?? false {
                let row = browser.horos_albumTable?.clickedRow ?? 0

                func add(_ title: String, _ action: Selector) {
                    let item = NSMenuItem(title: NSLocalizedString(title, comment: ""), action: action, keyEquivalent: "")
                    item.target = browser // required because the drawer is the first responder
                    menu.addItem(item)
                }

                if !(browser.horos_databaseIvar?.isReadOnly ?? false) {
                    add("Edit Album", #selector(BrowserController.albumTableDoublePressed(_:)))
                    menu.addItem(.separator())
                    add("Add Album", #selector(BrowserController.addAlbum(_:)))
                    add("Add Smart Album", #selector(BrowserController.addSmartAlbum(_:)))
                    menu.addItem(.separator())

                    if row > 0 { // index 0 is database, cannot be removed. Negative index = click on empty table (not on a particular item)
                        add("Delete Album", NSSelectorFromString("removeAlbum:"))
                        menu.addItem(.separator())
                    }
                }

                add("Save Albums", #selector(BrowserController.saveAlbums(_:)))
                add("Import Albums", #selector(BrowserController.addAlbums(_:)))
                menu.addItem(.separator())
                add("Create Default Albums", #selector(BrowserController.defaultAlbums(_:)))
            }
            return
        }

        // The less frequent commands are grouped in submenus, and what does not
        // apply to the selection is hidden at the end instead of dimmed.
        var groups: [NSMenu] = []
        func addGroup(_ title: String) -> NSMenu {
            let group = NSMenu(title: title)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = group
            menu.addItem(item)
            groups.append(group)
            return group
        }
        func add(_ title: String, _ action: String, to target: NSMenu? = nil) {
            (target ?? menu).addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: "")
        }
        func ellipsis(_ title: String) -> String { NSLocalizedString(title, comment: "") + "\u{2026}" }
        var group: NSMenu

        add(NSLocalizedString("Display only this patient", comment: ""), "searchForCurrentPatient:")

        menu.addItem(.separator())
        add(NSLocalizedString("Open Images", comment: ""), "viewerDICOM:")
        add(NSLocalizedString("Open Images in 4D", comment: ""), "MovieViewerDICOM:")
        group = addGroup(NSLocalizedString("Open Special", comment: ""))
        add(NSLocalizedString("Sub-Selection", comment: ""), "viewerSubSeriesDICOM:", to: group)
        add(NSLocalizedString("Reparsed Series", comment: ""), "viewerReparsedSeries:", to: group)
        add(NSLocalizedString("Merged Selection", comment: ""), "viewerDICOMMergeSelection:", to: group)
        group.addItem(.separator())
        add(NSLocalizedString("Key Images", comment: ""), "viewerDICOMKeyImages:", to: group)
        add(NSLocalizedString("ROIs Images", comment: ""), "viewerDICOMROIsImages:", to: group)
        add(NSLocalizedString("ROIs and Key Images", comment: ""), "viewerKeyImagesAndROIsImages:", to: group)
        add(NSLocalizedString("Reveal In Finder", comment: ""), "revealInFinder:")

        menu.addItem(.separator())
        if let workspace = processGraph.applicationMenus.workspaceMenu() {
            group = addGroup(NSLocalizedString("Workspace State", comment: ""))
            let load = NSMenuItem(title: NSLocalizedString("Load DICOM SR", comment: ""), action: nil, keyEquivalent: "")
            load.submenu = workspace.copy() as? NSMenu
            group.addItem(load)
            add(NSLocalizedString("Reset", comment: ""), "resetWindowsState:", to: group)
        }
        group = addGroup(NSLocalizedString("Export", comment: ""))
        add(ellipsis("DICOM Network Node"), "export2PACS:", to: group)
        add(ellipsis("DICOM File(s)"), "exportDICOMFile:", to: group)
        add(ellipsis("Email"), "sendMail:", to: group)
        group.addItem(.separator())
        add(ellipsis("Movie"), "exportQuicktime:", to: group)
        add(ellipsis("JPEG"), "exportJPEG:", to: group)
        add(ellipsis("TIFF"), "exportTIFF:", to: group)
        group.addItem(.separator())
        add(NSLocalizedString("ROI and Key Images as a DICOM Series", comment: ""), "exportROIAndKeyImagesAsDICOMSeries:", to: group)
        if isWritable {
            group.addItem(.separator())
            add(ellipsis("Burn to Disc"), "burnDICOM:", to: group)
        }

        if isWritable {
            group = addGroup(NSLocalizedString("Web Portal Users", comment: ""))
            add(NSLocalizedString("Add selected study(s) to user(s)", comment: ""), "addStudiesToUser:", to: group)
            add(NSLocalizedString("Send an email notification to user(s)", comment: ""), "sendEmailNotification:", to: group)
        }

        if isWritable { // TODO: allow report access, read-only
            add(NSLocalizedString("Create/Open Report", comment: ""), "generateReport:")
            group = addGroup(NSLocalizedString("Convert Report", comment: ""))
            add(ellipsis("Convert to PDF"), "convertReportToPDF:", to: group)
            add(NSLocalizedString("Convert to DICOM PDF", comment: ""), "convertReportToDICOMSR:", to: group)
            // File > Import's command on the selected study.
            DatabaseStudyCommands.addContextualItems(to: menu)
            StudyStates.addContextualItems(to: menu)
        }

        if isWritable {
            menu.addItem(.separator())
            add(NSLocalizedString("Lock Studies", comment: ""), "lockStudies:")
            add(NSLocalizedString("Unlock Studies", comment: ""), "unlockStudies:")
            add(NSLocalizedString("Merge Selected Studies", comment: ""), "mergeStudies:")
            add(NSLocalizedString("Unify patient identity", comment: ""), "unifyStudies:")
            add(NSLocalizedString("Anonymize", comment: ""), "anonymizeDICOM:")

            menu.addItem(.separator())
            add(NSLocalizedString("Compress DICOM files", comment: ""), "compressSelectedFiles:")
            add(NSLocalizedString("Decompress DICOM files", comment: ""), "decompressSelectedFiles:")
            group = addGroup(NSLocalizedString("Files & Maintenance", comment: ""))
            add(NSLocalizedString("Rebuild Selected Thumbnails", comment: ""), "rebuildThumbnails:", to: group)
            add(NSLocalizedString("Regenerate Auto-Fill Comment field", comment: ""), "regenerateAutoComments:", to: group)
            add(NSLocalizedString("Copy Linked Files to Database Folder", comment: ""), "copyToDBFolder:", to: group)

            menu.addItem(.separator())
            add(NSLocalizedString("Query Selected Patient from Q&R Window...", comment: ""), "querySelectedStudy:")
        }

        let autoroutingRules = preferences.object(forKey: RoutingRule.preferenceKey) as? [Any]

        if isWritable && (autoroutingRules?.count ?? 0) != 0, let autoroutingRules {
            menu.addItem(.separator())

            let title = NSLocalizedString("Apply this Routing Rule to Selection", comment: "")
            let submenu = NSMenu(title: title)

            submenu.addItem(NSMenuItem(title: NSLocalizedString("All routing rules", comment: ""), action: NSSelectorFromString("applyRoutingRule:"), keyEquivalent: ""))
            submenu.addItem(.separator())

            for case let routingRule as NSObject in autoroutingRules {
                let rule = routingRule as? [String: Any]
                let name = rule?["name"]
                let ruleTitle: String
                if let description = rule?["description"] as? NSString, description.length > 0 {
                    ruleTitle = String(format: "%@ - %@", (name as? NSObject) ?? "(null)" as NSString, description)
                } else {
                    ruleTitle = name as? String ?? ""
                }
                let item = NSMenuItem(title: ruleTitle, action: NSSelectorFromString("applyRoutingRule:"), keyEquivalent: "")
                item.representedObject = routingRule
                // Disabled whether the rule is activated or not.
                item.isEnabled = false
                submenu.addItem(item)
            }

            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }

        if isWritable {
            menu.addItem(.separator())
            add(NSLocalizedString("Delete", comment: ""), "delItem:")
        }

        // Validating here also sets the titles that follow the selection, such
        // as Delete Selected Lines and Merge Selected Series.
        ContextMenuPruning.hideUnavailableItems(in: menu, groups: groups, defaultTarget: browser)
    }

    /// The Help menu of the menu bar.
    func addHelpMenu() {
        let mainMenu = NSApplication.shared.mainMenu
        let helpItem = mainMenu?.addItem(withTitle: NSLocalizedString("Help", comment: ""), action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: NSLocalizedString("Help", comment: ""))
        helpItem?.submenu = helpMenu

        helpMenu.addItem(withTitle: NSLocalizedString("Professional support", comment: ""), action: NSSelectorFromString("openHorosSupport:"), keyEquivalent: "")
        helpMenu.addItem(withTitle: NSLocalizedString("Community support", comment: ""), action: NSSelectorFromString("openCommunityPage:"), keyEquivalent: "")
        helpMenu.addItem(.separator())
        helpMenu.addItem(withTitle: NSLocalizedString("Report a bug", comment: ""), action: NSSelectorFromString("openBugReportPage:"), keyEquivalent: "")
    }

    // MARK: - Validating the commands

    /// Whether a command of the browser is enabled; also titles it after the
    /// selection and checks it.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let outline = browser.horos_databaseOutline
        let selection = outline?.selectedRowIndexes ?? IndexSet()

        if menuItem.action == #selector(BrowserController.attachExistingReport(_:)) || menuItem.action == #selector(BrowserController.insertSelectedImagesIntoReport(_:)) {
            guard let database = browser.database, database.isLocal(), !database.isReadOnly, selection.count == 1 else { return false }
            let item = outline?.item(atRow: selection.first ?? -1) as? NSObject
            if isDistantRow(item) { return false }
            let isStudy = (item?.value(forKey: "type") as? NSString)?.isEqual(to: "Study") ?? false
            let study = isStudy ? item : item?.value(forKey: "study") as? NSObject
            guard let study, !boolValue(study.value(forKey: "lockedStudy")) else { return false }
            if menuItem.action == #selector(BrowserController.attachExistingReport(_:)) { return true }

            let report = study.value(forKey: "reportURL") as? String ?? ""
            return !report.isEmpty && FileManager.default.fileExists(atPath: report)
                && ReportImageInsertion.kind(ofReportPath: report) != .unsupported
        }

        var containsDistantStudy = false
        for row in selection where isDistantRow(outline?.item(atRow: row)) {
            containsDistantStudy = true
            break
        }

        let answer = BrowserMenuValidation.validate(action: menuItem.action.map(NSStringFromSelector) ?? "",
                                                    containsDistantStudy: containsDistantStudy,
                                                    facts: BrowserMenuState(browser: browser, item: menuItem, preferences: preferences))
        switch answer.title {
        case .deleteSelectedSeriesThumbnails: menuItem.title = NSLocalizedString("Delete Selected Series Thumbnails", comment: "")
        case .deleteSelectedLines: menuItem.title = NSLocalizedString("Delete Selected Lines", comment: "")
        case .mergeSelectedSeries: menuItem.title = NSLocalizedString("Merge Selected Series", comment: "")
        case .mergeSelectedStudies: menuItem.title = NSLocalizedString("Merge Selected Studies", comment: "")
        case nil: break
        }
        if let checked = answer.checked { menuItem.state = checked ? .on : .off }
        return answer.enabled
    }
}
