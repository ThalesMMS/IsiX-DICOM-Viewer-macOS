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

import CoreGraphics
import Foundation

// The synchronization of 2D viewers: what the "Sync" button of the toolbar
// does (between viewers of one study it switches the view's own syncro mode;
// across studies it locks the series at their current offset), and the
// settings one viewer hands on to another (window level, zoom, pan,
// rotation). The viewers apply them; these are the rules.

public enum ViewerSynchronization {

    /// Whether the "Sync" button works between studies: when the other
    /// displayed viewers are not all of `study`. A viewer without a study is of
    /// none (NSString equality, false with nil on either side).
    public static func syncsBetweenStudies(study: String?, otherStudies: [String?]) -> Bool {
        otherStudies.contains { !same(study, $0) }
    }

    /// Whether the series lock is reset after the button's behaviour is worked
    /// out again: always when it works within a study, and when it has just
    /// started working between studies.
    public static func resetsSeriesLock(betweenStudies: Bool, wasBetweenStudies: Bool) -> Bool {
        (betweenStudies && !wasBetweenStudies) || !betweenStudies
    }

    /// NSString equality, as -isEqualToString: answers it (false with nil).
    public static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return (a as NSString).isEqual(to: b)
    }
}

/// What a viewer knows of itself and of another to decide whether its window
/// level goes to the other one (with "propagate settings" on and the same
/// colour table).
public struct WindowLevelPropagation: Sendable {
    public var isRGB: Bool, otherIsRGB: Bool
    public var modality: String?, otherModality: String?
    public var subtraction: Bool, otherSubtraction: Bool
    public var suvConverted: Bool, otherSUVConverted: Bool

    public init(isRGB: Bool, otherIsRGB: Bool, modality: String?, otherModality: String?,
                subtraction: Bool, otherSubtraction: Bool, suvConverted: Bool, otherSUVConverted: Bool) {
        self.isRGB = isRGB
        self.otherIsRGB = otherIsRGB
        self.modality = modality
        self.otherModality = otherModality
        self.subtraction = subtraction
        self.otherSubtraction = otherSubtraction
        self.suvConverted = suvConverted
        self.otherSUVConverted = otherSUVConverted
    }

    /// Only between images of one kind: both RGB or both not, the same
    /// modality, the subtraction on both or neither; never to or from CR, never
    /// to NM; between PET only when both are in SUV or neither.
    public var propagates: Bool {
        let same = ViewerSynchronization.same
        var propagate = true
        if isRGB != otherIsRGB { propagate = false }
        if !same(otherModality, modality) { propagate = false }
        if subtraction != otherSubtraction { propagate = false }
        if same(otherModality, "CR") { propagate = false }
        if same(modality, "CR") { propagate = false }
        if same(otherModality, "NM") { propagate = false }
        if same(otherModality, "PT") && same(modality, "PT") && suvConverted != otherSUVConverted { propagate = false }
        return propagate
    }
}

public enum ViewerSettingsPropagation {

    /// The zoom the other viewer gets, or nil when it keeps its own: the same
    /// scale per millimetre when both views know their pixel spacing, the same
    /// scale otherwise; nothing from a view without a scale. The arithmetic is
    /// the viewer's: a float scale over a double spacing.
    public static func scale(_ scale: Float, pixelSpacing: Double, otherPixelSpacing: Double) -> Float? {
        guard scale != 0 else { return nil }
        if pixelSpacing != 0 && otherPixelSpacing != 0 {
            let perMillimetre = Float(Double(scale) / pixelSpacing)
            return Float(Double(perMillimetre) * otherPixelSpacing)
        }
        return scale
    }

    /// The other view's pan: this view's, moved by the distance between the two
    /// images' origins (`delta`, in millimetres) at this view's scale.
    public static func pan(_ origin: CGPoint, delta: CGPoint, scale: Float) -> CGPoint {
        let x = delta.x * CGFloat(scale), y = delta.y * CGFloat(scale)
        return CGPoint(x: origin.x + x, y: origin.y - y)
    }
}
