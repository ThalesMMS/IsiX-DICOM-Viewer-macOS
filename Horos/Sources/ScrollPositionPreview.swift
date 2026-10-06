//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Cocoa

// The DCMView (HorosScrollPositionPreview) category is implemented in Swift:
// the extension at the end of this file declares its selectors,
// which <Horos/ScrollPositionPreview.h> brings in through the generated
// interface. The preview itself, HorosScrollPositionPreview, is private to it.

private let previewKey = IdentityToken()

private func HorosScrollPreviewIsEnabled(_ defaults: UserDefaults) -> Bool {
    // The argument domain stores command-line YES/NO as strings. Read using
    // the defaults boolean conversion, while keeping absence enabled.
    return defaults.object(forKey: "ShowScrollPositionPreview") == nil ||
           defaults.bool(forKey: "ShowScrollPositionPreview")
}

/// A BOOL method of an object typed `id`, sent by its selector as the former
/// code did (-[ViewerController windowWillClose]).
private func sendBool(_ target: AnyObject?, _ name: String) -> Bool {
    guard let target = target as? NSObject else {
        return false
    }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    let selector = NSSelectorFromString(name)
    return unsafeBitCast(target.method(for: selector), to: Getter.self)(target, selector)
}

@objc(HorosScrollPositionPreview)
final class HorosScrollPositionPreview: NSView {
    private unowned(unsafe) var _host: DCMView? = nil // The host owns this view and detaches it before destruction.
    private var _slices: NSMutableArray? = nil
    private var _reslicer: OrthogonalReslice? = nil
    private var _plane: DCMPix? = nil
    private var _image: NSImage? = nil
    private var _labels: NSArray? = nil
    private var _orientation = HorosPreviewOrientation()
    private var _physicalSize = NSSize.zero
    private var _windowPoint = NSPoint.zero, _marker = NSPoint.zero
    private var _axis = 0, _position = 0
    private var _level: Float = 0, _width: Float = 0
    private var _pending = false

