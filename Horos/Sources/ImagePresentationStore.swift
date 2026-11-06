//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation
import IsiXImaging

/// The presentation state an image view records in the database: what the series
/// and the image on screen keep of the way they are shown, written to their typed
/// attributes. A series or an image that is nil records nothing.
///
/// Core Data raises an Objective-C exception for an object deleted under the view,
/// or whose data can no longer be read; finding the objects can raise it too. So
/// the objects are found and written inside `record`, the one place that catches
/// it: the write is given up and logged, and the view goes on.
@MainActor
struct ImagePresentationStore {
    let series: DicomSeries?
    let image: DicomImage?

    /// What the image's own state does when the series takes a window.
    enum ImageWindow {
        /// The image keeps the same window: it is the one shown with it.
        case same
        /// The image's own window is removed, and it shows the series'.
        case cleared
        /// The image's own window is left as it is.
        case untouched
    }

    /// The window kept by the image, else by the series unless `imageOnly`: its
    /// width and its level as stored, each nil when neither keeps it.
    func storedWindow(imageOnly: Bool) -> (width: Float?, storedLevel: Float?) {
        let width = image?.windowWidth ?? (imageOnly ? nil : series?.windowWidth)
        let level = image?.windowLevel ?? (imageOnly ? nil : series?.windowLevel)
        return (width?.floatValue, level?.floatValue)
    }

    /// The window of the series: its width, and its level as stored (the level of
    /// the pixel values, which an inverted image keeps negated).
    func storeWindow(width: Float, storedLevel: Float, image imageWindow: ImageWindow) {
        series?.windowWidth = NSNumber(value: width)
        series?.windowLevel = NSNumber(value: storedLevel)
        switch imageWindow {
        case .same:
            image?.windowWidth = NSNumber(value: width)
            image?.windowLevel = NSNumber(value: storedLevel)
        case .cleared:
            image?.windowWidth = nil
            image?.windowLevel = nil
        case .untouched:
            break
        }
    }

    // MARK: - Viewport

    /// The scale, relative to a view of `frameSize`, with the series, which
    /// shows it with display style 3; the absolute scale with the image when it
    /// keeps its own (`imageKeeps`). A fitted view saves no scale.
    func storeScale(_ scale: Float, frameSize: CGSize, fitted: Bool, imageKeeps: Bool) {
        series?.scale = fitted ? nil : NSNumber(value: ViewTransform.seriesScale(scale, frameSize: frameSize))
        series?.displayStyle = NSNumber(value: Int32(3))
        image?.scale = imageKeeps && !fitted ? NSNumber(value: scale) : nil
    }

    /// The rotation, with the series and, when it keeps its own, the image.
    func storeRotation(_ rotation: Float, imageKeeps: Bool) {
        series?.rotationAngle = NSNumber(value: rotation)
        image?.rotationAngle = imageKeeps ? NSNumber(value: rotation) : nil
    }

    /// A flip, horizontal or vertical, with the series and, when it keeps its
    /// own, the image.
    func storeFlip(_ flipped: Bool, horizontal: Bool, imageKeeps: Bool) {
        let value = NSNumber(value: flipped)
        if horizontal {
            series?.xFlipped = value
            image?.xFlipped = imageKeeps ? value : nil
        } else {
            series?.yFlipped = value
            image?.yFlipped = imageKeeps ? value : nil
        }
    }

    /// The pan, with the series and, when it keeps its own, the image.
    func storeOffset(x: Float, y: Float, imageKeeps: Bool) {
        storeSeriesOffset(x: x, y: y)
        image?.xOffset = imageKeeps ? NSNumber(value: x) : nil
        image?.yOffset = imageKeeps ? NSNumber(value: y) : nil
    }

    /// The pan, with the series only.
    func storeSeriesOffset(x: Float, y: Float) {
        series?.xOffset = NSNumber(value: x)
        series?.yOffset = NSNumber(value: y)
    }

