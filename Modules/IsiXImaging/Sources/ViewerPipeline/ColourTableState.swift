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

// The colour tables of a 2D view: whether it draws its image through its three
// tables of 256 entries or as grey levels, and what handing it new tables
// does. The view keeps the tables themselves, whose addresses -getCLUT:::
// hands to plugins and which therefore never move, and the colour buffer it
// drops once it is back to grey levels; this value decides, the view applies.

/// Whether a view draws through its colour tables, and the rule of -setCLUT:::.
public struct ColourTableState: Sendable, Equatable {
    /// True while the tables are anything but the grey levels: the image is
    /// drawn through them (the former colorTransfer).
    public var colorTransfer: Bool

    public init(colorTransfer: Bool = false) {
        self.colorTransfer = colorTransfer
    }

    /// What setting the tables did.
    public enum Change: Sendable, Equatable {
        /// The tables already held what was asked: nothing was written.
        case unchanged
        /// The tables hold colours now: the image is drawn through them.
        case colours
        /// The tables are the grey levels, asked as such or handed in as the
        /// identity: the view drops the colour buffer it kept.
        case greyLevels
    }

    /// The tables of a view, three channels of 256 entries.
    public struct Tables {
        public let red: UnsafeMutablePointer<UInt8>
        public let green: UnsafeMutablePointer<UInt8>
        public let blue: UnsafeMutablePointer<UInt8>

        public init(red: UnsafeMutablePointer<UInt8>, green: UnsafeMutablePointer<UInt8>, blue: UnsafeMutablePointer<UInt8>) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// Three channels of 256 entries handed to the view.
    public struct Request {
        public let red: UnsafePointer<UInt8>
        public let green: UnsafePointer<UInt8>
        public let blue: UnsafePointer<UInt8>

        public init(red: UnsafePointer<UInt8>, green: UnsafePointer<UInt8>, blue: UnsafePointer<UInt8>) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// Writes `request` into `tables`, or the grey levels when it is nil, as
    /// -setCLUT::: did. Nothing is written when the tables already hold the
    /// request, or when grey levels are asked of a view that already draws
    /// grey levels (`holdsColourBuffer` false and no colour transfer). Tables
    /// handed in as the identity are grey levels.
    public mutating func set(_ tables: Tables, to request: Request?, holdsColourBuffer: Bool) -> Change {
        guard let request else {
            if !holdsColourBuffer && !colorTransfer { return .unchanged }
            colorTransfer = false
            for i in 0..<256 {
                let level = UInt8(truncatingIfNeeded: i)
                tables.red[i] = level
                tables.green[i] = level
                tables.blue[i] = level
            }
            return .greyLevels
        }
        if memcmp(tables.red, request.red, 256) == 0 && memcmp(tables.green, request.green, 256) == 0
            && memcmp(tables.blue, request.blue, 256) == 0 {
            return .unchanged
        }
        tables.red.update(from: request.red, count: 256)
        tables.green.update(from: request.green, count: 256)
        tables.blue.update(from: request.blue, count: 256)
        let grey = Self.isGreyLevels(red: tables.red, green: tables.green, blue: tables.blue)
        colorTransfer = !grey
        return grey ? .greyLevels : .colours
    }

    /// Whether three tables of 256 entries are the grey levels: each entry
    /// its own index, in every channel.
    public static func isGreyLevels(red: UnsafePointer<UInt8>, green: UnsafePointer<UInt8>, blue: UnsafePointer<UInt8>) -> Bool {
        for i in 0..<256 where Int(red[i]) != i || Int(green[i]) != i || Int(blue[i]) != i {
            return false
        }
        return true
    }
}

extension ColorLookupTable {
    /// The grey levels: each entry its own index, in every channel.
    public static let greyLevels: ColorLookupTable = {
        let levels = (0..<256).map { UInt8(truncatingIfNeeded: $0) }
        return ColorLookupTable(red: levels, green: levels, blue: levels)
    }()

    /// Whether the table is the grey levels, the identity of every channel.
    public var isGreyLevels: Bool { self == Self.greyLevels }

    /// Copies the table into three tables of 256 entries.
    public func write(to tables: ColourTableState.Tables) {
        for i in 0..<256 {
            tables.red[i] = i < red.count ? red[i] : 0
            tables.green[i] = i < green.count ? green[i] : 0
            tables.blue[i] = i < blue.count ? blue[i] : 0
        }
    }
}
