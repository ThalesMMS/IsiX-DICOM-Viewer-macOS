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

/// What converting a PET series to SUV does to its windows, beside what
/// `WindowLevelState` (whether a window is in SUV, and its factor) and
/// `PETWindowing` (the window a PET image opens with) already say.
///
/// The 2D viewer converts every slice not converted yet; when the slice on
/// screen is among them, the windows the slices keep (their default level and
/// width) are multiplied by that slice's PET-to-SUV factor, and the view's own
/// window follows: multiplied the same way when the PET windowing is the stored
/// one, read again from the series' presentation otherwise. When the slice on
/// screen already was in SUV, the factor is 1 and the view's window stays.
/// The products are computed in double precision and rounded back to single
/// precision, as the viewer has always computed them.
public struct SUVWindowScaling: Sendable, Equatable {

    /// What the windows of the series are multiplied by.
    public let factor: Double
    /// Whether the view's window follows the conversion.
    public let rescalesView: Bool

    /// The scaling of a conversion: `currentSliceFactor` is the PET-to-SUV
    /// factor of the slice on screen when this conversion converts it, nil
    /// when it already was in SUV.
    public init(currentSliceFactor: Double?) {
        factor = currentSliceFactor ?? 1
        rescalesView = currentSliceFactor != nil
    }

    /// A window value of a slice, or of the view, in the converted values.
    public func scaled(_ value: Float) -> Float {
        Float(Double(value) * factor)
    }

    /// What the view's window becomes.
    public enum ViewWindow: Sendable, Equatable {
        /// It stays as it is.
        case unchanged
        /// The view reads it again from the series' presentation, which
        /// follows the PET windowing of the preferences.
        case fromSeries
        /// This window.
        case window(level: Float, width: Float)
    }

    /// The view's window after the conversion, from the window it shows
    /// (`current`) and the PET windowing of the preferences.
    public func viewWindow(current: (level: Float, width: Float), windowing: PETWindowing) -> ViewWindow {
        guard rescalesView else { return .unchanged }
        guard windowing == .stored else { return .fromSeries }
        return .window(level: scaled(current.level), width: scaled(current.width))
    }

    /// The choice of the SUV sheet, which the preference SUVCONVERSION keeps:
    /// leave the pixels, convert them to SUV, or keep them and display their
    /// SUV values. Any other value does none of these.
    public enum SheetConversion: Int, Sendable {
        case leaveValues = 0
        case convertPixels = 1
        case displaySUV = 2
    }

    /// A dose in becquerels from the megabecquerels the SUV sheet shows.
    public static func becquerels(megabecquerels: Float) -> Float {
        Float(Double(megabecquerels) * 1_000_000.0)
    }

    /// A dose in becquerels as the SUV sheet shows it, in megabecquerels.
    public static func megabecquerelsText(_ becquerels: Float) -> String {
        String(format: "%2.3f", Double(becquerels) / 1_000_000.0)
    }
}