    /// The image fitted again with the view: no scale of its own, and the pan
    /// `offset`.
    func storeFitted(offset: CGPoint) {
        image?.scale = nil
        image?.xOffset = NSNumber(value: Float(offset.x))
        image?.yOffset = NSNumber(value: Float(offset.y))
    }

    /// The image's own scale multiplied by `factor` when the view changes size;
    /// none stays none.
    func storeResized(by factor: Float) {
        let scale = image?.scale?.floatValue ?? 0
        image?.scale = scale != 0 ? NSNumber(value: scale * factor) : nil
    }

    /// What the image (or the series) saved of the viewport, for ViewportRestoration.
    var imageFlips: (x: Bool?, y: Bool?) { (image?.xFlipped?.boolValue, image?.yFlipped?.boolValue) }
    var seriesFlips: (x: Bool?, y: Bool?) { (series?.xFlipped?.boolValue, series?.yFlipped?.boolValue) }
    var imageScale: Float? { image?.scale?.floatValue }
    var seriesScale: (scale: Float?, displayStyle: Int32?) { (series?.scale?.floatValue, series?.displayStyle?.int32Value) }
    var rotations: (image: Float?, series: Float?) { (image?.rotationAngle?.floatValue, series?.rotationAngle?.floatValue) }
    var offsets: (image: (x: Float?, y: Float?), series: (x: Float?, y: Float?)) {
        ((image?.xOffset?.floatValue, image?.yOffset?.floatValue), (series?.xOffset?.floatValue, series?.yOffset?.floatValue))
    }

    // MARK: - Settings copied to the series

    /// Which of the zoom, pan, rotation and flips the image keeps.
    var storedViewport: SeriesSettingsPropagation.Stored {
        SeriesSettingsPropagation.Stored(scale: image?.scale != nil, rotationAngle: image?.rotationAngle != nil,
                                         yFlipped: image?.yFlipped != nil, xFlipped: image?.xFlipped != nil,
                                         xOffset: image?.xOffset != nil, yOffset: image?.yOffset != nil)
    }

    /// Writes a change of the "propagate the settings in the series" option
    /// into the image: a key cleared, or the window (`width`, and the level as
    /// stored, asked only when written: it loads the image), the zoom (none
    /// when `fitted`), the rotation, the flips and the pan of `viewport`, the
    /// view on screen.
    func storeCopySettings(_ writes: [SeriesSettingsPropagation.Write], width: Float, storedLevel: () -> Float, viewport: ViewportState,
                           fitted: () -> Bool) {
        let key = SeriesSettingsPropagation.Key.self
        for write in writes {
            switch write {
            case .clear(key.windowWidth): image?.windowWidth = nil
            case .clear(key.windowLevel): image?.windowLevel = nil
            case .clear(key.scale): image?.scale = nil
            case .clear(key.rotationAngle): image?.rotationAngle = nil
            case .clear(key.yFlipped): image?.yFlipped = nil
            case .clear(key.xFlipped): image?.xFlipped = nil
            case .clear(key.xOffset): image?.xOffset = nil
            case .clear(key.yOffset): image?.yOffset = nil
            case .clear: break
            case .windowWidth: image?.windowWidth = NSNumber(value: width)
            case .windowLevel: image?.windowLevel = NSNumber(value: storedLevel())
            case .scale: image?.scale = fitted() ? nil : NSNumber(value: viewport.scale)
            case .rotationAngle: image?.rotationAngle = NSNumber(value: viewport.rotation)
            case .yFlipped: image?.yFlipped = NSNumber(value: viewport.yFlipped)
            case .xFlipped: image?.xFlipped = NSNumber(value: viewport.xFlipped)
            case .offsets:
                image?.xOffset = NSNumber(value: Float(viewport.origin.x))
                image?.yOffset = NSNumber(value: Float(viewport.origin.y))
            }
        }
    }
}
