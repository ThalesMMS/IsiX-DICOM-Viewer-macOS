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

import Cocoa

// The file-level static of the former NavigatorView.m.
private let deg2rad: Float = Float(Double.pi / 180.0)

// max size of the thumbnails in pixels
private let thumbnailMaxHeight: Int32 = 100
private let thumbnailMaxWidth: Int32 = 100

// maximum number of thumbnails displayed at the same time in the view
private let maxThumbRow: Int32 = 10
private let maxThumbColumn: Int32 = 20

// lateral scroll bar size
private let lateralScrollBarSize: Int32 = 20

// MouseEventType's constants (NavigatorView.h), read at file scope: inside an
// NSView, `rotate` would name -rotateByDegrees:.
private let mouseZoom: MouseEventType = zoom
private let mouseTranslate: MouseEventType = translate
private let mouseWLWW: MouseEventType = wlww
private let mouseRotate: MouseEventType = rotate
private let mouseIdle: MouseEventType = idle

// The OpenGL enumerants ROICanvasGL.h names, which Swift cannot import: that
// header imports Horos-Swift.h.
private let GL_LINE_LOOP: UInt32 = 0x0002
private let GL_POLYGON: UInt32 = 0x0009
private let GL_LINE_SMOOTH: UInt32 = 0x0B20
private let GL_POLYGON_SMOOTH: UInt32 = 0x0B41
private let GL_BLEND: UInt32 = 0x0BE2
private let GL_SRC_ALPHA: UInt32 = 0x0302
private let GL_ONE_MINUS_SRC_ALPHA: UInt32 = 0x0303

// The static inline functions of ROICanvasGL.h, with the same parameter types:
// an argument goes through a float, as it did.
private func roiBegin(_ mode: UInt32) { ROICanvas.current?.begin(mode) }
private func roiEnd() { ROICanvas.current?.end() }
private func roiVertex2f(_ x: Float, _ y: Float) { ROICanvas.current?.vertex(x: CGFloat(x), y: CGFloat(y)) }
private func roiColor3f(_ r: Float, _ g: Float, _ b: Float) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: 1)
}
private func roiColor4f(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: CGFloat(a))
}
private func roiLineWidth(_ w: Float) { ROICanvas.current?.lineWidth(CGFloat(w)) }
private func roiEnable(_ cap: UInt32) { ROICanvas.current?.enable(cap) }
private func roiDisable(_ cap: UInt32) { ROICanvas.current?.disable(cap) }
private func roiBlendFunc(_ source: UInt32, _ destination: UInt32) { ROICanvas.current?.blend(source: source, destination: destination) }
private func roiScalef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.scale(x: Double(x), y: Double(y), z: Double(z)) }
private func roiTranslatef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.translate(x: Double(x), y: Double(y), z: Double(z)) }
private func roiRotatef(_ angle: Float, _ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.rotate(Double(z < 0 ? -angle : angle)) }

/// A float converted to int as the arm64 code of the former C did (fcvtzs):
/// toward zero, saturated, NaN to 0; a Swift conversion traps instead.
private func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

/// The same for a conversion to NSInteger.
private func cLong(_ x: Double) -> Int {
    if x.isNaN { return 0 }
    if x >= 9223372036854775807.0 { return Int.max }
    if x <= -9223372036854775808.0 { return Int.min }
    return Int(x)
}

/// `[array count]-z-1` of the former C: NSUInteger arithmetic, wrapping.
private func countMinus(_ count: Int, _ z: Int32) -> UInt {
    return UInt(bitPattern: count) &- UInt(bitPattern: Int(z)) &- 1
}

/// `x*thumbnailWidth` with an NSUInteger x: the int is converted to NSUInteger.
private func unsignedProduct(_ x: UInt, _ size: Int32) -> CGFloat {
    return CGFloat(x &* UInt(bitPattern: Int(size)))
}

/// -[ViewerController volumeData:], as the NSData object the viewer holds: Swift
/// would import it as a Data, a copy, and the former code compared the objects
/// and handed them to the new viewer.
private func volumeDataObject(_ viewer: ViewerController?, _ i: Int) -> NSData? {
    guard let viewer = viewer else { return nil }
    typealias Imp = @convention(c) (AnyObject, Selector, Int) -> Unmanaged<NSData>?
    let selector = NSSelectorFromString("volumeData:")
    return unsafeBitCast(viewer.method(for: selector), to: Imp.self)(viewer, selector, i)?.takeUnretainedValue()
}

/// +[ViewerController newWindow:::], with the viewer's own NSData. The former
/// code never released what it answered: Swift does not take it over either.
private func newViewerWindow(_ pixList: NSMutableArray?, _ fileList: NSMutableArray?, _ volumeData: NSData?) -> ViewerController? {
    typealias Imp = @convention(c) (AnyObject, Selector, NSMutableArray?, NSMutableArray?, NSData?) -> Unmanaged<ViewerController>?
    let selector = NSSelectorFromString("newWindow:::")
    let viewerClass: AnyClass = ViewerController.self
    guard let method = class_getClassMethod(viewerClass, selector) else { return nil }
    return unsafeBitCast(method_getImplementation(method), to: Imp.self)(viewerClass, selector, pixList, fileList, volumeData)?.takeUnretainedValue()
}

/// -[ViewerController addMovieSerie:::], with the viewer's own NSData.
private func addMovieSerie(_ viewer: ViewerController?, _ f: NSMutableArray?, _ d: NSMutableArray?, _ v: NSData?) {
    guard let viewer = viewer else { return }
    typealias Imp = @convention(c) (AnyObject, Selector, NSMutableArray?, NSMutableArray?, NSData?) -> Void
    let selector = NSSelectorFromString("addMovieSerie:::")
    unsafeBitCast(viewer.method(for: selector), to: Imp.self)(viewer, selector, f, d, v)
}

/// -[NSMutableDictionary setObject:forKey:], which raises for a nil key as the
/// former code did.
private func setObject(_ dictionary: NSMutableDictionary?, _ object: Any?, _ key: Any?) {
    _ = dictionary?.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: object, with: key)
}

/// [[[AppController sharedAppController] viewerScreens] objectAtIndex: 0],
/// which raises without a screen as it did.
@MainActor private func firstViewerScreen() -> NSScreen? {
    let screens = (AppController.shared()?.viewerScreens() ?? []) as NSArray
    return screens.object(at: 0) as? NSScreen
}

/// The view of the Navigator: the thumbnails of every slice (columns) and every
/// movie frame (rows) of the viewer's series.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/NavigatorView.h> are those of the former class, the customClass of
/// the view in Navigator.xib. MouseEventType stays declared in NavigatorView.h.
///
/// The whole view is drawn on a Core Graphics canvas: the thumbnails as
/// the intensity textures OpenGL drew, then the ROIs, the frames and the
/// scroll bars, with the same calls; the canvas is shown over the visible rect.
@objc(NavigatorView)
public final class NavigatorView: NSView, NSWindowDelegate {
    @objc public private(set) var thumbnailWidth: Int32 = 0
    @objc public private(set) var thumbnailHeight: Int32 = 0
    private var sizeFactor: Float = 0

    private var mouseDownPosition = NSPoint.zero, mouseDraggedPosition = NSPoint.zero, mouseMovedPosition = NSPoint.zero
    private var userAction = MouseEventType(rawValue: 0)
    private var offset = NSPoint.zero, translation = NSPoint.zero
    private var rotationAngle: Float = 0, zoomFactor: Float = 0

