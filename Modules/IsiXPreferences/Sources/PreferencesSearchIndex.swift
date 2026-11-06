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

/// The text of the preference panes, in the language in use, by pane. A term
/// matches a label when every one of its words is inside it, whatever the
/// case and the accents.
public struct PreferencesSearchIndex<Pane: Hashable> {
    private struct Entry {
        let pane: Pane
        let title: String
        let labels: [String]
    }

    private var entries: [Entry] = []

    public init() {}

    public var paneCount: Int { entries.count }

    /// Adds a pane, in the order the panes are listed. `labels` is empty for
    /// one known by its title alone, as a plugin's is.
    public mutating func add(pane: Pane, title: String, labels: [String]) {
        entries.append(Entry(pane: pane, title: Self.folded(title), labels: labels.map(Self.folded)))
    }

    /// The panes whose title or labels hold `term`, in the order they were added.
    public func panes(matching term: String) -> [Pane] {
        let words = Self.words(of: term)
        if words.isEmpty { return [] }
        return entries.filter { entry in
            Self.contains(entry.title, words) || entry.labels.contains { Self.contains($0, words) }
        }.map(\.pane)
    }

    /// Whether `label` holds every word of `term`.
    public static func label(_ label: String, matches term: String) -> Bool {
        let words = words(of: term)
        return !words.isEmpty && contains(folded(label), words)
    }

    private static func words(of term: String) -> [String] {
        folded(term).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func contains(_ text: String, _ words: [String]) -> Bool {
        words.allSatisfy { text.contains($0) }
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
