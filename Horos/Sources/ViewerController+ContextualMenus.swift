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
import IsiXImaging

// The contextual menus of the 2D viewer's image: the tools, crosshair,
// window level, size, orientation, layout, export and workspace menu of a
// click on the image, the menu of a click on a ROI, their actions (remove the
// ROI, apply a hanging protocol) and the comments menu. The selectors are
// those of the former Objective-C methods. The tools menu is shared by every
// viewer, as the file-scope static of ViewerController.m was, and rebuilt each
// time; the image view gets a copy, which plugins can fill through
// OsirixPopulatedContextualMenuNotification. A message to nil answered nil, 0
// or NO: the optional chains below answer the same.

/// The last contextual menu built, shared by every viewer.
@MainActor fileprivate var viewerContextualMenu: NSMenu? = nil

/// ToolsMenuIconSize, a macro of ViewerController.h that Swift does not import.
private let toolsMenuIconSize = NSMakeSize(28.0, 28.0)

public extension ViewerController {

    /// Drops the shared contextual menu: the next one is built anew, with the
    /// presets menus as they are then.
    internal func dropViewerContextualMenu() {
        viewerContextualMenu = nil
    }

    @available(*, deprecated)
    @objc(contextualDictionaryPath:)
    func contextualDictionaryPath(_ newContextualDictionaryPath: String!) {
    }

    @available(*, deprecated)
    @objc(contextualDictionaryPath)
    func contextualDictionaryPath() -> String! {
        return "default"
    }

    /// Gives the image view the contextual menu of a click on the image,
    /// after plugins have added to it, without the commands that do not apply.
    @objc(computeContextualMenu)
    func computeContextualMenu() {
        NSLog("2D Viewer Contextual Menu - Generate")
        let menu = contextualMenu()?.copy() as? NSMenu
        NotificationCenter.default.post(name: .OsirixPopulatedContextualMenu, object: menu,
                                        userInfo: [NSStringFromClass(ViewerController.self): self])
        // Only the top level is pruned: its submenus are copies of the main menu's
        // and keep their dimmed items, as there.
        if let menu {
            ContextMenuPruning.hideUnavailableItems(in: menu, groups: [], defaultTarget: self)
        }
        horos_imageView?.menu = menu
    }

    /// Gives the image view the contextual menu of a click on `roi`.
    @objc(computeContextualMenuForROI:)
    func computeContextualMenu(for roi: ROI!) {
        NSLog("2D Viewer Contextual Menu - Generate for ROI: %@", roi.map { String(describing: $0) } ?? "(null)")
        let menu = contextualMenu(for: roi)?.copy() as? NSMenu
        var userInfo: [AnyHashable: Any] = [NSStringFromClass(ViewerController.self): self]
        if let roi { userInfo[NSStringFromClass(ROI.self)] = roi }
        NotificationCenter.default.post(name: .OsirixPopulatedContextualMenu, object: menu, userInfo: userInfo)
        horos_imageView?.menu = menu
    }

