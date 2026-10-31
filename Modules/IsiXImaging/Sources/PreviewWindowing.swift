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

/// The window and level of the database preview, and the moves of its slider.
///
/// The preview is an image view beside the thumbnails: it shows one frame of
/// the selected series at a time, with the window the app's preview policy
/// chose for the series. What it keeps is the image view's vocabulary: the
/// window the shown frame's pixels have and the window the view mirrors and
/// draws with, both a `WindowLevelState`. Which window the policy picks, and
/// why, is the policy's; this decides around it: whether a window the view
/// reports asks for the automatic one, which frame the series' defaults are
/// read from, whether the frame's own range is worth reading, whether a window
/// is already on screen, and where the slider goes for a wheel notch or an
/// animation step.
public struct PreviewWindowing: Sendable, Equatable {

    /// The window the shown frame's pixels have.
    public var pixels: WindowLevelState
    /// The window the view keeps and draws with.
    public var view: WindowLevelState

    public init(pixels: WindowLevelState, view: WindowLevelState) {
        self.pixels = pixels
        self.view = view
    }

    /// Whether `level` and `width` are already the window of the pixels and of
    /// the view. The pixels can have it while the view still holds the
    /// previous frame's window, which the renderer reads on each draw: only
    /// when both have it is applying it again a reload of the textures for
    /// nothing.
    public func isShowing(level: Float, width: Float) -> Bool {
        pixels.width == width && pixels.level == level && view.width == width && view.level == level
    }

    /// Whether a window the view reports is one on screen, re-asserted by a
    /// redraw, rather than a request for the automatic window: a width of zero,
    /// or a number that is not finite, asks the preview to compute its window
    /// again rather than to show an image two units wide.
    public static func isWindowOnScreen(level: Float, width: Float) -> Bool {
        width > 0 && width.isFinite && level.isFinite
    }

    /// The frame a series' preview defaults are read from.
    public enum ReferenceFrame: Sendable, Equatable {
        /// The frame on screen: it is the middle one, or there is no other.
        case shown
        /// The middle frame of the series' single, multiframe file.
        case fileFrame(Int, of: Int)
        /// The middle image of the series, at its frame.
        case seriesImage(Int, of: Int, frame: Int)
    }

    /// The frame the defaults of a series are read from: its middle image, the
    /// one the series thumbnail is made from and the 2D viewer takes its
    /// window from. Some scanners compute a window for every slice, and an edge
    /// slice, mostly air, carries the window of its own noise; the preview
    /// opens on the first slice and keeps its defaults for the whole series.
    ///
    /// A series of one file uses that file's middle frame (`fileFrames` is the
    /// file's number of frames); a series of several images, the image at
    /// `imageCount / 2`, whose frame and whether it is the frame shown
    /// `middleImage` answers for that index.
    public static func referenceFrame(imageCount: Int, fileFrames: Int, shownFrame: Int,
                                      middleImage: (Int) -> (isShown: Bool, frame: Int)) -> ReferenceFrame {
        if imageCount < 1 { return .shown }
        if imageCount == 1 {
            let middle = fileFrames / 2
            if fileFrames < 2 || shownFrame == middle { return .shown }
            return .fileFrame(middle, of: fileFrames)
        }
        let index = imageCount / 2
        let middle = middleImage(index)
        if middle.isShown && shownFrame == middle.frame { return .shown }
        return .seriesImage(index, of: imageCount, frame: middle.frame)
    }

    /// Whether the frame's own minimum and maximum are read: only when there
    /// was nothing to sample (no automatic window), the frame is not colour,
    /// and the file has no usable window. A uniform frame has no percentiles
    /// worth taking, and the stored bit range would show it as flat grey.
    public static func needsFrameRange(hasAutomaticWindow: Bool, isColor: Bool, hasValidFileWindow: Bool) -> Bool {
        !hasAutomaticWindow && !isColor && !hasValidFileWindow
    }

    /// The slider position after one wheel event: one step in the direction
    /// of `deltaY` (the other way round when the wheel is reversed), from the
    /// last position back to the first and from the first to the last. Nil
    /// for an event that does not move vertically.
    public static func wheelPosition(from position: Int32, deltaY: Double, reversed: Bool, maxValue: Double) -> Int32? {
        if deltaY == 0 { return nil }
        let change = (reversed ? -1 : 1) * Float(deltaY)
        var next = position &+ (change > 0 ? 1 : -1)
        if Double(next) > maxValue { next = 0 }
        if next < 0 { next = int32(maxValue) }
        return next
    }

    /// The next frame of the animation: one step on, back to the first after
    /// the last.
    public static func nextAnimationPosition(from position: Int32, maxValue: Double) -> Int32 {
        let next = position &+ 1
        return Double(next) > maxValue ? 0 : next
    }

    /// A double converted to an int as arm64 converts it: NaN is 0, and a
    /// value out of range saturates, where Swift would trap.
    private static func int32(_ value: Double) -> Int32 {
        if value.isNaN { return 0 }
        if value >= Double(Int32.max) { return Int32.max }
        if value <= Double(Int32.min) { return Int32.min }
        return Int32(value)
    }
}
