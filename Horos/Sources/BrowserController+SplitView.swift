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

// The "NSSplitViewDelegate" block of BrowserController is implemented in Swift
// since #831: an extension of BrowserController, which stays Objective-C, with
// the same selectors. The instance variables it reads are reached through
// BrowserController (SwiftIvars), and the file-scope contextual menus of
// BrowserController.m through BrowserController (SwiftStatics): their retain
// setters keep the menus for the life of the application, as the former
// statics did.
//
// An outlet is nil until the nib is loaded: a message to it is an optional
// chain, and what a message to nil returned (nil, NO, 0, a zero rect) is the
// default. [[view subviews] objectAtIndex:i] goes through NSArray, so an index
// out of range raises the same NSRangeException. An @try is
// HorosObjCException.perform. The branches of WITH_BANNER, which is not
// defined, are left out.

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

/// `[[split subviews] objectAtIndex:index]`: nil for a nil split view, an
/// NSRangeException for an index out of range.
fileprivate func objcSubview(_ split: NSSplitView?, _ index: Int) -> NSView? {
    guard let split else { return nil }
    return (split.subviews as NSArray).object(at: index) as? NSView
}

/// `[array addObject:object]`: a nil object raises NSInvalidArgumentException,
/// as it did, instead of being boxed.
fileprivate func objcAdd(_ array: NSMutableArray, _ object: Any?) {
    if let object {
        array.add(object)
    } else {
        _ = array.perform(#selector(NSMutableArray.add(_:)), with: nil)
    }
}

/// MINIMUMSIZEFORCOMPARATIVEDRAWER_HORZ.
fileprivate let MINIMUMSIZEFORCOMPARATIVEDRAWER_HORZ: CGFloat = 50
/// MINIMUMSIZEFORCOMPARATIVEDRAWER.
fileprivate let MINIMUMSIZEFORCOMPARATIVEDRAWER: CGFloat = 192
/// BONJOURPACKETS.
fileprivate let BONJOURPACKETS = 50

extension BrowserController: NSSplitViewDelegate {}

public extension BrowserController {

    // MARK: - NSSplitViewDelegate

    @objc(splitView:resizeSubviewsWithOldSize:)
    func splitView(_ sender: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        //    if( starting)
        //        return;

        if sender === horos_splitAlbums {
            DatabaseBrowserLayout.layoutSidebar(sender)
            return
        }

        if sender === horos_splitDrawer {
            let left = objcSubview(sender, 0)!
            let right = objcSubview(sender, 1)!

            let bounds = sender.bounds
            let divider = sender.dividerThickness
            let availableWidth = max(0, bounds.size.width - divider)
            let hidden = left.isHidden || sender.isSubviewCollapsed(left)
            let width = hidden ? 0 : min(192, availableWidth / 2)
            left.frame = NSMakeRect(0, 0, width, bounds.size.height)
            right.frame = NSMakeRect(width + divider, 0,
                                     max(0, availableWidth - width), bounds.size.height)

            return
        }

        if sender === horos_splitComparative {
            if BrowserController.horizontalHistory() {
                let top = objcSubview(sender, 0)!
                let bottom = objcSubview(sender, 1)!

                let splitFrame = sender.frame
                let dividerThickness = sender.dividerThickness
                let availableHeight = splitFrame.size.height - dividerThickness

                var topFrame = top.frame
                var bottomFrame = bottom.frame

                topFrame.origin.x = 0
                bottomFrame.origin.x = 0

                topFrame.size.height += oldSize.height - splitFrame.size.height
                bottomFrame.size.height -= oldSize.height - splitFrame.size.height

                if objcSubview(horos_splitComparative, 0).map({ horos_splitComparative?.isSubviewCollapsed($0) ?? false }) ?? false || top.isHidden {
                    bottomFrame.size.height = availableHeight
                } else if topFrame.size.height < MINIMUMSIZEFORCOMPARATIVEDRAWER_HORZ || availableHeight - bottomFrame.size.height < MINIMUMSIZEFORCOMPARATIVEDRAWER_HORZ {
                    bottomFrame.size.height = availableHeight - MINIMUMSIZEFORCOMPARATIVEDRAWER_HORZ
                }

                if bottomFrame.size.height > availableHeight {
                    bottomFrame.size.height = availableHeight
                }

                topFrame.size.width = splitFrame.size.width
                topFrame.size.height = availableHeight - bottomFrame.size.height

                bottomFrame.size.width = splitFrame.size.width
                bottomFrame.size.height = availableHeight - topFrame.size.height
                bottomFrame.origin.y = topFrame.origin.y + topFrame.size.height + dividerThickness

                topFrame.size.height = availableHeight - bottomFrame.size.height

                top.frame = topFrame
                bottom.frame = bottomFrame
            } else {
                let left = objcSubview(sender, 0)!
                let right = objcSubview(sender, 1)!

                let splitFrame = sender.frame
                let dividerThickness = sender.dividerThickness
                let availableWidth = splitFrame.size.width - dividerThickness

                var leftFrame = left.frame
                var rightFrame = right.frame

                leftFrame.size.width -= oldSize.width - splitFrame.size.width
                rightFrame.size.width += oldSize.width - splitFrame.size.width

                if objcSubview(horos_splitComparative, 1).map({ horos_splitComparative?.isSubviewCollapsed($0) ?? false }) ?? false || right.isHidden {
                    leftFrame.size.width = availableWidth
                } else if rightFrame.size.width < MINIMUMSIZEFORCOMPARATIVEDRAWER || availableWidth - leftFrame.size.width < MINIMUMSIZEFORCOMPARATIVEDRAWER {
                    leftFrame.size.width = availableWidth - MINIMUMSIZEFORCOMPARATIVEDRAWER
                }

                if leftFrame.size.width > availableWidth {
                    leftFrame.size.width = availableWidth
                }

                rightFrame.size.height = splitFrame.size.height
                rightFrame.origin.x = leftFrame.origin.x + leftFrame.size.width + dividerThickness
                rightFrame.size.width = availableWidth - leftFrame.size.width
                if rightFrame.size.width >= 192 {
                    rightFrame.size.width = 192
                }

                leftFrame.size.height = splitFrame.size.height
                leftFrame.size.width = availableWidth - rightFrame.size.width

                rightFrame.origin.x = leftFrame.origin.x + leftFrame.size.width + dividerThickness
                rightFrame.size.width = availableWidth - leftFrame.size.width

                right.frame = rightFrame
                left.frame = leftFrame
            }
            return
        }

        if sender === horos_splitViewVert {
            if horos_splitViewVertDividerRatio == 0 {
                horos_splitViewVertDividerRatio = objcSubview(sender, 0)!.bounds.size.width / oldSize.width
            }

            var dividerPosition = sender.bounds.size.width * horos_splitViewVertDividerRatio
            let save = horos_splitViewVertDividerRatio
            dividerPosition = self.splitView(sender, constrainSplitPosition: dividerPosition, ofSubviewAt: 0)
            horos_splitViewVertDividerRatio = save

            let splitFrame = sender.frame

            objcSubview(sender, 0)!.frame = NSMakeRect(0, 0, dividerPosition, splitFrame.size.height)
            objcSubview(sender, 1)!.frame = NSMakeRect(dividerPosition + sender.dividerThickness, 0, splitFrame.size.width - dividerPosition - sender.dividerThickness, splitFrame.size.height)

            return
        }

        if sender === horos_bottomSplit {
            self.splitViewDidResizeSubviews(Notification(name: NSSplitView.didResizeSubviewsNotification, object: horos_splitViewVert))
            return
        }

        sender.adjustSubviews()
    }

    @objc(splitViewWillResizeSubviews:)
    func splitViewWillResizeSubviews(_ notification: Notification) {
        //    if( starting)
        //        return;

        let window = self.window // N2OpenGLViewWithSplitsWindow

        if window?.responds(to: NSSelectorFromString("disableUpdatesUntilFlush")) == true {
            _ = window?.perform(NSSelectorFromString("disableUpdatesUntilFlush"))
        }
    }

    @objc(splitViewDidResizeSubviews:)
    func splitViewDidResizeSubviews(_ notification: Notification) {
        //    if( starting)
        //        return;

        if (notification.object as AnyObject?) === horos_splitViewVert {
            let theView = objcSubview(horos_splitViewVert, 0)
            let theRect = theView.flatMap { theView in theView.window?.contentView?.convert(theView.bounds, from: theView) } ?? .zero
            let dividerPosition = theRect.origin.x + theRect.size.width
            let bottomSplit = horos_bottomSplit
            let splitFrame = bottomSplit?.frame ?? .zero
            let bottomDividerThickness = bottomSplit?.dividerThickness ?? 0
            objcSubview(bottomSplit, 0)?.frame = NSMakeRect(0, 0, dividerPosition, splitFrame.size.height)
            objcSubview(bottomSplit, 1)?.frame = NSMakeRect(dividerPosition + bottomDividerThickness, 0, splitFrame.size.width - dividerPosition - bottomDividerThickness, splitFrame.size.height)

            horos_animationSlider?.setFrameSize(NSMakeSize(splitFrame.size.width - dividerPosition - bottomDividerThickness - (horos_animationCheck?.frame.size.width ?? 0) - 10, horos_animationSlider?.frame.size.height ?? 0)) // for some weird reason, we need this..
        }
        // The bannerSplit branch of WITH_BANNER, which is not defined, is left out.
    }

    @objc(splitView:canCollapseSubview:)
    func splitView(_ sender: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        if sender === horos_splitViewVert {
            return false
        }

        if sender === horos_splitAlbums {
            return false
        }

        if sender === horos_splitDrawer && subview === objcSubview(horos_splitDrawer, 1) {
            return false
        }

        if sender === horos_splitComparative {
            if BrowserController.horizontalHistory() {
                if subview === objcSubview(horos_splitComparative, 1) {
                    return false
                }
            } else {
                if subview === objcSubview(horos_splitComparative, 0) {
                    return false
                }
            }
        }
        if sender === horos_bottomSplit {
            return false
        }

        return true
    }

    @objc(comparativeToggle:)
    func comparativeToggle(_ sender: Any!) {
        let splitComparative = horos_splitComparative
        if BrowserController.horizontalHistory() {
            let top = objcSubview(splitComparative, 0)
            let shouldExpand = (top?.isHidden ?? false) || (objcSubview(splitComparative, 0).map { splitComparative?.isSubviewCollapsed($0) ?? false } ?? false)

            top?.isHidden = !shouldExpand
        } else {
            let right = objcSubview(splitComparative, 1)
            let shouldExpand = (right?.isHidden ?? false) || (objcSubview(splitComparative, 1).map { splitComparative?.isSubviewCollapsed($0) ?? false } ?? false)

            right?.isHidden = !shouldExpand
        }

        if let splitComparative {
            splitComparative.resizeSubviews(withOldSize: splitComparative.bounds.size)
        }
    }

    @objc(drawerToggle:)
    func drawerToggle(_ sender: Any!) {
        let splitDrawer = horos_splitDrawer
        let left = splitDrawer?.subviews.first
        let leftWidth = left?.frame.size.width ?? 0
        let shouldExpand = (left?.isHidden ?? false) || !leftWidth.isFinite
            || leftWidth <= 0 || (left.map { splitDrawer?.isSubviewCollapsed($0) ?? false } ?? false)
        left?.isHidden = !shouldExpand
        if shouldExpand {
            // A collapsed zero-width pane must have a size before the resize delegate runs.
            if let left {
                var frame = left.frame
                frame.size.width = min(192, max(0, (splitDrawer?.bounds.size.width ?? 0) - (splitDrawer?.dividerThickness ?? 0)) / 2)
                left.frame = frame
            }
        }
        if let splitDrawer {
            splitDrawer.resizeSubviews(withOldSize: splitDrawer.bounds.size)
        }
    }

    @objc(splitView:constrainMinCoordinate:ofSubviewAt:)
    func splitView(_ sender: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt offset: Int) -> CGFloat {
        if sender === horos_splitViewHorz {
            return horos_oMatrix?.cellSize.height ?? 0
        }

        if sender === horos_splitViewVert {
            return horos_oMatrix?.cellSize.width ?? 0
        }

        if sender === horos_splitDrawer {
            return MINIMUMSIZEFORCOMPARATIVEDRAWER
        }

        if sender === horos_splitAlbums {
            return NSMinY(objcSubview(sender, offset)!.frame)
                + DatabaseBrowserLayout.minimumPaneHeight(in: sender, at: offset)
        }

        if sender === horos_splitComparative {
            if BrowserController.horizontalHistory() {
                return MINIMUMSIZEFORCOMPARATIVEDRAWER_HORZ
            } else {
                return sender.bounds.size.width - 192
            }
        }

        if sender.isEqual(horos_bannerSplit) {
            return sender.frame.size.height - ((horos_banner?.image?.size.height ?? 0) + 3)
        }

        return proposedMin
    }

    @objc(splitView:constrainMaxCoordinate:ofSubviewAt:)
    func splitView(_ sender: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt offset: Int) -> CGFloat {
        if sender === horos_splitViewVert {
            return sender.bounds.size.width - 200
        }

        if sender === horos_splitViewHorz {
            return sender.bounds.size.height - (2 * (horos_oMatrix?.cellSize.height ?? 0))
        }

        if sender === horos_splitDrawer {
            return 192
        }

        if sender === horos_splitComparative {
            if BrowserController.horizontalHistory() {
                return sender.bounds.size.height - 150
            } else {
                return sender.bounds.size.width - MINIMUMSIZEFORCOMPARATIVEDRAWER
            }
        }

        if sender === horos_bannerSplit {
            return sender.frame.size.height - ((horos_banner?.image?.size.height ?? 0) + 3)
        }

        if sender === horos_splitAlbums {
            return NSMaxY(objcSubview(sender, offset + 1)!.frame) - sender.dividerThickness
                - DatabaseBrowserLayout.minimumPaneHeight(in: sender, at: offset + 1)
        }

        return proposedMax
    }

    @objc(firstObjectForDatabaseMatrixSelection)
    func firstObjectForDatabaseMatrixSelection() -> DicomImage! {
        let cells = horos_oMatrix?.selectedCells
        let aFile = horos_databaseOutline.flatMap { $0.item(atRow: $0.selectedRow) }

        if let cells, aFile != nil {
            for cell in cells {
                if cell.isEnabled == true {
                    let curObj = (horos_matrixViewArray as NSArray?)?.object(at: cell.tag) as? NSManagedObject

                    if (curObj?.value(forKey: "type") as? NSString)?.isEqual(to: "Image") == true {
                        return curObj as? DicomImage
                    }

                    if (curObj?.value(forKey: "type") as? NSString)?.isEqual(to: "Series") == true {
                        return (curObj?.value(forKey: "images") as? NSSet)?.anyObject() as? DicomImage
                    }
                }
            }
        }
        return nil
    }

    @objc(filesForDatabaseMatrixSelection:onlyImages:)
    func files(forDatabaseMatrixSelection correspondingManagedObjects: NSMutableArray!, onlyImages: Bool) -> NSMutableArray! {
        let selectedFiles = NSMutableArray()
        let cells = horos_oMatrix?.selectedCells
        let aFile = horos_databaseOutline.flatMap { $0.item(atRow: $0.selectedRow) }

        let correspondingManagedObjects: NSMutableArray = correspondingManagedObjects ?? NSMutableArray()

        let context = self.database?.managedObjectContext

        context?.lock()

        if let e = objcTry({
            if let cells, aFile != nil {
                for cell in cells {
                    autoreleasepool {
                        if cell.isEnabled == true {
                            let curObj = (self.horos_matrixViewArray as NSArray?)?.object(at: cell.tag) as? NSManagedObject

                            if (curObj?.value(forKey: "type") as? NSString)?.isEqual(to: "Image") == true {
                                objcAdd(correspondingManagedObjects, curObj)
                            }

                            if (curObj?.value(forKey: "type") as? NSString)?.isEqual(to: "Series") == true {
                                correspondingManagedObjects.addObjects(from: self.imagesArray(curObj, onlyImages: onlyImages) ?? [])
                            }
                        }
                    }
                }
            }

            correspondingManagedObjects.removeDuplicatedObjects()

            if !(self.database?.isLocal() ?? false) {
                let splash = Wait(string: NSLocalizedString("Downloading files...", comment: ""))
                splash?.showWindow(self)
                splash?.setCancel(true)

                splash?.progress()?.maxValue = Double(correspondingManagedObjects.count)

                for img in correspondingManagedObjects {
                    autoreleasepool {
                        if (splash?.aborted() ?? false) == false {
                            objcAdd(selectedFiles, self.getLocalDCMPath(img as? NSManagedObject, BONJOURPACKETS))

                            splash?.increment(by: 1)
                        }
                    }
                }

                if splash?.aborted() == true {
                    selectedFiles.removeAllObjects()
                    correspondingManagedObjects.removeAllObjects()
                }

                splash?.close()
            } else {
                selectedFiles.addObjects(from: (correspondingManagedObjects.value(forKey: "completePath") as? [Any]) ?? [])
            }

            if correspondingManagedObjects.count != selectedFiles.count {
                NSLog("****** WARNING [correspondingManagedObjects count] != [selectedFiles count]")
            }
        }) {
            _N2LogExceptionImpl(e, true, "-[BrowserController filesForDatabaseMatrixSelection:onlyImages:]")
        }

        context?.unlock()

        return selectedFiles
    }

    @objc(filesForDatabaseMatrixSelection:)
    func files(forDatabaseMatrixSelection correspondingManagedObjects: NSMutableArray!) -> NSMutableArray! {
        return self.files(forDatabaseMatrixSelection: correspondingManagedObjects, onlyImages: true)
    }

    @objc(saveAlbums:)
    func saveAlbums(_ sender: Any!) {
        let sPanel = NSSavePanel()
        sPanel.allowedFileTypes = ["albums"]
        sPanel.nameFieldStringValue = NSLocalizedString("DatabaseAlbums.albums", comment: "")

        sPanel.begin { result in
            if result != .OK {
                return
            }

            self.database?.saveAlbums(toPath: sPanel.url?.path)
        }
    }

    @objc(addAlbumsFile:)
    func addAlbumsFile(_ file: String!) {
        self.database?.loadAlbums(fromPath: file)

        self.refreshAlbums()

        _ = self.outlineViewRefresh()
    }

    @objc(addAlbums:)
    func addAlbums(_ sender: Any!) {
        let oPanel = NSOpenPanel()
        oPanel.allowedFileTypes = ["albums"]

        oPanel.begin { result in
            if result != .OK {
                return
            }

            self.addAlbumsFile(oPanel.url?.path)
        }
    }

    @objc(initContextualMenus)
    func initContextualMenus() { // MATRIX contextual menu
        // The two menus are statics of the class, and every call added their
        // items once more: they are built by the first call only, and a later
        // one hands them out again.
        if BrowserController.horos_contextualMenu == nil {
            buildContextualMenus()
        }
        horos_oMatrix?.menu = BrowserController.horos_contextualMenu

        // init albums contextual menu

        let acm = NSMenu(title: "")
        acm.delegate = self
        horos_albumTable?.menu = acm
    }

    /// The matrix's contextual menu and its copy for the RT objects.
    private func buildContextualMenus() {
        var item: NSMenuItem

        // ****************

        let contextual: NSMenu? = NSMenu(title: NSLocalizedString("Tools", comment: ""))
        BrowserController.horos_contextualMenu = contextual

        contextual?.addItem(withTitle: NSLocalizedString("Open Images", comment: ""), action: #selector(BrowserController.viewerDICOM(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Open Images in 4D", comment: ""), action: #selector(BrowserController.movieViewerDICOM(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Open Sub-Selection", comment: ""), action: #selector(BrowserController.viewerSubSeriesDICOM(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Open Reparsed series", comment: ""), action: #selector(BrowserController.viewerReparsedSeries(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Open Key Images", comment: ""), action: #selector(BrowserController.viewerDICOMKeyImages(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Open ROIs Images", comment: ""), action: #selector(BrowserController.viewerDICOMROIsImages(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Open ROIs and Key Images", comment: ""), action: #selector(BrowserController.viewerKeyImagesAndROIsImages(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Open Merged Selection", comment: ""), action: #selector(BrowserController.viewerDICOMMergeSelection(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Reveal In Finder", comment: ""), action: #selector(BrowserController.revealInFinder(_:)), keyEquivalent: "")
        contextual?.addItem(NSMenuItem.separator())

        contextual?.addItem(withTitle: NSLocalizedString("Export to DICOM Network Node", comment: "") + "\u{2026}", action: #selector(BrowserController.export2PACS(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Export to Movie", comment: "") + "\u{2026}", action: #selector(BrowserController.exportQuicktime(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Export to JPEG", comment: "") + "\u{2026}", action: #selector(BrowserController.exportJPEG(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Export to TIFF", comment: "") + "\u{2026}", action: #selector(BrowserController.exportTIFF(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Export to DICOM File(s)", comment: "") + "\u{2026}", action: #selector(BrowserController.exportDICOMFile(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Export ROI and Key Images as a DICOM Series", comment: ""), action: #selector(BrowserController.exportROIAndKeyImagesAsDICOMSeries(_:)), keyEquivalent: "")
        contextual?.addItem(NSMenuItem.separator())

        contextual?.addItem(withTitle: NSLocalizedString("Compress DICOM files", comment: ""), action: #selector(BrowserController.compressSelectedFiles(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Decompress DICOM files", comment: ""), action: #selector(BrowserController.decompressSelectedFiles(_:)), keyEquivalent: "")
        contextual?.addItem(NSMenuItem.separator())

        contextual?.addItem(withTitle: NSLocalizedString("Toggle Images/Series Displaying", comment: ""), action: #selector(BrowserController.displayImagesOfSeries(_:)), keyEquivalent: "")
        contextual?.addItem(NSMenuItem.separator())

        contextual?.addItem(withTitle: NSLocalizedString("Merge Selected Series", comment: ""), action: #selector(BrowserController.mergeSeries(_:)), keyEquivalent: "")
        contextual?.addItem(NSMenuItem.separator())

        contextual?.addItem(withTitle: NSLocalizedString("Delete", comment: ""), action: #selector(BrowserController.delItem(_:)), keyEquivalent: "")
        contextual?.addItem(NSMenuItem.separator())

        contextual?.addItem(withTitle: NSLocalizedString("Query Selected Patient from Q&R Window...", comment: ""), action: #selector(BrowserController.querySelectedStudy(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Burn", comment: ""), action: #selector(BrowserController.burnDICOM(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Anonymize", comment: ""), action: #selector(BrowserController.anonymizeDICOM(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Rebuild Selected Thumbnails", comment: ""), action: #selector(BrowserController.rebuildThumbnails(_:)), keyEquivalent: "")
        contextual?.addItem(withTitle: NSLocalizedString("Copy Linked Files to Database Folder", comment: ""), action: #selector(BrowserController.copyToDBFolder(_:)), keyEquivalent: "")

        // Create alternate contextual menu for RT objects

        let contextualRT = contextual?.copy() as? NSMenu
        BrowserController.horos_contextualRTMenu = contextualRT

        item = NSMenuItem(title: NSLocalizedString("Create ROIs from RTSTRUCT", comment: ""), action: #selector(BrowserController.createROIsFromRTSTRUCT(_:)), keyEquivalent: "")
        contextualRT?.insertItem(item, at: 0)

        contextualRT?.insertItem(NSMenuItem.separator(), at: 1)

        // Now remove non-applicable items - usually related to images (most RT objects don't have embedded images)

        var indx = contextualRT?.indexOfItem(withTitle: NSLocalizedString("Open Images in 4D", comment: "")) ?? 0
        if indx >= 0 { contextualRT?.removeItem(at: indx) }
        indx = contextualRT?.indexOfItem(withTitle: NSLocalizedString("Open Key Images", comment: "")) ?? 0
        if indx >= 0 { contextualRT?.removeItem(at: indx) }
        indx = contextualRT?.indexOfItem(withTitle: NSLocalizedString("Open Sub-Selection", comment: "")) ?? 0
        if indx >= 0 { contextualRT?.removeItem(at: indx) }
        // The item's title, whose "series" is lower case, unlike the main menu's.
        indx = contextualRT?.indexOfItem(withTitle: NSLocalizedString("Open Reparsed series", comment: "")) ?? 0
        if indx >= 0 { contextualRT?.removeItem(at: indx) }
        indx = contextualRT?.indexOfItem(withTitle: NSLocalizedString("Open ROIs Images", comment: "")) ?? 0
        if indx >= 0 { contextualRT?.removeItem(at: indx) }
        indx = contextualRT?.indexOfItem(withTitle: NSLocalizedString("Open ROIs and Key Images", comment: "")) ?? 0
        if indx >= 0 { contextualRT?.removeItem(at: indx) }
        indx = contextualRT?.indexOfItem(withTitle: NSLocalizedString("Export to Movie", comment: "") + "\u{2026}") ?? 0
        if indx >= 0 { contextualRT?.removeItem(at: indx) }
        indx = contextualRT?.indexOfItem(withTitle: NSLocalizedString("Export to JPEG", comment: "") + "\u{2026}") ?? 0
        if indx >= 0 { contextualRT?.removeItem(at: indx) }
        indx = contextualRT?.indexOfItem(withTitle: NSLocalizedString("Export to TIFF", comment: "") + "\u{2026}") ?? 0
        if indx >= 0 { contextualRT?.removeItem(at: indx) }
    }

    @objc(annotMenu:)
    func annotMenu(_ sender: Any!) {
        horos_imageView?.annotMenu(sender)
    }
}
