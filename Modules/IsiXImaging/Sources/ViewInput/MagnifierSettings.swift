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

/// The magnifier of the 2D views, as the preferences keep it: its zoom and
/// size factors, which the keys step and every view starts from, and whether
/// it sits in the view's lower right corner and shows on its own while a
/// point of a measurement is placed. The app reads and writes the preferences;
/// the drawing and the frame are the app's MagnifierPresentation.
public struct MagnifierSettings: Sendable, Equatable {

    /// The zoom factor: 4 shows the picture at twice the view's scale and 2.2,
    /// the closest, at twenty times.
    public var zoomFactor: Float
    /// The size factor of the magnifier's side.
    public var sizeFactor: Float
    public var inCorner: Bool
    public var whileMeasuring: Bool

    public static let defaultZoomFactor: Float = 3
    public static let defaultSizeFactor: Float = 1
    public static let zoomRange: ClosedRange<Float> = 2.2...4
    public static let sizeRange: ClosedRange<Float> = 0.5...3

    /// The settings of the stored factors (a number, else the default), kept
    /// within their ranges.
    public init(storedZoomFactor: Any?, storedSizeFactor: Any?, inCorner: Bool = false, whileMeasuring: Bool = false) {
        zoomFactor = Self.stored(storedZoomFactor, Self.defaultZoomFactor, Self.zoomRange)
        sizeFactor = Self.stored(storedSizeFactor, Self.defaultSizeFactor, Self.sizeRange)
        self.inCorner = inCorner
        self.whileMeasuring = whileMeasuring
    }

    private static func stored(_ value: Any?, _ fallback: Float, _ range: ClosedRange<Float>) -> Float {
        guard let number = value as? NSNumber, number.floatValue.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, number.floatValue))
    }

    /// One step of the zoom factor, closer or farther, within its range.
    public static func zoomFactor(_ factor: Float, steppedIn closer: Bool) -> Float {
        let current = min(zoomRange.upperBound, max(zoomRange.lowerBound, factor))
        return closer ? max(zoomRange.lowerBound, current - 0.2) : min(zoomRange.upperBound, current + 0.2)
    }

    /// One step of the size factor, kept where the magnifier still fits a view.
    public static func sizeFactor(_ factor: Float, steppedUp larger: Bool) -> Float {
        min(sizeRange.upperBound, max(sizeRange.lowerBound, larger ? factor * 1.25 : factor / 1.25))
    }

    /// The settings after an arrow key: left and right step the zoom (right
    /// closer), up and down the size (up larger).
    public func stepped(zoomCloser: Bool? = nil, sizeLarger: Bool? = nil) -> MagnifierSettings {
        var settings = self
        if let zoomCloser { settings.zoomFactor = Self.zoomFactor(zoomFactor, steppedIn: zoomCloser) }
        if let sizeLarger { settings.sizeFactor = Self.sizeFactor(sizeFactor, steppedUp: sizeLarger) }
        return settings
    }
}
