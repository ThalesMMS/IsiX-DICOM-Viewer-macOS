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

import Foundation

/// The order and the columns of the study list for one album, as the
/// database folder's AlbumSortDescriptors.plist keeps them: a dictionary from
/// the album's identifier ("Database" for the whole database) to an array of
/// the archived sort descriptors and the visible columns, each an array of
/// its identifier and its width. The file is read by older versions too, so
/// its keys and values do not change.
public struct AlbumColumnLayout: Sendable, Equatable {

    public struct Column: Sendable, Equatable {
        public let identifier: String
        public let width: Int

        public init(identifier: String, width: Int) {
            self.identifier = identifier
            self.width = width
        }
    }

    /// The key of the whole database's layout.
    public static let databaseKey = "Database"

    /// The keyed archive of the sort descriptors; nil when there are none.
    public var sortDescriptors: Data?
    /// The visible columns in their order; nil when the entry has none.
    public var columns: [Column]?

    public init(sortDescriptors: Data?, columns: [Column]?) {
        self.sortDescriptors = sortDescriptors
        self.columns = columns
    }

    /// The entry of the file. An entry without sort descriptors was written
    /// empty, as the array that ended at its first missing element was.
    public var propertyList: [Any] {
        guard let sortDescriptors else { return [] }
        return [sortDescriptors, (columns ?? []).map { [$0.identifier, $0.width] as [Any] }]
    }

    /// The layout an entry of the file keeps; nil when it is not an array. A
    /// column that is not an identifier and a width is skipped.
    public init?(propertyList: Any?) {
        guard let entry = propertyList as? [Any] else { return nil }
        sortDescriptors = entry.first as? Data
        columns = entry.count > 1 ? (entry[1] as? [Any]).map { items in
            items.compactMap { item -> Column? in
                guard let column = item as? [Any], column.count >= 2, let identifier = column[0] as? String,
                      let width = column[1] as? Int else { return nil }
                return Column(identifier: identifier, width: width)
            }
        } : nil
    }

    /// The file's layouts with `layout` stored under `key`, without those of
    /// albums that are gone: every key but the database's that `living` does
    /// not hold.
    public static func file(_ file: [String: Any], storing layout: AlbumColumnLayout, under key: String,
                            living: Set<String>) -> [String: Any] {
        var kept = file.filter { $0.key == databaseKey || living.contains($0.key) }
        kept[key] = layout.propertyList
        return kept
    }

    /// Where the columns go once the layout is applied: the columns of the
    /// table it names, in its order and at its widths, and every other column
    /// hidden, as an entry without columns hides them all. `tableColumns` are
    /// the identifiers of the table's columns.
    public func placement(of tableColumns: [String]) -> (shown: [Column], hidden: [String]) {
        var shown: [Column] = []
        var unvisited = tableColumns
        for column in columns ?? [] {
            guard let index = unvisited.firstIndex(of: column.identifier) else { continue }
            unvisited.remove(at: index)
            shown.append(column)
        }
        return (shown, unvisited)
    }
}
