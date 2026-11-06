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

/// The window a PET-like image (PT, or NM when the preference says so) opens
/// with, as the DEFAULTPETWLWW preference chooses it:
/// - 0: the stored window, converted to SUV for an SUV image of the 2D viewer;
/// - 1: a range given in percent of the series maximum (PETWLWWFROM/TO);
/// - 2: for an SUV image, a range of SUV values (PETWLWWFROMSUV/TOSUV); the
///   stored window otherwise.
public enum PETWindowing: Sendable, Equatable {
    case stored
    case percentOfMaximum(from: Float, to: Float)
    case suv(from: Float, to: Float)
    /// Any other value of the preference: the window does not change.
    case unchanged

    /// The choice of the preference `mode`, with the bounds the other
    /// preferences give.
    public init(mode: Int, percentFrom: Float, percentTo: Float, suvFrom: Float, suvTo: Float) {
        switch mode {
        case 0: self = .stored
        case 1: self = .percentOfMaximum(from: percentFrom, to: percentTo)
        case 2: self = .suv(from: suvFrom, to: suvTo)
        default: self = .unchanged
        }
    }

    /// The window a view restores when it shows an image, or nil when it
    /// restores none.
    ///
    /// `stored` is what the presentation state saved, or else the image's own
    /// window; `current` the view's window. A stored window with a width is
    /// restored: as it is for an image that is not PET-like, following the
    /// preference for a PET-like one. A stored window with neither level nor
    /// width (an image that has none) gives a PET-like image the preference's
    /// range, unless only the image's own state is read (`imageOnly`). A range
    /// of no width is skipped when the image has a stored window, and kept
    /// when it has none. `suvFactor` answers the 2D viewer's PET-to-SUV factor,
    /// or nil in another viewer, where a stored window of an SUV image leaves
    /// the view's window as it is.
    public func restored(stored: (level: Float, width: Float), current: (level: Float, width: Float),
                         petLike: Bool, suvConverted: Bool, seriesMaximum: Float, imageOnly: Bool,
                         suvFactor: () -> Float?) -> (level: Float, width: Float)? {
        let (wl, ww) = (stored.level, stored.width)
        if ww != 0 || wl != 0 {
            guard ww != 0 else { return nil }
            guard petLike else { return (wl, ww) }
            switch self {
            case .stored:
                if !suvConverted { return (wl, ww) }
                if let factor = suvFactor() { return (wl * factor, ww * factor) }
                return current
            case .percentOfMaximum(let percentFrom, let percentTo):
                let from = ViewTransform.percentOfMaximum(seriesMaximum, percentFrom)
                let to = ViewTransform.percentOfMaximum(seriesMaximum, percentTo)
                guard to - from != 0 else { return current }
                let window = ViewTransform.window(from: from, to: to)
                return (window.level, window.width)
            case .suv(let from, let to):
                guard suvConverted else { return (wl, ww) }
                guard to - from != 0 else { return current }
                let window = ViewTransform.window(from: from, to: to)
                return (window.level, window.width)
            case .unchanged:
                return current
            }
        }
        guard !imageOnly, petLike else { return nil }
        switch self {
        case .percentOfMaximum(let percentFrom, let percentTo):
            let window = ViewTransform.window(from: ViewTransform.percentOfMaximum(seriesMaximum, percentFrom),
                                              to: ViewTransform.percentOfMaximum(seriesMaximum, percentTo))
            return (window.level, window.width)
        case .suv(let from, let to) where suvConverted:
            let window = ViewTransform.window(from: from, to: to)
            return (window.level, window.width)
        case .stored, .suv, .unchanged:
            return (wl, ww)
        }
    }
}
