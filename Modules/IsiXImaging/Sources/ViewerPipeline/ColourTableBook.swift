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

// The colour tables (CLUT) a 2D viewer applies from its menu, as the "CLUT"
// preference stores them by name: what one stored table gives the viewer, and
// the stored form of a table the CLUT editor made. The app reads and writes the
// preference through its typed key and hands each entry over as the property
// list it is; this module does not read the preferences itself.

/// The stored colour tables of the 2D viewers, entry by entry.
public struct ColourTableBook: Sendable {

    /// What a stored table gives a viewer: the three channels handed to its
    /// views and thick slab, and the black index of every slice, the darkest
    /// entry, drawn where there is no image.
    public struct Entry: Sendable, Equatable {
        public let table: ColorLookupTable
        public let blackIndex: Int32

        public init(table: ColorLookupTable) {
            self.table = table
            blackIndex = Int32(table.darkestIndex)
        }

        /// The entry of a stored table (a dictionary of "Red", "Green" and
        /// "Blue"); nil when it is not one, or one of its channels lacks its
        /// 256 numbers, which the viewer never applied.
        public init?(stored: Any?) {
            guard let preset = stored as? [String: Any], let table = ColorLookupTable(stored: preset) else { return nil }
            self.init(table: table)
        }
    }

    /// Whether a stored table opens in the CLUT editor: only one the editor
    /// made has its points, an empty list included.
    public static func opensInEditor(_ stored: Any?) -> Bool {
        (stored as? [String: Any])?[ColorLookupTable.pointsKey] is [Any]
    }

    /// The editor's points and their colours of a stored table, as stored;
    /// empty when it has none.
    public static func editorContent(of stored: Any?) -> (points: [Any], colours: [Any]) {
        let preset = stored as? [String: Any]
        return (preset?[ColorLookupTable.pointsKey] as? [Any] ?? [], preset?[ColorLookupTable.colorsKey] as? [Any] ?? [])
    }

    /// The stored form of a table the CLUT editor made: its three channels as
    /// numbers, and the editor's points and colours as the editor keeps them.
    public static func storedForm(of table: ColorLookupTable, points: [Any], colours: [Any]) -> [String: Any] {
        [ColorLookupTable.redKey: table.red.map { Int($0) },
         ColorLookupTable.greenKey: table.green.map { Int($0) },
         ColorLookupTable.blueKey: table.blue.map { Int($0) },
         ColorLookupTable.pointsKey: points,
         ColorLookupTable.colorsKey: colours]
    }
}

extension ColorLookupTable {
    /// The table of a stored preset, read as init(preset:) reads one: nil when
    /// one of its three channels is missing, has fewer than 256 entries or one
    /// of its first 256 is not a number; each number is taken as a long and
    /// kept to its low eight bits.
    init?(stored preset: [String: Any]) {
        func channel(_ key: String) -> [UInt8]? {
            guard let values = preset[key] as? [Any], values.count >= 256 else { return nil }
            var channel = [UInt8](repeating: 0, count: 256)
            for i in 0..<256 {
                guard let number = values[i] as? NSNumber else { return nil }
                channel[i] = UInt8(truncatingIfNeeded: number.int64Value)
            }
            return channel
        }
        guard let red = channel(Self.redKey), let green = channel(Self.greenKey), let blue = channel(Self.blueKey) else { return nil }
        self.init(red: red, green: green, blue: blue)
    }
}
