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

/// What a viewer's capture is asked for, and the rules that turn the request
/// into a picture: whether the tiles of the viewer are assembled, whether the
/// picture is cropped to the image, in which form its samples come (the screen
/// in RGB or in 16 bits, the image in memory in RGB, 8 or 16 bits), whether its
/// pixels are made square, the thumbnail of a secondary capture, and how the
/// views of several viewers are placed in one picture. The view (DCMView, in
/// the app) gathers its pixels and geometry and the database objects, and
/// writes the DICOM file; CaptureRaster does the arithmetic of the buffers.
/// Every rule below is the one -getRawPixelsWidth:… and the exports of the
/// view have always followed.
public struct ViewCaptureRequest: Sendable, Equatable {
    /// What the view shows, rather than the image in memory.
    public var screenCapture: Bool
    /// 8-bit samples, also for an image that would give 16.
    public var force8bits: Bool
    /// Without what is drawn over the image (the view draws as when it exports).
    public var removeGraphical: Bool
    /// Pixels made square when they are not (8-bit images in memory only).
    public var squarePixels: Bool
    /// In a viewer showing several images at once, all the tiles side by side.
    public var allTiles: Bool
    /// The picture reduced to the part of the view that holds the image, when
    /// the preferences ask for it too.
    public var allowSmartCropping: Bool

    public init(screenCapture: Bool, force8bits: Bool, removeGraphical: Bool, squarePixels: Bool,
                allTiles: Bool, allowSmartCropping: Bool) {
        self.screenCapture = screenCapture
        self.force8bits = force8bits
        self.removeGraphical = removeGraphical
        self.squarePixels = squarePixels
        self.allTiles = allTiles
        self.allowSmartCropping = allowSmartCropping
    }

    // MARK: - The requests of the view

    /// -getRawPixels::::::, which plugins call: without the graphics, the
    /// pixels as they are, the tiles as the preferences say, never cropped.
    public static func rawPixels(screenCapture: Bool, force8bits: Bool, includeAllTiledViews: Bool) -> ViewCaptureRequest {
        ViewCaptureRequest(screenCapture: screenCapture, force8bits: force8bits, removeGraphical: true,
                           squarePixels: false, allTiles: includeAllTiledViews, allowSmartCropping: false)
    }

    /// A secondary capture (the DICOM file of the view, and its image as a
    /// thumbnail): what the view shows, in RGB, without the graphics, with
    /// square pixels, uncropped, only this view.
    public static let secondaryCapture = ViewCaptureRequest(screenCapture: true, force8bits: true, removeGraphical: true,
                                                            squarePixels: true, allTiles: false, allowSmartCropping: false)

    /// What is copied or dragged: what the view shows with its graphics (the
    /// image in memory with `originalSize`), in 8 bits with square pixels, its
    /// tiles as the preferences say, cropped as they say unless every viewer
    /// is taken.
    public static func copy(originalSize: Bool, allViewers: Bool, includeAllTiledViews: Bool,
                            allowSmartCropping: Bool) -> ViewCaptureRequest {
        ViewCaptureRequest(screenCapture: allViewers || !originalSize, force8bits: true, removeGraphical: false,
                           squarePixels: true, allTiles: includeAllTiledViews,
                           allowSmartCropping: allViewers ? false : allowSmartCropping)
    }

    // MARK: - Tiles

    /// A 2D viewer that shows more than one image at once.
    public static func isTiled(twoDViewer: Bool, rows: Int, columns: Int) -> Bool {
        twoDViewer && (rows != 1 || columns != 1)
    }

    /// Whether the picture is the grid of all the viewer's tiles.
    public func capturesTiles(twoDViewer: Bool, rows: Int, columns: Int) -> Bool {
        allTiles && Self.isTiled(twoDViewer: twoDViewer, rows: rows, columns: columns)
    }

    /// What each tile of the grid is asked: the same, never cropped, since
    /// the tiles must be of one size.
    public var forTile: ViewCaptureRequest {
        var tile = self
        tile.allowSmartCropping = false
        return tile
    }

    /// The grid of a tiled viewer, all its tiles the size of the first.
    public struct TileGrid: Sendable, Equatable {
        public var columns: Int
        public var rows: Int

        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }

        /// The tiles, in the order of the viewer's image views: row by row.
        public func index(column: Int, row: Int) -> Int {
            column + row * columns
        }

        /// The picture of the whole grid.
        public func size(tileWidth: Int, tileHeight: Int) -> (width: Int, height: Int) {
            (tileWidth * columns, tileHeight * rows)
        }