    private var dontListenToNotification: Int32 = 0
    private var wl: Float = 0, ww: Float = 0, startWL: Float = 0, startWW: Float = 0
    private var isTextureWLWWUpdated: NSMutableArray?

    private var drawLeftLateralScrollBar = false, drawRightLateralScrollBar = false
    private var scrollTimer: Timer?

    private var cursorTracking: NSTrackingArea?

    private var previousImageIndex: Int32 = 0, previousMovieIndex: Int32 = 0

    private var mouseDragged = false, mouseClickedWithCommandKey = false

    private var savedTransformDict: NSMutableDictionary?

    private var roiCanvas: ROICanvas?

    @objc(minimumWindowHeight)
    public dynamic func minimumWindowHeight() -> Int32 {
        var scrollbarShift = thumbnailHeight
        //if( [[[[self viewer] window] screen] visibleFrame].size.width < [[self window] maxSize].width) scrollbarShift += 12;
        if (self.viewer()?.window?.screen?.visibleFrame ?? .zero).size.width < self.frame.size.width { scrollbarShift += 12 }
        return 16 + scrollbarShift
    }

    @objc(rect)
    public class func rect() -> NSRect {
        if let navigator = NavigatorWindowController.navigatorWindowController() {
            let n = navigator.navigatorView
            let v = navigator.viewerController
            var rect = NSRect.zero

            rect.size.width = n?.window?.maxSize.width ?? 0
            rect.size.height = CGFloat(Int32(v?.maxMovieIndex() ?? 0) * (n?.thumbnailHeight ?? 0))

            let screen = firstViewerScreen()

            if rect.size.width > (screen?.visibleFrame ?? .zero).size.width { rect.size.width = (screen?.visibleFrame ?? .zero).size.width }
            if rect.size.height > (screen?.visibleFrame ?? .zero).size.height / 2 { rect.size.height = (screen?.visibleFrame ?? .zero).size.height / 2 }

            rect.origin.x = (screen?.visibleFrame ?? .zero).origin.x
            rect.origin.y = (screen?.visibleFrame ?? .zero).origin.y

            var scrollbarShift: Float = 0
            if rect.size.width < (n?.frame ?? .zero).size.width { scrollbarShift = 12 }

            rect.size.height += CGFloat(17 + scrollbarShift)

            return rect
        }

        return NSMakeRect(0, 0, 0, 0)
    }

    @objc(adjustIfScreenAreaIf4DNavigator:)
    public class func adjustIfScreenAreaIf4DNavigator(_ frame: NSRect) -> NSRect {
        var frame = frame
        if let navigator = NavigatorWindowController.navigatorWindowController() {
            let navRect = navigator.window?.frame ?? .zero

            let iRect = NSIntersectionRect(frame, navRect)

            if NSIsEmptyRect(iRect) == false {
                frame.size.height = frame.size.height - iRect.size.height
                frame.origin.y = iRect.origin.y + iRect.size.height
            }
        }

        return frame
    }

    @objc(removeNotificationObserver)
    public dynamic func removeNotificationObserver() {
        dontListenToNotification += 1
    }

    @objc(addNotificationObserver)
    public dynamic func addNotificationObserver() {
        dontListenToNotification -= 1
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)

        userAction = mouseIdle
        translation = NSMakePoint(0, 0)
        offset = NSMakePoint(0, 0)
        sizeFactor = 1.0
        zoomFactor = 1.0

        drawLeftLateralScrollBar = false
        drawRightLateralScrollBar = false

        previousImageIndex = -1
        previousMovieIndex = -1

        savedTransformDict = NSMutableDictionary()

        //		previousViewer = nil;

