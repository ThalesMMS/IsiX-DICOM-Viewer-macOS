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

// The "Toolbar functions" block of BrowserController is implemented in Swift
// since #831: a Swift extension of BrowserController, which stays Objective-C,
// with the same selectors. The instance variables it used are read through
// BrowserController (SwiftIvars), the file-scope statics through
// BrowserController (SwiftStatics).
//
// The toolbar identifiers were file-scope statics of BrowserController.m; the
// ones only this block used are the fileprivate constants below, with the same
// texts (BrowserController.m keeps its own OpenKeyImagesAndROIsToolbarItemIdentifier
// and SearchToolbarItemIdentifier). The class does not declare NSToolbarDelegate
// in Swift any more: this file does, and the delegate methods take the SDK's
// Swift signatures. A message to nil answered nil, 0 or NO: the optional
// chains below answer the same. An @try is HorosObjCException.perform (objcTry),
// an @synchronized is objcSynchronized. The caches the former code released and
// retained go through the retain setters of the ivar accessors. The disabled
// EXPORTTOOLBARITEM branches are left out.

/// `@synchronized (object) { … }`: the same recursive lock, taken on nothing
/// when the object is nil, and left before an exception raised inside goes on.
@inline(__always)
fileprivate func objcSynchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
    guard let object else { return body() }
    objc_sync_enter(object)
    var result: T?
    var raised: NSException?
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    objc_sync_exit(object)
    if let raised { raised.raise() }
    return result!
}

/// Runs `body` as an @try block: the NSException it raises is returned.
@inline(__always)
fileprivate func objcTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