        /// The bytes allocated for the grid: each tile with a margin of 4
        /// pixels each way, as always allocated.
        public func byteCount(tileWidth: Int, tileHeight: Int, samplesPerPixel: Int, bitsPerSample: Int) -> Int {
            bitsPerSample * samplesPerPixel * (tileWidth + 4) * (tileHeight + 4) / 8 * columns * rows
        }
    }

    // MARK: - One view

    /// Whether the screen capture is cropped to the image: asked, allowed by
    /// the preferences (ScreenCaptureSmartCropping), and never for the views
    /// of the orthogonal MPR.
    public func cropsSmartly(orthogonalMPR: Bool, screenCaptureSmartCropping: Bool) -> Bool {
        allowSmartCropping && !orthogonalMPR && screenCaptureSmartCropping
    }

    /// The form of the samples of a capture.
    public enum Form: Sendable, Equatable {
        /// What the view shows, read back from its frame, in RGB.
        case screenColour
        /// The image as shown, rendered again at full resolution, in 16 bits.
        case screenGrey16
        /// The image in memory, in RGB.
        case colour
        /// The image in memory, as displayed, in 8 bits.
        case grey8
        /// The image in memory, in 16 bits.
        case grey16

        public var samplesPerPixel: Int {
            switch self {
            case .screenColour, .colour: return 3
            case .screenGrey16, .grey8, .grey16: return 1
            }
        }

        public var bitsPerSample: Int {
            switch self {
            case .screenColour, .colour, .grey8: return 8
            case .screenGrey16, .grey16: return 16
            }
        }

        /// The bytes allocated for a `width` × `height` picture. The colour
        /// screen capture has room for 4 samples a pixel and 10 bytes more.
        public func byteCount(width: Int, height: Int) -> Int {
            if self == .screenColour { return 10 + width * height * 4 * bitsPerSample / 8 }
            return width * height * samplesPerPixel * bitsPerSample / 8
        }
    }

    /// The form of the capture of an image (`isRGB`), fused or not with
    /// another, shown as a thick slab rendered in volume (`thickSlabVR`) with
    /// the stack mode `stackMode`. The screen is captured in RGB when asked
    /// for 8 bits, for a colour image or a fusion, otherwise in 16 bits. In
    /// memory, a thick slab is 8 bits, in colour for the stack modes 4 and 5
    /// (the volume renderings).
    public func form(isRGB: Bool, fused: Bool, thickSlabVR: Bool, stackMode: Int) -> Form {
        if screenCapture {
            return force8bits || isRGB || fused ? .screenColour : .screenGrey16
        }
        var isRGB = isRGB, force8bits = force8bits
        if thickSlabVR {
            force8bits = true
            if stackMode == 4 || stackMode == 5 { isRGB = true }
        }
        if isRGB { return .colour }
        return force8bits ? .grey8 : .grey16
    }

    /// Whether an image in memory, `bitsPerSample` bits a sample, of pixels
    /// `spacingX` × `spacingY`, is resampled to square pixels.
    public func squaresPixels(bitsPerSample: Int, spacingX: Double, spacingY: Double) -> Bool {
        !screenCapture && squarePixels && bitsPerSample == 8 && spacingX != spacingY
    }

    /// The spacing of the colour screen capture, both ways: the image's
    /// horizontal spacing at the view's zoom.
    public static func screenSpacing(pixelSpacingX: Double, scale: Float) -> Float {
        Float(pixelSpacingX / Double(scale))
    }

    /// The rectangle and origin at which the 16-bit screen capture renders the
    /// image, at zoom 1: the image as shown, at full resolution, not less, not
    /// more.
    public static func fullResolution(frameSize: NSSize, origin: NSPoint, scale: Float) -> (size: NSSize, origin: NSPoint) {
        var size = frameSize, origin = origin
        size.width /= CGFloat(scale)
        size.height /= CGFloat(scale)
        origin.x /= CGFloat(scale)
        origin.y /= CGFloat(scale)
        return (size, origin)
    }

    /// The factor of the 16-bit samples: the SUV of a PET image (`suvFactor`
    /// times the image's `slope`), 1 for any other modality.
    public static func sampleSlope(modality: String?, suvFactor: Float, slope: Float) -> Float {
        modality == "PT" ? suvFactor * slope : 1
    }

    /// Whether the colour screen capture reads the frame inverted: the
    /// inverted colours of the viewers, but not while the view exports.
    public static func readsInverted(invertColors: Bool, stringID: String?) -> Bool {
        invertColors && stringID != "export"
    }

    /// The value of the pixels of a colour screen capture outside the frame:
    /// white on a white background showing an image, black otherwise, swapped
    /// when the frame is read inverted.
    public static func clearValue(whiteBackground: Bool, showsImage: Bool, inverted: Bool) -> UInt8 {
        (whiteBackground && showsImage) != inverted ? 255 : 0
    }

    // MARK: - Thumbnails

    /// What becomes of a capture when a thumbnail of `size` pixels is asked.
    public enum Thumbnail: Sendable, Equatable {
        /// No thumbnail asked: the capture as it is.
        case asCaptured
        /// Only an RGB capture is reduced: this one stays as it is.
        case notResized
        /// The `side` × `side` thumbnail of the centre of the capture.
        case square(side: Int)
    }

    public static func thumbnail(size: Int32, samplesPerPixel: Int) -> Thumbnail {
        guard size != 0 else { return .asCaptured }
        return samplesPerPixel == 3 ? .square(side: Int(size)) : .notResized
    }

    /// The geometry of the thumbnail of a `width` × `height` capture in a
    /// secondary capture: where the square it is made from starts (its origin
    /// in the view, from the top left) and the factor its spacing is divided by.
    public static func thumbnailGeometry(width: Int, height: Int, size: Int32) -> (origin: NSPoint, rescale: Float) {
        let square = CaptureRaster.centredSquare(width: width, height: height)
        let rescale = Float(size) / Float(width > height ? height : width)
        return (NSPoint(x: Double(width - square.side) / 2.0, y: Double(height - square.side) / 2.0), rescale)
    }

    // MARK: - Several viewers

    /// Whether the views of several viewers, with their rectangles on screen,
    /// are captured in one picture: more than one, each with its rectangle.
    public static func assemblesViews(viewCount: Int, rectCount: Int) -> Bool {
        viewCount > 1 && viewCount == rectCount
    }

    /// The bytes allocated for the picture of several views, `width` ×
    /// `height`, with a margin of 4 pixels each way.
    public static func canvasByteCount(width: Int, height: Int, samplesPerPixel: Int, bitsPerSample: Int) -> Int {
        (4 + width) * (4 + height) * samplesPerPixel * bitsPerSample / 8
    }

    /// Whether two views have different spacings: the picture of several
    /// views then has none.
    public static func spacingsDiffer(_ spacing: (x: Float, y: Float), _ other: (x: Float, y: Float)) -> Bool {
        abs(Double(spacing.x - other.x)) > 0.005 || abs(Double(spacing.y - other.y)) > 0.005
    }

    /// The order in which the windows of several viewers, by their frames on
    /// screen (y up), are captured: from the top left to the bottom right.
    /// Each turn takes, among the windows left, the highest one, then the one
    /// most to its left among those no lower than it. Returns indices into
    /// `frames`.
    public static func readingOrder(of frames: [NSRect]) -> [Int] {
        var remaining = Array(frames.indices)
        var order: [Int] = []
        for _ in 0..<remaining.count {
            var index = 0
            var minY = Float(frames[remaining[0]].origin.y)
            for x in 0..<remaining.count where frames[remaining[x]].origin.y > CGFloat(minY) {
                minY = Float(frames[remaining[x]].origin.y)
                index = x
            }
            var minX = Float(frames[remaining[index]].origin.x)
            for x in 0..<remaining.count {
                let frame = frames[remaining[x]]
                if frame.origin.x < CGFloat(minX) && frame.origin.y >= CGFloat(minY) {
                    minX = Float(frame.origin.x)
                    index = x
                }
            }
            order.append(remaining.remove(at: index))
        }
        return order
    }

    /// The rectangle of a viewer's view in the picture of several viewers, in
    /// screen pixels: the view's bounds, the whole grid of tiles when `tiles`
    /// is given (the preferences include all the tiled views), placed at
    /// `screenOrigin` (where the bounds' origin is on screen), made integral,
    /// at the window's `backingScale`.
    public static func capturedRect(viewBounds: NSRect, screenOrigin: NSPoint, tiles: TileGrid?,
                                    backingScale: CGFloat) -> NSRect {
        var bounds = viewBounds
        if let tiles {
            bounds.size.width *= CGFloat(tiles.columns)
            bounds.size.height *= CGFloat(tiles.rows)
        }
        bounds.origin = screenOrigin
        bounds = NSIntegralRect(bounds)
        bounds.origin.x *= backingScale
        bounds.origin.y *= backingScale
        bounds.size.width *= backingScale
        bounds.size.height *= backingScale
        return bounds
    }

    // MARK: - Secondary capture

    /// Whether the DICOM file of a secondary capture gets the picture's
    /// spacing and origin: whenever asked. The former test also looked at the
    /// values, but its origin part (origin x different from 0, from 1 or
    /// from 2) is always true.
    public static func writesSpacingAndOrigin(asked: Bool) -> Bool {
        asked
    }

    /// The colour bars shown while a secondary capture is taken: the current
    /// ones when the preferences keep them (keepCLUTBarsForSecondaryCapture),
    /// `hidden` otherwise. The annotations are reduced to the graphics.
    public static func secondaryCaptureBars(keepsCLUTBars: Bool, current: Int, hidden: Int) -> Int {
        keepsCLUTBars ? current : hidden
    }

    // MARK: - Copy

    /// Whether a copy hides the frame of the selected view first: when the
    /// view has no identifier of its own and shows what it draws.
    public static func copyMarksViews(stringID: String?, originalSize: Bool) -> Bool {
        stringID == nil && !originalSize
    }

    /// Whether a copy takes every 2D viewer shown: asked, from a 2D viewer,
    /// with more than one open.
    public static func copiesAllViewers(twoDViewer: Bool, allViewers: Bool, viewerCount: Int) -> Bool {
        twoDViewer && allViewers && viewerCount > 1
    }
}