    @objc(initWithHost:)
    init(host: DCMView) {
        _host = host
        super.init(frame: NSZeroRect)
        self.isHidden = true
        self.wantsLayer = true
        self.autoresizingMask = [.maxXMargin, .minYMargin]
        self.setAccessibilityLabel(NSLocalizedString("Scroll position preview", comment: ""))
        NotificationCenter.default.addObserver(self, selector: #selector(volumeChanged(_:)),
                                               name: NSNotification.Name.OsirixUpdateVolumeData, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed(_:)),
                                               name: NSWindow.willCloseNotification, object: host.window)
    }

    // NSView's, which the former class inherited and nothing uses.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isFlipped: Bool { return true }
    override func hitTest(_ point: NSPoint) -> NSView? { return nil }
    override var acceptsFirstResponder: Bool { return false }

    @objc(clearVolume)
    private func clearVolume() {
        _reslicer = nil
        _slices = nil
        _plane = nil
        _image = nil
        _labels = nil
        _position = -1
    }

    @objc(volumeChanged:)
    private func volumeChanged(_ note: NSNotification) {
        if (note.object as AnyObject?) !== _slices { return }
        if !Thread.isMainThread {
            self.performSelector(onMainThread: #selector(volumeChanged(_:)), with: note, waitUntilDone: false)
            return
        }
        hide()
        clearVolume()
    }

    @objc(windowClosed:)
    private func windowClosed(_ note: NSNotification) { detach() }

    @objc(detach)
    func detach() {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        NotificationCenter.default.removeObserver(self)
        _pending = false
        _host = nil
        clearVolume()
        removeFromSuperview()
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        clearVolume()
    }

    @objc(hide)
    func hide() {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        _pending = false
        let wasVisible = !self.isHidden
        self.isHidden = true
        if wasVisible { _host?.needsDisplay = true }
    }

    // Validate once for this slice list. The existing orthogonal reslicer requires
    // a loaded, regular parallel stack. Never trigger decoding during scrolling,
    // repair the source series, or present a misleading scout for mixed geometry.
    @objc(prepareVolume)
    private func prepareVolume() -> Bool {
        let slices: NSMutableArray? = _host?.dcmPixList
        if slices === _slices { return _reslicer != nil }
        clearVolume()
        guard let list = slices, list.count >= 2 else { return false }
        let first = list.firstObject as! DCMPix, last = list.lastObject as! DCMPix
        if !first.isLoaded() || first.isRGB || first.pwidth < 2 || first.pheight < 2 ||
            !first.pixelSpacingX.isFinite || first.pixelSpacingX <= 0 ||
            !first.pixelSpacingY.isFinite || first.pixelSpacingY <= 0 { return false }
        var o = [Float](repeating: 0, count: 9); first.orientation(&o)
        let count = Double(list.count - 1)
        let step: [Double] = [(last.originX - first.originX) / count,
                              (last.originY - first.originY) / count,
                              (last.originZ - first.originZ) / count]
        let interval = step[0]*Double(o[6]) + step[1]*Double(o[7]) + step[2]*Double(o[8])
        let usedInterval = first.sliceInterval != 0 ? first.sliceInterval : (list[1] as! DCMPix).sliceLocation - first.sliceLocation
        if !interval.isFinite || abs(interval) < 1e-6 || !usedInterval.isFinite ||
            abs(interval - usedInterval) > fmax(0.01, abs(interval)*0.01) { return false }
        for k in 0..<3 {
            if !step[k].isFinite || abs(step[k] - interval*Double(o[6+k])) > 0.01 { return false }
        }
        var index = 0
        for case let pix as DCMPix in list {
            if !pix.isLoaded() || pix.isRGB || pix.pwidth != first.pwidth || pix.pheight != first.pheight ||
                abs(pix.pixelSpacingX - first.pixelSpacingX) > 1e-5 ||
                abs(pix.pixelSpacingY - first.pixelSpacingY) > 1e-5 { return false }
            var orientation = [Float](repeating: 0, count: 9); pix.orientation(&orientation)
            for k in 0..<9 {
                if !orientation[k].isFinite || abs(orientation[k] - o[k]) > 1e-4 { return false }
            }
            let origins: [Double] = [pix.originX - first.originX, pix.originY - first.originY, pix.originZ - first.originZ]
            for k in 0..<3 {
                if !origins[k].isFinite || abs(origins[k] - Double(index)*step[k]) > 0.01 { return false }
            }
            index += 1
        }
        _axis = Int(HorosPreviewResliceAxis(o))
        _slices = list
        _reslicer = OrthogonalReslice(originalDCMPixList: list)
        _reslicer?.useYcache = false
        return true
    }

    @objc(scheduleUpdate)
    private func scheduleUpdate() {
        if _pending { return }
        _pending = true
        self.perform(#selector(updatePreview), with: nil, afterDelay: 1.0/30.0,
                     inModes: [RunLoop.Mode.common])
    }

    @objc(showAtWindowPoint:)
    func show(atWindowPoint point: NSPoint) {
        _windowPoint = point
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hide), object: nil)
        self.perform(#selector(hide), with: nil, afterDelay: 1.0, inModes: [RunLoop.Mode.common])
        scheduleUpdate()
    }

    @objc(moveAtWindowPoint:)
    func move(atWindowPoint point: NSPoint) {
        if self.isHidden && !_pending { return }
        _windowPoint = point
        scheduleUpdate()
    }

    @objc(updatePreview)
    private func updatePreview() {
        _pending = false
        guard let host = _host, host.window?.isVisible ?? false, host.is2DViewer(),
              !sendBool(host.windowController() as AnyObject?, "windowWillClose"),
              prepareVolume() else { hide(); return }
        let location = host.convert(_windowPoint, from: nil)
        if !NSPointInRect(location, host.bounds) { hide(); return }
        var pixel = host.convert(fromNSView2GL: location)
        guard pixel.x.isFinite, pixel.y.isFinite, let current = host.curDCM else { hide(); return }
        pixel.x = fmax(0.5, fmin(CGFloat(current.pwidth) - 0.5, pixel.x))
        pixel.y = fmax(0.5, fmin(CGFloat(current.pheight) - 0.5, pixel.y))
        let position = Int(floor(_axis != 0 ? pixel.x : pixel.y))
        if _position != position || _plane == nil {
            _reslicer?.axeReslice(Int16(truncatingIfNeeded: _axis), position)
            _plane = ((_axis != 0 ? _reslicer?.yReslicedDCMPixList : _reslicer?.xReslicedDCMPixList)?.firstObject) as? DCMPix
            guard let plane = _plane else { hide(); return }
            _position = position
            var o = [Float](repeating: 0, count: 9); plane.orientation(&o)
            _orientation = HorosPreviewDisplayOrientation(o)
            _physicalSize = NSMakeSize(CGFloat(Double(plane.pwidth) * plane.pixelSpacingX), CGFloat(Double(plane.pheight) * plane.pixelSpacingY))
            if _orientation.transpose { _physicalSize = NSMakeSize(_physicalSize.height, _physicalSize.width) }
            let labels = NSMutableArray()
            for edge in 0..<4 {
                let vertical = edge >= 2
                let axis = (vertical != _orientation.transpose) ? 3 : 0
                let sign: Float = Float(edge % 2 == 0 ? -1 : 1) * ((vertical ? _orientation.flipY : _orientation.flipX) ? -1 : 1)
                var vector: [Float] = [o[axis]*sign, o[axis+1]*sign, o[axis+2]*sign]
                var text = [CChar](repeating: 0, count: 32); host.getOrientationText(&text, &vector, false)
                labels.add((NSString(utf8String: text) as String?) ?? "")
            }
            _labels = labels.copy() as? NSArray
            _image = nil
        }
        guard let plane = _plane else { return }
        if _image == nil || _level != current.wl || _width != current.ww {
            _level = current.wl; _width = current.ww
            plane.changeWLWW(_level, _width)
            _image = plane.image()
        }
        // A point in patient space ties the marker to the actual slice, including
        // reversed acquisition order. DCMPix returns millimetres along the plane.
        var patient = [Double](repeating: 0, count: 3), local = [Double](repeating: 0, count: 3)
        current.convertDoubleX(Double(pixel.x), pixY: Double(pixel.y), toDICOMCoords: &patient, pixelCenter: true)
        plane.convertDICOMCoordsDouble(&patient, toSliceCoords: &local, pixelCenter: true)
        _marker = NSMakePoint(CGFloat(local[0] / (Double(plane.pwidth) * plane.pixelSpacingX)),
                              CGFloat(local[1] / (Double(plane.pheight) * plane.pixelSpacingY)))
        let side = fmin(150, fmin(NSWidth(host.bounds), NSHeight(host.bounds)) * 0.3)
        if side < 72 { hide(); return }
        let y = host.isFlipped ? NSMinY(host.bounds) + 6 : NSMaxY(host.bounds) - side - 6
        let annotationLayoutChanged = self.isHidden || NSWidth(self.frame) != side
        self.frame = NSMakeRect(NSMinX(host.bounds) + 6, y, side, side)
        self.isHidden = false
        self.needsDisplay = true
        // Moving the marker must not submit the full diagnostic image again.
        // The host only needs a draw when its annotation margin changes.
        if annotationLayoutChanged { host.needsDisplay = true }
    }

    @objc(point:inImageRect:)
    private func point(_ point: NSPoint, inImageRect rect: NSRect) -> NSPoint {
        var x = 0.0, y = 0.0; HorosPreviewMapPoint(_orientation, Double(point.x), Double(point.y), &x, &y)
        return NSMakePoint(NSMinX(rect) + CGFloat(x)*NSWidth(rect), NSMinY(rect) + CGFloat(y)*NSHeight(rect))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); self.bounds.fill(using: .copy)
        guard let image = _image, _physicalSize.width > 0, _physicalSize.height > 0 else { return }
        let available = NSInsetRect(self.bounds, 13, 13)
        let scale = fmin(NSWidth(available)/_physicalSize.width, NSHeight(available)/_physicalSize.height)
        let rect = NSMakeRect(NSMidX(available) - _physicalSize.width*scale/2,
                              NSMidY(available) - _physicalSize.height*scale/2,
                              _physicalSize.width*scale, _physicalSize.height*scale)
        let origin = self.point(NSZeroPoint, inImageRect: rect)
        let x = self.point(NSMakePoint(1, 0), inImageRect: rect)
        let y = self.point(NSMakePoint(0, 1), inImageRect: rect)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.transformStruct = NSAffineTransformStruct(m11: x.x-origin.x, m12: x.y-origin.y, m21: y.x-origin.x, m22: y.y-origin.y, tX: origin.x, tY: origin.y)
        transform.concat()
        image.draw(in: NSMakeRect(0, 0, 1, 1), from: NSZeroRect, operation: .copy,
                   fraction: 1, respectFlipped: true, hints: [NSImageRep.HintKey.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        NSGraphicsContext.restoreGraphicsState()
        NSColor.red.set()
        let line = NSBezierPath()
        line.move(to: self.point(NSMakePoint(0, _marker.y), inImageRect: rect))
        line.line(to: self.point(NSMakePoint(1, _marker.y), inImageRect: rect))
        let marker = self.point(_marker, inImageRect: rect)
        line.move(to: NSMakePoint(marker.x-3, marker.y-3))
        line.line(to: NSMakePoint(marker.x+3, marker.y+3))
        line.move(to: NSMakePoint(marker.x-3, marker.y+3))
        line.line(to: NSMakePoint(marker.x+3, marker.y-3))
        line.lineWidth = 1; line.stroke()
        NSInsetRect(self.bounds, 0.5, 0.5).frame(withWidth: 1, using: .copy)
        let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 10)]
        for edge in 0..<(_labels?.count ?? 0) {
            let label = _labels![edge] as! NSString; let size = label.size(withAttributes: attributes)
            var p = NSMakePoint((NSWidth(self.bounds)-size.width)/2, (NSHeight(self.bounds)-size.height)/2)
            if edge == 0 { p.x = 3 }
            if edge == 1 { p.x = NSWidth(self.bounds)-size.width-3 }
            if edge == 2 { p.y = 1 }
            if edge == 3 { p.y = NSHeight(self.bounds)-size.height-1 }
            label.draw(at: p, withAttributes: attributes)
        }
    }
}

