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

import Foundation

/// What the ROI Manager lists: the ROIs of the slice on screen or of the whole
/// series, filtered, and grouped by name.
///
/// ROIs that share a name are one object across slices, as the viewer's
/// volume and rename treat them; "Unnamed" ROIs were never grouped by the user
/// and each stays a row of its own. Identity is the ROI object, never its name:
/// deleting or renaming a row touches that ROI only.
public enum ROIManagerScope: Int {
    case slice = 0
    case series = 1
}

public struct ROIManagerFilter: Equatable {
    public var text = ""
    public var selectedOnly = false
    public var visibleOnly = false
    public var lockedOnly = false

    public init() {}
}

/// One ROI and the slice it is on.
public final class ROIManagerRow: NSObject {
    public let roi: AnyObject
    public let slice: Int

    init(roi: AnyObject, slice: Int) {
        self.roi = roi
        self.slice = slice
    }
}

/// ROIs of one name on two or more rows.
public final class ROIManagerGroup: NSObject {
    public let name: String
    public private(set) var rows: [ROIManagerRow]

    init(name: String, rows: [ROIManagerRow]) {
        self.name = name
        self.rows = rows
    }

    public var firstSlice: Int { rows.map(\.slice).min() ?? 0 }
    public var lastSlice: Int { rows.map(\.slice).max() ?? 0 }
    /// Slices with at least one of its ROIs.
    public var sliceCount: Int { Set(rows.map(\.slice)).count }
}

/// How the model reads an ROI, so that it can be tested without one.
public struct ROIManagerReader {
    public var name: (AnyObject) -> String
    public var hidden: (AnyObject) -> Bool
    public var locked: (AnyObject) -> Bool
    public var selected: (AnyObject) -> Bool
    public var unnamed: (String) -> Bool

    public init(name: @escaping (AnyObject) -> String, hidden: @escaping (AnyObject) -> Bool,
                locked: @escaping (AnyObject) -> Bool, selected: @escaping (AnyObject) -> Bool,
                unnamed: @escaping (String) -> Bool) {
        self.name = name
        self.hidden = hidden
        self.locked = locked
        self.selected = selected
        self.unnamed = unnamed
    }
}

public enum ROIManagerModel {
    /// The top-level items, in the order their ROIs first appear: a
    /// `ROIManagerGroup` for a name on two or more rows, a `ROIManagerRow`
    /// otherwise. `slices` holds the ROIs of each slice.
    public static func items(slices: [[AnyObject]], currentSlice: Int, scope: ROIManagerScope,
                             filter: ROIManagerFilter, groupByName: Bool, reader: ROIManagerReader) -> [AnyObject] {
        let range: [Int]
        switch scope {
        case .slice: range = slices.indices.contains(currentSlice) ? [currentSlice] : []
        case .series: range = Array(slices.indices)
        }
        let text = filter.text.trimmingCharacters(in: .whitespacesAndNewlines)

        var order: [String] = []
        var byName: [String: [ROIManagerRow]] = [:]
        var singles: [(Int, ROIManagerRow)] = []
        var position = 0
        for slice in range {
            for roi in slices[slice] {
                let name = reader.name(roi)
                if !text.isEmpty && name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) == nil { continue }
                if filter.selectedOnly && !reader.selected(roi) { continue }
                if filter.visibleOnly && reader.hidden(roi) { continue }
                if filter.lockedOnly && !reader.locked(roi) { continue }
                let row = ROIManagerRow(roi: roi, slice: slice)
                position += 1
                if !groupByName || reader.unnamed(name) {
                    singles.append((position, row))
                    continue
                }
                if byName[name] == nil {
                    order.append(name)
                    byName[name] = []
                    singles.append((position, ROIManagerRow(roi: NSNull(), slice: -1)))   // the group's place
                }
                byName[name]!.append(row)
            }
        }

        var names = order.makeIterator()
        var items: [AnyObject] = []
        for (_, row) in singles {
            guard row.roi is NSNull else { items.append(row); continue }
            guard let name = names.next(), let rows = byName[name] else { continue }
            items.append(rows.count == 1 ? rows[0] : ROIManagerGroup(name: name, rows: rows))
        }
        return items
    }

    /// Every ROI of these items, groups opened.
    public static func rows(of items: [AnyObject]) -> [ROIManagerRow] {
        items.flatMap { item -> [ROIManagerRow] in
            if let group = item as? ROIManagerGroup { return group.rows }
            if let row = item as? ROIManagerRow { return [row] }
            return []
        }
    }

    /// A check for several ROIs: on, off, or mixed (-1, NSControl.StateValue.mixed).
    public static func state(of values: [Bool]) -> Int {
        if values.isEmpty { return 0 }
        if values.allSatisfy({ $0 }) { return 1 }
        if values.allSatisfy({ !$0 }) { return 0 }
        return -1
    }

    // MARK: CSV

    public static let csvHeader = ["Name", "Slice", "Area (cm²)", "Mean", "SDev", "Min", "Max", "Sum", "Visible", "Locked", "Comments"]

    /// One ROI of the CSV file; the slice is counted from 1, as on screen.
    public static func csvRecord(name: String, slice: Int, areaCm2: Double, statistics: ROIManagerStatistics,
                                 hidden: Bool, locked: Bool, comments: String) -> [String] {
        [name, "\(slice + 1)", String(format: "%.4f", areaCm2),
         String(format: "%.3f", statistics.mean), String(format: "%.3f", statistics.deviation),
         String(format: "%.3f", statistics.minimum), String(format: "%.3f", statistics.maximum),
         String(format: "%.3f", statistics.total),
         hidden ? "no" : "yes", locked ? "yes" : "no", comments]
    }
}

/// The pixel values of one ROI, as -[DCMPix computeROI:...] gives them.
public struct ROIManagerStatistics {
    public var mean: Float = 0
    public var total: Float = 0
    public var deviation: Float = 0
    public var minimum: Float = 0
    public var maximum: Float = 0

    public init() {}
}

/// One rebuild of the list for a burst of changes, and none while the window
/// is hidden: a reslice or a plugin import changes thousands of ROIs, each
/// with its own notification.
public final class ROIManagerCoalescer {
    /// A rebuild is scheduled and has not run yet.
    public private(set) var pending = false
    /// The list no longer shows the viewer's ROIs.
    public private(set) var dirty = true

    public init() {}

    /// A change: true when the caller is to schedule a rebuild now.
    public func changed(visible: Bool) -> Bool {
        dirty = true
        guard !pending, visible else { return false }
        pending = true
        return true
    }

    /// The scheduled rebuild runs.
    public func fired() {
        pending = false
    }

    /// The list was rebuilt.
    public func rebuilt() {
        dirty = false
    }
}
