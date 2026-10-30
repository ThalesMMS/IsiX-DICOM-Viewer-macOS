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

import Foundation

// The colour look-up tables (CLUT) of a 2D viewer as its presets store them:
// the user defaults key "CLUT" holds a dictionary of named tables, each a
// dictionary with "Red", "Green" and "Blue", 256 numbers each, and, for a table
// made in the CLUT editor, the editor's "Points" and "Colors". The format is
// persisted: it does not change here.

public struct ColorLookupTable: Sendable, Equatable {
    public static let redKey = "Red", greenKey = "Green", blueKey = "Blue"
    public static let pointsKey = "Points", colorsKey = "Colors"

    public var red: [UInt8]
    public var green: [UInt8]
    public var blue: [UInt8]

    public init(red: [UInt8], green: [UInt8], blue: [UInt8]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The table of a stored preset; nil when one of its three channels is
    /// missing or has fewer than 256 numbers. Each number is taken as a long and
    /// kept to its low eight bits, as the viewer did.
    public init?(preset: NSDictionary) {
        func channel(_ key: String) -> [UInt8]? {
            guard let values = preset.object(forKey: key) as? NSArray, values.count >= 256 else { return nil }
            var channel = [UInt8](repeating: 0, count: 256)
            for i in 0..<256 {
                guard let number = values.object(at: i) as? NSNumber else { return nil }
                channel[i] = UInt8(truncatingIfNeeded: number.int64Value)
            }
            return channel
        }
        guard let red = channel(Self.redKey), let green = channel(Self.greenKey), let blue = channel(Self.blueKey) else { return nil }
        self.init(red: red, green: green, blue: blue)
    }

    /// The index of the darkest entry, the first of the lowest red + green +
    /// blue: the viewer's black index, the value drawn where there is no image.
    public var darkestIndex: Int {
        var darkness = 256 * 3, index = 0
        for i in 0..<256 where Int(red[i]) + Int(green[i]) + Int(blue[i]) < darkness {
            index = i
            darkness = Int(red[i]) + Int(green[i]) + Int(blue[i])
        }
        return index
    }

    /// The preset the CLUT editor stores: the three channels as numbers, and
    /// the editor's points and colours as they are.
    public func preset(points: [Any], colors: [Any]) -> NSDictionary {
        let preset = NSMutableDictionary()
        preset.setObject(red.map { NSNumber(value: Int($0)) } as NSArray, forKey: Self.redKey as NSString)
        preset.setObject(green.map { NSNumber(value: Int($0)) } as NSArray, forKey: Self.greenKey as NSString)
        preset.setObject(blue.map { NSNumber(value: Int($0)) } as NSArray, forKey: Self.blueKey as NSString)
        preset.setObject(points as NSArray, forKey: Self.pointsKey as NSString)
        preset.setObject(colors as NSArray, forKey: Self.colorsKey as NSString)
        return preset
    }
}

// The opacity tables of a 2D viewer's thick slab, as its presets store them:
// the user defaults key "OPACITY" holds a dictionary of named tables, each a
// dictionary with the editor's "Points".
public enum OpacityTablePreset {
    public static let pointsKey = "Points"

    /// The points of a stored preset, nil when it has none.
    public static func points(of preset: NSDictionary) -> NSArray? {
        return preset.object(forKey: pointsKey) as? NSArray
    }

    /// The preset the opacity editor stores.
    public static func preset(points: NSArray) -> NSDictionary {
        return NSDictionary(object: points, forKey: pointsKey as NSString)
    }
}
