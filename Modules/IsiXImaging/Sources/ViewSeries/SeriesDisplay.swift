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

/// The rules of the series a DCMView shows that need neither the view nor
/// AppKit: which image an index picks, whether the series is a volume, and
/// the age shown with the image.
public enum SeriesDisplay {

    /// The image an index picks in a series of `count` images: the last one
    /// past the end, the first one before it. The index is compared with the
    /// count as the Objective-C compared it with an NSUInteger, unsigned, so a
    /// negative index is past the end. The index is a full integer: a series of
    /// more than 32767 images reaches its last image.
    public static func clampedIndex(_ index: Int, count: Int) -> Int {
        var current = index
        if UInt(bitPattern: current) >= UInt(bitPattern: count) {
            current = count - 1
        }
        if current < 0 { current = 0 }
        return current
    }

    /// A series is a volume unless it has a single image or its first and last
    /// images are at the same slice location (a time series, a scout).
    public static func isVolume(count: Int, firstSliceLocation: Double, lastSliceLocation: Double) -> Bool {
        if count > 1 {
            return firstSliceLocation != lastSliceLocation
        }
        return false
    }

    /// The patient's age, followed by the age at acquisition when they differ;
    /// a missing one reads "(null)", as the Objective-C format printed it.
    public static func ageText(now: String?, atAcquisition: String?) -> String {
        if let now, let atAcquisition, now == atAcquisition {
            return now
        }
        return "\(now ?? "(null)") / \(atAcquisition ?? "(null)")"
    }
}

/// What a change of the "propagate the settings in the series" option writes
/// into each image's presentation state.
public enum SeriesSettingsPropagation {

    /// The presentation-state keys of an image.
    public enum Key {
        public static let windowWidth = "windowWidth"
        public static let windowLevel = "windowLevel"
        public static let scale = "scale"
        public static let rotationAngle = "rotationAngle"
        public static let yFlipped = "yFlipped"
        public static let xFlipped = "xFlipped"
        public static let xOffset = "xOffset"
        public static let yOffset = "yOffset"
        /// In the order they are written.
        public static let all = [windowWidth, windowLevel, scale, rotationAngle, yFlipped, xFlipped, xOffset, yOffset]
    }

    /// Which of the zoom, pan, rotation and flips an image already has.
    public struct Stored: Equatable, Sendable {
        public var scale, rotationAngle, yFlipped, xFlipped, xOffset, yOffset: Bool
        public init(scale: Bool, rotationAngle: Bool, yFlipped: Bool, xFlipped: Bool, xOffset: Bool, yOffset: Bool) {
            self.scale = scale
            self.rotationAngle = rotationAngle
            self.yFlipped = yFlipped
            self.xFlipped = xFlipped
            self.xOffset = xOffset
            self.yOffset = yOffset
        }
    }

    /// One write: a key cleared, or a key given the value on screen. `scale` is
    /// the zoom on screen, or cleared when the image is fitted to the view;
    /// `offsets` writes both offsets.
    public enum Write: Equatable, Sendable {
        case clear(String)
        case windowWidth, windowLevel, scale, rotationAngle, yFlipped, xFlipped, offsets
    }

    /// The writes for one image, in order. With propagation, every key is
    /// cleared: the image takes the settings on screen. Without it, the image on
    /// screen keeps the window on screen, and an image takes the zoom, pan,
    /// rotation and flips on screen when it is the one on screen or has none of
    /// its own (both offsets go together).
    public static func writes(propagate: Bool, onScreen: Bool, stored: Stored) -> [Write] {
        if propagate {
            return Key.all.map { .clear($0) }
        }
        var writes: [Write] = []
        if onScreen {
            writes.append(.windowWidth)
            writes.append(.windowLevel)
        }
        if onScreen || !stored.scale { writes.append(.scale) }
        if onScreen || !stored.rotationAngle { writes.append(.rotationAngle) }
        if onScreen || !stored.yFlipped { writes.append(.yFlipped) }
        if onScreen || !stored.xFlipped { writes.append(.xFlipped) }
        if onScreen || !stored.xOffset || !stored.yOffset { writes.append(.offsets) }
        return writes
    }
}

/// The name of the window level shown: a preset of the user's, the image's
/// full dynamic, its default (the one stored with it), or "Other".
public enum WindowLevelPreset: Equatable, Sendable {
    case named(String)
    case fullDynamic
    case imageDefault
    case other

    /// The first preset, in the order given, whose level and width are those on
    /// screen; then the image's full dynamic and its default, when there is an
    /// image. Values are compared as floats, exactly.
    public static func match(level: Float, width: Float, presets: [(name: String, level: Float, width: Float)],
                             fullDynamic: (level: Float, width: Float)?, imageDefault: (level: Float, width: Float)?) -> WindowLevelPreset {
        for preset in presets where preset.level == level && preset.width == width {
            return .named(preset.name)
        }
        if let fullDynamic, let imageDefault {
            if level == fullDynamic.level && width == fullDynamic.width { return .fullDynamic }
            if level == imageDefault.level && width == imageDefault.width { return .imageDefault }
        }
        return .other
    }
}
