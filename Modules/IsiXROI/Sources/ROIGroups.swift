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

// The groups of the ROIs of one image and their order in its list: a ROI
// brought to the front is drawn last and found first by a click, and a group
// moves as one, keeping its own order. The app hands the ROIs of the list and
// stores the order given back in the same list.

/// The groups of the 2D viewer's ROIs and their order in an image's list.
public enum ROIGroups: Sendable {
    /// The group of a ROI that belongs to none.
    public static let ungrouped: Double = 0

    /// The group the selected ROIs join: a new one, named after the moment
    /// `now` (seconds since the reference date), or none to ungroup them.
    public static func groupID(grouping: Bool, now: Double) -> Double {
        grouping ? now : ungrouped
    }

    /// The indexes of the members of `group` among the groups of a list; none
    /// for the ROIs of no group.
    public static func members(of group: Double, in groups: [Double]) -> [Int] {
        group == ungrouped ? [] : groups.indices.filter { groups[$0] == group }
    }

    /// The list with `target` in front: alone, taken out of every place it
    /// had, or with its whole group, the members in the order they had.
    public static func broughtToFront<Item>(_ items: [Item], _ target: Item, group: (Item) -> Double,
                                            same: (Item, Item) -> Bool) -> [Item] {
        let moved = moving(items, target, group: group, same: same)
        return moved.front + moved.rest
    }

    /// The list with `target` at the back: alone, taken out of every place it
    /// had, or with its whole group, the members in the order they had.
    public static func sentToBack<Item>(_ items: [Item], _ target: Item, group: (Item) -> Double,
                                        same: (Item, Item) -> Bool) -> [Item] {
        let moved = moving(items, target, group: group, same: same)
        return moved.rest + moved.front
    }

    /// What moves (the target, or the members of its group once each, in
    /// their order) and what stays, in its order.
    private static func moving<Item>(_ items: [Item], _ target: Item, group: (Item) -> Double,
                                     same: (Item, Item) -> Bool) -> (front: [Item], rest: [Item]) {
        let id = group(target)
        var front: [Item] = []
        if id == ungrouped {
            front = [target]
        } else {
            for item in items where group(item) == id && !front.contains(where: { same($0, item) }) {
                front.append(item)
            }
        }
        let rest = items.filter { item in !front.contains { same($0, item) } }
        return (front, rest)
    }
}