    /// The menu of a click on `roi`: its name, and unless it is locked, Remove
    /// and the geometry commands of a line or a point.
    @objc(contextualMenuForROI:)
    func contextualMenu(for roi: ROI!) -> NSMenu! {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: String(format: "ROI: %@", (roi?.name ?? "(null)") as NSString), action: nil, keyEquivalent: ""))

        // A message to nil answered NO: no ROI counts as unlocked, as before.
        if !(roi?.locked ?? false) {
            menu.addItem(NSMenuItem.separator())

            var temp = NSMenuItem(title: "Remove", action: #selector(ViewerController.roiContextualMenuActionRemove(_:)), keyEquivalent: "")
            temp.representedObject = roi
            temp.target = self
            menu.addItem(temp)

            if roi?.type == .tMesure && (roi?.points?.count ?? 0) >= 2 {
                temp = NSMenuItem(title: NSLocalizedString("Generate Perpendicular, Parallel and Midpoint", comment: ""),
                                  action: #selector(ViewerController.generateGeometryFromSelectedLine(_:)), keyEquivalent: "")
                temp.representedObject = roi
                temp.target = self
                menu.addItem(temp)
            }
            if roi?.type == .t2DPoint {
                temp = NSMenuItem(title: NSLocalizedString("Measure Between Slices (Projection vs 3D)", comment: ""),
                                  action: #selector(ViewerController.measureBetweenSelectedSlices(_:)), keyEquivalent: "")
                temp.representedObject = roi
                temp.target = self
                menu.addItem(temp)
            }
        }

        return menu
    }

    /// Remove, in the menu of a ROI: takes the ROI off its image.
    @objc(roiContextualMenuActionRemove:)
    func roiContextualMenuActionRemove(_ source: NSMenuItem!) {
        let roi = source?.representedObject as? ROI
        withExtendedLifetime(roi) {
            roi?.curView?.curRoiList?.remove(roi as Any)
            NotificationCenter.default.post(name: .OsirixRemoveROI, object: roi)
        }
    }

    /// A hanging protocol of the contextual menu: closes the viewers, forgets
    /// the series' saved display and the study's saved layout, and opens the
    /// study again with the protocol.
    @objc(applyWindowProtocol:)
    func applyWindowProtocol(_ sender: Any!) {
        AppController.shared()?.closeAllViewers(self)

        let s = currentStudy()
        let imageSeries = s?.imageSeries() as NSArray?

        for key in ["rotationAngle", "scale", "windowLevel", "windowWidth", "xFlipped", "yFlipped", "xOffset", "yOffset", "displayStyle"] {
            imageSeries?.setValue(nil, forKey: key)
        }
        s?.setValue(nil, forKey: "windowsState")

        let hangingProtocol = (sender as AnyObject?)?.representedObject as? NSDictionary
        BrowserController.currentBrowser()?.databaseOpen(currentStudy(), withProtocol: hangingProtocol as? [AnyHashable: Any])
    }

    /// The contextual menu of a click on the image, built anew.
    @objc(contextualMenu)
    func contextualMenu() -> NSMenu! {
        viewerContextualMenu = nil

        /******************* Tools menu ***************************/
        let contextualMenu = NSMenu(title: NSLocalizedString("Tools", comment: ""))
        viewerContextualMenu = contextualMenu

        // ******************* series popup menu *********************

        buildSeriesPopup()
        if let seriesPopup = horos_seriesPopupContextualMenu {
            // The previous menu let it go when it was released; one still held
            // elsewhere gives it up here, as an item belongs to one menu only.
            seriesPopup.menu?.removeItem(seriesPopup)
            contextualMenu.addItem(seriesPopup)
        }
        contextualMenu.addItem(NSMenuItem.separator())

        let submenu = NSMenu(title: NSLocalizedString("ROI", comment: ""))
        let titles = [NSLocalizedString("Contrast", comment: ""), NSLocalizedString("Move", comment: ""), NSLocalizedString("Magnify", comment: ""),
                      NSLocalizedString("Rotate", comment: ""), NSLocalizedString("Scroll", comment: "")]
        var images = ["WLWW", "Move", "Zoom", "Rotate", "Stack", "Length"].makeIterator() // DO NOT LOCALIZE THIS LINE ! -> filenames !

        for subItem in (horos_popupRoi?.itemArray ?? []).dropFirst() { // First item is pop main menu
            let tag = Int(Int32(truncatingIfNeeded: subItem.tag))
            if tag != 0 {
                let item = NSMenuItem(title: subItem.title, action: Selector(("setROITool:")), keyEquivalent: "")
                item.tag = tag
                item.target = self
                item.image?.size = toolsMenuIconSize
                submenu.addItem(item)
            } else {
                submenu.addItem(NSMenuItem.separator())
            }
        }

        for (i, title) in titles.enumerated() {
            let image = images.next()
            let item = NSMenuItem(title: title, action: #selector(ViewerController.setDefaultTool(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.image = image.flatMap { NSImage(named: $0) }
            item.image?.size = toolsMenuIconSize
            contextualMenu.addItem(item)
        }

        var item = NSMenuItem(title: NSLocalizedString("Patient Crosshair", comment: ""), action: #selector(ViewerController.setDefaultTool(_:)), keyEquivalent: "")
        item.tag = Int(ToolMode.tCross.rawValue)
        item.target = self
        contextualMenu.addItem(item)

        item = NSMenuItem(title: NSLocalizedString("ROI", comment: ""), action: nil, keyEquivalent: "")
        item.tag = -1
        item.target = self

        let currentTool = horos_imageView?.currentTool ?? ToolMode(rawValue: 0)!
        item.image = image(forROI: currentTool.rawValue >= ToolMode.tMesure.rawValue ? currentTool : .tMesure)
        item.image?.size = toolsMenuIconSize

        contextualMenu.addItem(item)
        contextualMenu.item(at: contextualMenu.items.count - 1)?.submenu = submenu
        contextualMenu.addItem(NSMenuItem.separator())

        // Clear Patient Crosshair and the two geometry commands only apply to a
        // placed crosshair or a selected line: they are hidden otherwise, in
        // -computeContextualMenu.
        item = NSMenuItem(title: NSLocalizedString("Show Patient Crosshair", comment: ""), action: Selector(("togglePatientCrosshair:")), keyEquivalent: "")
        item.target = self
        contextualMenu.addItem(item)
        item = NSMenuItem(title: NSLocalizedString("Clear Patient Crosshair", comment: ""), action: Selector(("clearPatientCrosshair:")), keyEquivalent: "")
        item.target = self
        contextualMenu.addItem(item)
        contextualMenu.addItem(withTitle: NSLocalizedString("Generate Perpendicular, Parallel and Midpoint", comment: ""),
                               action: #selector(ViewerController.generateGeometryFromSelectedLine(_:)), keyEquivalent: "")
        contextualMenu.addItem(withTitle: NSLocalizedString("Measure Between Slices (Projection vs 3D)", comment: ""),
                               action: #selector(ViewerController.measureBetweenSelectedSlices(_:)), keyEquivalent: "")
        contextualMenu.addItem(NSMenuItem.separator())

        /******************* WW/WL menu items **********************/

        let appController = AppController.shared()
        item = NSMenuItem(title: NSLocalizedString("Window Width & Level", comment: ""), action: nil, keyEquivalent: "")
        item.submenu = appController?.wlwwMenu()?.copy() as? NSMenu
        contextualMenu.addItem(item)

        /************* image and window size ****************/

        let sizeMenu = NSMenu(title: NSLocalizedString("Size", comment: ""))
        sizeMenu.addItem(withTitle: NSLocalizedString("No Rescale Size (100%)", comment: ""), action: #selector(DCMView.actualSize(_:)), keyEquivalent: "")
        sizeMenu.addItem(withTitle: NSLocalizedString("Actual size", comment: ""), action: #selector(DCMView.realSize(_:)), keyEquivalent: "")
        sizeMenu.addItem(withTitle: NSLocalizedString("Scale To Fit", comment: ""), action: #selector(DCMView.scaleToFit(_:)), keyEquivalent: "")
        sizeMenu.addItem(NSMenuItem.separator())

        let resizeMenu = NSMenu(title: "Resize window")
        for (tag, titleMenu) in ["25%", "50%", "100%", "200%", "300%", "iPod Video"].enumerated() {
            item = NSMenuItem(title: titleMenu, action: Selector(("resizeWindow:")), keyEquivalent: "")
            item.tag = tag
            item.target = horos_imageView
            resizeMenu.addItem(item)
        }

        item = NSMenuItem(title: NSLocalizedString("Resize window", comment: ""), action: nil, keyEquivalent: "")
        item.submenu = resizeMenu
        sizeMenu.addItem(item)

        item = NSMenuItem(title: NSLocalizedString("Size", comment: ""), action: nil, keyEquivalent: "")
        item.submenu = sizeMenu
        contextualMenu.addItem(item)

        /********** Orientation submenu ************/

        item = NSMenuItem(title: NSLocalizedString("Orientation", comment: ""), action: nil, keyEquivalent: "")
        item.submenu = appController?.orientationMenu()?.copy() as? NSMenu
        contextualMenu.addItem(item)

        contextualMenu.addItem(withTitle: NSLocalizedString("Mark as Key image", comment: ""), action: Selector(("setKeyImage:")), keyEquivalent: "")
        contextualMenu.addItem(NSMenuItem.separator())

        /********** Tiling and protocols ************/

        let layoutMenu = NSMenu(title: NSLocalizedString("Layout", comment: ""))

        item = NSMenuItem(title: NSLocalizedString("Image Tiling", comment: ""), action: nil, keyEquivalent: "")
        item.submenu = appController?.imageTilingMenu()?.copy() as? NSMenu
        layoutMenu.addItem(item)

        item = NSMenuItem(title: NSLocalizedString("Windows Tiling - Rows", comment: ""), action: nil, keyEquivalent: "")
        item.submenu = appController?.windowsTilingMenuRows?.copy() as? NSMenu
        layoutMenu.addItem(item)

        item = NSMenuItem(title: NSLocalizedString("Windows Tiling - Columns", comment: ""), action: nil, keyEquivalent: "")
        item.submenu = appController?.windowsTilingMenuColumns?.copy() as? NSMenu
        layoutMenu.addItem(item)

        layoutMenu.addItem(NSMenuItem.separator())

        let protocolsMenu = NSMenu(title: NSLocalizedString("Apply Window Protocol", comment: ""))
        let m = modality()
        for case let hangingProtocol as NSDictionary in WindowLayoutManager.hangingProtocols(forModality: m) ?? [] {
            let t = String(format: "%@ - %@", (m ?? "(null)") as NSString, (hangingProtocol.object(forKey: "Study Description") as? NSObject)?.description ?? "(null)")

            item = NSMenuItem(title: t, action: #selector(ViewerController.applyWindowProtocol(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = hangingProtocol
            protocolsMenu.addItem(item)
        }

        item = NSMenuItem(title: NSLocalizedString("Apply Window Protocol", comment: ""), action: nil, keyEquivalent: "")
        item.submenu = protocolsMenu
        layoutMenu.addItem(item)

        item = NSMenuItem(title: NSLocalizedString("Layout", comment: ""), action: nil, keyEquivalent: "")
        item.submenu = layoutMenu
        contextualMenu.addItem(item)

        /*************Export submenu**************/
        item = NSMenuItem(title: NSLocalizedString("Export", comment: ""), action: nil, keyEquivalent: "")
        item.submenu = appController?.exportMenu()?.copy() as? NSMenu
        contextualMenu.addItem(item)

        /*************Workspace submenu**************/
        if let workspaceMenu = appController?.workspaceMenu() {
            let workspace = NSMenu(title: NSLocalizedString("Workspace State", comment: ""))
            workspace.addItem(withTitle: NSLocalizedString("Save Workspace State", comment: ""), action: #selector(ViewerController.saveWindowsState(_:)), keyEquivalent: "")
            workspace.addItem(withTitle: NSLocalizedString("Save Workspace State as DICOM SR", comment: ""), action: #selector(ViewerController.saveWindowsStateAsDICOMSR(_:)), keyEquivalent: "")
            let mi = NSMenuItem(title: NSLocalizedString("Load Workspace State DICOM SR", comment: ""), action: nil, keyEquivalent: "")
            mi.submenu = workspaceMenu.copy() as? NSMenu
            workspace.addItem(mi)

            item = NSMenuItem(title: NSLocalizedString("Workspace State", comment: ""), action: nil, keyEquivalent: "")
            item.submenu = workspace
            contextualMenu.addItem(item)
        }

        // The SEG command is supplied by the separately integrated SEG category.
        if responds(to: Selector(("showSEGSurfaces:"))) {
            let segSurfaces = contextualMenu.addItem(withTitle: NSLocalizedString("SEG Surfaces...", comment: ""),
                                                     action: Selector(("showSEGSurfaces:")), keyEquivalent: "")
            segSurfaces.target = self
        }

        return contextualMenu
    }

    /// An item of the comments menu: "?" opens the comments sheet; any other
    /// writes its composed title (the titles of the menus that hold it and its
    /// own) as the series comment.
    @objc(contextualMenuEvent:)
    func contextualMenuEvent(_ sender: Any!) {
        // Receives a NSMenuItem (each intermediate NSMenu is also a NSMenuItem)
        // The complete title is obtain joining the ITEM title menu title with all its MENU supermenu titles, excepted the last one

        // Window anchored annotations need to be updated
        // Point clicked available in [imageView contextualMenuInWindowPosX] [imageView contextualMenuInWindowPosY]

        let senderItem = sender as AnyObject?
        var enclosing: [String] = []
        var currentMenu = senderItem?.menu as NSMenu?
        while let menu = currentMenu, let superMenu = menu.supermenu {
            enclosing.append(menu.title)
            currentMenu = superMenu
        }
        let composedMenuTitle = ViewerContextualMenus.composedTitle(itemTitle: ViewerSender.string(sender, "title") ?? "", enclosingMenuTitles: enclosing)

        horosLoadViewerPanels()

        if (composedMenuTitle as NSString).isEqual(to: "?") { // creating a content panel
            if let sheet = horos_CommentsWindow {
                window?.beginSheet(sheet, completionHandler: nil)
            }
        } else { // same action as endSetComments, but with composedMenuTitle
            let movieIndex = Int(horos_curMovieIndex)
            let image = Int(horos_imageView?.curImage ?? 0)
            let file = horos_fileList(at: movieIndex)?.object(at: image) as AnyObject?
            file?.setValue(composedMenuTitle, forKeyPath: "series.comment")

            let browser = BrowserController.currentBrowser()
            if browser?.isCurrentDatabaseBonjour ?? false {
                (browser?.database as? RemoteDicomDatabase)?.object(horos_fileList(at: movieIndex)?.object(at: image) as? NSManagedObject,
                                                                    setValue: horos_CommentsEditField?.stringValue, forKey: "series.comment")
            }

            browser?.databaseOutline?.reloadData()

            horos_CommentsField?.title = composedMenuTitle

            buildMatrixPreview(false)
        }
    }
}
