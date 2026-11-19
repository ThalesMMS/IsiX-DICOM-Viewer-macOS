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

/// The curved paths of a curved MPR window: several, each with a name, one of
/// them the path the window shows.
///
/// A window had one path, and its file - the one kept with the series in the
/// 3D states folder, and the one Save Path writes - was the archive of that
/// path. A coronary CT is read along three or four vessels, so the window
/// keeps a path for each, and the file holds them all. A path is kept here as
/// the archive the window makes of it, which this type does not open: it
/// knows the names, which path is shown and how the file is written.
///
/// The file of several paths is a property list that says so. A set of one
/// path under the name a window gives a path by itself is written as the
/// archive alone, the file it always was, which a reader of the former
/// format still opens; and such a file is read as a set of that one path.
public struct CurvedPathSet: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var name: String
        /// The archive of the path, as the window wrote it.
        public var path: Data

        public init(name: String, path: Data) {
            self.name = name
            self.path = path
        }
    }

    public private(set) var entries: [Entry]
    /// The path shown; 0 in a set with none.
    public private(set) var selected: Int

    /// The names offered for a new path, in the order a coronary CT is read:
    /// left main, left anterior descending, left circumflex, right coronary.
    public static let suggestedNames = ["LM", "LAD", "LCx", "RCA"]

    public init() {
        entries = []
        selected = 0
    }

    public init(entries: [Entry], selected: Int) {
        self.entries = entries
        self.selected = entries.indices.contains(selected) ? selected : 0
    }

    public var names: [String] { entries.map(\.name) }
    public var current: Entry? { entries.indices.contains(selected) ? entries[selected] : nil }

    /// `wanted`, or `wanted` with the first number from 2 that no other path
    /// has: a path is chosen by its name. A name of blanks is `fallback`.
    public func uniqueName(_ wanted: String, fallback: String, except index: Int? = nil) -> String {
        let trimmed = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? fallback : trimmed
        let taken = Set(entries.indices.filter { $0 != index }.map { entries[$0].name })
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// The name a new path is offered: the first suggested one no path has,
    /// then `generic` numbered.
    public func nextName(generic: String) -> String {
        Self.suggestedNames.first { !names.contains($0) } ?? uniqueName("\(generic) \(entries.count + 1)", fallback: generic)
    }

    /// Keeps `path` as the path shown: the window's path as it is now.
    public mutating func store(_ path: Data, defaultName: String) {
        if entries.isEmpty {
            entries = [Entry(name: defaultName, path: path)]
            selected = 0
        } else {
            entries[selected].path = path
        }
    }

    /// Adds a path and shows it. Returns its name, made unique.
    @discardableResult
    public mutating func add(name: String, path: Data, fallback: String) -> String {
        let unique = uniqueName(name, fallback: fallback)
        entries.append(Entry(name: unique, path: path))
        selected = entries.count - 1
        return unique
    }

    public mutating func select(_ index: Int) {
        if entries.indices.contains(index) { selected = index }
    }

    public mutating func rename(_ index: Int, to name: String, fallback: String) {
        guard entries.indices.contains(index) else { return }
        entries[index].name = uniqueName(name, fallback: fallback, except: index)
    }

    /// Removes a path; the one shown is then the one before it, or the first.
    public mutating func remove(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
        if index <= selected { selected = max(selected - 1, 0) }
    }

    // MARK: - The file

    private static let marker = "IsiXCurvedPaths"

    /// The file of the set; nil for a set with no path. One path named
    /// `defaultName` is the archive of that path alone.
    public func fileData(defaultName: String) -> Data? {
        guard let first = entries.first else { return nil }
        if entries.count == 1, first.name == defaultName { return first.path }
        let list: [String: Any] = [Self.marker: 1, "selected": selected,
                                   "paths": entries.map { ["name": $0.name, "path": $0.path] as [String: Any] }]
        return try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
    }

    /// The set a file holds: its paths, or the one path of a file of the
    /// former format, which is taken as it is under `defaultName`. Whether
    /// that one opens is for the window to say.
    public init(fileData: Data, defaultName: String) {
        if let list = (try? PropertyListSerialization.propertyList(from: fileData, options: [], format: nil)) as? [String: Any],
           list[Self.marker] != nil, let paths = list["paths"] as? [[String: Any]] {
            let entries = paths.compactMap { item -> Entry? in
                guard let name = item["name"] as? String, let path = item["path"] as? Data else { return nil }
                return Entry(name: name, path: path)
            }
            self.init(entries: entries, selected: list["selected"] as? Int ?? 0)
        } else {
            self.init(entries: [Entry(name: defaultName, path: fileData)], selected: 0)
        }
    }
}
