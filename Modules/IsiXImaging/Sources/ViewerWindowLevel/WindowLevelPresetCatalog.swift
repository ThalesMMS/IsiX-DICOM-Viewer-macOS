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

/// The user's window level presets (the WLWW3 preference), as the image views
/// use them: to name the window on screen, and to apply one with the hot keys
/// 1 to 9.
public struct WindowLevelPresetCatalog: Sendable, Equatable {

    /// A preset by name; `window` is nil when the stored entry is not a level
    /// and a width, which names no window and applies none.
    public struct Entry: Sendable, Equatable {
        public var name: String
        public var window: Window?

        public init(name: String, window: Window?) {
            self.name = name
            self.window = window
        }
    }

    public struct Window: Sendable, Equatable {
        public var level: Float
        public var width: Float

        public init(level: Float, width: Float) {
            self.level = level
            self.width = width
        }
    }

    /// The presets in the order the preference's dictionary gave them.
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// The name of the window on screen: the first preset, in the dictionary's
    /// order, that has this level and width; then the image's full dynamic and
    /// its default window, when there is an image.
    public func name(matching level: Float, width: Float, fullDynamic: (level: Float, width: Float)?,
                     imageDefault: (level: Float, width: Float)?) -> WindowLevelPreset {
        let presets = entries.compactMap { entry in entry.window.map { (name: entry.name, level: $0.level, width: $0.width) } }
        return WindowLevelPreset.match(level: level, width: width, presets: presets,
                                       fullDynamic: fullDynamic, imageDefault: imageDefault)
    }

    /// The presets in the order of their names, without regard to case, which
    /// is the order the hot keys 1 to 9 count them in. Names that differ only
    /// in case keep the order of their characters.
    public var hotKeyOrder: [Entry] {
        entries.sorted { first, second in
            switch first.name.caseInsensitiveCompare(second.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return first.name < second.name
            }
        }
    }

    /// The preset of hot key `index` (0 for the key 1), nil beyond the presets.
    public func hotKeyPreset(_ index: Int) -> Entry? {
        let ordered = hotKeyOrder
        guard index >= 0, index < ordered.count else { return nil }
        return ordered[index]
    }
}
