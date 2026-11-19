//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// One thing done to a column of the study list while its columns are
/// arranged. The steps of an arrangement are done in the order they are given.
public enum StudyListColumnStep: Sendable, Equatable {
    case hide(String)
    case show(String)
    /// The column goes to this position among the list's columns, the hidden
    /// ones counted.
    case move(String, to: Int)
    /// The column gets this width, in points, which the column itself keeps
    /// within its minimum and its maximum.
    case width(String, Double)

    public var isWidth: Bool {
        if case .width = self { return true }
        return false
    }
}

/// The steps that arrange the columns of the study list: when the columns
/// saved at the last closing come back, when a column is shown or hidden from
/// the header's menu, and when a preset or the layout of an album is applied.
///
/// The rule they all follow: which columns there are comes first, and the
/// widths last. The list shares width among the columns that resize with it
/// whenever a column is shown or hidden: showing one takes its width from
/// them, down to their minimum, and hiding one gives its width to them. A
/// width given before the last column is shown or hidden is therefore not the
/// one the column ends with, and in a list wider than its view every column
/// that resizes with it would end at its minimum. So the widths are the last
/// steps, and nothing is fitted to the view after them: fitting the last
/// column takes a column that resizes with the list back to its minimum when
/// the list is wider than the view.
///
/// Showing or hiding one column changes no other width: the columns that stay
/// are given back the widths they had. A list narrower than its view is then
/// left with room after its last column, and one that outgrows it scrolls.
public enum StudyListColumnSteps {

    /// A column of the list as it is before the steps.
    public struct Column: Sendable, Equatable {
        public let identifier: String
        public let width: Double
        public let isHidden: Bool

        public init(identifier: String, width: Double, isHidden: Bool) {
            self.identifier = identifier
            self.width = width
            self.isHidden = isHidden
        }
    }

    static let identifierKey = "Identifier"
    static let widthKey = "Width"

    /// The steps that put back the columns saved when the window closed:
    /// `savedState` is the list of the columns that were shown, each a table
    /// with its identifier and its width, and `tableColumns` the identifiers
    /// of the list's columns.
    ///
    /// Every column the state does not name is hidden, but the name's, which
    /// is always shown; those it names are shown; then each gets its saved
    /// width, the name's included. An entry that is not a table, or that names
    /// a column the list does not have, is skipped. A width that is missing
    /// counts as zero, which leaves the column at its minimum. A state that is
    /// not a list names no column.
    public static func restoring(savedState: Any?, tableColumns: [String]) -> [StudyListColumnStep] {
        let existing = Set(tableColumns)
        var saved: [(identifier: String, width: Double)] = []
        for case let entry as [AnyHashable: Any] in (savedState as? [Any]) ?? [] {
            guard let identifier = entry[identifierKey] as? String, existing.contains(identifier) else { continue }
            saved.append((identifier, width(entry[widthKey])))
        }

        let named = Set(saved.map(\.identifier))
        var steps: [StudyListColumnStep] = []
        var seen = Set<String>()
        for identifier in tableColumns
        where identifier != StudyListColumnPreset.fixedColumn && !named.contains(identifier) && seen.insert(identifier).inserted {
            steps.append(.hide(identifier))
        }
        seen.removeAll()
        for column in saved where column.identifier != StudyListColumnPreset.fixedColumn && seen.insert(column.identifier).inserted {
            steps.append(.show(column.identifier))
        }
        steps += saved.map { .width($0.identifier, $0.width) }
        return steps
    }

    /// The steps that show or hide one column from the header's menu, leaving
    /// every other column at the width it has. `columns` are the list's
    /// columns as they are, hidden ones included.
    ///
    /// None for the name's column, which is not hidden, for a column the list
    /// does not have and for one that is already as asked. A column shown goes
    /// to the second place, after the name's, at the width it had when hidden.
    public static func toggling(_ identifier: String, visible: Bool, columns: [Column]) -> [StudyListColumnStep] {
        guard identifier != StudyListColumnPreset.fixedColumn,
              let column = columns.first(where: { $0.identifier == identifier }), column.isHidden == visible else { return [] }
        var steps: [StudyListColumnStep] = visible ? [.show(identifier), .move(identifier, to: 1)] : [.hide(identifier)]
        for other in columns where (other.identifier == identifier ? visible : !other.isHidden) {
            steps.append(.width(other.identifier, other.width))
        }
        return steps
    }

    /// The steps that put the list as an arrangement says: the columns of
    /// `hidden` hidden, those of `shown` shown and moved to the place they have
    /// there, then each given its width when it has one.
    public static func arranging(shown: [(identifier: String, width: Double?)], hidden: [String]) -> [StudyListColumnStep] {
        var steps: [StudyListColumnStep] = hidden.map { .hide($0) }
        for (position, column) in shown.enumerated() {
            steps.append(.show(column.identifier))
            steps.append(.move(column.identifier, to: position))
        }
        for column in shown {
            if let width = column.width {
                steps.append(.width(column.identifier, width))
            }
        }
        return steps
    }

    /// A saved width as a number: zero when it is neither a number nor text.
    private static func width(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return Double(number.floatValue) }
        if let text = value as? NSString { return Double(text.floatValue) }
        return 0
    }
}

extension StudyListColumnPreset.Plan {
    /// The steps that apply the plan to the list.
    public var steps: [StudyListColumnStep] {
        StudyListColumnSteps.arranging(shown: shown.map { ($0.identifier, $0.width) }, hidden: hidden)
    }
}

extension AlbumColumnLayout {
    /// The steps that show the list with the columns of the layout, for a
    /// list whose columns have the identifiers `tableColumns`.
    public func steps(for tableColumns: [String]) -> [StudyListColumnStep] {
        let placement = placement(of: tableColumns)
        return StudyListColumnSteps.arranging(shown: placement.shown.map { ($0.identifier, Double($0.width)) }, hidden: placement.hidden)
    }
}