/// `[value boolValue]` of an Info.plist value: an NSNumber or an NSString.
fileprivate func objcBoolValue(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
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

extension BrowserController: NSToolbarDelegate {}

public extension BrowserController {

    // MARK: -
    // MARK: Toolbar functions

    // ============================================================
    // NSToolbar Related Methods
    // ============================================================

    @objc(windowDidResignKey:)
    func windowDidResignKey(_ notification: Notification!) {
        self.horos_DatabaseIsEdited = false
    }

    @objc(windowDidBecomeKey:)
    func windowDidBecomeKey(_ notification: Notification!) {
        self.flagsChanged(with: NSApp.currentEvent)

        objcSynchronized(self.horos_albumNoOfStudiesCache) {
            if (self.horos_albumNoOfStudiesCache?.count ?? 0) == 0 {
                self.refreshAlbums()
            }
        }
    }

    // [NSApp currentEvent], which -windowDidBecomeKey: sends, can be nil: the
    // parameter stays optional, and nil has no modifier flags.
    @objc(flagsChanged:)
    override func flagsChanged(with event: NSEvent?) {
        let modifierFlags: NSEvent.ModifierFlags = event?.modifierFlags ?? []

        if self.horos_previousFlags == modifierFlags.rawValue {
            return
        }

        for toolbarItem in self.horos_toolbar?.items ?? [] {
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
        if (self.horos_databaseOutline?.editedRow ?? 0) == -1 {
            self.outlineViewSelectionDidChange(nil)
        } else {
            self.horos_refreshDeferredWhileEditing = true
        }

        self.horos_previousFlags = modifierFlags.rawValue
    }

    @objc(setupToolbar)
    func setupToolbar() {
        // Create a new toolbar instance, and attach it to our document window
        let toolbar = NSToolbar(identifier: DatabaseToolbarIdentifier)
        self.horos_toolbar = toolbar

        // Set up toolbar properties: Allow customization, give a default display mode, and remember state in user defaults
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        // A row of its own: in the title bar, the window title and the
        // database folder's icon took room from the items (#984).
        self.window?.toolbarStyle = .expanded

        // We are the delegate
        toolbar.delegate = self

        // Attach the toolbar to the document window
        self.window?.toolbar = toolbar
        self.window?.showsToolbarButton = false
        self.window?.toolbar?.isVisible = true
        ToolbarPolicy.adopt(toolbar: toolbar, in: self.window)

        // The EXPORTTOOLBARITEM branch (a screenshot of every item), disabled, is left out.
    }

    @objc(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:)
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
            newItem.target = self
            newItem.action = #selector(BrowserController.selectFilesAndFoldersToAdd(_:))
        } else if itemIdent == QTSaveToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Movie Export", comment: "")
            newItem.paletteLabel = NSLocalizedString("Movie Export", comment: "")
            newItem.image = NSImage.toolbarImageNamed(QTSaveToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.exportQuicktime(_:))
        } else if itemIdent == WebServerSingleNotification {
            newItem.label = NSLocalizedString("Notification", comment: "")
            newItem.paletteLabel = NSLocalizedString("Notification", comment: "")
            newItem.image = NSImage.toolbarImageNamed(WebServerSingleNotification)
            newItem.target = self
            newItem.action = #selector(BrowserController.sendEmailNotification(_:))
        } else if itemIdent == AddStudiesToUserItemIdentifier {
            newItem.label = NSLocalizedString("Add Studies", comment: "")
            newItem.paletteLabel = NSLocalizedString("Add Studies", comment: "")
            newItem.image = NSImage.toolbarImageNamed(AddStudiesToUserItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.addStudiesToUser(_:))
        } else if itemIdent == MailToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Email", comment: "")
            newItem.paletteLabel = NSLocalizedString("Email", comment: "")
            newItem.image = NSImage.toolbarImageNamed(MailToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.sendMail(_:))
        } else if itemIdent == ExportToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Export", comment: "")
            newItem.paletteLabel = NSLocalizedString("Export", comment: "")
            newItem.toolTip = NSLocalizedString("Export selected study/series to a DICOM folder", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ExportToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.exportDICOMFile(_:))
        } else if itemIdent == ExportROIAndKeyImagesToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Export ROIs & Keys", comment: "")
            newItem.paletteLabel = NSLocalizedString("Export ROIs & Keys", comment: "")
            newItem.toolTip = NSLocalizedString("Export ROI and Key images of selected study/series as a DICOM Series", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ExportROIAndKeyImagesToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.exportROIAndKeyImagesAsDICOMSeries(_:))
        } else if itemIdent == ViewersToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Viewers", comment: "")
            newItem.paletteLabel = NSLocalizedString("Viewers", comment: "")
            newItem.toolTip = NSLocalizedString("Bring Viewers windows to the front", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ViewersToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.tileWindows(_:))
        } else if itemIdent == AnonymizerToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Anonymize", comment: "")
            newItem.paletteLabel = NSLocalizedString("Anonymize", comment: "")
            newItem.toolTip = NSLocalizedString("Anonymize selected study/series to a DICOM folder", comment: "")
            newItem.image = NSImage.toolbarImageNamed(AnonymizerToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.anonymizeDICOM(_:))
        } else if itemIdent == QueryToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Query", comment: "")
            newItem.paletteLabel = NSLocalizedString("Query", comment: "")
            newItem.toolTip = NSLocalizedString("Query and retrieve a DICOM study from a DICOM node\rShift + click to query selected patient.", comment: "")
            newItem.image = NSImage.toolbarImageNamed(QueryToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.queryDICOM(_:))
            newItem.tag = 0
        } else if itemIdent == SendToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Send", comment: "")
            newItem.paletteLabel = NSLocalizedString("Send", comment: "")
            newItem.toolTip = NSLocalizedString("Send selected study/series to a DICOM node", comment: "Send selected study/series to a DICOM node")
            newItem.image = NSImage.toolbarImageNamed(SendToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.export2PACS(_:))
        } else if itemIdent == ViewerToolbarItemIdentifier {

            newItem.label = NSLocalizedString("2D Viewer", comment: "")
            newItem.paletteLabel = NSLocalizedString("2D Viewer", comment: "")
            newItem.toolTip = NSLocalizedString("View selected study/series", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ViewerToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.viewerDICOM(_:))
        }
        //	else if ([itemIdent isEqualToString: CDRomToolbarItemIdentifier])
        //	{
        //
        //		[toolbarItem setLabel: NSLocalizedString(@"CD-Rom",nil)];
        //		[toolbarItem setPaletteLabel: NSLocalizedString(@"CD-Rom",nil)];
        //        [toolbarItem setToolTip: NSLocalizedString(@"Load images from current DICOM CD-Rom",nil)];
        //		[toolbarItem setImage: [NSImage toolbarImageNamed: CDRomToolbarItemIdentifier]];
        //		[toolbarItem setTarget: self];
        //		[toolbarItem setAction: @selector(ReadDicomCDRom:)];
        //    }
        else if itemIdent == MovieToolbarItemIdentifier {

            newItem.label = NSLocalizedString("4D Viewer", comment: "")
            newItem.paletteLabel = NSLocalizedString("4D Viewer", comment: "")
            newItem.toolTip = NSLocalizedString("Load multiple series into an animated 4D series", comment: "")
            newItem.image = NSImage.toolbarImageNamed(MovieToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.movieViewerDICOM(_:))
        } else if itemIdent == TrashToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Delete", comment: "")
            newItem.paletteLabel = NSLocalizedString("Delete", comment: "")
            newItem.toolTip = NSLocalizedString("Delete selected images from the database", comment: "")
            newItem.image = NSImage.toolbarImageNamed(TrashToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.delItem(_:))
        } else if itemIdent == ReportToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Report", comment: "")
            newItem.paletteLabel = NSLocalizedString("Report", comment: "")
            newItem.toolTip = NSLocalizedString("Create/Open a report for selected study", comment: "")
            self.setToolbarReportIconFor(newItem)
            newItem.target = self
            newItem.action = #selector(BrowserController.generateReport(_:))
        } else if itemIdent == OpenKeyImagesAndROIsToolbarItemIdentifier {
            newItem.label = NSLocalizedString("ROIs & Keys", comment: "")
            newItem.paletteLabel = NSLocalizedString("ROIs & Keys", comment: "")
            newItem.toolTip = NSLocalizedString("View all Key Images and ROIs", comment: "")
            newItem.image = NSImage.toolbarImageNamed(OpenKeyImagesAndROIsToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.viewerKeyImagesAndROIsImages(_:))
        } else if itemIdent == XMLToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Meta-Data", comment: "")
            newItem.paletteLabel = NSLocalizedString("Meta-Data", comment: "")
            newItem.toolTip = NSLocalizedString("View meta-data of this image", comment: "")
            newItem.image = NSImage.toolbarImageNamed(XMLToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.viewXML(_:))
        } else if itemIdent == BurnerToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Burn", comment: "")
            newItem.paletteLabel = NSLocalizedString("Burn", comment: "")
            newItem.toolTip = NSLocalizedString("Burn a DICOM-compatible CD or DVD", comment: "Burn a DICOM-compatible CD or DVD")
            newItem.image = NSImage.toolbarImageNamed(BurnerToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.burnDICOM(_:))
        } else if itemIdent == ToggleDrawerToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Albums & Sources", comment: "")
            newItem.paletteLabel = NSLocalizedString("Albums & Sources", comment: "")
            newItem.toolTip = NSLocalizedString("Toggle Albums & Sources drawer", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ToggleDrawerToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.drawerToggle(_:))
        } else if itemIdent == SearchToolbarItemIdentifier {
            // A custom search field cannot be edited from the overflow menu.
            newItem.visibilityPriority = .high
            newItem.label = NSLocalizedString("Search by All Fields", comment: "")
            newItem.paletteLabel = NSLocalizedString("Search", comment: "")
            newItem.toolTip = NSLocalizedString("Search", comment: "")

            // Use a custom view, a text field, for the search item
            newItem.view = self.horos_searchView
        } else if itemIdent == TimeIntervalToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Time Interval", comment: "")
            newItem.paletteLabel = NSLocalizedString("Time Interval", comment: "")
            newItem.toolTip = NSLocalizedString("Time Interval", comment: "")

            // Use a custom view, a text field, for the search item
            newItem.view = self.horos_timeIntervalView
        } else if itemIdent == ModalityFilterToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Modality", comment: "")
            newItem.paletteLabel = NSLocalizedString("Modality", comment: "")
            newItem.toolTip = NSLocalizedString("Modality", comment: "")

            // Use a custom view, a text field, for the search item
            newItem.view = self.horos_modalityFilterView
        } else if itemIdent == ResetSplitViewsItemIdentifier {
            newItem.label = NSLocalizedString("Restore Views", comment: "")
            newItem.paletteLabel = NSLocalizedString("Restore Views", comment: "")
            newItem.toolTip = NSLocalizedString("Restore Views To Original State", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ResetSplitViewsItemIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.restoreWindowState(_:))
        } else if itemIdent == HorosMigrationAssistantIdentifier {
            newItem.label = NSLocalizedString("Migration Assistant", comment: "")
            newItem.paletteLabel = NSLocalizedString("Migration Assistant", comment: "")
            newItem.toolTip = NSLocalizedString("Open Horos Migration Assistant", comment: "")
            newItem.image = NSImage.toolbarImageNamed(HorosMigrationAssistantIdentifier)
            newItem.target = self
            newItem.action = #selector(BrowserController.openHorosMigrationAssistant(_:))
        } else {
            // Is it a plugin menu item?
            if PluginManager.pluginsDict()?.object(forKey: itemIdent) != nil {
                let bundle = PluginManager.pluginsDict()?.object(forKey: itemIdent) as? Bundle
                let info = bundle?.infoDictionary as NSDictionary?

                newItem.label = itemIdent
                newItem.paletteLabel = itemIdent
                let toolTips = info?.object(forKey: "ToolbarToolTips") as? NSDictionary
                if let toolTips {
                    newItem.toolTip = toolTips.object(forKey: itemIdent) as? String
                } else {
                    newItem.toolTip = itemIdent
                }

                //			NSLog( @"ICON:");
                //			NSLog( [info objectForKey:@"ToolbarIcon"]);

                var image = (info?.object(forKey: "ToolbarIcon") as? String)
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

                newItem.target = self
                newItem.action = #selector(BrowserController.executeFilterFromToolbar(_:))
            }

            let pluginToolbarItemSelector = #selector(PluginFilter.toolbarItem(forItemIdentifier:forBrowserController:))
            for key in PluginManager.plugins()?.allKeys ?? [] {
                let plugin = PluginManager.plugins()?.object(forKey: key) as AnyObject?
                if plugin?.responds(to: pluginToolbarItemSelector) == true {
                    let item: NSToolbarItem? = plugin?.toolbarItem?(forItemIdentifier: itemIdent, forBrowserController: self) ?? nil

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

    @objc(openHorosMigrationAssistant:)
    func openHorosMigrationAssistant(_ sender: Any!) {
        UserDefaults.standard.removeObject(forKey: "O2H_MIGRATION_USER_ACTION")
        UserDefaults.standard.synchronize()

        if O2HMigrationAssistant.isOsiriXInstalled() == false {
            HorosAlertPanel.runInformational(title: NSLocalizedString("Horos Migration Assistant", comment: ""),
                                             message: NSLocalizedString("It seems you don't have OsiriX installed.", comment: ""),
                                             defaultButton: NSLocalizedString("Return", comment: ""),
                                             alternateButton: nil,
                                             otherButton: nil)
            return
        }

        O2HMigrationAssistant.performStartupO2HTasks(self)
    }

    @objc(spaceEvenly:)
    func spaceEvenly(_ splitView: NSSplitView!) {
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

    @objc(restoreWindowState:)
    func restoreWindowState(_ sender: Any!) {
        // Restore only presentation: keep the database, selected source and albums intact.
        self.spaceEvenly(self.horos_splitDrawer)
        if let splitDrawer = self.horos_splitDrawer {
            splitDrawer.resizeSubviews(withOldSize: splitDrawer.bounds.size)
        }
        self.spaceEvenly(self.horos_splitAlbums)
        if let splitAlbums = self.horos_splitAlbums {
            DatabaseBrowserLayout.layoutSidebar(splitAlbums)
        }
        self.spaceEvenly(self.horos_splitViewHorz)
        self.spaceEvenly(self.horos_splitComparative)
        if let splitComparative = self.horos_splitComparative {
            splitComparative.resizeSubviews(withOldSize: splitComparative.bounds.size)
        }
        self.horos_splitViewVertDividerRatio = 0.5
        self.spaceEvenly(self.horos_splitViewVert)

        self.horos_splitDrawer?.saveDefault("SplitDrawer")
        self.horos_splitAlbums?.saveDefault("SplitAlbums")
        self.horos_splitViewHorz?.saveDefault("SplitHorz2")
        self.horos_splitComparative?.saveDefault("SplitComparative")
        self.horos_splitViewVert?.saveDefault("SplitVert2")
        UserDefaults.standard.set(false, forKey: "SplitDrawerHidden")
        UserDefaults.standard.set(false, forKey: "SplitComparativeHidden")
    }

    @objc(toolbarDefaultItemIdentifiers:)
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

    @objc(toolbarAllowedItemIdentifiers:)
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let array = NSMutableArray(array: [
            ViewersToolbarItemIdentifier,
            SearchToolbarItemIdentifier,
            TimeIntervalToolbarItemIdentifier,
            ModalityFilterToolbarItemIdentifier,
            NSToolbarItem.Identifier.customizeToolbar.rawValue,
            NSToolbarItem.Identifier.flexibleSpace.rawValue,
            ToolbarPolicy.spaceItemIdentifier,
            NSToolbarItem.Identifier.separator.rawValue,
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
        ])

        let allPlugins = PluginManager.pluginsDict()?.allKeys ?? []
        let pluginsItems = NSMutableSet(capacity: allPlugins.count)

        for case let plugin as String in allPlugins {
            if plugin == "(-" {
                continue
            }

            let bundle = PluginManager.pluginsDict()?.object(forKey: plugin) as? Bundle
            let info = bundle?.infoDictionary as NSDictionary?

            if (info?.object(forKey: "pluginType") as? String) == "Database" {
                let allowToolbarIcon = info?.object(forKey: "allowToolbarIcon")
                if allowToolbarIcon != nil {
                    if objcBoolValue(allowToolbarIcon) == true {
                        let toolbarNames = info?.object(forKey: "ToolbarNames") as? NSArray
                        if let toolbarNames {
                            if toolbarNames.contains(plugin) {
                                pluginsItems.add(plugin)
                            }
                        } else {
                            pluginsItems.add(plugin)
                        }
                    }
                }
            }
        }

        if pluginsItems.count != 0 {
            array.addObjects(from: pluginsItems.allObjects)
        }

        let pluginAllowedIdentifiersSelector = #selector(PluginFilter.toolbarAllowedIdentifiers(forBrowserController:))
        for key in PluginManager.plugins()?.allKeys ?? [] {
            let plugin = PluginManager.plugins()?.object(forKey: key) as AnyObject?
            if plugin?.responds(to: pluginAllowedIdentifiersSelector) == true {
                let identifiers: [Any]? = plugin?.toolbarAllowedIdentifiers?(forBrowserController: self) ?? nil
                if let identifiers {
                    array.addObjects(from: identifiers)
                }
            }
        }

        // The toolbar only takes strings: anything else a plugin returned is left out.
        return array.compactMap { ($0 as? String).map { NSToolbarItem.Identifier($0) } }
    }

    @objc(toolbarWillAddItem:)
    func toolbarWillAddItem(_ notification: Notification) {
        // Optional delegate method:  Before an new item is added to the toolbar, this notification is posted.
        // This is the best place to notice a new item is going into the toolbar.  For instance, if you need to
        // cache a reference to the toolbar item or need to set up some initial state, this is the best place
        // to do it.  The notification object is the toolbar to which the item is being added.  The item being
        // added is found by referencing the @"item" key in the userInfo

        let addedItem = notification.userInfo?["item"] as? NSToolbarItem

        if addedItem?.itemIdentifier.rawValue == SearchToolbarItemIdentifier {
            self.horos_toolbarSearchItem = addedItem
        }
    }

    @objc(toolbarDidRemoveItem:)
    func toolbarDidRemoveItem(_ notification: Notification) {
        // Optional delegate method:  After an item is removed from a toolbar, this notification is sent.   This allows
        // the chance to tear down information related to the item that may have been cached.   The notification object
        // is the toolbar from which the item is being removed.  The item being added is found by referencing the @"item"
        // key in the userInfo
        let removedItem = notification.userInfo?["item"] as? NSToolbarItem

        if removedItem?.itemIdentifier.rawValue == SearchToolbarItemIdentifier {
            self.horos_toolbarSearchItem = nil
        }
    }

    @objc(ROIsAndKeyImages:sameSeries:)
    func roisAndKeyImages(_ sender: Any!, sameSeries: UnsafeMutablePointer<ObjCBool>!) -> [Any]! {
        let selectedItems = NSMutableArray()

        if ((sender as? NSMenuItem).map { $0.menu === self.horos_oMatrix?.menu } ?? false) || self.window?.firstResponder === self.horos_oMatrix {
            _ = self.files(forDatabaseMatrixSelection: selectedItems)
        } else {
            _ = self.files(forDatabaseOutlineSelection: selectedItems)
        }

        if selectedItems.isEqual(self.horos_lastROIsAndKeyImagesSelectedFiles) && self.horos_ROIsAndKeyImagesCache != nil {
            if let sameSeries {
                sameSeries.pointee = ObjCBool(self.horos_ROIsAndKeyImagesCacheSameSeries)
            }

            return self.horos_ROIsAndKeyImagesCache
        }

        let roisImagesArray = NSMutableArray()

        if selectedItems.count > 0 {
            var study: DicomStudy? = nil
            var roisArray: [Any]? = nil

            for case let image as DicomImage in selectedItems {
                if study !== image.series?.study {
                    study = image.series?.study
                    roisArray = (study?.roiSRSeries()?.value(forKey: "images") as? NSSet)?.allObjects
                }

                if let e = objcTry({
                    let roiImage = study?.roiForImage(image, inArray: roisArray as NSArray?)

                    if roiImage != nil && (roiImage?.value(forKey: "scale") == nil || ((roiImage?.value(forKey: "scale") as? NSNumber)?.int32Value ?? 0) > 0) { // @"scale" contains the number of ROI objects
                        roisImagesArray.add(image)
                    } else if ((image.value(forKey: "isKeyImage") as? NSNumber)?.boolValue ?? false) == true {
                        roisImagesArray.add(image)
                    }
                }) {
                    _N2LogExceptionImpl(e, true, "-[BrowserController ROIsAndKeyImages:sameSeries:]")
                }
            }

            let series = (roisImagesArray.lastObject as AnyObject?)?.value(forKey: "series") as AnyObject?

            self.horos_ROIsAndKeyImagesCacheSameSeries = true
            if let sameSeries {
                sameSeries.pointee = ObjCBool(self.horos_ROIsAndKeyImagesCacheSameSeries)
            }

            for case let image as DicomImage in roisImagesArray {
                if (image.value(forKey: "series") as AnyObject?) !== series {
                    self.horos_ROIsAndKeyImagesCacheSameSeries = false
                    if let sameSeries {
                        sameSeries.pointee = ObjCBool(self.horos_ROIsAndKeyImagesCacheSameSeries)
                    }
                    break
                }
            }
        }

        self.horos_ROIsAndKeyImagesCache = roisImagesArray as? [Any]

        self.horos_lastROIsAndKeyImagesSelectedFiles = selectedItems

        return roisImagesArray as? [Any]
    }

    @objc(ROIsAndKeyImages:)
    func roisAndKeyImages(_ sender: Any!) -> [Any]! {
        return self.roisAndKeyImages(sender, sameSeries: nil)
    }

    @objc(viewerKeyImagesAndROIsImages:)
    func viewerKeyImagesAndROIsImages(_ sender: Any!) {
        var sameSeries: ObjCBool = false
        let roisImagesArray = (self.roisAndKeyImages(sender, sameSeries: &sameSeries) ?? []) as NSArray

        if roisImagesArray.count != 0 {

            let copySettings = NSMutableArray()

            if sameSeries.boolValue == false {
                for case let im as DicomImage in roisImagesArray {
                    let d = NSMutableDictionary()

                    d.setObject(im, forKey: "im" as NSString)

                    if let value = im.value(forKeyPath: "series.windowWidth") {
                        d.setObject(value, forKey: "windowWidth" as NSString)
                    }

                    if let value = im.value(forKeyPath: "series.windowLevel") {
                        d.setObject(value, forKey: "windowLevel" as NSString)
                    }

                    if let value = im.value(forKeyPath: "series.rotationAngle") {
                        d.setObject(value, forKey: "rotationAngle" as NSString)
                    }

                    if let value = im.value(forKeyPath: "series.yFlipped") {
                        d.setObject(value, forKey: "yFlipped" as NSString)
                    }

                    if let value = im.value(forKeyPath: "series.xFlipped") {
                        d.setObject(value, forKey: "xFlipped" as NSString)
                    }

                    if let value = im.value(forKeyPath: "series.xOffset") {
                        d.setObject(value, forKey: "xOffset" as NSString)
                    }

                    if let value = im.value(forKeyPath: "series.yOffset") {
                        d.setObject(value, forKey: "yOffset" as NSString)
                    }

                    if let value = im.value(forKeyPath: "series.displayStyle") {
                        d.setObject(value, forKey: "displayStyle" as NSString)
                    }

                    if let value = im.value(forKeyPath: "series.scale") {
                        d.setObject(value, forKey: "scale" as NSString)
                    }

                    copySettings.add(d)
                }
            }
            BrowserController.horos_dontShowOpenSubSeries = true
            let v = self.openViewer(fromImages: [roisImagesArray], movie: false, viewer: nil, keyImagesOnly: false)
            BrowserController.horos_dontShowOpenSubSeries = false

            if sameSeries.boolValue == false {
                v?.imageView()?.copysettingsinseries = false

                for case let d as NSDictionary in copySettings {
                    let im = d.object(forKey: "im") as? NSManagedObject

                    // Each of these guards asked whether the destination image
                    // already carried the setting, not whether the source series
                    // had one to copy. An image with no image-level presentation -
                    // which is every image until propagation is turned off - was
                    // therefore skipped, so images gathered from different series
                    // all reverted to their own defaults instead of keeping the
                    // presentation of the series they came from. The scale branch
                    // below already asks the right question.
                    if d.value(forKey: "windowWidth") != nil {
                        im?.setValue(d.value(forKey: "windowWidth"), forKey: "windowWidth")
                    }

                    if d.value(forKey: "windowLevel") != nil {
                        im?.setValue(d.value(forKey: "windowLevel"), forKey: "windowLevel")
                    }

                    if d.value(forKey: "rotationAngle") != nil {
                        im?.setValue(d.value(forKey: "rotationAngle"), forKey: "rotationAngle")
                    }

                    if d.value(forKey: "yFlipped") != nil {
                        im?.setValue(d.value(forKey: "yFlipped"), forKey: "yFlipped")
                    }

                    if d.value(forKey: "xFlipped") != nil {
                        im?.setValue(d.value(forKey: "xFlipped"), forKey: "xFlipped")
                    }

                    if d.value(forKey: "xOffset") != nil {
                        im?.setValue(d.value(forKey: "xOffset"), forKey: "xOffset")
                    }

                    if d.value(forKey: "yOffset") != nil {
                        im?.setValue(d.value(forKey: "yOffset"), forKey: "yOffset")
                    }

                    let displayStyle = (d.value(forKey: "displayStyle") as? NSNumber)?.int32Value ?? 0
                    let seriesScale = (im?.value(forKeyPath: "series.scale") as? NSNumber)?.floatValue ?? 0
                    let imageViewFrame = v?.imageView()?.frame ?? .zero
                    if displayStyle == 3 {
                        im?.setValue(NSNumber(value: Float(Double(seriesScale) * sqrt(Double(imageViewFrame.size.height * imageViewFrame.size.width)))), forKey: "scale")
                    } else if displayStyle == 2 {
                        im?.setValue(NSNumber(value: Float(Double(seriesScale) * Double(imageViewFrame.size.width))), forKey: "scale")
                    } else {
                        if d.value(forKey: "scale") != nil {
                            im?.setValue(d.value(forKey: "scale"), forKey: "scale")
                        }
                    }
                }
            }

            if UserDefaults.standard.bool(forKey: "AUTOTILING") {
                NSApp.sendAction(#selector(BrowserController.tileWindows(_:)), to: nil, from: self)
            } else {
                AppController.shared()?.checkAllWindowsAreVisible(self, makeKey: true)
            }

            // #ifndef OSIRIX_LIGHT
            let escKey = CGEventSource.keyState(.combinedSessionState, key: 53)

            if escKey { //Open the images, and export them
                if (ViewerController.getDisplayed2DViewers()?.count ?? 0) != 0 {
                    let v = ViewerController.getDisplayed2DViewers()?.object(at: 0) as? ViewerController

                    v?.exportAllImages("Key And ROIs images")

                    v?.window?.close()
                }
            }
            // #endif
        } else {
            HorosAlertPanel.runInformational(title: NSLocalizedString("ROIs Images", comment: ""),
                                             message: NSLocalizedString("No images containing ROIs or Key Images are found in this selection.", comment: ""),
                                             defaultButton: NSLocalizedString("OK", comment: ""),
                                             alternateButton: nil,
                                             otherButton: nil)
        }
    }

    @objc(ROIImages:sameSeries:)
    func roiImages(_ sender: Any!, sameSeries: UnsafeMutablePointer<ObjCBool>!) -> [Any]! {
        let selectedItems = NSMutableArray()

        if ((sender as? NSMenuItem).map { $0.menu === self.horos_oMatrix?.menu } ?? false) || self.window?.firstResponder === self.horos_oMatrix {
            _ = self.files(forDatabaseMatrixSelection: selectedItems)
        } else {
            _ = self.files(forDatabaseOutlineSelection: selectedItems)
        }

        if selectedItems.isEqual(self.horos_lastROIsImagesSelectedFiles) && self.horos_ROIsImagesCache != nil {
            if let sameSeries {
                sameSeries.pointee = ObjCBool(self.horos_ROIsImagesCacheSameSeries)
            }

            return self.horos_ROIsImagesCache
        }

        let roisImagesArray = NSMutableArray()

        if selectedItems.count > 0 {
            for case let image as DicomImage in selectedItems {
                let str = image.series?.study?.roiPath(forImage: image)

                if let exception = objcTry({
                    // An unreadable ROI SR has no data: NSUnarchiver dies on nil, and
                    // no @catch saves the app from that (#778).
                    let data = str != nil ? SRAnnotation.roi(fromDICOM: str) : nil
                    if (RestrictedUnarchiver.unarchiveROIs(with: data)?.count ?? 0) > 0 {
                        roisImagesArray.add(image)
                    }
                }) {
                    _N2LogExceptionImpl(exception, false, "-[BrowserController ROIImages:sameSeries:]")
                }
            }

            let series = (roisImagesArray.lastObject as AnyObject?)?.value(forKey: "series") as AnyObject?

            self.horos_ROIsImagesCacheSameSeries = true
            if let sameSeries {
                sameSeries.pointee = ObjCBool(self.horos_ROIsImagesCacheSameSeries)
            }
            for case let image as DicomImage in roisImagesArray {
                if (image.value(forKey: "series") as AnyObject?) !== series {
                    self.horos_ROIsImagesCacheSameSeries = false
                    if let sameSeries {
                        sameSeries.pointee = ObjCBool(self.horos_ROIsImagesCacheSameSeries)
                    }
                    break
                }
            }
        }

        self.horos_ROIsImagesCache = roisImagesArray as? [Any]

        self.horos_lastROIsImagesSelectedFiles = selectedItems

        return roisImagesArray as? [Any]
    }

    @objc(ROIImages:)
    func roiImages(_ sender: Any!) -> [Any]! {
        return self.roiImages(sender, sameSeries: nil)
    }

    @objc(KeyImages:)
    func keyImages(_ sender: Any!) -> [Any]! {
        let selectedItems = NSMutableArray()

        if ((sender as? NSMenuItem).map { $0.menu === self.horos_oMatrix?.menu } ?? false) || self.window?.firstResponder === self.horos_oMatrix {
            _ = self.files(forDatabaseMatrixSelection: selectedItems)
        } else {
            _ = self.files(forDatabaseOutlineSelection: selectedItems)
        }

        if selectedItems.isEqual(self.horos_lastKeyImagesSelectedFiles) && self.horos_KeyImagesCache != nil {
            return self.horos_KeyImagesCache
        }

        let keyImagesArray = NSMutableArray()

        for case let image as NSManagedObject in selectedItems {
            if ((image.value(forKey: "isKeyImage") as? NSNumber)?.boolValue ?? false) == true {
                keyImagesArray.add(image)
            }
        }

        self.horos_KeyImagesCache = keyImagesArray as? [Any]

        self.horos_lastKeyImagesSelectedFiles = selectedItems

        return keyImagesArray as? [Any]
    }

    @objc(tileWindows:)
    func tileWindows(_ sender: Any!) {
        if delayedTileWindows != 0 {
            delayedTileWindows = 0
            if let appController = AppController.shared() {
                NSObject.cancelPreviousPerformRequests(withTarget: appController, selector: #selector(AppController.tileWindows(_:)), object: nil)
            }
        }

        AppController.shared()?.tileWindows(nil)
    }

    @objc(validateToolbarItem:)
    func validate(_ toolbarItem: NSToolbarItem!) -> Bool {
        // The EXPORTTOOLBARITEM branch (every item enabled), disabled, is left out.

        var containsDistantStudy = false

        if (self.horos_databaseOutline?.selectedRowIndexes.count ?? 0) > 0 {
            var idx = self.horos_databaseOutline?.selectedRowIndexes.first

            while let row = idx {
                let object = self.horos_databaseOutline?.item(atRow: row) as AnyObject?

                if object?.isDistant?() ?? false {
                    containsDistantStudy = true
                    break
                }

                idx = self.horos_databaseOutline?.selectedRowIndexes.integerGreaterThan(row)
            }
        }

        let itemIdentifier = toolbarItem?.itemIdentifier.rawValue
        let action = toolbarItem?.action

        if self.database?.isReadOnly ?? false {
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

        if (self.horos_databaseOutline?.selectedRowIndexes.count ?? 0) < 1 || containsDistantStudy { // No Database Selection
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

        if !(self.database?.isLocal() ?? false) {
            if itemIdentifier == ImportToolbarItemIdentifier { return false }
            if itemIdentifier == TrashToolbarItemIdentifier { return false }
            if itemIdentifier == QueryToolbarItemIdentifier { return false }
        }

        if itemIdentifier == OpenKeyImagesAndROIsToolbarItemIdentifier {
            if containsDistantStudy {
                return false
            }

            return self.horos_ROIsAndKeyImagesButtonAvailable
        }

        if itemIdentifier == ExportROIAndKeyImagesToolbarItemIdentifier {
            if containsDistantStudy {
                return false
            }

            return self.horos_ROIsAndKeyImagesButtonAvailable
        }

        if itemIdentifier == ViewersToolbarItemIdentifier {
            if ViewerController.numberOf2DViewer() >= 1 { return true }
            else { return false }
        }

        if itemIdentifier == WebServerSingleNotification {
            if containsDistantStudy {
                return false
            }

            if UserDefaults.standard.bool(forKey: "httpWebServer") == false || UserDefaults.standard.bool(forKey: "passwordWebServer") == false {
                return false
            }
        }

        if itemIdentifier == AddStudiesToUserItemIdentifier {
            if containsDistantStudy {
                return false
            }

            if UserDefaults.standard.bool(forKey: "httpWebServer") == false || UserDefaults.standard.bool(forKey: "passwordWebServer") == false {
                return false
            }
        }

        return true
    }
}
