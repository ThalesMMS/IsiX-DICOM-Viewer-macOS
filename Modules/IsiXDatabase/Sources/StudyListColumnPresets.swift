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

/// A named arrangement of the study list's columns: the columns shown, in
/// their order, each with its width. A column is kept by its identifier,
/// never by its title, so a preset saved in one language is the same
/// arrangement in another.
///
/// A preset says nothing of the names being hidden nor of the order of the
/// rows: applying one changes neither.
public struct StudyListColumnPreset: Sendable, Equatable {

    public struct Column: Sendable, Equatable {
        public let identifier: String
        /// The width in points; nil when the preset does not say, and the
        /// column keeps the width it has.
        public let width: Double?

        public init(identifier: String, width: Double?) {
            self.identifier = identifier
            self.width = width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
    }

    /// The column of the patient's name, which the list always shows: a
    /// preset never hides it.
    public static let fixedColumn = "name"

    /// How far, in points, a column may be from the width a preset keeps and
    /// still be at that width: widths are stored and laid out with rounding.
    public static let widthTolerance = 1.0

    public let name: String
    /// The columns shown, from the first to the last.
    public let columns: [Column]

    /// The name as it is kept: without the white space around it; nil when
    /// nothing is left, which names no preset.
    public static func normalizedName(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Nil when the name is empty. A column without an identifier is left
    /// out, and so is one named a second time.
    public init?(name: String, columns: [Column]) {
        guard let name = Self.normalizedName(name) else { return nil }
        self.name = name
        var seen = Set<String>()
        self.columns = columns.filter { !$0.identifier.isEmpty && seen.insert($0.identifier).inserted }
    }

    // MARK: The property list

    static let nameKey = "Name"
    static let columnsKey = "Columns"
    static let identifierKey = "Identifier"
    static let widthKey = "Width"

    public var propertyList: [String: Any] {
        [Self.nameKey: name,
         Self.columnsKey: columns.map { column -> [String: Any] in
             var entry: [String: Any] = [Self.identifierKey: column.identifier]
             if let width = column.width { entry[Self.widthKey] = width }
             return entry
         }]
    }

    /// The preset an entry of the preference keeps; nil when it is not a
    /// table with a name and a list of columns. A column that is not a table
    /// with an identifier is skipped; a width that is not a positive number
    /// is taken as not said.
    public init?(propertyList: Any?) {
        guard let entry = propertyList as? [String: Any], let name = entry[Self.nameKey] as? String,
              let items = entry[Self.columnsKey] as? [Any] else { return nil }
        let columns = items.compactMap { item -> Column? in
            guard let column = item as? [String: Any], let identifier = column[Self.identifierKey] as? String else { return nil }
            return Column(identifier: identifier, width: (column[Self.widthKey] as? NSNumber)?.doubleValue)
        }
        self.init(name: name, columns: columns)
    }

    // MARK: Applying

    /// What applying a preset does to the list's columns.
    public struct Plan: Sendable, Equatable {
        /// The columns to show, each moved to the position it has here and
        /// given its width when it has one.
        public var shown: [Column]
        /// The columns to hide, which stay after those shown.
        public var hidden: [String]
    }

    /// The plan for a list whose columns have the identifiers `tableColumns`.
    /// A column of the preset that the list no longer has is ignored. The
    /// name's column is always shown: first, at the width it has, when the
    /// preset does not place it.
    public func plan(for tableColumns: [String]) -> Plan {
        let existing = Set(tableColumns)
        var shown = columns.filter { existing.contains($0.identifier) }
        if existing.contains(Self.fixedColumn), !shown.contains(where: { $0.identifier == Self.fixedColumn }) {
            shown.insert(Column(identifier: Self.fixedColumn, width: nil), at: 0)
        }
        let placed = Set(shown.map(\.identifier))
        var seen = Set<String>()
        let hidden = tableColumns.filter { !placed.contains($0) && seen.insert($0).inserted }
        return Plan(shown: shown, hidden: hidden)
    }

    /// Whether the list is as the preset arranges it: `arrangement`, the
    /// columns it shows from the first to the last with their widths, are
    /// those of the plan, in its order and at its widths. The width of the
    /// last column does not count: the list stretches it to fill the view.
    public func matches(_ arrangement: [Column], of tableColumns: [String]) -> Bool {
        let shown = plan(for: tableColumns).shown
        guard shown.count == arrangement.count else { return false }
        for (index, (planned, current)) in zip(shown, arrangement).enumerated() {
            if planned.identifier != current.identifier { return false }
            guard index < shown.count - 1, let width = planned.width else { continue }
            guard let currentWidth = current.width, abs(currentWidth - width) <= Self.widthTolerance else { return false }
        }
        return true
    }
}

/// The presets of the study list's columns, in the order they were saved,
/// each under a name of its own.
public struct StudyListColumnPresets: Sendable, Equatable {
    public private(set) var presets: [StudyListColumnPreset]

    /// Of two presets with the same name, the first is kept.
    public init(_ presets: [StudyListColumnPreset] = []) {
        var seen = Set<String>()
        self.presets = presets.filter { seen.insert($0.name).inserted }
    }

    /// The presets the preference keeps. Anything that is not a list is no
    /// preset at all, and an entry that is not a preset is skipped.
    public init(propertyList: Any?) {
        self.init(((propertyList as? [Any]) ?? []).compactMap { StudyListColumnPreset(propertyList: $0) })
    }

    public var propertyList: [[String: Any]] { presets.map(\.propertyList) }

    public var names: [String] { presets.map(\.name) }

    /// The preset saved under `name`, compared without the white space around it.
    public func preset(named name: String) -> StudyListColumnPreset? {
        guard let name = StudyListColumnPreset.normalizedName(name) else { return nil }
        return presets.first { $0.name == name }
    }

    /// The presets with `preset` saved: in the place of the one that has its
    /// name, else after the others.
    public func saving(_ preset: StudyListColumnPreset) -> StudyListColumnPresets {
        var saved = presets
        if let index = saved.firstIndex(where: { $0.name == preset.name }) {
            saved[index] = preset
        } else {
            saved.append(preset)
        }
        return StudyListColumnPresets(saved)
    }

    public func removing(named name: String) -> StudyListColumnPresets {
        guard let removed = preset(named: name) else { return self }
        return StudyListColumnPresets(presets.filter { $0.name != removed.name })
    }

    /// The presets with the one named `name` now named `newName`, in the
    /// same place; another preset that had the new name is replaced by it.
    /// Nil when there is no preset named `name` or the new name is empty.
    public func renaming(_ name: String, to newName: String) -> StudyListColumnPresets? {
        guard let old = preset(named: name), let renamed = StudyListColumnPreset(name: newName, columns: old.columns) else { return nil }
        if renamed.name == old.name { return self }
        return StudyListColumnPresets(presets.compactMap { preset in
            if preset.name == old.name { return renamed }
            return preset.name == renamed.name ? nil : preset
        })
    }
}
