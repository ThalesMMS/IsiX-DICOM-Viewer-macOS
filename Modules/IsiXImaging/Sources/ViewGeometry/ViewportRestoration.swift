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

/// How a view restores the viewport its image, or else its series, saved:
/// the flips, the scale (absolute, or relative to the view's size), the
/// rotation and the pan. The view applies the steps in that order, reading
/// what is saved just before each step: applying one writes the presentation
/// state again, and the views of the same series take it from one another.
public struct ViewportRestoration: Sendable, Equatable {
    /// Only the image's own values count: the series' are ignored.
    public var onlyImage: Bool
    /// Whether the saved scale, and the saved pan, are restored at all when
    /// the settings are copied to the whole series.
    public var restoresScale: Bool
    public var restoresOffset: Bool
    /// The database's preview, which always fits the image.
    public var isPreview: Bool
    /// The AlwaysScaleToFit preference.
    public var alwaysFit: Bool
    /// Whether the settings are copied to the whole series.
    public var copiesSettingsInSeries: Bool

    public init(onlyImage: Bool, restoresScale: Bool, restoresOffset: Bool, isPreview: Bool, alwaysFit: Bool,
                copiesSettingsInSeries: Bool) {
        self.onlyImage = onlyImage
        self.restoresScale = restoresScale
        self.restoresOffset = restoresOffset
        self.isPreview = isPreview
        self.alwaysFit = alwaysFit
        self.copiesSettingsInSeries = copiesSettingsInSeries
    }

    /// The scale restored: the image fitted to the view, or a value given to
    /// the view's scale.
    public enum Scale: Sendable, Equatable {
        case fit
        case value(Float)
    }

    /// A flip: the image's, else the series' unless only the image counts,
    /// else none.
    public func flip(image: Bool?, series: Bool?) -> Bool {
        if let image { return image }
        if !onlyImage { return series ?? false }
        return false
    }

    /// The scale: the image's (0 fits it), else the series' relative to the
    /// view of `frameSize` as its display style says (none or 0 fits it);
    /// fitted in the preview and when the settings copied to the series do
    /// not restore it.
    public func scale(image: Float?, series: Float?, displayStyle: Int32?, frameSize: CGSize) -> Scale {
        guard !isPreview, (restoresScale && !alwaysFit) || !copiesSettingsInSeries else { return .fit }
        if let image {
            return image != 0 ? .value(image) : .fit
        }
        if !onlyImage, let series, series != 0 {
            return .value(ViewTransform.restoredScale(series, displayStyle: Int(displayStyle ?? 0), frameSize: frameSize))
        }
        return .fit
    }

    /// The rotation: the image's, else the series' unless only the image
    /// counts, else 0.
    public func rotation(image: Float?, series: Float?) -> Float {
        if let image { return image }
        if !onlyImage { return series ?? 0 }
        return 0
    }

    /// Whether the pan is restored: never in the preview, nor when the
    /// settings copied to the series do not restore it.
    public var restoresOrigin: Bool {
        return !isPreview && ((restoresOffset && !alwaysFit) || !copiesSettingsInSeries)
    }

    /// The pan, each coordinate the image's, else the series' (0 when it has
    /// none) unless only the image counts; nil when a coordinate is missing,
    /// or infinite.
    public func origin(image: (x: Float?, y: Float?), series: (x: Float?, y: Float?)) -> CGPoint? {
        guard restoresOrigin else { return nil }
        var o = CGPoint(x: CGFloat(Float.infinity), y: CGFloat(Float.infinity))
        if let x = image.x { o.x = CGFloat(x) } else if !onlyImage { o.x = CGFloat(series.x ?? 0) }
        if let y = image.y { o.y = CGFloat(y) } else if !onlyImage { o.y = CGFloat(series.y ?? 0) }
        if o.x != CGFloat(Float.infinity) && o.y != CGFloat(Float.infinity) {
            return o
        }
        return nil
    }
}