        let cursorTracking = NSTrackingArea(rect: self.visibleRect, options: [.activeWhenFirstResponder, .inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        self.cursorTracking = cursorTracking
        self.addTrackingArea(cursorTracking)

        NotificationCenter.default.addObserver(self, selector: #selector(changeWLWW(_:)), name: NSNotification.Name.OsirixChangeWLWW, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh(_:)), name: NSNotification.Name.OsirixDCMViewIndexChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshROIs(_:)), name: NSNotification.Name.OsirixRemoveROI, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshROIs(_:)), name: NSNotification.Name.OsirixROIChange, object: nil)

        self.window?.delegate = self
    }

    /// The former class did not override -initWithCoder:, NSView's ran, with
    /// every ivar 0.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func awakeFromNib() {
        MainActor.assumeIsolated {
            self.enclosingScrollView?.backgroundColor = NSColor.black

            // The picture is laid out on the visible rect, as OpenGL's viewport was:
            // scrolling or resizing redraws all of it.
            let clipView = self.enclosingScrollView?.contentView
            clipView?.postsBoundsChangedNotifications = true
            clipView?.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(visibleRectChanged(_:)), name: NSView.boundsDidChangeNotification, object: clipView)
            NotificationCenter.default.addObserver(self, selector: #selector(visibleRectChanged(_:)), name: NSView.frameDidChangeNotification, object: clipView)
        }
    }

    @objc(visibleRectChanged:)
    private func visibleRectChanged(_ notification: Notification?) {
        self.needsDisplay = true
    }

    isolated deinit {
        roiCanvas = nil
        NSLog("NavigatorView dealloc")
        NotificationCenter.default.removeObserver(self)
        isTextureWLWWUpdated = nil
        savedTransformDict = nil

        //	[previousViewer release];

        if let timer = scrollTimer {
            timer.invalidate()
            scrollTimer = nil
        }

        cursorTracking = nil
    }

    @objc(setViewer)
    public dynamic func setViewer() {
        wl = self.viewer()?.imageView()?.curWL ?? 0
        ww = self.viewer()?.imageView()?.curWW ?? 0
        self.initTextureArray()
        self.computeThumbnailSize()
        self.frame = NSMakeRect(0.0, 0.0, unsignedProduct(UInt(bitPattern: self.viewer()?.pixList()?.count ?? 0), thumbnailWidth), CGFloat(Int32(self.viewer()?.maxMovieIndex() ?? 0) * thumbnailHeight))
        previousImageIndex = -1
        previousMovieIndex = -1
        //	[previousViewer release];
        //	previousViewer = [[self viewer] retain];
        self.loadTransformForCurrentViewer()
        self.needsDisplay = true
    }

    @objc(initTextureArray)
    public dynamic func initTextureArray() {
        if isTextureWLWWUpdated == nil {
            isTextureWLWWUpdated = NSMutableArray()
        } else {
            isTextureWLWWUpdated?.removeAllObjects()
        }

        var t: Int32 = 0
        while t < Int32(self.viewer()?.maxMovieIndex() ?? 0) {
            let pixList = self.viewer()?.pixList(Int(t))
            var z: Int32 = 0
            while Int(z) < (pixList?.count ?? 0) {
                isTextureWLWWUpdated?.add(NSNumber(value: false))
                z += 1
            }
            t += 1
        }
    }

    @objc(thumbnailPixForSlice:movieIndex:arrayIndex:)
    public dynamic func thumbnailPix(forSlice z: Int32, movieIndex t: Int32, arrayIndex i: Int32) -> DCMPix? {
        if isTextureWLWWUpdated == nil || UInt(bitPattern: Int(i)) >= UInt(isTextureWLWWUpdated?.count ?? 0) { self.initTextureArray() }

        let pix = self.viewer()?.pixList(Int(t))?.object(at: Int(z)) as? DCMPix

        if !((isTextureWLWWUpdated?.object(at: Int(i)) as? NSNumber)?.boolValue ?? false) {
            pix?.changeWLWW(wl, ww)
            isTextureWLWWUpdated?.replaceObject(at: Int(i), with: NSNumber(value: true))
        }

        return pix
    }

    @objc(computeThumbnailSize)
    public dynamic func computeThumbnailSize() {
        // we consider that every image has the same size
        let aPix = self.viewer()?.pixList()?.object(at: 0) as? DCMPix
        let width = Int32(truncatingIfNeeded: aPix?.pwidth ?? 0)
        let height = cInt32(Double(aPix?.pheight ?? 0) * (aPix?.pixelRatio ?? 0))

        let wFactor = Float(width) / Float(thumbnailMaxWidth)
        let hFactor = Float(height) / Float(thumbnailMaxHeight)
        let factor = (wFactor > hFactor) ? wFactor : hFactor
        // Without a viewer, or with an image of no size, the factor is zero, and
        // the sizes and the offsets were divided by it: they stay as they are.
        guard factor > 0 else { return }
        sizeFactor = factor

        thumbnailWidth = cInt32(Double(Float(width) / sizeFactor))
        thumbnailHeight = cInt32(Double(Float(height) / sizeFactor))

        self.enclosingScrollView?.horizontalPageScroll = CGFloat(thumbnailWidth)
        self.enclosingScrollView?.horizontalLineScroll = CGFloat(thumbnailWidth)

        self.enclosingScrollView?.verticalPageScroll = CGFloat(thumbnailHeight)
        self.enclosingScrollView?.verticalLineScroll = CGFloat(thumbnailHeight)
    }

    // MARK: - Drawing

    // Shows what the canvas drew, premultiplied pixels with rows from the top, on
    // the black the OpenGL view cleared to: the canvas is the clip view's size, its
    // top on the top of the visible rect, where the mouse locations are read from.
    @objc(presentCanvasIn:clipSize:)
    private func presentCanvas(in visible: NSRect, clipSize: NSSize) {
        NSColor.black.set()
        visible.fill(using: .copy) // NSRectFill

        guard let roiCanvas = roiCanvas, let pixels = roiCanvas.pixels, !NSIsEmptyRect(roiCanvas.drawnRect) else {
            return
        }

        let w = roiCanvas.pixelWidth, h = roiCanvas.pixelHeight
        let space = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(dataInfo: nil, data: UnsafeRawPointer(pixels), size: w * h * 4, releaseData: { _, _, _ in }),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: NSMinX(visible), y: NSMaxY(visible) - clipSize.height, width: clipSize.width, height: clipSize.height))
        context.restoreGState()
    }

    public override func draw(_ dirtyRect: NSRect) {
        let clipView = self.enclosingScrollView?.contentView
        let visible = clipView?.documentVisibleRect ?? .zero
        let viewBounds = self.convertToBacking(visible)
        let viewFrame = self.convertToBacking(clipView?.frame ?? .zero)
        let viewSize = viewFrame.size

        let scaledThumbnailWidth = Float(Double(thumbnailWidth) * Double(self.window?.backingScaleFactor ?? 0))
        let scaledThumbnailHeight = Float(Double(thumbnailHeight) * Double(self.window?.backingScaleFactor ?? 0))

        if roiCanvas == nil { roiCanvas = ROICanvas() }
        roiCanvas?.beginFrame(width: cLong(Double(viewSize.width)), height: cLong(Double(viewSize.height)), colorSpace: nil)
        ROICanvas.current = roiCanvas

        // The projection the OpenGL view set: pixels from the top left.
        roiCanvas?.set(modelview: CGAffineTransform(a: 2.0 / (viewSize.width), b: 0, c: 0, d: -2.0 / (viewSize.height), tx: -1, ty: 1), viewport: NSMakeRect(0, 0, viewSize.width, viewSize.height))

        var i: Int32 = 0
        var upperLeft = NSPoint.zero
        var thumbRect = NSRect.zero

        let associatedViewers = self.associatedViewers() ?? NSArray()

        do {
            var t: Int32 = 0
            while t < Int32(self.viewer()?.maxMovieIndex() ?? 0) {
                var highlightLine = false

                if t == Int32(self.viewer()?.curMovieIndex() ?? 0) {
                    highlightLine = true
                } else {
                    // associated Viewers
                    for case let v as ViewerController in associatedViewers {
                        if t == Int32(v.curMovieIndex()) { highlightLine = true }
                    }
                }

                if self.viewer()?.isPlaying4D() ?? false { highlightLine = true }

                var highlightThumbnail = false
                let pixList = self.viewer()?.pixList(Int(t))

                let flippedData = self.viewer()?.imageView()?.flippedData ?? false

                var z: Int32 = 0
                while Int(z) < (pixList?.count ?? 0) {
                    highlightThumbnail = highlightLine || (Int(z) == (self.viewer()?.imageIndex() ?? 0))

                    // An intensity texture modulated by the colour: the others are at half brightness.
                    if highlightThumbnail {
                        roiColor4f(1.0, 1.0, 1.0, 1.0)
                    } else {
                        roiColor4f(0.5, 0.5, 0.5, 1.0)
                    }

                    upperLeft = NSMakePoint(CGFloat(Float(z) * scaledThumbnailWidth) - viewBounds.origin.x, CGFloat(Float(t) * scaledThumbnailHeight) + viewBounds.origin.y + viewSize.height - viewFrame.size.height)
                    thumbRect = NSMakeRect(upperLeft.x, upperLeft.y, CGFloat(scaledThumbnailWidth), CGFloat(scaledThumbnailHeight))

                    if NSIntersectsRect(thumbRect, viewFrame) {
                        let correctedZ = flippedData ? Int32(truncatingIfNeeded: countMinus(pixList?.count ?? 0, z)) : z

                        let pix = self.thumbnailPix(forSlice: correctedZ, movieIndex: t, arrayIndex: i)
                        if let pix = pix, let base = pix.baseAddr {
                            let thumbnail = UnsafePointer<UInt8>(OpaquePointer(base))

                            roiCanvas?.clip(to: thumbRect)

                            roiTranslatef(Float(upperLeft.x), Float(upperLeft.y), 0.0)
                            roiTranslatef(scaledThumbnailWidth / 2.0, scaledThumbnailHeight / 2.0, 0.0)
                            roiRotatef(-rotationAngle / deg2rad, 0.0, 0.0, 1.0)
                            roiScalef(1.0 / zoomFactor, 1.0 / zoomFactor, 1.0)
                            roiTranslatef(-scaledThumbnailWidth / 2.0, -scaledThumbnailHeight / 2.0, 0.0)
                            roiTranslatef(Float(-upperLeft.x), Float(-upperLeft.y), 0.0)

                            roiTranslatef(Float(-offset.x / CGFloat(sizeFactor)), Float(-offset.y / CGFloat(sizeFactor)), 0.0)

                            roiCanvas?.drawIntensity(thumbnail, width: pix.pwidth, height: pix.pheight, rowBytes: pix.pwidth,
                                                     x0: upperLeft.x, y0: upperLeft.y, x1: upperLeft.x + CGFloat(scaledThumbnailWidth), y1: upperLeft.y + CGFloat(scaledThumbnailHeight), interpolate: true)

                            roiCanvas?.clip(to: NSZeroRect)

                            roiTranslatef(Float(offset.x / CGFloat(sizeFactor)), Float(offset.y / CGFloat(sizeFactor)), 0.0)

                            roiTranslatef(Float(upperLeft.x), Float(upperLeft.y), 0.0)
                            roiTranslatef(scaledThumbnailWidth / 2.0, scaledThumbnailHeight / 2.0, 0.0)
                            roiScalef(zoomFactor, zoomFactor, 1.0)
                            roiRotatef(rotationAngle / deg2rad, 0.0, 0.0, 1.0)
                            roiTranslatef(-scaledThumbnailWidth / 2.0, -scaledThumbnailHeight / 2.0, 0.0)
                            roiTranslatef(Float(-upperLeft.x), Float(-(upperLeft.y)), 0.0)
                        }
                    }
                    i += 1
                    z += 1
                }
                t += 1
            }
        }

        if UserDefaults.standard.integer(forKey: "ANNOTATIONS") > annotNone {
            var t: Int32 = 0
            while t < Int32(self.viewer()?.maxMovieIndex() ?? 0) {
                let pixList = self.viewer()?.pixList(Int(t))
                let roiList = self.viewer()?.roiList(Int(t))

                let flippedData = self.viewer()?.imageView()?.flippedData ?? false

                var z: Int32 = 0
                while Int(z) < (pixList?.count ?? 0) {
                    let correctedZ = flippedData ? Int32(truncatingIfNeeded: countMinus(pixList?.count ?? 0, z)) : z
                    let pix = pixList?.object(at: Int(correctedZ)) as? DCMPix
                    upperLeft = NSMakePoint(CGFloat(Float(z) * scaledThumbnailWidth) - viewBounds.origin.x, CGFloat(Float(t) * scaledThumbnailHeight) + viewBounds.origin.y + viewSize.height - viewFrame.size.height)

                    roiCanvas?.clip(to: NSMakeRect(upperLeft.x, upperLeft.y, CGFloat(scaledThumbnailWidth), CGFloat(scaledThumbnailHeight)))

                    let rois = roiList?.object(at: Int(correctedZ)) as? NSArray

                    roiTranslatef(Float(upperLeft.x), Float(upperLeft.y), 0.0)
                    roiTranslatef(scaledThumbnailWidth / 2.0, scaledThumbnailHeight / 2.0, 0.0)
                    roiRotatef(-rotationAngle / deg2rad, 0.0, 0.0, 1.0)

                    if (pix?.pixelRatio ?? 0) != 1.0 { roiScalef(1.0, Float(pix?.pixelRatio ?? 0), 1.0) }

                    let f = Float(self.window?.backingScaleFactor ?? 0)

                    for case let r as ROI in rois ?? NSArray() {
                        roiColor4f(1.0, 1.0, 1.0, 1.0)

                        if r.type != .tText {
                            let pwidth = Double(pix?.pwidth ?? 0), pheight = Double(pix?.pheight ?? 0), pixelRatio = pix?.pixelRatio ?? 0
                            r.draw(withScaleValue: f / (zoomFactor * sizeFactor),
                                   offsetX: Float(Double(offset.x) / Double(f) + pwidth / 2.0),
                                   offsetY: Float(Double(offset.y) / (Double(f) * pixelRatio) + pheight / 2.0),
                                   pixelSpacingX: Float(pix?.pixelSpacingX ?? 0), pixelSpacingY: Float(pix?.pixelSpacingY ?? 0),
                                   highlightIfSelected: false, thickness: 1.0, prepareTextualData: false)
                        }
                    }

                    roiCanvas?.clip(to: NSZeroRect)

                    if (pix?.pixelRatio ?? 0) != 1.0 { roiScalef(1.0, Float(1.0 / (pix?.pixelRatio ?? 0)), 1.0) }
                    roiRotatef(rotationAngle / deg2rad, 0.0, 0.0, 1.0)
                    roiTranslatef(-scaledThumbnailWidth / 2.0, -scaledThumbnailHeight / 2.0, 0.0)
                    roiTranslatef(Float(-upperLeft.x), Float(-(upperLeft.y)), 0.0)
                    z += 1
                }
                t += 1
            }
        }

        // draw selection
        roiEnable(GL_LINE_SMOOTH)

        // associated Viewers
        for case let v as ViewerController in self.associatedViewers() ?? NSArray() {
            let t = Int32(v.curMovieIndex())
            upperLeft.y = CGFloat(Float(t) * scaledThumbnailHeight) + viewBounds.origin.y + viewSize.height - viewFrame.size.height

            let z = Int32(truncatingIfNeeded: v.imageIndex())
            upperLeft.x = CGFloat(Float(z) * scaledThumbnailWidth) - viewBounds.origin.x
            thumbRect = NSMakeRect(upperLeft.x, upperLeft.y, CGFloat(scaledThumbnailWidth), CGFloat(scaledThumbnailHeight))

            if NSIntersectsRect(thumbRect, viewFrame) {
                roiCanvas?.clip(to: thumbRect)

                roiLineWidth(Float(6.0 * Double(self.window?.backingScaleFactor ?? 0)))
                roiColor3f(0.0, 1.0, 0.0)
                roiBegin(GL_LINE_LOOP)
                    roiVertex2f(Float(upperLeft.x + 1), Float(upperLeft.y + 1))
                    roiVertex2f(Float(upperLeft.x - 1 + CGFloat(scaledThumbnailWidth)), Float(upperLeft.y + 1))
                    roiVertex2f(Float(upperLeft.x - 1 + CGFloat(scaledThumbnailWidth)), Float(upperLeft.y + CGFloat(scaledThumbnailHeight) - 1))
                    roiVertex2f(Float(upperLeft.x + 1), Float(upperLeft.y + CGFloat(scaledThumbnailHeight) - 1))
                roiEnd()
                roiCanvas?.clip(to: NSZeroRect)

                roiColor3f(0.0, 0.0, 0.0)
                roiLineWidth(Float(1.0 * Double(self.window?.backingScaleFactor ?? 0)))
            }
        }

        // selected time line
        let t = Int32(self.viewer()?.curMovieIndex() ?? 0)
        upperLeft.y = CGFloat(Float(t) * scaledThumbnailHeight) + viewBounds.origin.y + viewSize.height - viewFrame.size.height

        // selected image
        let z = Int32(truncatingIfNeeded: self.viewer()?.imageIndex() ?? 0)
        upperLeft.x = CGFloat(Float(z) * scaledThumbnailWidth) - viewBounds.origin.x
        thumbRect = NSMakeRect(upperLeft.x, upperLeft.y, CGFloat(scaledThumbnailWidth), CGFloat(scaledThumbnailHeight))

        if NSIntersectsRect(thumbRect, viewFrame) {
            roiCanvas?.clip(to: thumbRect)

            roiLineWidth(Float(6.0 * Double(self.window?.backingScaleFactor ?? 0)))
            roiColor3f(1.0, 0.0, 0.0)
            roiBegin(GL_LINE_LOOP)
                roiVertex2f(Float(upperLeft.x + 1), Float(upperLeft.y + 1))
                roiVertex2f(Float(upperLeft.x - 1 + CGFloat(scaledThumbnailWidth)), Float(upperLeft.y + 1))
                roiVertex2f(Float(upperLeft.x - 1 + CGFloat(scaledThumbnailWidth)), Float(upperLeft.y + CGFloat(scaledThumbnailHeight) - 1))
                roiVertex2f(Float(upperLeft.x + 1), Float(upperLeft.y + CGFloat(scaledThumbnailHeight) - 1))
            roiEnd()
            roiCanvas?.clip(to: NSZeroRect)

            roiColor3f(0.0, 0.0, 0.0)
            roiLineWidth(Float(1.0 * Double(self.window?.backingScaleFactor ?? 0)))
        }

        roiDisable(GL_LINE_SMOOTH)

        // lateral scroll bar
        if drawLeftLateralScrollBar && self.cansScrollLeft() {
            // draw the dark part
            roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
            roiEnable(GL_BLEND)
            roiEnable(GL_POLYGON_SMOOTH)
            roiColor4f(0.0, 0.0, 0.0, 0.75)
            roiBegin(GL_POLYGON)
                roiVertex2f(0.0, 0.0)
                roiVertex2f(Float(lateralScrollBarSize), 0.0)
                roiVertex2f(Float(lateralScrollBarSize), Float(viewSize.height))
                roiVertex2f(0.0, Float(viewSize.height))
            roiEnd()

            // draw the triangle
            roiColor4f(1.0, 1.0, 1.0, 0.9)
            roiBegin(GL_POLYGON)
                roiVertex2f(Float(Double(lateralScrollBarSize) - 7.0), Float(viewBounds.size.height / 2.0 - 6.0))
                roiVertex2f(Float(Double(lateralScrollBarSize) - 7.0), Float(viewBounds.size.height / 2.0 + 6.0))
                roiVertex2f(3.0, Float(viewBounds.size.height / 2.0))
            roiEnd()
            roiColor3f(0.0, 0.0, 0.0)

            roiDisable(GL_BLEND)
            roiDisable(GL_POLYGON_SMOOTH)
        }

        if drawRightLateralScrollBar && self.cansScrollRight() {
            // draw the dark part
            roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
            roiEnable(GL_BLEND)
            roiEnable(GL_POLYGON_SMOOTH)
            roiColor4f(0.0, 0.0, 0.0, 0.75)
            roiBegin(GL_POLYGON)
                roiVertex2f(Float(viewBounds.size.width - CGFloat(lateralScrollBarSize)), 0.0)
                roiVertex2f(Float(viewBounds.size.width), 0.0)
                roiVertex2f(Float(viewBounds.size.width), Float(viewSize.height))
                roiVertex2f(Float(viewBounds.size.width - CGFloat(lateralScrollBarSize)), Float(viewSize.height))
            roiEnd()

            // draw the triangle
            roiColor4f(1.0, 1.0, 1.0, 0.9)
            roiBegin(GL_POLYGON)
                roiVertex2f(Float(viewBounds.size.width - CGFloat(lateralScrollBarSize) + 6.0), Float(viewBounds.size.height / 2.0 - 6.0))
                roiVertex2f(Float(viewBounds.size.width - CGFloat(lateralScrollBarSize) + 6.0), Float(viewBounds.size.height / 2.0 + 6.0))
                roiVertex2f(Float(viewBounds.size.width - 4.0), Float(viewBounds.size.height / 2.0))
            roiEnd()
            roiColor3f(0.0, 0.0, 0.0)

            roiDisable(GL_BLEND)
            roiDisable(GL_POLYGON_SMOOTH)
        }

        ROICanvas.current = nil
        self.presentCanvas(in: visible, clipSize: clipView?.bounds.size ?? .zero)
    }

    // MARK: - Mouse functions

    public override func acceptsFirstMouse(for theEvent: NSEvent?) -> Bool {
        return true
    }

    public override var acceptsFirstResponder: Bool {
        return false
    }

    @objc(convertPointFromWindowToViewport:)
    public dynamic func convertPointFromWindowToViewport(_ pointInWindow: NSPoint) -> NSPoint {
        var pointInView = self.convert(pointInWindow, from: nil)
        pointInView.x -= (self.enclosingScrollView?.contentView.documentVisibleRect ?? .zero).origin.x
        pointInView.y -= (self.enclosingScrollView?.contentView.documentVisibleRect ?? .zero).origin.y
        pointInView.y = (self.enclosingScrollView?.contentView.documentVisibleRect ?? .zero).size.height - pointInView.y

        pointInView = self.convertToBacking(pointInView)

        return pointInView
    }

    public override func mouseDown(with theEvent: NSEvent) {
        let event_location = theEvent.locationInWindow
        mouseDownPosition = self.convertPointFromWindowToViewport(event_location)
        mouseDragged = false

        let scrollLeft = self.isMouseOnLeftLateralScrollBar(self.convertFromBacking(mouseDownPosition)) && self.cansScrollLeft()
        let scrollRight = self.isMouseOnRightLateralScrollBar(self.convertFromBacking(mouseDownPosition)) && self.cansScrollRight()

        mouseClickedWithCommandKey = false

        if theEvent.modifierFlags.contains(.shift) {
            userAction = mouseZoom
        } else if theEvent.modifierFlags.contains(.option) && theEvent.modifierFlags.contains(.command) {
            userAction = mouseRotate
        } else if theEvent.modifierFlags.contains(.command) {
            userAction = mouseTranslate
            mouseClickedWithCommandKey = true
        } else if theEvent.modifierFlags.contains(.option) {
            userAction = mouseWLWW
        } else {
            if !scrollLeft && !scrollRight { self.displaySelectedViewInNewWindow(false) }
            userAction = MouseEventType(rawValue: Int32(self.viewer()?.imageView()?.currentTool.rawValue ?? 0))
        }

        startWW = ww
        startWL = wl

        if scrollLeft && scrollTimer == nil {
            scrollTimer = Timer.scheduledTimer(timeInterval: 0.01, target: self, selector: #selector(NavigatorView.scrollLeft(_:)), userInfo: nil, repeats: true)
        } else if scrollRight && scrollTimer == nil {
            scrollTimer = Timer.scheduledTimer(timeInterval: 0.01, target: self, selector: #selector(NavigatorView.scrollRight(_:)), userInfo: nil, repeats: true)
        }

        if scrollLeft || scrollRight {
            userAction = mouseIdle
        }
    }

    public override func rightMouseDown(with theEvent: NSEvent) {
        let event_location = theEvent.locationInWindow
        mouseDownPosition = self.convertPointFromWindowToViewport(event_location)

        userAction = MouseEventType(rawValue: Int32(self.viewer()?.imageView()?.currentToolRight.rawValue ?? 0))
    }

    public override func mouseDragged(with theEvent: NSEvent) {
        let event_location = theEvent.locationInWindow
        mouseDraggedPosition = self.convertPointFromWindowToViewport(event_location)
        mouseDragged = true

        if userAction == mouseTranslate {
            self.translationFrom(mouseDownPosition, to: mouseDraggedPosition)
        } else if userAction == mouseRotate {
            self.rotateFrom(mouseDownPosition, to: mouseDraggedPosition)
        } else if userAction == mouseZoom {
            self.zoomFrom(mouseDownPosition, to: mouseDraggedPosition)
        } else if userAction == mouseWLWW {
            self.wlwwFrom(mouseDownPosition, to: mouseDraggedPosition)
        }

        if userAction != mouseWLWW { mouseDownPosition = mouseDraggedPosition }

        self.needsDisplay = true
    }

    public override func rightMouseDragged(with theEvent: NSEvent) {
        self.mouseDragged(with: theEvent)
    }

    public override func mouseUp(with theEvent: NSEvent) {
        let scrollLeft = self.isMouseOnLeftLateralScrollBar(self.convertFromBacking(mouseDownPosition)) && self.cansScrollLeft()
        let scrollRight = self.isMouseOnRightLateralScrollBar(self.convertFromBacking(mouseDownPosition)) && self.cansScrollRight()

        if !mouseDragged && !scrollLeft && !scrollRight {
            let newWindow = mouseClickedWithCommandKey
            self.displaySelectedViewInNewWindow(newWindow)
        }

        userAction = mouseIdle
        if let timer = scrollTimer {
            timer.invalidate()
            scrollTimer = nil
        }
    }

    public override func rightMouseUp(with theEvent: NSEvent) {
        self.mouseUp(with: theEvent)
    }

    @objc(translationFrom:to:)
    public dynamic func translationFrom(_ start: NSPoint, to stop: NSPoint) {
        translation.x = start.x - stop.x
        translation.y = start.y - stop.y

        translation = self.rotatePoint(translation, aroundPoint: NSMakePoint(0, 0), angle: rotationAngle)

        offset.x += translation.x * CGFloat(zoomFactor) * CGFloat(sizeFactor)
        offset.y += translation.y * CGFloat(zoomFactor) * CGFloat(sizeFactor)
    }

    @objc(rotateFrom:to:)
    public dynamic func rotateFrom(_ start: NSPoint, to stop: NSPoint) {
        rotationAngle = Float(Double(rotationAngle) + Double(stop.x - start.x) / (Double(sizeFactor) * 10.0))
    }

    @objc(rotatePoint:aroundPoint:angle:)
    public dynamic func rotatePoint(_ pt: NSPoint, aroundPoint c: NSPoint, angle a: Float) -> NSPoint {
        var pt = pt
        var rot = NSPoint.zero

        pt.x -= c.x
        pt.y -= c.y

        rot.x = CGFloat(cos(Double(a))) * pt.x - CGFloat(sin(Double(a))) * pt.y
        rot.y = CGFloat(sin(Double(a))) * pt.x + CGFloat(cos(Double(a))) * pt.y

        rot.x += c.x
        rot.y += c.y

        return rot
    }

    @objc(zoomFrom:to:)
    public dynamic func zoomFrom(_ start: NSPoint, to stop: NSPoint) {
        var zoom = Float(stop.y - start.y)
        zoom *= zoomFactor
        zoom = Float(Double(zoom) / 50.0)

        zoomFactor += zoom

        if Double(zoomFactor) < 0.01 { zoomFactor = Float(0.01) }
        if zoomFactor > 10 { zoomFactor = 10 }
    }

    @objc(zoomPoint:withCenter:factor:)
    public dynamic func zoomPoint(_ pt: NSPoint, withCenter c: NSPoint, factor f: Float) -> NSPoint {
        var pt = pt
        pt.x -= c.x
        pt.y -= c.y

        pt.x *= CGFloat(f)
        pt.y *= CGFloat(f)

        pt.x += c.x
        pt.y += c.y

        return pt
    }

    @objc(changeWLWW:)
    public dynamic func changeWLWW(_ notif: Notification?) {
        if dontListenToNotification > 0 { return }

        // The notification also comes with a blending DCMView, or with no
        // image, which were taken for an image of WL and WW 0.
        guard let pix = notif?.object as? DCMPix else { return }
        if pix.ww != ww || pix.wl != wl {
            ww = pix.ww
            wl = pix.wl
            var i = 0
            while i < (isTextureWLWWUpdated?.count ?? 0) {
                isTextureWLWWUpdated?.replaceObject(at: i, with: NSNumber(value: false))
                i += 1
            }
            self.needsDisplay = true

            for case let viewer as ViewerController in self.associatedViewers() ?? NSArray() {
                viewer.imageView()?.setWLWW(wl, ww)
            }
        }
    }

    @objc(refresh:)
    private func refresh(_ notif: Notification?) {
        if dontListenToNotification > 0 { return }

        let curImageIndex = Int32(truncatingIfNeeded: self.viewer()?.imageIndex() ?? 0)
        let curMovieIndex = Int32(self.viewer()?.curMovieIndex() ?? 0)
        if curImageIndex != previousImageIndex || curMovieIndex != previousMovieIndex {
            self.computeThumbnailSize()
            self.viewer()?.imageView()?.sendSyncMessage(0)
            self.displaySelectedImage()
            self.needsDisplay = true
            previousImageIndex = curImageIndex
            previousMovieIndex = curMovieIndex
        }
    }

    @objc(refreshROIs:)
    private func refreshROIs(_ notif: Notification?) {
        if dontListenToNotification > 0 { return }

        self.displaySelectedImage()
        self.needsDisplay = true
    }

    @objc(wlwwFrom:to:)
    public dynamic func wlwwFrom(_ start: NSPoint, to stop: NSPoint) {
        var WWAdapter = Float(Double(startWW) / 100.0)
        if Double(WWAdapter) < 0.001 { WWAdapter = Float(0.001) }

        wl = Float(Double(startWL) + Double(-(stop.y - start.y)) * Double(WWAdapter))
        ww = Float(Double(startWW) + Double(stop.x - start.x) * Double(WWAdapter))

        self.viewer()?.imageView()?.setWLWW(wl, ww)
        var i = 0
        while i < (isTextureWLWWUpdated?.count ?? 0) {
            isTextureWLWWUpdated?.replaceObject(at: i, with: NSNumber(value: false))
            i += 1
        }

        for case let viewer as ViewerController in self.associatedViewers() ?? NSArray() {
            viewer.imageView()?.setWLWW(wl, ww)
        }
    }

    public override func mouseMoved(with theEvent: NSEvent) {
        if !(self.window?.isVisible ?? false) {
            return
        }

        let event_location = theEvent.locationInWindow
        mouseMovedPosition = self.convertPointFromWindowToViewport(event_location)

        let leftLateralScrollBarAlreadyDrawn = drawLeftLateralScrollBar
        let rightLateralScrollBarAlreadyDrawn = drawRightLateralScrollBar

        drawLeftLateralScrollBar = false
        drawRightLateralScrollBar = false

        if self.isMouseOnLeftLateralScrollBar(mouseMovedPosition) {
            drawLeftLateralScrollBar = true
        } else if self.isMouseOnRightLateralScrollBar(mouseMovedPosition) {
            drawRightLateralScrollBar = true
        }

        if leftLateralScrollBarAlreadyDrawn != drawLeftLateralScrollBar || rightLateralScrollBarAlreadyDrawn != drawRightLateralScrollBar {
            self.needsDisplay = true
        }
    }

    public override func mouseExited(with theEvent: NSEvent) {
        let leftLateralScrollBarAlreadyDrawn = drawLeftLateralScrollBar
        let rightLateralScrollBarAlreadyDrawn = drawRightLateralScrollBar

        drawLeftLateralScrollBar = false
        drawRightLateralScrollBar = false

        if leftLateralScrollBarAlreadyDrawn != drawLeftLateralScrollBar || rightLateralScrollBarAlreadyDrawn != drawRightLateralScrollBar {
            self.needsDisplay = true
        }
    }

    // MARK: - Scroll functions

    @objc(isMouseOnLeftLateralScrollBar:)
    public dynamic func isMouseOnLeftLateralScrollBar(_ mousePos: NSPoint) -> Bool {
        let clipView = self.enclosingScrollView?.contentView
        let viewBounds = clipView?.documentVisibleRect ?? .zero
        var inZone = mousePos.x <= CGFloat(lateralScrollBarSize)
        inZone = inZone && mousePos.x >= 0
        inZone = inZone && mousePos.y + viewBounds.origin.y <= viewBounds.size.height
        inZone = inZone && mousePos.y + viewBounds.origin.y >= 0
        return inZone
    }

    @objc(isMouseOnRightLateralScrollBar:)
    public dynamic func isMouseOnRightLateralScrollBar(_ mousePos: NSPoint) -> Bool {
        let clipView = self.enclosingScrollView?.contentView
        let viewBounds = clipView?.documentVisibleRect ?? .zero
        var inZone = mousePos.x >= viewBounds.size.width - CGFloat(lateralScrollBarSize)
        inZone = inZone && mousePos.x <= viewBounds.size.width
        inZone = inZone && mousePos.y + viewBounds.origin.y <= viewBounds.size.height
        inZone = inZone && mousePos.y + viewBounds.origin.y >= 0
        return inZone
    }

    @objc(canScrollHorizontallyOfAmount:)
    public dynamic func canScrollHorizontallyOfAmount(_ amount: Float) -> Bool {
        let clipView = self.enclosingScrollView?.contentView
        let viewBounds = clipView?.documentVisibleRect ?? .zero
        let origin = viewBounds.origin

        var canScroll = true

        if amount < 0 {
            canScroll = (origin.x > 0)
        } else {
            canScroll = (origin.x + viewBounds.size.width < self.frame.size.width)
        }

        return canScroll
    }

    @objc(scrollHorizontallyOfAmount:)
    public dynamic func scrollHorizontallyOfAmount(_ amount: Float) {
        let clipView = self.enclosingScrollView?.contentView
        let viewBounds = clipView?.documentVisibleRect ?? .zero
        var newOrigin = viewBounds.origin
        newOrigin.x += CGFloat(amount)
        //	if([self needsHorizontalScroller])
        //		newOrigin.y += 20.0; // ... ?? don't know why, but it works...

        if newOrigin.x < 0 { newOrigin.x = 0.0 }
        if newOrigin.x + viewBounds.size.width > self.frame.size.width { newOrigin.x = self.frame.size.width - viewBounds.size.width }

        if newOrigin.x != viewBounds.origin.x {
            if let clipView = clipView {
                clipView.scroll(to: clipView.constrainBoundsRect(NSRect(origin: newOrigin, size: clipView.bounds.size)).origin) //scrollToPoint
                self.enclosingScrollView?.reflectScrolledClipView(clipView)
            }
        }
    }

    @objc(scrollLeft)
    public dynamic func scrollLeft() {
        self.scrollHorizontallyOfAmount(Float(-(self.enclosingScrollView?.horizontalPageScroll ?? 0)))
    }

    @objc(cansScrollLeft)
    public dynamic func cansScrollLeft() -> Bool {
        return self.canScrollHorizontallyOfAmount(Float(-(self.enclosingScrollView?.horizontalPageScroll ?? 0)))
    }

    @objc(scrollRight)
    public dynamic func scrollRight() {
        self.scrollHorizontallyOfAmount(Float(self.enclosingScrollView?.horizontalPageScroll ?? 0))
    }

    @objc(cansScrollRight)
    public dynamic func cansScrollRight() -> Bool {
        return self.canScrollHorizontallyOfAmount(Float(self.enclosingScrollView?.horizontalPageScroll ?? 0))
    }

    @objc(scrollLeft:)
    public dynamic func scrollLeft(_ theTimer: Timer?) {
        self.scrollLeft()
    }

    @objc(scrollRight:)
    public dynamic func scrollRight(_ theTimer: Timer?) {
        self.scrollRight()
    }

    public override func scrollWheel(with theEvent: NSEvent) {
        //float d = [theEvent deltaY];
        if theEvent.deltaY == 0 { return }
        //if( fabs( d) < 1.0) d = 1.0 * fabs( d) / d;

        self.viewer()?.imageView()?.scrollWheel(with: theEvent)

        if !theEvent.modifierFlags.contains(.option) {
            self.displaySelectedImage()
        }
    }

    @objc(displaySelectedImage)
    public dynamic func displaySelectedImage() {
        if self.viewer() == nil { return }

        let clipView = self.enclosingScrollView?.contentView
        let viewBounds = clipView?.documentVisibleRect ?? .zero
        let viewFrame = clipView?.frame ?? .zero

        let z = Int32(self.viewer()?.imageView()?.curImage ?? 0)
        let t = Int32(self.viewer()?.curMovieIndex() ?? 0)
        var upperLeft = NSPoint.zero
        upperLeft.x = CGFloat(z * thumbnailWidth)

        if self.viewer()?.imageView()?.flippedData ?? false { upperLeft.x = unsignedProduct(countMinus(self.viewer()?.pixList()?.count ?? 0, z), thumbnailWidth) }

        upperLeft.y = CGFloat((Int32(self.viewer()?.maxMovieIndex() ?? 0) - t) * thumbnailHeight) //-viewBounds.origin.y;

        let thumbRect = NSMakeRect(upperLeft.x, upperLeft.y - CGFloat(thumbnailHeight), CGFloat(thumbnailWidth), CGFloat(thumbnailHeight))
        let intersectionRect = NSIntersectionRect(thumbRect, viewBounds)

        if abs(intersectionRect.size.width) < CGFloat(thumbnailWidth) || abs(intersectionRect.size.height) < CGFloat(thumbnailHeight) {
            var scrollToMe = NSMakePoint(viewBounds.origin.x, viewBounds.origin.y)

            if thumbRect.origin.x < viewBounds.origin.x {
                scrollToMe.x = thumbRect.origin.x
            } else if thumbRect.origin.x + CGFloat(thumbnailWidth) > viewBounds.origin.x + viewBounds.size.width {
                scrollToMe.x = thumbRect.origin.x + thumbRect.size.width - viewFrame.size.width
            }
            if thumbRect.origin.y < viewBounds.origin.y {
                scrollToMe.y = thumbRect.origin.y
            } else if thumbRect.origin.y + CGFloat(thumbnailHeight) > viewBounds.origin.y + viewBounds.size.height {
                scrollToMe.y = thumbRect.origin.y + thumbRect.size.height - viewFrame.size.height
            }

            if let clipView = clipView {
                clipView.scroll(to: clipView.constrainBoundsRect(NSRect(origin: scrollToMe, size: clipView.bounds.size)).origin)

                self.enclosingScrollView?.reflectScrolledClipView(clipView)
            }
        }
    }

    @objc(needsHorizontalScroller)
    public dynamic func needsHorizontalScroller() -> Bool {
        return unsignedProduct(UInt(bitPattern: self.viewer()?.pixList()?.count ?? 0), thumbnailWidth) > (self.enclosingScrollView?.contentView.frame ?? .zero).size.width
    }

    // MARK: - New Viewers

    // current selected viewer
    @objc(viewer)
    public dynamic func viewer() -> ViewerController? {
        return NavigatorWindowController.navigatorWindowController()?.viewerController

        //	NSArray *displayed2DViewers = [ViewerController getDisplayed2DViewers];
        //
        //	for (ViewerController *v in displayed2DViewers)
        //	{
        //		if([[[v imageView] window] isMainWindow] && [v imageView].isKeyView)
        //			return v;
        //	}
        //
        //	if([displayed2DViewers count]) return [displayed2DViewers lastObject];
        //
        //	return previousViewer;
    }

    // associatedViewers are all the opened viewers that share the same NSData, i.e. same stack
    @objc(associatedViewers)
    public dynamic func associatedViewers() -> NSArray? {
        let associatedViewers = NSMutableArray()

        let displayed2DViewers = ViewerController.getDisplayed2DViewers() as NSArray?
        let mainViewer = self.viewer()

        for case let v as ViewerController in displayed2DViewers ?? NSArray() {
            if v.maxMovieIndex() == (mainViewer?.maxMovieIndex() ?? 0) && v !== mainViewer {
                var sameVolumeData = true
                var i: Int32 = 0
                while i < Int32(v.maxMovieIndex()) {
                    sameVolumeData = sameVolumeData && (volumeDataObject(v, Int(i)) === volumeDataObject(mainViewer, Int(i)))
                    i += 1
                }
                if sameVolumeData { associatedViewers.add(v) }
            }
        }

        return NSArray(array: associatedViewers as [AnyObject])
    }

    @objc(displaySelectedViewInNewWindow:)
    public dynamic func displaySelectedViewInNewWindow(_ newWindow: Bool) {
        let clipView = self.enclosingScrollView?.contentView
        let viewBounds = clipView?.documentVisibleRect ?? .zero
        let viewFrame = clipView?.frame ?? .zero
        let viewSize = viewFrame.size

        let position = self.convertFromBacking(mouseDownPosition)

        let z = cInt32(Double((position.x + viewBounds.origin.x) / CGFloat(thumbnailWidth)))
        let t = cInt32(Double((position.y + self.frame.size.height - viewSize.height - viewBounds.origin.y) / CGFloat(thumbnailHeight)))

        if !newWindow { //t == [[self viewer] curMovieIndex] || [[self viewer] isPlaying4D]) // same time line: select the clicked slice
            let view = self.viewer()?.imageView()
            if view?.flippedData ?? false {
                view?.setIndex(Int16(truncatingIfNeeded: countMinus(self.viewer()?.pixList()?.count ?? 0, z)))
            } else {
                view?.setIndex(Int16(truncatingIfNeeded: z))
            }

            if t != Int32(self.viewer()?.curMovieIndex() ?? 0) {
                var selectedViewer: ViewerController?
                var alreadyOpen = false
                for case let viewer as ViewerController in self.associatedViewers() ?? NSArray() {
                    if t == Int32(viewer.curMovieIndex()) {
                        selectedViewer = viewer
                        alreadyOpen = true
                    }
                }

                if !alreadyOpen {
                    self.viewer()?.setMovieIndex(Int16(truncatingIfNeeded: t))
                } else {
                    // select the correct slice
                    let view = selectedViewer?.imageView()
                    if view?.flippedData ?? false {
                        view?.setIndex(Int16(truncatingIfNeeded: countMinus(self.viewer()?.pixList()?.count ?? 0, z)))
                    } else {
                        view?.setIndex(Int16(truncatingIfNeeded: z))
                    }
                    // sync other viewers
                    view?.sendSyncMessage(0)
                    // make key viewer
                    selectedViewer?.window?.makeKey()
                    self.needsDisplay = true
                }
            }

            view?.sendSyncMessage(0)
        } else {
            dontListenToNotification += 1
            self.openNewViewer(atSlice: z, movieFrame: t) // creates a new viewer
            dontListenToNotification -= 1
        }
    }

    @objc(openNewViewerAtSlice:movieFrame:)
    public dynamic func openNewViewer(atSlice z: Int32, movieFrame t: Int32) {
        // create the new viewer
        let newViewer = newViewerWindow(self.viewer()?.pixList(0), self.viewer()?.fileList(0), volumeDataObject(self.viewer(), 0))

        // add all the 4D frames
        var i: Int32 = 1
        while i < Int32(self.viewer()?.maxMovieIndex() ?? 0) {
            addMovieSerie(newViewer, self.viewer()?.pixList(Int(i)), self.viewer()?.fileList(Int(i)), volumeDataObject(self.viewer(), Int(i)))
            i += 1
        }

        i = 0
        while i < Int32(self.viewer()?.maxMovieIndex() ?? 0) {
            newViewer?.setRoiList(Int(i), array: self.viewer()?.roiList(Int(i)))
            i += 1
        }

        newViewer?.setMovieIndex(Int16(truncatingIfNeeded: t))

        // select the correct slice
        let view = newViewer?.imageView()
        if self.viewer()?.imageView()?.flippedData ?? false {
            view?.setIndex(Int16(truncatingIfNeeded: countMinus(self.viewer()?.pixList()?.count ?? 0, z)))
        } else {
            view?.setIndex(Int16(truncatingIfNeeded: z))
        }

        // flippedData must be the same on all viewers
        view?.flippedData = self.viewer()?.imageView()?.flippedData ?? false

        newViewer?.adjustSlider()

        newViewer?.window?.makeKeyAndOrderFront(self)
        newViewer?.setWL(wl, ww: ww)
        newViewer?.propagateSettings()

        //[view sendSyncMessage:0];
        newViewer?.checkEverythingLoaded()
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        self.viewer()?.imageView()?.keyDown(with: event)
    }

    // MARK: - Saving Transformation Values

    /// The series' seriesInstanceUID, the key of the saved transforms.
    private func seriesInstanceUID() -> Any? {
        let pix = self.viewer()?.pixList(0)?.object(at: 0) as? DCMPix
        return pix?.seriesObj()?.value(forKey: "seriesInstanceUID")
    }

    @objc(saveTransformForCurrentViewer)
    public dynamic func saveTransformForCurrentViewer() {
        if self.viewer() == nil { return }
        let seriesInstanceUID = self.seriesInstanceUID()
        let currentTransform = NSMutableDictionary()
        currentTransform.setObject(NSNumber(value: zoomFactor), forKey: "zoomFactor" as NSString)
        currentTransform.setObject(NSNumber(value: rotationAngle), forKey: "rotationAngle" as NSString)
        currentTransform.setObject(NSValue(point: offset), forKey: "offset" as NSString)
        setObject(savedTransformDict, currentTransform, seriesInstanceUID)
    }

    @objc(loadTransformForCurrentViewer)
    public dynamic func loadTransformForCurrentViewer() {
        if self.viewer() == nil { return }
        let seriesInstanceUID = self.seriesInstanceUID()
        let currentTransform = seriesInstanceUID.flatMap { savedTransformDict?.object(forKey: $0) } as? NSDictionary
        if let currentTransform = currentTransform {
            zoomFactor = (currentTransform.object(forKey: "zoomFactor") as? NSNumber)?.floatValue ?? 0
            rotationAngle = (currentTransform.object(forKey: "rotationAngle") as? NSNumber)?.floatValue ?? 0
            offset = (currentTransform.object(forKey: "offset") as? NSValue)?.pointValue ?? .zero
        } else {
            zoomFactor = 1.0
            rotationAngle = 0.0
            offset = NSMakePoint(0, 0)
        }

        self.needsDisplay = true
    }
}