extension DCMView {
    @objc(horosShowScrollPreviewAtWindowPoint:)
    public func horosShowScrollPreview(atWindowPoint point: NSPoint) {
        if !self.is2DViewer() || (self.dcmPixList?.count ?? 0) < 2 ||
            !HorosScrollPreviewIsEnabled(UserDefaults.standard) { return }
        var preview = objc_getAssociatedObject(self, previewKey.key) as? HorosScrollPositionPreview
        if preview == nil {
            let created = HorosScrollPositionPreview(host: self)
            objc_setAssociatedObject(self, previewKey.key, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            self.addSubview(created)
            preview = created
        }
        preview?.show(atWindowPoint: point)
    }

    @objc(horosMoveScrollPreviewAtWindowPoint:)
    public func horosMoveScrollPreview(atWindowPoint point: NSPoint) {
        (objc_getAssociatedObject(self, previewKey.key) as? HorosScrollPositionPreview)?.move(atWindowPoint: point)
    }

    @objc(horosHideScrollPreview)
    public func horosHideScrollPreview() { (objc_getAssociatedObject(self, previewKey.key) as? HorosScrollPositionPreview)?.hide() }

    @objc(horosDiscardScrollPreview)
    public func horosDiscardScrollPreview() {
        (objc_getAssociatedObject(self, previewKey.key) as? HorosScrollPositionPreview)?.detach()
        objc_setAssociatedObject(self, previewKey.key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc(horosScrollPreviewAnnotationInset)
    public func horosScrollPreviewAnnotationInset() -> CGFloat {
        let preview = objc_getAssociatedObject(self, previewKey.key) as? NSView
        return preview != nil && !preview!.isHidden ? NSMaxX(preview!.frame) + 4 : 0
    }
}
