//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The viewer's series list can dock on any edge. The choice is one
/// preference, applied live to every open viewer and kept across relaunches;
/// the list itself, its cells, its selection and its accessibility are the
/// host's own — this only decides which edge it sits on.
///
/// The ViewerController (HorosSeriesListPlacement) category, in Swift: the
/// selectors and <Horos/SeriesListPlacementMenu.h> are those of the former
/// category.
extension ViewerController {

    /// The former +horosFindSeriesListItemIn:owner:, which nothing outside this
    /// category sent.
    private class func horosFindSeriesListItem(in menu: NSMenu?, owner: inout NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if (item.title as NSString).isEqual(to: NSLocalizedString("Series List", comment: "")) || (item.title as NSString).isEqual(to: "Series List") {
                owner = menu
                return item
            }
            if let submenu = item.submenu {
                if let found = self.horosFindSeriesListItem(in: submenu, owner: &owner) { return found }
            }
        }
        return nil
    }

    /// Adds "Series List Placement" to the 2D Viewer menu, under "Series List".
    @objc public class func installSeriesListPlacementMenuItems() {
        var owner: NSMenu? = nil
        let anchor = self.horosFindSeriesListItem(in: NSApp.mainMenu, owner: &owner)
        guard let anchor = anchor, let owner = owner else { NSLog("Series list: 'Series List' menu item not found; placement submenu not installed"); return }
        if owner.indexOfItem(withTitle: NSLocalizedString("Series List Placement", comment: "")) != -1 { return }

        let submenu = NSMenu(title: NSLocalizedString("Series List Placement", comment: ""))
        let titles = [NSLocalizedString("Left", comment: ""), NSLocalizedString("Right", comment: ""),
                      NSLocalizedString("Top", comment: ""), NSLocalizedString("Bottom", comment: "")]
        for index in 0..<titles.count {
            let item = NSMenuItem(title: titles[index],
                                  action: #selector(setSeriesListPlacement(_:)), keyEquivalent: "")
            item.tag = index
            item.target = nil // first responder: the front 2D viewer
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: NSLocalizedString("Series List Placement", comment: ""),
                              action: nil, keyEquivalent: "")
        item.submenu = submenu
        owner.insertItem(item, at: owner.index(of: anchor) + 1)
    }

    /// Menu action: the item's tag is a HorosSeriesListPlacement.
    @IBAction @objc(setSeriesListPlacement:)
    public func setSeriesListPlacement(_ sender: Any?) {
        // The items' tags are the four placements; any other tag counts as left.
        let placement = SeriesListPlacement(rawValue: (sender as AnyObject?)?.tag ?? 0) ?? .left
        SeriesListLayout.store(placement, in: UserDefaults.standard)
        // Each viewer re-places its list in its own dock, and finds that dock
        // from where the list is. A list lent to a floating panel is in neither
        // pane: the panel would be left showing nothing, and with the dock on
        // the right or at the bottom the image pane would be taken for the dock
        // and hidden. Return the lent lists first, then lend each screen's front
        // list again.
        var lent: [(panel: ThumbnailsListPanel, viewer: ViewerController?, screen: NSScreen)] = []
        for screen in NSScreen.screens {
            guard let panel = AppController.thumbnailsListPanel(for: screen), panel.thumbnailsView != nil else { continue }
            lent.append((panel, panel.viewer, screen))
            panel.returnBorrowedList()
        }
        NotificationCenter.default.post(name: NSNotification.Name(SeriesListLayout.placementDidChangeNotification), object: nil)
        for (panel, viewer, screen) in lent {
            // Only the front viewer of a screen lends its list to that screen's panel.
            guard let lender = ViewerController.frontMostDisplayed2DViewer(for: screen) ?? viewer else { continue }
            panel.setThumbnailsView(lender.previewMatrixScrollView(), viewer: lender)
        }
    }
}
