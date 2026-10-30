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

import Foundation

/// The image tiling of a 2D viewer: the tag of each item of the Image Tiling
/// menu and the rows and columns it gives the viewer.
public enum ViewerImageTiling {

    /// The tag of the item for `rows` × `columns`: (rows − 1) × 4 + (columns − 1),
    /// counted in 32 bits as the menu validation counted it.
    public static func tag(rows: Int, columns: Int) -> Int {
        let rows = Int32(truncatingIfNeeded: rows), columns = Int32(truncatingIfNeeded: columns)
        return Int((rows &- 1) &* 4 &+ (columns &- 1))
    }

    /// The rows and columns of an item's tag: below 16, rows = tag / 4 + 1 and
    /// columns = tag % 4 + 1 (divisions that round toward zero); 1 × 1 for any
    /// other tag.
    public static func layout(tag: Int) -> (rows: Int32, columns: Int32) {
        let tag = Int32(truncatingIfNeeded: tag)
        guard tag < 16 else { return (1, 1) }
        return (tag / 4 + 1, tag % 4 + 1)
    }

    /// Rows and columns kept between 1 and 8.
    public static func clamped(rows: Int32, columns: Int32) -> (rows: Int32, columns: Int32) {
        (min(max(rows, 1), 8), min(max(columns, 1), 8))
    }
}

/// The presets menus of a 2D viewer (window level and width, convolution
/// filters, opacity tables): the order of the presets and which item is the
/// current one.
public enum ViewerPresetMenus {

    /// The names of the presets in menu order: the keys of the presets
    /// dictionary sorted with caseInsensitiveCompare: (names that differ only by
    /// case keep the order the dictionary gave them).
    public static func sortedNames(_ keys: [Any]) -> [String] {
        let sorted = NSArray(array: keys).sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:)))
        return sorted.compactMap { $0 as? String }
    }

    /// The title of the window level preset at `index` (from 0) in its menu:
    /// "1 - name", numbered from 1.
    public static func wlwwPresetTitle(index: Int, name: String) -> String {
        String(format: "%d - %@", Int32(truncatingIfNeeded: index + 1), name as NSString)
    }

    /// Whether the item of a window level menu is checked for the current
    /// preset: its title, or its title without the four characters of its
    /// number ("1 - "), is the current preset. Nothing is checked without a
    /// current preset. The titles are compared character by character, as
    /// NSString compares them.
    public static func checksWLWWItem(title: String, current: String?) -> Bool {
        guard let current else { return false }
        let title = title as NSString
        if title.length >= 4 && (title.substring(from: 4) as NSString).isEqual(to: current) {
            return true
        }
        return title.isEqual(to: current)
    }
}

/// The contextual menus of a 2D viewer.
public enum ViewerContextualMenus {

    /// The comment an item of the comments contextual menu writes: the titles
    /// of the menus that contain it, from the outermost one below the menu
    /// itself, then its own title, separated by spaces. `enclosingMenuTitles`
    /// lists the titles from the item's menu outward, without the outermost
    /// menu.
    public static func composedTitle(itemTitle: String, enclosingMenuTitles: [String]) -> String {
        var composed = itemTitle
        for title in enclosingMenuTitles {
            composed = String(format: "%@ %@", title as NSString, composed as NSString)
        }
        return composed
    }
}

/// The icon of the Report toolbar item, after the reports application chosen
/// in the preferences (REPORTSMODE).
public enum ViewerReportIcon {

    /// The image name for the REPORTSMODE preference, read as NSString reads an
    /// integer (no preference is 0): Word, TextEdit (RTF), Pages or the generic
    /// report.
    public static func name(reportsMode: String?) -> String {
        switch (reportsMode as NSString?)?.intValue ?? 0 {
        case 0: return "ReportWord.icns"
        case 1: return "ReportRTF.icns"
        case 2: return "ReportPages.icns"
        default: return "Report.icns"
        }
    }
}
