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
import Accelerate
import IsiXVolumeRendering

// C conversions from floating point to integers, as the arm64 code of the
// former Objective-C++ did them (fcvtzs/fcvtzu): toward zero, saturating, and
// NaN giving 0. Swift's own initializers trap instead.
@inline(__always) private func cInt(_ value: Double) -> Int32 {
    if value.isNaN { return 0 }
    if value >= 2147483647.0 { return Int32.max }
    if value <= -2147483648.0 { return Int32.min }
    return Int32(value)
}

@inline(__always) private func cInt(_ value: Float) -> Int32 {
    return cInt(Double(value))
}

@inline(__always) private func cPixelCount(_ value: Double) -> vImagePixelCount {
    if value.isNaN || value <= 0 { return 0 }
    if value >= 18446744073709551615.0 { return vImagePixelCount.max }
    return vImagePixelCount(value)
}

@inline(__always) private func cPixelCount(_ value: Float) -> vImagePixelCount {
    return cPixelCount(Double(value))
}

/// `(int) a.x == (int) b.x && (float) a.y == (float) b.y`, the test the editor
/// uses everywhere to find the selected point.
@inline(__always) private func sameEditorPoint(_ a: NSPoint, _ b: NSPoint) -> Bool {
    return cInt(Double(a.x)) == cInt(Double(b.x)) && Float(a.y) == Float(b.y)
}

/// `[sender floatValue]` of an action's sender; 0 for nil, as messaging nil.
@inline(__always) private func senderFloatValue(_ sender: Any?) -> Float {
    return (sender as AnyObject?)?.floatValue ?? 0
}

/// The 16-bit CLUT and opacity editor of the volume rendering viewer.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// `<Horos/CLUTOpacityView.h>` are those of the former Objective-C++ class.
/// The VRView outlet is told the CLUT and the window level, and its
/// controller the CLUT's name.
///
/// The curves are kept as the former class kept them: `NSMutableArray`s of
/// `NSMutableArray`s of `NSValue` points, and of `NSColor`s, shared with the
/// dictionaries handed to the VRView and to the presets.
@objc(CLUTOpacityView)
public final class CLUTOpacityView: NSView {
    private var backgroundColor: NSColor = NSColor.black
    private var histogramColor: NSColor = NSColor.lightGray
    private var pointsColor: NSColor = NSColor.black
    private var pointsBorderColor: NSColor = NSColor.black
    private var curveColor: NSColor = NSColor.gray
    private var selectedPointColor: NSColor = NSColor.white
    private var textLabelColor: NSColor = NSColor.white
    private var histogramOpacity: Float = 0.25
    /// Not owned: the viewer's volume.
    private var volumePointer: UnsafeMutablePointer<Float>?
    private var voxelCount: Int32 = 0
    private var protectionAgainstReentry: Int32 = 0
    /// malloc'd, freed here.
    private var histogram: UnsafeMutablePointer<vImagePixelCount>?
    private var histogramSize: Int32 = 0
    /// Hounsfield units bounds.
    private var HUmin: Float = -100000.0
    private var HUmax: Float = 100000.0
    private var selectedPoint = NSPoint(x: 0.0, y: -1.0)
    /// The index of the selected curve, -1 for none. It follows its curve
    /// when curves are inserted, removed or moved.
    private var selectedCurve: Int32 = -1
    private var pointDiameter: Int32 = 8
    private var lineWidth: Int32 = 3
    private var pointBorder: Int32 = 2

    private var curves = NSMutableArray()
    private var pointColors = NSMutableArray()

    private var contextualMenu: NSMenu?

    /// The editor's own undo manager, not the responder chain's.
    private let clutUndoManager = UndoManager()
    private var nothingChanged = false
    private var clutChanged = false
    /// Whether the click in progress has sent the curves to the volume.
    private var sentInClick = false
    /// The undo group of the click in progress, which mouse up ends.
    private var clickUndoGroupOpen = false

    private var zoomFactor: Float = 1.0
    private var zoomFixedPoint: Float = 0.0

    @IBOutlet public var chooseNameAndSaveWindow: NSWindow?
    @IBOutlet public var clutSavedName: NSTextField?

    /// Only compared with the window a notification closes.
    private weak var vrViewWindow: NSWindow?
    /// A VRView. Weak: the VRView keeps this view in its own outlet.
    @IBOutlet public weak var vrView: NSView?
    /// The outlet as the VRView it is; nil, and every message to it a no-op,
    /// without one, as a message to nil was.
    private var volumeView: VRView? { vrView as? VRView }
    private var vrViewLowResolution = false
    private var didResizeVRVIew = false

    private var mousePositionX: Float = 0.0

    private var drawingRect = NSRect.zero
    private var sideBarRect = NSRect.zero
    private var addCurveButtonRect = NSRect.zero
    private var removeSelectedCurveButtonRect = NSRect.zero
    private var saveButtonRect = NSRect.zero
    private var closeButtonRect = NSRect.zero
    private var isAddCurveButtonHighlighted = false
    private var isRemoveSelectedCurveButtonHighlighted = false
    private var isSaveButtonHighlighted = false
    private var isCloseButtonHighlighted = false

    private var mouseDraggingStartPoint = NSPoint.zero
    /// Re-entry guards of -updateView and -setCLUTtoVRView:.
    private var updatingView = false
    private var settingCLUTtoVRView = false
    private var windowWillClose = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    /// The xibs create the view with -initWithFrame:; a coder gets the same state.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(changePointColor(_:)), name: NSColorPanel.colorDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(computeHistogram(_:)), name: NSNotification.Name.OsirixUpdateVolumeData, object: nil)
        center.addObserver(self, selector: #selector(windowWillCloseNotification(_:)), name: NSWindow.willCloseNotification, object: nil)

        createContextualMenu()

        updateView()
    }

    @objc(windowWillCloseNotification:)
    public func windowWillCloseNotification(_ notification: Notification) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(setCLUTtoVRViewHighRes), object: nil)

        if (notification.object as AnyObject?) === vrViewWindow {
            windowWillClose = true
        }
        if notification.object is NSColorPanel { Self.colourPanelOwner = nil }
    }

    @objc public func cleanup() {
        curves = NSMutableArray()
        pointColors = NSMutableArray()
        forgetSelection()
        forgetUndoHistory()
        // The volume takes another CLUT: the empty one does not reach it, now
        // nor from a high-resolution send still pending.
        clutChanged = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(setCLUTtoVRViewHighRes), object: nil)
        if let histogram = histogram {
            free(histogram)
            self.histogram = nil
        }
        didResizeVRVIew = false
        updateView()
    }

    isolated deinit {
        NSObject.cancelPreviousPerformRequests(withTarget: self)

        window?.acceptsMouseMovedEvents = false

        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(setCLUTtoVRViewHighRes), object: nil)
        NotificationCenter.default.removeObserver(self)

        if let histogram = histogram {
            free(histogram)
        }
    }

    // MARK: - Array access, as the former messages did it

    private func curve(_ index: Int) -> NSArray {
        return curves.object(at: index) as! NSArray
    }

    private func mutableCurve(_ index: Int) -> NSMutableArray {
        return curves.object(at: index) as! NSMutableArray
    }

    private func colors(_ index: Int) -> NSArray {
        return pointColors.object(at: index) as! NSArray
    }

    private func mutableColors(_ index: Int) -> NSMutableArray {
        return pointColors.object(at: index) as! NSMutableArray
    }

    private func point(_ curve: NSArray, _ index: Int) -> NSPoint {
        return (curve.object(at: index) as! NSValue).pointValue
    }

    private func lastPoint(_ curve: NSArray) -> NSPoint {
        return (curve.lastObject as? NSValue)?.pointValue ?? NSPoint.zero
    }

    /// The color in the RGB space whose components the VRView reads, nil for
    /// none or for one without RGB components (a pattern). Colors enter the
    /// curves converted: the VRView's -redComponent raised on a gray one.
    private func rgbColor(_ color: NSColor?) -> NSColor? {
        return color?.usingColorSpace(.genericRGB)
    }

    /// No curve selected, and no point: unselected, or the curves they were on are gone.
    private func forgetSelection() {
        selectedCurve = -1
        selectedPoint.y = -1.0
    }

    /// The selected curve, or the first one when none is: the curve whose
    /// ends give the VRView its window level and width.
    private func windowingCurveIndex() -> Int {
        let curveIndex = Int(selectedCurveIndex())
        return curveIndex >= 0 && curveIndex < curves.count ? curveIndex : 0
    }

    /// How many of a curve's points windowing measures and moves: all but an open end, a last point at the top of a CT's
    /// 12-bit range or beyond at the height of the point before it (AdvancedCLUTFunctions.isOpenEnd, the volume's own rule),
    /// as the bundled bone presets end. Windowing, the curve's square and the scaling by its ends leave it out and in place.
    private func windowedCount(_ index: Int) -> Int {
        let aCurve = curve(index), n = aCurve.count, last = lastPoint(aCurve)
        return n > 2 && AdvancedCLUTFunctions.isOpenEnd(count: n, lastValue: last.x, lastHeight: last.y, heightBefore: point(aCurve, n - 2).y) ? n - 1 : n
    }
    /// Where the volume holds an open end's height up to, as AdvancedCLUTFunctions goes on with its curve: the top of the
    /// editor's range, short of any other curve that reaches above the end. Nil for none, or for a curve without an open end.
    private func openEndReach(_ index: Int) -> CGFloat? {
        guard windowedCount(index) < curve(index).count else { return nil }
        let others = (0..<curves.count).filter { $0 != index }.map { (first: Double(point(curve($0), 0).x), last: Double(lastPoint(curve($0)).x)) }
        return AdvancedCLUTFunctions.openEndReach(from: lastPoint(curve(index)).x, top: Double(HUmax), others: others, margin: 0).map { CGFloat($0) }
    }
    /// A colour's red, green and blue, as an open end and the point before it are compared.
    private func rgb(_ c: NSColor?) -> [CGFloat] { rgbColor(c).map { [$0.redComponent, $0.greenComponent, $0.blueComponent] } ?? [0, 0, 0] }

    /// The undo history acts on curves by their index: it goes when the curves
    /// are replaced all at once, by a CLUT loaded or by another kind of CLUT.
    private func forgetUndoHistory() {
        clutUndoManager.removeAllActions()
        clickUndoGroupOpen = false
    }

    /// Register typed inverse operations. AnyObject method lookup on the
    /// invocation proxy can return nil under Swift 6 before it records an undo.
    /// The editor and its undo/redo actions run on AppKit's main actor.
    private func registerUndo(_ action: @escaping @MainActor (CLUTOpacityView) -> Void) {
        clutUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { action(target) }
        }
    }

    // MARK: - Contextual menu

    @objc public func createContextualMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: NSLocalizedString("New Curve", comment: ""), action: #selector(newCurve(_:)), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Send to back", comment: ""), action: #selector(sendToBack(_:)), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Remove All Curves", comment: ""), action: #selector(removeAllCurves(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: NSLocalizedString("Save...", comment: ""), action: #selector(chooseNameAndSave(_:)), keyEquivalent: "")
        contextualMenu = menu
    }

    // MARK: - Histogram

    @objc(setVolumePointer:width:height:numberOfSlices:)
    public func setVolumePointer(_ ptr: UnsafeMutablePointer<Float>?, width: Int32, height: Int32, numberOfSlices n: Int32) {
        volumePointer = ptr
        voxelCount = width &* height &* n
    }

    @objc(setHUmin:HUmax:)
    public func setHUmin(_ min: Float, HUmax max: Float) {
        var max = max
        if max - min < 1 {
            max = min + 1
        }

        HUmin = min
        HUmax = max
    }

    @objc public func callComputeHistogram() {
        protectionAgainstReentry = 0
        computeHistogram()
    }

    @objc public func computeHistogram() {
        if windowWillClose {
            return
        }

        vrViewWindow = vrView?.window

        var buffer = vImage_Buffer()
        buffer.data = UnsafeMutableRawPointer(volumePointer)
        buffer.height = 1
        buffer.width = vImagePixelCount(bitPattern: Int(voxelCount))
        buffer.rowBytes = Int(voxelCount) &* MemoryLayout<Float>.size

        histogramSize = cInt((HUmax - HUmin) / 2)
        histogramSize = histogramSize &+ 1
        if histogramSize < 100 {
            histogramSize = 100
        }

        if let histogram = histogram {
            free(histogram)
            self.histogram = nil
        }

        // Without a volume there is nothing to count. The buffer was allocated
        // all the same, never filled, and drawn with what memory held.
        if buffer.data == nil || voxelCount <= 0 {
            return
        }

        histogram = malloc(MemoryLayout<vImagePixelCount>.size &* ((Int(histogramSize) &+ 100) &* 2))?
            .assumingMemoryBound(to: vImagePixelCount.self)
        if let histogram = histogram {
            vImageHistogramCalculation_PlanarF(&buffer, histogram, UInt32(bitPattern: histogramSize), HUmin, HUmax, vImage_Flags(kvImageDoNotTile))

            var min = histogram[0]
            var max: vImagePixelCount = 0

            for i in stride(from: 0, to: Int(histogramSize), by: 1) {
                if histogram[i] < min { min = histogram[i] }
                if histogram[i] > max { max = histogram[i] }
            }

            for i in stride(from: 0, to: Int(histogramSize), by: 1) {
                // float / float, then times the double 10000.0, stored in a float.
                let temp = Float(Double(Float(histogram[i] &- min) / Float(max)) * 10000.0)
                if temp >= 1 {
                    // Objective-C++ resolved log(float) to the float overload.
                    histogram[i] = cPixelCount(logf(temp) * 1000)
                } else {
                    histogram[i] = cPixelCount(temp)
                }
            }
        }

        let reentry = protectionAgainstReentry
        protectionAgainstReentry = reentry &+ 1
        if reentry > 20 {
            return
        }

        simplifyHistogram()
    }

    @objc public func simplifyHistogram() {
        guard let histogram = histogram else { return }
        if histogramSize == 0 { return }

        var sum: vImagePixelCount = 0
        for i in stride(from: 0, to: Int(histogramSize), by: 1) {
            sum = sum &+ histogram[i]
        }

        if sum <= 100 { return }

        var maxBin = histogramSize - 1
        let binWidth: Float = (HUmax - HUmin) / Float(histogramSize)
        var newHUmax: Float = 0

        var i = histogramSize - 2
        while i >= 0 {
            if histogram[Int(i)] <= 10 {
                maxBin = i
                newHUmax = Float(Double(HUmin) + Double(binWidth * Float(i)) * 1.5) // factor 1.5 is for tunning
            } else {
                i = -1
            }
            i -= 1
        }

        if maxBin < histogramSize - 2 {
            if newHUmax >= HUmax { return }
            setHUmin(HUmin, HUmax: newHUmax)
            computeHistogram()
        }
    }

    @objc(drawBinHistogramInRect:)
    public func drawBinHistogram(in rect: NSRect) {
        guard let histogram = histogram else { return }

        var max: Int32 = 0
        var i = 2
        while i < Int(histogramSize) {
            if histogram[i] > vImagePixelCount(bitPattern: Int(max)) { max = Int32(truncatingIfNeeded: histogram[i]) }
            i += 1
        }

        let heightFactor: Float = (max == 0) ? 1 : Float(Double(rect.size.height) / Double(max))

        let count = Int(histogramSize)
        let rects = UnsafeMutablePointer<NSRect>.allocate(capacity: Swift.max(count, 0))
        let binWidth = Float(Double(rect.size.width) / Double(histogramSize))
        for i in stride(from: 0, to: count, by: 1) {
            rects[i] = NSMakeRect(CGFloat(Float(i) * binWidth), 0, CGFloat(binWidth), CGFloat(Float(histogram[i]) * heightFactor))
        }

        histogramColor.set()
        __NSRectFillList(rects, count)

        rects.deallocate()
    }

    @objc(drawHistogramInRect:)
    public func drawHistogram(in rect: NSRect) {
        // Without a histogram (no volume, freed by -cleanup) nothing is drawn:
        // not even the flat outline along the bottom.
        guard let histogram = histogram else { return }

        let transform = self.transform()

        let count = Int(histogramSize)
        var max: vImagePixelCount = 0
        for i in stride(from: 0, to: count, by: 1) {
            if histogram[i] > max { max = histogram[i] }
        }

        let heightFactor: Float = (max == 0) ? 1.0 : Float(1.0 / Double(max))
        let binWidth: Float = (HUmax - HUmin) / Float(histogramSize)

        let line = NSBezierPath()

        line.move(to: transform.transform(NSMakePoint(CGFloat(HUmin), 0.0)))
        for i in stride(from: 0, to: count, by: 1) {
            // HUmin + i * binWidth, fused as clang contracted it.
            let pt = NSMakePoint(CGFloat(HUmin.addingProduct(Float(i), binWidth)), CGFloat(Float(histogram[i]) * heightFactor))
            let ptInView = transform.transform(pt)
            line.line(to: ptInView)

            if Double(mousePositionX) > Double(pt.x) - 1 && Double(mousePositionX) < Double(pt.x) + 1 {
                let dotFrame = NSMakeRect(ptInView.x - 3, ptInView.y - 3, 6, 6)
                let dot = NSBezierPath(ovalIn: dotFrame)
                let cDot = histogramColor.withAlphaComponent(CGFloat(Double(histogramOpacity) * 3.0))
                cDot.set()
                dot.fill()
            }
        }

        var pt = NSMakePoint(CGFloat(HUmax), 0.0)
        pt = transform.transform(pt)
        line.line(to: pt)

        line.close()
        var c = histogramColor.withAlphaComponent(CGFloat(histogramOpacity))
        c.set()
        line.fill()
        c = histogramColor.withAlphaComponent(CGFloat(Double(histogramOpacity) * 2.0))
        c.set()
        line.lineWidth = 1.0
        line.stroke()
    }

    // MARK: - Curves

    @objc public func newCurve() {
        let theNewCurve = NSMutableArray(capacity: 4)

        var pt1 = NSMakePoint(12, 0.0)
        var pt2 = NSMakePoint(202, CGFloat(sqrt(0.027)))
        var pt3 = NSMakePoint(404, CGFloat(sqrt(0.133)))
        var pt4 = NSMakePoint(549, CGFloat(sqrt(0.682)))

        var shift: Float = 40.0

        if Double(pt1.x) < Double(HUmin) || Double(pt4.x) > Double(HUmax) {
            let middle = Float(Double(HUmin + HUmax) / 2.0)
            let length: Float = HUmax - HUmin
            // middle -/+ k*length, fused as clang contracted it.
            pt1.x = CGFloat(Double(middle).addingProduct(-0.05, Double(length)))
            pt2.x = CGFloat(middle)
            pt3.x = CGFloat(Double(middle).addingProduct(0.05, Double(length)))
            pt4.x = CGFloat(Double(middle).addingProduct(0.1, Double(length)))
            shift = Float(0.01 * Double(length))
        }

        var needsShift = false
        var c1: NSPoint
        var c2: NSPoint
        var i = 0
        while i < curves.count {
            c1 = point(curve(i), 0)
            c2 = lastPoint(curve(i))
            let s = Double(shift)
            needsShift = (Double(pt1.x) > Double(c1.x) - s && Double(pt1.x) < Double(c1.x) + s) || (Double(pt4.x) > Double(c2.x) - s && Double(pt4.x) < Double(c2.x) + s)

            if needsShift {
                pt1.x += CGFloat(shift)
                pt2.x += CGFloat(shift)
                pt3.x += CGFloat(shift)
                pt4.x += CGFloat(shift)
                i = -1
                needsShift = false
            }
            i += 1
        }

        theNewCurve.add(NSValue(point: pt1))
        theNewCurve.add(NSValue(point: pt2))
        theNewCurve.add(NSValue(point: pt3))
        theNewCurve.add(NSValue(point: pt4))

        let theColors = NSMutableArray(capacity: 4)
        theColors.add(NSColor(deviceRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
        theColors.add(NSColor(deviceRed: 1.0, green: 0.0, blue: 0.0, alpha: 1.0))
        theColors.add(NSColor(deviceRed: 1.0, green: 1.0, blue: 0.0, alpha: 1.0))
        theColors.add(NSColor(deviceRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))

        addCurveAtindex(0, withPoints: theNewCurve, colors: theColors)

        // select the new curve
        let controlPoint = controlPointForCurve(at: 0)
        selectedPoint = controlPoint
        selectedCurve = 0

        nothingChanged = false
        clutChanged = true
        vrViewLowResolution = false
        updateView()
    }

    @objc(fillCurvesInRect:)
    public func fillCurves(in rect: NSRect) {
        let transform = self.transform()

        for i in (0..<curves.count).reversed() {
            let aCurve = curve(i), reach = openEndReach(i) // an open end's curve is drawn on as far as the volume holds it

            let locations = UnsafeMutablePointer<CGFloat>.allocate(capacity: Swift.max(aCurve.count, 1)) // for NSGradient

            var line = NSBezierPath()
            let p0 = point(aCurve, 0)
            line.move(to: NSMakePoint(p0.x, 0.0))

            let minX = Float(point(aCurve, 0).x)
            let maxX = Float(reach ?? lastPoint(aCurve).x)
            let d: Float = maxX - minX

            // construct path & locations
            var pt: NSPoint
            for j in 0..<aCurve.count {
                pt = point(aCurve, j)
                locations[j] = CGFloat((Double(pt.x) - Double(minX)) / Double(d))
                line.line(to: pt)
            }
            if let reach { line.line(to: NSPoint(x: reach, y: lastPoint(aCurve).y)) }

            // close path
            line.line(to: NSPoint(x: reach ?? lastPoint(aCurve).x, y: 0.0))
            line.close()
            line = transform.transform(line)

            // GRADIENT FILL
            let gradient = NSGradient(colors: colors(i) as! [NSColor], atLocations: locations, colorSpace: NSColorSpace.genericRGB)
            gradient?.draw(in: line, angle: 0)

            locations.deallocate()
        }
    }

    @objc(drawCurvesInRect:)
    public func drawCurves(in rect: NSRect) {
        let transform = self.transform()

        for i in (0..<curves.count).reversed() {
            let aCurve = curve(i)

            // CONTROL POINT SELECTED? The selected curve's, the one «−» and Delete
            // remove, also where undo, the volume's windowing or a zoom moved it.
            let controlPoint = controlPointForCurve(at: Int32(truncatingIfNeeded: i))
            let controlPointSelected = i == Int(selectedCurve)

            // LINE
            var line = NSBezierPath()
            line.move(to: point(aCurve, 0))
            for j in stride(from: 1, to: aCurve.count, by: 1) { line.line(to: point(aCurve, j)) }
            if let reach = openEndReach(i) { line.line(to: NSPoint(x: reach, y: lastPoint(aCurve).y)) } // as the volume holds it
            line = transform.transform(line)
            curveColor.set()
            if controlPointSelected { selectedPointColor.set() }
            line.lineWidth = CGFloat(lineWidth)
            line.stroke()

            // CONTROL POINT (DRAW)
            let frame = NSMakeRect(controlPoint.x - CGFloat(Double(pointDiameter) * 0.5), controlPoint.y - CGFloat(Double(pointDiameter) * 0.5), CGFloat(pointDiameter), CGFloat(pointDiameter))
            let control = NSBezierPath(rect: frame)
            control.lineWidth = CGFloat(pointBorder)
            pointsColor.set()
            control.fill()
            curveColor.set()
            if controlPointSelected { selectedPointColor.set() }
            control.stroke()

            // DOTS
            var selectedPointForLabel = NSMakePoint(-1.0, -1.0)

            for j in 0..<aCurve.count {
                let pt = point(aCurve, j)
                var selected = false
                if isAnyPointSelected() {
                    if sameEditorPoint(selectedPoint, pt) {
                        selected = true
                    }
                }
                //border
                let pt1 = transform.transform(pt)
                let frame1 = NSMakeRect(pt1.x - CGFloat(Double(pointDiameter) * 0.5) - CGFloat(pointBorder), pt1.y - CGFloat(Double(pointDiameter) * 0.5) - CGFloat(pointBorder), CGFloat(pointDiameter &+ 2 &* pointBorder), CGFloat(pointDiameter &+ 2 &* pointBorder))
                let dot1 = NSBezierPath(ovalIn: frame1)
                pointsColor.set()
                dot1.stroke()
                curveColor.set()
                if selected || controlPointSelected { selectedPointColor.set() }
                dot1.fill()

                //inside
                let pt2 = transform.transform(pt)
                let frame = NSMakeRect(pt2.x - CGFloat(Double(pointDiameter) * 0.5), pt2.y - CGFloat(Double(pointDiameter) * 0.5), CGFloat(pointDiameter), CGFloat(pointDiameter))
                let dot = NSBezierPath(ovalIn: frame)

                pointsColor.set()
                dot.stroke()
                let c = colors(i).object(at: j) as! NSColor
                c.set()
                dot.fill()

                if selected { selectedPointForLabel = pt }
            }

            // LABEL FOR SELECTED POINT
            if selectedPointForLabel.y >= 0.0 { drawPointLabel(atPosition: selectedPointForLabel) }

            // LABEL FOR ALL POINTS
            if controlPointSelected {
                var maxYIndex: Int32 = -1
                var minYIndex: Int32 = -1
                var minY: Float = 1.0
                var maxY: Float = 0.0
                var currentPoint: NSPoint
                for j in 0..<aCurve.count {
                    currentPoint = point(aCurve, j)
                    if Double(currentPoint.y) < Double(minY) {
                        minY = Float(currentPoint.y)
                        minYIndex = Int32(j)
                    }
                    if Double(currentPoint.y) > Double(maxY) {
                        maxY = Float(currentPoint.y)
                        maxYIndex = Int32(j)
                    }
                }
                drawPointLabel(atPosition: point(aCurve, 0))
                drawPointLabel(atPosition: point(aCurve, aCurve.count - 1))
                if minYIndex > 0 && minY > 0.0 { drawPointLabel(atPosition: point(aCurve, Int(minYIndex))) }
                if maxYIndex > 0 { drawPointLabel(atPosition: point(aCurve, Int(maxYIndex))) }
            }
        }
    }

    @objc(addCurveAtindex:withPoints:colors:)
    public func addCurveAtindex(_ curveIndex: Int32, withPoints pointsArray: NSArray, colors colorsArray: NSArray) {
        registerUndo { $0.deleteCurveAtIndex(curveIndex) }
        curves.insert(pointsArray, at: Int(curveIndex))
        pointColors.insert(colorsArray, at: Int(curveIndex))
        if selectedCurve >= curveIndex { selectedCurve += 1 }
    }

    @objc(deleteCurveAtIndex:)
    public func deleteCurveAtIndex(_ curveIndex: Int32) {
        nothingChanged = false
        clutChanged = true
        let previousPoints = NSMutableArray(array: curve(Int(curveIndex)))
        let previousColors = NSMutableArray(array: colors(Int(curveIndex)))
        registerUndo { $0.addCurveAtindex(curveIndex, withPoints: previousPoints, colors: previousColors) }
        curves.removeObject(at: Int(curveIndex))
        pointColors.removeObject(at: Int(curveIndex))
        // The index was left as it was: past the end, it made the next
        // -setCLUTtoVRView:, -setWL:ww:, -copy: or -delete: raise.
        if selectedCurve == curveIndex {
            forgetSelection()
        } else if selectedCurve > curveIndex {
            selectedCurve -= 1
        }
    }

    @objc(moveCurveAtIndex:toIndex:)
    public func moveCurveAtIndex(_ i0: Int32, toIndex i1: Int32) {
        registerUndo { $0.moveCurveAtIndex(i1, toIndex: i0) }

        let theCurve = curves.object(at: Int(i0))
        let theColors = pointColors.object(at: Int(i0))

        if i0 > i1 {
            curves.insert(theCurve, at: Int(i1))
            pointColors.insert(theColors, at: Int(i1))
            curves.removeObject(at: Int(i0) + 1)
            pointColors.removeObject(at: Int(i0) + 1)
        } else {
            curves.insert(theCurve, at: Int(i1) + 1)
            pointColors.insert(theColors, at: Int(i1) + 1)
            curves.removeObject(at: Int(i0))
            pointColors.removeObject(at: Int(i0))
        }

        // "Send to back" left the index on the curve that took the place of
        // the selected one, which -delete: then removed.
        if selectedCurve == i0 {
            selectedCurve = i1
        } else if i0 > i1 && selectedCurve >= i1 && selectedCurve < i0 {
            selectedCurve += 1
        } else if i0 < i1 && selectedCurve > i0 && selectedCurve <= i1 {
            selectedCurve -= 1
        }
    }

    /// The order is an edit the volume receives: of two curves' points at one value, the front curve's is the volume's.
    @objc(sendToBackCurveAtIndex:)
    public func sendToBackCurve(at i: Int32) {
        guard Int(i) != curves.count - 1 else { return }
        nothingChanged = false
        // Only where a curve behind has a point at one of this curve's values does the order give the volume another CLUT.
        let values = Set((0..<curve(Int(i)).count).map { point(curve(Int(i)), $0).x })
        if (Int(i) + 1..<curves.count).contains(where: { j in (0..<curve(j).count).contains { values.contains(point(curve(j), $0).x) } }) { clutChanged = true }
        moveCurveAtIndex(i, toIndex: Int32(truncatingIfNeeded: curves.count - 1))
    }

    @objc(sendToFrontCurveAtIndex:)
    public func sendToFrontCurve(at i: Int32) {
        guard i != 0 else { return }
        nothingChanged = false
        clutChanged = true // as Send to back; a click on a point or a square sends the curves itself
        moveCurveAtIndex(i, toIndex: 0)
    }

    @objc public func selectedCurveIndex() -> Int32 {
        return selectedCurve
    }

    @objc(selectCurveAtIndex:)
    public func selectCurve(at i: Int32) {
        if curves.count == 0 { return }
        let controlPoint = controlPointForCurve(at: i)
        selectedCurve = i
        selectedPoint = controlPoint
        setCLUTtoVRView(false)
    }

    @objc(setColor:forCurveAtIndex:)
    public func setColor(_ color: NSColor?, forCurveAt curveIndex: Int32) {
        guard let color = rgbColor(color) else { return }

        nothingChanged = false
        clutChanged = true
        let previousColors = NSMutableArray(array: colors(Int(curveIndex)))
        registerUndo { $0.setColors(previousColors, forCurveAt: curveIndex) }

        let theColors = mutableColors(Int(curveIndex))
        for i in 0..<curve(Int(curveIndex)).count {
            theColors.replaceObject(at: i, with: color)
        }
    }

    @objc(setColors:forCurveAtIndex:)
    public func setColors(_ newColors: NSArray, forCurveAt curveIndex: Int32) {
        nothingChanged = false
        clutChanged = true
        let previousColors = NSMutableArray(array: colors(Int(curveIndex)))
        registerUndo { $0.setColors(previousColors, forCurveAt: curveIndex) }

        let theColors = mutableColors(Int(curveIndex))
        for i in 0..<curve(Int(curveIndex)).count {
            theColors.replaceObject(at: i, with: newColors.object(at: i))
        }
    }

    @objc(shiftCurveAtIndex:shift:)
    public func shiftCurveAtIndex(_ curveIndex: Int32, shift aShift: Float) {
        registerUndo { $0.shiftCurveAtIndex(curveIndex, shift: -aShift) }
        let theCurve = mutableCurve(Int(curveIndex))
        var pt: NSPoint

        for i in 0..<theCurve.count {
            pt = point(theCurve, i)
            pt.y += CGFloat(aShift)
            theCurve.replaceObject(at: i, with: NSValue(point: pt))
        }
    }

    @objc(setCurves:)
    public func setCurves(_ newCurves: NSMutableArray) {
        curves = newCurves
        forgetSelection()
        forgetUndoHistory()
    }

    @objc(setPointColors:)
    public func setPointColors(_ newPointColors: NSMutableArray) {
        pointColors = newPointColors
        forgetUndoHistory()
    }

    // MARK: - Coordinate to NSView Transform

    @objc public func transform() -> NSAffineTransform {
        let transform = NSAffineTransform()
        let width = Double(drawingRect.size.width)
        let range = Double(HUmax - HUmin)
        // -HUmin*width/range*zoomFactor + x, the last product fused as clang contracted it.
        transform.translateX(by: CGFloat(Double(drawingRect.origin.x).addingProduct(Double(-HUmin) * width / range, Double(zoomFactor))), yBy: 0.0)
        transform.scaleX(by: CGFloat(width / range * Double(zoomFactor)), yBy: drawingRect.size.height)

        let transform3 = NSAffineTransform()
        transform3.translateX(by: CGFloat(-zoomFixedPoint * zoomFactor), yBy: 0.0)
        transform.append(transform3 as AffineTransform)

        return transform
    }

    // MARK: - Global draw method

    public override func draw(_ dirtyRect: NSRect) {
        if histogram == nil {
            callComputeHistogram()
        }

        // The editor lays its side bar, histogram and curves out over the whole
        // view. Taking the area needing redraw instead placed them wrongly on a
        // partial redraw, and since macOS 14 NSView no longer clips drawing to its
        // bounds, painted outside the view on an oversized one.
        var rect = bounds

        backgroundColor.set()
        __NSRectFill(rect)

        sideBarRect.origin = rect.origin
        sideBarRect.size.height = rect.size.height
        sideBarRect.size.width = 30.0

        rect.origin.x += sideBarRect.size.width
        rect.size.width -= sideBarRect.size.width

        drawingRect = rect

        fillCurves(in: rect)
        drawHistogram(in: rect)
        drawCurves(in: rect)

        drawSideBar(sideBarRect)
    }

    @objc public func updateView() {
        if updatingView { return } // avoid re-entry
        updatingView = true

        needsDisplay = true

        if clutChanged { setCLUTtoVRView() }
        clutChanged = false

        updatingView = false
    }

    // MARK: - Points

    @discardableResult
    @objc(selectPointAtPosition:)
    public func selectPoint(atPosition position: NSPoint) -> Bool {
        if let hit = nearestHit(to: position, squares: false) {
            selectedPoint = point(curve(hit.curve), hit.point)
            selectedCurve = -1 // before the panel's colour, whose notification would colour the curve selected before with this point's
            NSColorPanel.shared.color = colors(hit.curve).object(at: hit.point) as! NSColor
            sendToFrontCurve(at: Int32(truncatingIfNeeded: hit.curve))
            clutChanged = false
            updateView()
            setCLUTtoVRView(false)
            return true
        }
        setCLUTtoVRView(false)
        return false
    }

    /// The point, or the curve's square, nearest to a position in the view
    /// within its click box: the curves "+" adds lie a few pixels apart, and a
    /// curve's square within the box of the points of the curves next to it.
    private func nearestHit(to position: NSPoint, squares: Bool) -> (curve: Int, point: Int, distance: CGFloat)? {
        let transform = self.transform(), reach = CGFloat(pointDiameter)
        var nearest: (curve: Int, point: Int, distance: CGFloat)?
        for i in 0..<curves.count {
            let aCurve = curve(i)
            let targets = squares ? [controlPointForCurve(at: Int32(truncatingIfNeeded: i))] : (0..<aCurve.count).map { transform.transform(point(aCurve, $0)) }
            for (j, target) in targets.enumerated() where abs(position.x - target.x) <= reach && abs(position.y - target.y) <= reach {
                let distance = hypot(position.x - target.x, position.y - target.y)
                if distance < nearest?.distance ?? .infinity { nearest = (i, j, distance) }
            }
        }
        return nearest
    }

    /// Whether a click is on a curve's square rather than on a point.
    private func controlPointIsNearest(to position: NSPoint) -> Bool {
        guard let square = nearestHit(to: position, squares: true) else { return false }
        return square.distance < nearestHit(to: position, squares: false)?.distance ?? .infinity
    }

    @objc public func unselectPoints() {
        forgetSelection() // a curve's square too: nothing is left for «−» or Delete
        clutChanged = false
        updateView()
    }

    @objc public func isAnyPointSelected() -> Bool {
        return selectedPoint.y >= 0.0
    }

    /// The editor the colour panel colours for: the one whose double click opened it, until the panel closes. The panel is the
    /// application's: a colour well of any window, or a click in another 3D window's editor, coloured the curve selected here.
    private static weak var colourPanelOwner: CLUTOpacityView?
    func openColourPanel() { Self.colourPanelOwner = self; NSColorPanel.shared.orderFront(self) }

    /// The colour panel colours the selected curve, found by its index as «Send to back» finds it, or else the selected point.
    @objc(changePointColor:)
    public func changePointColor(_ notification: Notification) {
        guard Self.colourPanelOwner === self, isAnyPointSelected() else { return }
        let newColor = (notification.object as? NSColorPanel)?.color.usingColorSpace(.genericRGB)
        if selectedCurve >= 0 && Int(selectedCurve) < curves.count {
            setColor(newColor, forCurveAt: selectedCurve)
        } else if let selected = selectedPointIndexes() {
            setColor(newColor, forPointAt: selected.point, inCurveAt: selected.curve)
        } else {
            return
        }
        if clutChanged { vrViewLowResolution = true } // a click on a point gives the panel its colour: no change, nothing to send at the mouse up
        updateView()
    }

    /// An open end with the colour of the point before it takes that point's new colour too, as it takes its height: the
    /// curve keeps the colour up to its densest values, in the editor, the volume and what is saved, rather than fading.
    @objc(setColor:forPointAtIndex:inCurveAtIndex:)
    public func setColor(_ color: NSColor?, forPointAt pointIndex: Int32, inCurveAt curveIndex: Int32) {
        guard let newColor = rgbColor(color) else { return }
        let theColors = colors(Int(curveIndex)), previousColor = theColors.object(at: Int(pointIndex)) as? NSColor, n = theColors.count
        guard rgb(previousColor) != rgb(newColor) else { return }
        let openEndFollows = Int(pointIndex) + 2 == n && windowedCount(Int(curveIndex)) < n && rgb(theColors.lastObject as? NSColor) == rgb(previousColor)
        clutChanged = true
        nothingChanged = false
        registerUndo { $0.setColor(previousColor, forPointAt: pointIndex, inCurveAt: curveIndex) }
        mutableColors(Int(curveIndex)).replaceObject(at: Int(pointIndex), with: newColor)
        if openEndFollows { setColor(newColor, forPointAt: pointIndex + 1, inCurveAt: curveIndex) }
    }

    @objc(legalizePoint:inCurve:atIndex:)
    public func legalizePoint(_ point: NSPoint, inCurve aCurve: NSArray, at j: Int32) -> NSPoint {
        var point = point
        if point.y < 0.0 { point.y = 0.0 }
        if point.y >= 0.999 { point.y = 0.999 }

        if j > 0 {
            let previous = self.point(aCurve, Int(j) - 1)
            if point.x <= previous.x + 10 { point.x = previous.x + 10 }
        }
        if Int(j) < aCurve.count - 1 {
            let next = self.point(aCurve, Int(j) + 1)
            if point.x >= next.x - 10 { point.x = next.x - 10 }
        }

        return point
    }

    @objc(drawPointLabelAtPosition:)
    public func drawPointLabel(atPosition pt: NSPoint) {
        let attrsDictionary: [NSAttributedString.Key: Any] = [.foregroundColor: textLabelColor]

        let label = NSAttributedString(string: String(format: NSLocalizedString("value : %.0f\nalpha : %1.3f", comment: "don't translate the 'backslash n' before 'alpha', it is a new line symbol!"), Double(pt.x), Double(pt.y * pt.y)), attributes: attrsDictionary)
        let labelValue = NSAttributedString(string: String(format: NSLocalizedString("value : %.0f", comment: ""), Double(pt.x)), attributes: attrsDictionary)
        let labelAlpha = NSAttributedString(string: String(format: NSLocalizedString("alpha : %1.3f", comment: ""), Double(pt.y * pt.y)), attributes: attrsDictionary)

        let transform = self.transform()
        let pt1 = transform.transform(pt)
        var labelPosition = NSMakePoint(pt1.x + CGFloat(pointDiameter), pt1.y + CGFloat(pointDiameter))

        let rect = drawingRect
        var labelBounds = label.boundingRect(with: rect.size, options: .usesDeviceMetrics)
        let labelValueBounds = labelValue.boundingRect(with: rect.size, options: .usesDeviceMetrics)
        let labelAlphaBounds = labelAlpha.boundingRect(with: rect.size, options: .usesDeviceMetrics)
        labelBounds.size.height *= 3.0 // because of the \n, we have 2 lines!
        labelBounds.size.height += 1.0
        labelBounds.size.width = labelValueBounds.size.width
        if labelValueBounds.size.width < labelAlphaBounds.size.width { labelBounds.size.width = labelAlphaBounds.size.width }
        labelBounds.size.width += 4.0

        if labelPosition.y + labelBounds.size.height >= rect.size.height {
            labelPosition.y = rect.size.height - labelBounds.size.height
        }

        if labelPosition.x + labelBounds.size.width >= rect.size.width {
            labelPosition.x = rect.size.width - labelBounds.size.width
        }

        let labelRect = NSBezierPath(rect: NSMakeRect(labelPosition.x - 2.0, labelPosition.y, labelBounds.size.width, labelBounds.size.height))
        NSColor.black.withAlphaComponent(0.5).set()
        labelRect.fill()
        label.draw(at: labelPosition)
    }

    @objc(addPoint:atIndex:inCurveAtIndex:withColor:)
    public func addPoint(_ point: NSPoint, at pointIndex: Int32, inCurveAt curveIndex: Int32, with color: NSColor) {
        registerUndo { $0.removePoint(at: pointIndex, inCurveAt: curveIndex) }

        mutableCurve(Int(curveIndex)).insert(NSValue(point: point), at: Int(pointIndex))
        mutableColors(Int(curveIndex)).insert(color, at: Int(pointIndex))
    }

    @objc(removePointAtIndex:inCurveAtIndex:)
    public func removePoint(at ip: Int32, inCurveAt ic: Int32) {
        let theCurve = mutableCurve(Int(ic))
        if theCurve.count <= 3 {
            deleteCurveAtIndex(ic)
        } else if ip == 0 || Int(ip) == theCurve.count - 1 {
            return
        } else {
            let previousPoint = point(theCurve, Int(ip))
            let previousColor = colors(Int(ic)).object(at: Int(ip)) as! NSColor
            let endFollowed = Int(ip) + 2 == theCurve.count && windowedCount(Int(ic)) < theCurve.count && rgb(colors(Int(ic)).lastObject as? NSColor) == rgb(previousColor)
            registerUndo { $0.addPoint(previousPoint, at: ip, inCurveAt: ic, with: previousColor) }
            theCurve.removeObject(at: Int(ip))
            mutableColors(Int(ic)).removeObject(at: Int(ip))
            // An open end that had the colour of the point removed takes the colour of the point now before it, as setColor gives it.
            if endFollowed && windowedCount(Int(ic)) < theCurve.count { setColor(colors(Int(ic)).object(at: Int(ip) - 1) as? NSColor, forPointAt: ip, inCurveAt: ic) }
        }
        unselectPoints()
        clutChanged = true // the volume loses the point (or the curve) too
        updateView()
    }

    @objc(replacePointAtIndex:inCurveAtIndex:withPoint:)
    public func replacePoint(at ip: Int32, inCurveAt ic: Int32, with point: NSPoint) {
        let previousPoint = self.point(curve(Int(ic)), Int(ip))
        registerUndo { $0.replacePoint(at: ip, inCurveAt: ic, with: previousPoint) }
        mutableCurve(Int(ic)).replaceObject(at: Int(ip), with: NSValue(point: point))
    }

    // MARK: - Control Point

    @objc(controlPointForCurveAtIndex:)
    public func controlPointForCurve(at i: Int32) -> NSPoint {
        // Halfway between the curve's ends, an open end left out, at half the height of its middle.
        let aCurve = curve(Int(i)), n = windowedCount(Int(i))
        let y = n % 2 == 1 ? point(aCurve, (n - 1) / 2).y / 2.0 : (point(aCurve, n / 2 - 1).y + point(aCurve, n / 2).y) / 4.0
        return transform().transform(NSPoint(x: (point(aCurve, n - 1).x + point(aCurve, 0).x) / 2.0, y: y))
    }

    @discardableResult
    @objc(selectControlPointAtPosition:)
    public func selectControlPoint(atPosition position: NSPoint) -> Bool {
        guard let hit = nearestHit(to: position, squares: true) else { return false }
        selectedPoint = controlPointForCurve(at: Int32(truncatingIfNeeded: hit.curve))
        sendToFrontCurve(at: Int32(truncatingIfNeeded: hit.curve))
        selectedCurve = 0
        clutChanged = false // the curves go to the volume here, in their new order: the mouse up sends nothing more
        setCLUTtoVRView(false)
        return true
    }

    // MARK: - Lines selection

    @discardableResult
    @objc(clickOnLineAtPosition:)
    public func clickOnLine(atPosition position: NSPoint) -> Bool {
        var i = 0, j = 0
        var pt0: NSPoint, pt1: NSPoint, p0: NSPoint, p1: NSPoint
        var a: Float, b: Float // line between p0 & p1 : y = a x + b
        let transform = self.transform()
        var aCurve: NSArray = NSArray()
        var colors: NSArray = NSArray()

        var addPoint = false

        while i < curves.count && !addPoint {
            aCurve = curve(i)
            colors = self.colors(i)
            j = 1
            while j < aCurve.count && !addPoint {
                pt0 = point(aCurve, j - 1)
                pt1 = point(aCurve, j)
                p0 = transform.transform(pt0)
                p1 = transform.transform(pt1)

                if position.x > p0.x && position.x < p1.x {
                    if (position.y >= p0.y && position.y <= p1.y) || (position.y <= p0.y && position.y >= p1.y) || (p0.y == p1.y && position.y >= p0.y - 10.0 && position.y <= p0.y + 10.0) {
                        // b = p0.y - a*p0.x and a*x + b, fused as clang contracted them.
                        a = Float(Double(p1.y - p0.y) / Double(p1.x - p0.x))
                        b = Float(Double(p0.y).addingProduct(-Double(a), Double(p0.x)))
                        let y = Double(b).addingProduct(Double(a), Double(position.x))
                        if Double(position.y) >= y - 10.0 && Double(position.y) <= y + 10.0 {
                            addPoint = true
                        }
                    }
                } else if position.x == p0.x && position.x == p1.x {
                    addPoint = true
                }
                j += 1
            }
            i += 1
        }

        if addPoint {
            nothingChanged = false
            clutChanged = true
            transform.invert()
            var newPoint = transform.transform(position)
            if point(aCurve, j - 2).y == point(aCurve, j - 1).y { newPoint.y = point(aCurve, j - 1).y } // on a flat line, which stays flat (an open end, open)
            selectedPoint = newPoint
            let blendingFactor = Float(Double(newPoint.x - point(aCurve, j - 2).x) / Double(point(aCurve, j - 1).x - point(aCurve, j - 2).x))
            if let blended = (colors.object(at: j - 2) as! NSColor).blended(withFraction: CGFloat(blendingFactor), of: colors.object(at: j - 1) as! NSColor) {
                self.addPoint(newPoint, at: Int32(j - 1), inCurveAt: Int32(i - 1), with: blended)
            }
            sendToFrontCurve(at: Int32(i - 1))
            selectedCurve = -1 // the new point, as a click on it: Delete removes it, «−» its curve
            updateView()
        }

        return addPoint
    }

    // MARK: - Mouse

    public override func mouseDown(with theEvent: NSEvent) {
        let mousePositionInWindow = theEvent.locationInWindow
        let mousePositionInView = convert(mousePositionInWindow, from: nil)

        mouseDraggingStartPoint = mousePositionInView

        nothingChanged = true
        clutChanged = false
        sentInClick = false
        if !clickUndoGroupOpen { clutUndoManager.beginUndoGrouping() } // a click whose mouse up never came ends with this one
        clickUndoGroupOpen = true

        vrViewLowResolution = false

        super.mouseDown(with: theEvent)

        if clickInAddCurveButton(atPosition: mousePositionInView) || clickInRemoveSelectedCurveButton(atPosition: mousePositionInView) || clickInSaveButton(atPosition: mousePositionInView) || clickInCloseButton(atPosition: mousePositionInView) {
            needsDisplay = true
            return
        }

        if controlPointIsNearest(to: mousePositionInView) || !selectPoint(atPosition: mousePositionInView) {
            unselectPoints()
            if !selectControlPoint(atPosition: mousePositionInView) {
                clickOnLine(atPosition: mousePositionInView)
            } else if theEvent.clickCount == 2 {
                nothingChanged = true
                clutChanged = false
                openColourPanel()
            }
        } else if theEvent.clickCount == 2 {
            nothingChanged = true
            clutChanged = false
            openColourPanel()
        }
    }

    public override func mouseUp(with theEvent: NSEvent) {
        // A side-bar button acts at each click (both of a double-click): the undo below is for the curves.
        let clickOutlivedCurves = !clickUndoGroupOpen // replaced in the click (another kind of CLUT, a load): nothing to send or undo
        let pressedSideBarButton = [addCurveButtonRect, removeSelectedCurveButtonRect, saveButtonRect, closeButtonRect].contains { NSPointInRect(mouseDraggingStartPoint, $0) }
        if isRemoveSelectedCurveButtonHighlighted {
            removeSelectedCurve()
            isRemoveSelectedCurveButtonHighlighted = false
            nothingChanged = false
            needsDisplay = true
        }

        if clickUndoGroupOpen {
            clutUndoManager.endUndoGrouping()
            clickUndoGroupOpen = false
        }

        if isAddCurveButtonHighlighted {
            newCurve()
            isAddCurveButtonHighlighted = false
            needsDisplay = true
        }

        if isSaveButtonHighlighted {
            chooseNameAndSave(nil)
        }

        if isCloseButtonHighlighted {
            isCloseButtonHighlighted = false
            volumeView?.controller()?.clutOpacityDrawer()?.close()
        }

        let undoesClick = !clickOutlivedCurves && !pressedSideBarButton && (theEvent.clickCount == 2 || nothingChanged)
        if undoesClick {
            clutUndoManager.undoNestedGroup()
        }

        let wasInLowResolution = vrViewLowResolution
        vrViewLowResolution = false

        if !clickOutlivedCurves && (clutChanged || wasInLowResolution) {
            setCLUTtoVRView()
        } else if undoesClick && (theEvent.clickCount == 2 || !sentInClick) {
            setCLUTtoVRView(false) // what the undo put back; a click that changed nothing has sent the curves already
        }

        super.mouseUp(with: theEvent)
    }

    public override func menu(for theEvent: NSEvent) -> NSMenu? {
        return contextualMenu
    }

    public override func rightMouseDown(with theEvent: NSEvent) {
        if let contextualMenu = contextualMenu {
            NSMenu.popUpContextMenu(contextualMenu, with: theEvent, for: self)
        }
    }

    public override func mouseDragged(with theEvent: NSEvent) {
        super.mouseDragged(with: theEvent)

        NSCursor.arrow.set()

        let mousePositionInWindow = theEvent.locationInWindow
        let mousePositionInView = convert(mousePositionInWindow, from: nil)

        if clickInAddCurveButton(atPosition: mouseDraggingStartPoint) {
            _ = clickInAddCurveButton(atPosition: mousePositionInView)
            needsDisplay = true
            return
        }

        if clickInRemoveSelectedCurveButton(atPosition: mouseDraggingStartPoint) {
            _ = clickInRemoveSelectedCurveButton(atPosition: mousePositionInView)
            needsDisplay = true
            return
        }

        if clickInSaveButton(atPosition: mouseDraggingStartPoint) {
            _ = clickInSaveButton(atPosition: mousePositionInView)
            needsDisplay = true
            return
        }

        if clickInCloseButton(atPosition: mouseDraggingStartPoint) {
            _ = clickInCloseButton(atPosition: mousePositionInView)
            needsDisplay = true
            return
        }

        if clickInSideBar(atPosition: mouseDraggingStartPoint) {
            return
        }

        if isAnyPointSelected() {
            vrViewLowResolution = true

            nothingChanged = false
            clutChanged = true
            let transformCoordinate2View = transform()
            let transformView2Coordinate = transform()
            transformView2Coordinate.invert()
            var firstPoint: NSPoint, lastPoint: NSPoint

            let mouseLocation = transformView2Coordinate.transform(convert(theEvent.locationInWindow, from: nil))
            mousePositionX = Float(mouseLocation.x)

            let alternate = theEvent.modifierFlags.contains(.option)
            for i in 0..<curves.count {
                let aCurve = mutableCurve(i), n = windowedCount(i) // the points that move as the curve, an open end left out
                let ci = Int32(truncatingIfNeeded: i)

                if !alternate {
                    for j in 0..<aCurve.count {
                        let pt = point(aCurve, j)
                        if sameEditorPoint(pt, selectedPoint) {
                            var newPoint = transformView2Coordinate.transform(convert(theEvent.locationInWindow, from: nil))
                            newPoint = legalizePoint(newPoint, inCurve: aCurve, at: Int32(j))
                            replacePoint(at: Int32(j), inCurveAt: ci, with: newPoint)
                            if j + 1 == n && n < aCurve.count { replacePoint(at: Int32(n), inCurveAt: ci, with: NSPoint(x: self.lastPoint(aCurve).x, y: newPoint.y)) }
                            selectedPoint.x = newPoint.x
                            selectedPoint.y = newPoint.y
                            updateView()
                        }
                    }
                } else {
                    firstPoint = point(aCurve, 0)
                    lastPoint = point(aCurve, n - 1)
                    let firstPointSelected = sameEditorPoint(firstPoint, selectedPoint)
                    let lastPointSelected = sameEditorPoint(lastPoint, selectedPoint)
                    firstPoint = transformCoordinate2View.transform(firstPoint)
                    lastPoint = transformCoordinate2View.transform(lastPoint)
                    if firstPointSelected || lastPointSelected {
                        let shiftX = Float(theEvent.deltaX)
                        let d = Float(lastPoint.x - firstPoint.x)
                        for j in 0..<n {
                            var pt = point(aCurve, j)
                            pt = transformCoordinate2View.transform(pt)
                            var shiftedPoint: NSPoint
                            var alpha: Float = 1.0
                            if firstPointSelected {
                                alpha = Float(abs(Double(pt.x - lastPoint.x)) / Double(d))
                            } else {
                                alpha = Float(abs(Double(pt.x - firstPoint.x)) / Double(d))
                            }
                            shiftedPoint = NSMakePoint(pt.x + CGFloat(alpha * shiftX), pt.y)
                            shiftedPoint = transformView2Coordinate.transform(shiftedPoint)
                            replacePoint(at: Int32(j), inCurveAt: ci, with: shiftedPoint)
                        }
                        for j in 0..<aCurve.count {
                            var pt = point(aCurve, j)
                            pt = legalizePoint(pt, inCurve: aCurve, at: Int32(j))
                            replacePoint(at: Int32(j), inCurveAt: ci, with: pt)
                        }
                        if firstPointSelected {
                            selectedPoint = point(aCurve, 0)
                        } else {
                            selectedPoint = point(aCurve, n - 1)
                        }

                        updateView()
                    }
                }

                var controlPoint = controlPointForCurve(at: ci)
                if sameEditorPoint(controlPoint, selectedPoint) {
                    let shiftX = Float(theEvent.deltaX)
                    var shiftY = Float(theEvent.deltaY)

                    firstPoint = transformCoordinate2View.transform(point(aCurve, 0))
                    lastPoint = transformCoordinate2View.transform(point(aCurve, n - 1))
                    let d = Float(lastPoint.x - firstPoint.x)
                    let middlePointX = Float(Double(firstPoint.x) + Double(d) / 2.0)

                    for j in 0..<n {
                        var pt = point(aCurve, j)
                        pt = transformCoordinate2View.transform(pt)
                        var shiftedPoint: NSPoint
                        if theEvent.modifierFlags.contains(.option) {
                            shiftY = 0

                            var alpha: Float = 1.0
                            if j > 0 && j < n - 1 {
                                alpha = Float(2.0 * abs(Double(middlePointX) - Double(pt.x)) / Double(d))
                            }
                            if pt.x <= controlPoint.x {
                                shiftedPoint = NSMakePoint(pt.x - CGFloat(alpha * shiftX), pt.y - CGFloat(shiftY))
                            } else {
                                shiftedPoint = NSMakePoint(pt.x + CGFloat(alpha * shiftX), pt.y - CGFloat(shiftY))
                            }
                            if shiftedPoint.x > controlPoint.x + 10.0 || shiftedPoint.x < controlPoint.x - 10.0 || pt.x == controlPoint.x || (pt.x < controlPoint.x + 10.0 && shiftedPoint.x > controlPoint.x + 10.0) || (pt.x > controlPoint.x - 10.0 && shiftedPoint.x < controlPoint.x - 10.0) {
                                shiftedPoint = transformView2Coordinate.transform(shiftedPoint)
                                replacePoint(at: Int32(j), inCurveAt: ci, with: shiftedPoint)
                                controlPoint = controlPointForCurve(at: ci)
                            }
                        } else {
                            shiftedPoint = NSMakePoint(pt.x + CGFloat(shiftX), pt.y - CGFloat(shiftY))
                            if j == 0 { shiftedPoint = NSMakePoint(pt.x + CGFloat(shiftX), pt.y) }
                            shiftedPoint = transformView2Coordinate.transform(shiftedPoint)
                            replacePoint(at: Int32(j), inCurveAt: ci, with: shiftedPoint)
                            controlPoint = controlPointForCurve(at: ci)
                        }
                    }
                    if n < aCurve.count { replacePoint(at: Int32(n), inCurveAt: ci, with: NSPoint(x: self.lastPoint(aCurve).x, y: point(aCurve, n - 1).y)) }

                    for j in 0..<aCurve.count {
                        var pt = point(aCurve, j)
                        pt = legalizePoint(pt, inCurve: aCurve, at: Int32(j))
                        replacePoint(at: Int32(j), inCurveAt: ci, with: pt)
                    }
                    controlPoint = controlPointForCurve(at: ci)
                    selectedPoint.x = controlPoint.x
                    selectedPoint.y = controlPoint.y
                    updateView()
                    return
                }
            }
        } else {
            if abs(theEvent.deltaX) > abs(theEvent.deltaY) {
                zoomFixedPoint = Float(Double(zoomFixedPoint) - Double(theEvent.deltaX) / Double(zoomFactor))
            }
            updateView()
        }
    }

    public override func acceptsFirstMouse(for theEvent: NSEvent?) -> Bool {
        return true
    }

    public override func mouseMoved(with theEvent: NSEvent) {
        if !(window?.isVisible ?? false) {
            return
        }

        super.mouseMoved(with: theEvent)

        if !(window?.isMainWindow ?? false) { return }

        let mousePositionInView = convert(theEvent.locationInWindow, from: nil)

        if !NSPointInRect(NSEvent.mouseLocation, window?.frame ?? NSRect.zero) {
            NSCursor.arrow.set()
            mousePositionX = -9999.0
            updateView()
            return
        } else if clickInSideBar(atPosition: mousePositionInView) {
            let mouseLabel: String
            if clickInAddCurveButton(atPosition: mousePositionInView) {
                mouseLabel = NSLocalizedString("Add", comment: "")
            } else if clickInRemoveSelectedCurveButton(atPosition: mousePositionInView) {
                mouseLabel = NSLocalizedString("Remove", comment: "")
            } else if clickInSaveButton(atPosition: mousePositionInView) {
                mouseLabel = NSLocalizedString("Save", comment: "")
            } else if clickInCloseButton(atPosition: mousePositionInView) {
                mouseLabel = NSLocalizedString("Close", comment: "")
            } else {
                mouseLabel = ""
            }

            setCursorLabelWithText(mouseLabel)
            mousePositionX = -9999.0
            updateView()
            return
        }

        let transformView2Coordinate = transform()
        transformView2Coordinate.invert()
        let location = transformView2Coordinate.transform(mousePositionInView)

        setCursorLabelWithText(String(format: "x: %d", cInt(Double(location.x))))

        mousePositionX = Float(location.x)
        updateView()
    }

    // MARK: - Keyboard

    public override func keyDown(with theEvent: NSEvent) {
        guard let characters = theEvent.characters as NSString?, characters.length > 0 else { return }

        let c = Int(characters.character(at: 0))
        if c == NSDeleteFunctionKey || c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteCharFunctionKey {
            if isAnyPointSelected() {
                delete(self)
                return
            }
        }
        super.keyDown(with: theEvent)
    }

    public override var acceptsFirstResponder: Bool {
        return true
    }

    // MARK: - GUI

    @objc(computeHistogram:)
    @IBAction public func computeHistogram(_ sender: Any?) {
        callComputeHistogram()
        updateView()
    }

    @objc(setHistogramOpacity:)
    @IBAction public func setHistogramOpacity(_ sender: Any?) {
        histogramOpacity = senderFloatValue(sender)
        updateView()
    }

    @objc(newCurve:)
    @IBAction public func newCurve(_ sender: Any?) {
        newCurve()
    }

    @objc(setLineWidth:)
    @IBAction public func setLineWidth(_ sender: Any?) {
        lineWidth = cInt(senderFloatValue(sender))
        updateView()
    }

    @objc(setPointDiameter:)
    @IBAction public func setPointDiameter(_ sender: Any?) {
        pointDiameter = cInt(senderFloatValue(sender))
        updateView()
    }

    @objc public func niceDisplay() {
        let screenFrame = vrView?.window?.screen?.frame ?? NSRect.zero

        var newFrame = screenFrame
        newFrame.size.height = 200
        window?.backgroundColor = NSColor.black

        var vrFrame = vrView?.window?.frame ?? NSRect.zero
        vrFrame.size.height = vrFrame.size.height - newFrame.size.height + 8
        vrFrame.origin.y = vrFrame.origin.y + newFrame.size.height - 8
        if !didResizeVRVIew {
            vrView?.window?.setFrame(vrFrame, display: true, animate: false)
            volumeView?.squareView(self)
            didResizeVRVIew = true
        }


        if curves.count == 0 {
            newCurve()
        }
    }

    @objc(niceDisplay:)
    @IBAction public func niceDisplay(_ sender: Any?) {
        niceDisplay()
    }

    @objc(sendToBack:)
    @IBAction public func sendToBack(_ sender: Any?) {
        let curveIndex = curveIndexOfSelection()
        guard curveIndex >= 0 else { return }
        sendToBackCurve(at: curveIndex)
        if !clutChanged { setCLUTtoVRView(false) } // the same CLUT for the volume: the curves in their order, the menu's name kept
        updateView()
    }

    /// The selected curve, by its index: undo, the volume's windowing, a zoom
    /// or a resize move its square away from the position the click stored.
    /// Else the curve of the selected point; -1 for none.
    private func curveIndexOfSelection() -> Int32 {
        if selectedCurve >= 0 && Int(selectedCurve) < curves.count { return selectedCurve }
        return selectedPointIndexes()?.curve ?? -1
    }

    /// The curve of the selected point and the point's index in it; nil for none.
    private func selectedPointIndexes() -> (curve: Int32, point: Int32)? {
        for i in 0..<curves.count {
            if let j = (0..<curve(i).count).first(where: { sameEditorPoint(selectedPoint, point(curve(i), $0)) }) {
                return (Int32(truncatingIfNeeded: i), Int32(truncatingIfNeeded: j))
            }
        }
        return nil
    }

    @objc(setZoomFator:)
    @IBAction public func setZoomFator(_ sender: Any?) {
        zoomFactor = senderFloatValue(sender)
        updateView()
    }

    @objc(scroll:)
    @IBAction public func scrollAction(_ sender: Any?) {
        let maxValue: Double = (sender as AnyObject?)?.maxValue ?? 0
        zoomFixedPoint = Float(Double(senderFloatValue(sender)) / maxValue * Double(drawingRect.size.width))
        updateView()
    }

    @objc(removeAllCurves:)
    @IBAction public func removeAllCurves(_ sender: Any?) {
        // The colors go too: they stayed, a set for each curve gone, and were
        // saved with the next preset.
        if curves.count > 0 || pointColors.count > 0 { replaceAllCurves(with: [], colors: []) }
        updateView()
    }

    /// These curves and colors in the editor's arrays in place of its own, with
    /// its own for undo: they come back together, at their indexes.
    private func replaceAllCurves(with newCurves: [Any], colors newColors: [Any]) {
        let previousCurves = Array(curves), previousColors = Array(pointColors)
        registerUndo { $0.replaceAllCurves(with: previousCurves, colors: previousColors) }
        curves.setArray(newCurves)
        pointColors.setArray(newColors)
        forgetSelection()
        nothingChanged = false
        clutChanged = true
    }

    @objc public func addCurveIfNeeded() {
        if curves.count == 0 {
            newCurve()
        }
    }

    // MARK: Custom GUI

    @objc(drawSideBar:)
    public func drawSideBar(_ rect: NSRect) {
        backgroundColor.set()
        __NSRectFill(rect)

        let leftMargin: Float = 5.0
        let topMargin: Float = 5.0
        let buttonsMargin: Float = 5.0
        let buttonSize: Float = 15.0

        closeButtonRect = NSMakeRect(rect.origin.x + CGFloat(leftMargin), rect.origin.y + rect.size.height - CGFloat(2.0 * Double(topMargin)) - CGFloat(buttonSize), CGFloat(buttonSize), CGFloat(buttonSize))
        addCurveButtonRect = NSMakeRect(closeButtonRect.origin.x, closeButtonRect.origin.y - closeButtonRect.size.height - CGFloat(buttonsMargin), CGFloat(buttonSize), CGFloat(buttonSize))
        removeSelectedCurveButtonRect = NSMakeRect(addCurveButtonRect.origin.x, addCurveButtonRect.origin.y - addCurveButtonRect.size.height - CGFloat(buttonsMargin), CGFloat(buttonSize), CGFloat(buttonSize))

        saveButtonRect = NSMakeRect(addCurveButtonRect.origin.x, CGFloat(2.0 * Double(buttonsMargin)), CGFloat(buttonSize), CGFloat(buttonSize))

        drawCloseButton(closeButtonRect)
        drawAddCurveButton(addCurveButtonRect)
        drawRemoveSelectedCurveButton(removeSelectedCurveButtonRect)
        drawSaveButton(saveButtonRect)
    }

    /// A button's circle, dark while pressed, drawn in white, the color left set.
    private func drawButtonCircle(_ rect: NSRect, highlighted: Bool) {
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 1.5
        (highlighted ? NSColor.darkGray : backgroundColor).set()
        path.fill()
        NSColor.white.set()
        path.stroke()
    }

    @objc(drawCloseButton:)
    public func drawCloseButton(_ rect: NSRect) {
        drawButtonCircle(rect, highlighted: isCloseButtonHighlighted)

        let line = NSBezierPath()
        line.lineWidth = 2.0
        var p1: NSPoint, p2: NSPoint
        p1 = NSMakePoint(rect.origin.x + 4, rect.origin.y + 4)
        p2 = NSMakePoint(rect.origin.x + rect.size.width - 4, rect.origin.y + rect.size.height - 4)
        line.move(to: p1)
        line.line(to: p2)

        p1 = NSMakePoint(rect.origin.x + 4, rect.origin.y + rect.size.height - 4)
        p2 = NSMakePoint(rect.origin.x + rect.size.width - 4, rect.origin.y + 4)
        line.move(to: p1)
        line.line(to: p2)

        line.stroke()
    }

    @objc(drawAddCurveButton:)
    public func drawAddCurveButton(_ rect: NSRect) {
        drawButtonCircle(rect, highlighted: isAddCurveButtonHighlighted)

        let line = NSBezierPath()
        line.lineWidth = 2.0
        var p1: NSPoint, p2: NSPoint
        let lineLength: Float = 11
        p1 = NSMakePoint(rect.origin.x + 2, rect.origin.y + rect.size.height * 0.5)
        p2 = NSMakePoint(p1.x + CGFloat(lineLength), p1.y)
        line.move(to: p1)
        line.line(to: p2)

        p1 = NSMakePoint(rect.origin.x + rect.size.width * 0.5, rect.origin.y + 2)
        p2 = NSMakePoint(p1.x, p1.y + CGFloat(lineLength))
        line.move(to: p1)
        line.line(to: p2)

        line.stroke()
    }

    @objc(drawRemoveSelectedCurveButton:)
    public func drawRemoveSelectedCurveButton(_ rect: NSRect) {
        drawButtonCircle(rect, highlighted: isRemoveSelectedCurveButtonHighlighted)

        let line = NSBezierPath()
        line.lineWidth = 2.0
        var p1: NSPoint, p2: NSPoint
        let lineLength: Float = 11
        p1 = NSMakePoint(rect.origin.x + 2, rect.origin.y + rect.size.height * 0.5)
        p2 = NSMakePoint(p1.x + CGFloat(lineLength), p1.y)
        line.move(to: p1)
        line.line(to: p2)

        line.stroke()
    }

    @objc(drawSaveButton:)
    public func drawSaveButton(_ rect: NSRect) {
        drawButtonCircle(rect, highlighted: isSaveButtonHighlighted)

        let center = NSMakePoint(rect.origin.x + rect.size.width * 0.5, rect.origin.y + rect.size.height * 0.5)
        let dotFrame = NSMakeRect(center.x - 3, center.y - 3, 6, 6)
        let dot = NSBezierPath(ovalIn: dotFrame)
        dot.fill()
    }

    @discardableResult
    @objc(clickInSideBarAtPosition:)
    public func clickInSideBar(atPosition position: NSPoint) -> Bool {
        return NSPointInRect(position, sideBarRect)
    }

    @discardableResult
    @objc(clickInAddCurveButtonAtPosition:)
    public func clickInAddCurveButton(atPosition position: NSPoint) -> Bool {
        isAddCurveButtonHighlighted = NSPointInRect(position, addCurveButtonRect)
        return isAddCurveButtonHighlighted
    }

    @discardableResult
    @objc(clickInRemoveSelectedCurveButtonAtPosition:)
    public func clickInRemoveSelectedCurveButton(atPosition position: NSPoint) -> Bool {
        isRemoveSelectedCurveButtonHighlighted = NSPointInRect(position, removeSelectedCurveButtonRect)
        return isRemoveSelectedCurveButtonHighlighted
    }

    @discardableResult
    @objc(clickInCloseButtonAtPosition:)
    public func clickInCloseButton(atPosition position: NSPoint) -> Bool {
        isCloseButtonHighlighted = NSPointInRect(position, closeButtonRect)
        return isCloseButtonHighlighted
    }

    @discardableResult
    @objc(clickInSaveButtonAtPosition:)
    public func clickInSaveButton(atPosition position: NSPoint) -> Bool {
        isSaveButtonHighlighted = NSPointInRect(position, saveButtonRect)
        return isSaveButtonHighlighted
    }

    // MARK: - Copy / Paste

    @objc(copy:)
    @IBAction public func copy(_ sender: Any?) {
        let curveIndex = selectedCurveIndex()

        if curveIndex >= 0 && Int(curveIndex) < curves.count {
            let dict = NSMutableDictionary(capacity: 2)
            dict.setObject(curves.object(at: Int(curveIndex)), forKey: "curve" as NSString)
            dict.setObject(pointColors.object(at: Int(curveIndex)), forKey: "colors" as NSString)

            // Compatibility: osirixCLUTOpacityCurve is a released typedstream pasteboard type.
            guard let curveData = try? HistoricalArchive.archivedData(withRootObject: dict) else { return }
            let pasteboard = NSPasteboard.general

            pasteboard.declareTypes([NSPasteboard.PasteboardType("osirixCLUTOpacityCurve")], owner: self)
            pasteboard.setData(curveData, forType: NSPasteboard.PasteboardType("osirixCLUTOpacityCurve"))
        } else {
            if selectedPoint.y >= 0.0 {
                for i in 0..<curves.count {
                    let aCurve = curve(i)
                    for j in 0..<aCurve.count {
                        let pt = point(aCurve, j)
                        if sameEditorPoint(selectedPoint, pt) {
                            // Compatibility: osirixCLUTOpacityPointColor readers expect typedstreams.
                            guard let colorData = try? HistoricalArchive.archivedData(withRootObject: colors(i).object(at: j)) else { return }
                            let pasteboard = NSPasteboard.general

                            pasteboard.declareTypes([NSPasteboard.PasteboardType("osirixCLUTOpacityPointColor")], owner: self)
                            pasteboard.setData(colorData, forType: NSPasteboard.PasteboardType("osirixCLUTOpacityPointColor"))
                            return
                        }
                    }
                }
            }
        }
    }

    @objc(paste:)
    @IBAction public func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let type = pasteboard.availableType(from: [NSPasteboard.PasteboardType("osirixCLUTOpacityCurve"), NSPasteboard.PasteboardType("osirixCLUTOpacityPointColor")])
        if type?.rawValue == "osirixCLUTOpacityCurve" {
            // A curve that does not unarchive stops here; the former code
            // raised when it inserted the missing curve. Any application can
            // write this type, so only the classes of a curve are decoded.
            guard let curveData = pasteboard.data(forType: type!),
                  let dict = RestrictedUnarchiver.unarchiveObjectOrNil(with: curveData,
                                                                       allowedClassNames: RestrictedUnarchiver.clutCurveClassNames) as? NSDictionary,
                  let aCurve = dict.object(forKey: "curve") as? NSArray,
                  let newColors = dict.object(forKey: "colors") as? NSArray else { return }

            let scx = selectedCurveIndex()
            let selectedCurve: NSArray
            if scx >= 0 && Int(scx) < curves.count {
                selectedCurve = curve(Int(scx))
            } else {
                selectedCurve = aCurve
            }

            let shift: Float = 20
            let delta = Float(Double(point(selectedCurve, 0).x) - Double(point(aCurve, 0).x) + Double(shift))

            let aNewCurve = NSMutableArray(capacity: aCurve.count)
            for i in 0..<aCurve.count {
                var pt = point(aCurve, i)
                pt.x += CGFloat(delta)
                aNewCurve.add(NSValue(point: pt))
            }

            addCurveAtindex(0, withPoints: aNewCurve, colors: newColors)
            selectCurve(at: 0)
            updateView()
        } else if type?.rawValue == "osirixCLUTOpacityPointColor" {
            if selectedPoint.y >= 0.0 {
                for i in 0..<curves.count {
                    let aCurve = curve(i)
                    for j in 0..<aCurve.count {
                        let pt = point(aCurve, j)
                        if sameEditorPoint(selectedPoint, pt) {
                            let colorData = pasteboard.data(forType: type!)
                            let color = RestrictedUnarchiver.unarchiveObjectOrNil(with: colorData,
                                                                                  allowedClassNames: RestrictedUnarchiver.colorClassNames) as? NSColor
                            setColor(color, forPointAt: Int32(j), inCurveAt: Int32(truncatingIfNeeded: i))
                            updateView()
                        }
                    }
                }
            }
        }
    }

    @objc(delete:)
    @IBAction public func delete(_ sender: Any?) {
        let curveIndex = selectedCurveIndex()
        if curveIndex >= 0 && Int(curveIndex) < curves.count {
            removeCurveSelectingNext(curveIndex) // Delete again removes the next.
        } else {
            if selectedPoint.y >= 0.0 {
                for i in 0..<curves.count {
                    let aCurve = curve(i)
                    for j in 0..<aCurve.count {
                        let pt = point(aCurve, j)
                        if sameEditorPoint(selectedPoint, pt) {
                            if aCurve.count <= 3 {
                                deleteCurveAtIndex(Int32(truncatingIfNeeded: i))
                            } else {
                                removePoint(at: Int32(j), inCurveAt: Int32(truncatingIfNeeded: i))
                            }
                            updateView()
                            return
                        }
                    }
                }
            }
        }
    }

    /// The «−» button: the selected curve goes, or the curve of the selected
    /// point (the Delete key removes the point), and the next is selected.
    private func removeSelectedCurve() {
        let curveIndex = curveIndexOfSelection()
        if curveIndex >= 0 { removeCurveSelectingNext(curveIndex) }
    }

    private func removeCurveSelectingNext(_ curveIndex: Int32) {
        deleteCurveAtIndex(curveIndex)
        if curves.count > 0 { selectCurve(at: min(curveIndex, Int32(curves.count - 1))) } else { forgetSelection() }
        vrViewLowResolution = false
        updateView()
    }

    @objc(cut:)
    @IBAction public func cut(_ sender: Any?) {
        copy(self)
        delete(self)
    }

    @objc(undo:)
    @IBAction public func undo(_ sender: Any?) {
        if clutUndoManager.canUndo && !clickUndoGroupOpen { // not while a click is in progress
            clutUndoManager.undo()
            vrViewLowResolution = false
            clutChanged = true
            updateView()
        }
    }

    @objc(redo:)
    @IBAction public func redo(_ sender: Any?) {
        if clutUndoManager.canRedo && !clickUndoGroupOpen {
            clutUndoManager.redo()
            vrViewLowResolution = false
            clutChanged = true
            updateView()
        }
    }

    // MARK: - Saving (as plist)

    @objc(chooseNameAndSave:)
    public func chooseNameAndSave(_ sender: Any?) {
        if isSaveButtonHighlighted {
            isSaveButtonHighlighted = false
            needsDisplay = true
        }
        if let sheet = chooseNameAndSaveWindow {
            if let window = window {
                window.beginSheet(sheet, completionHandler: nil)
            }
            sheet.orderFront(self)
        }
    }

    @objc(save:)
    @IBAction public func save(_ sender: Any?) {
        if ((sender as AnyObject?)?.tag ?? 0) == 1 {
            if let name = clutSavedName?.stringValue, (name as NSString).length > 0 {
                saveWithName(name)
                chooseNameAndSaveWindow?.orderOutAndEndSheet()
            }
        } else {
            chooseNameAndSaveWindow?.orderOutAndEndSheet()
        }
    }

    @objc(saveWithName:)
    public func saveWithName(_ name: String) {
        let clut = NSMutableDictionary(capacity: 2)
        clut.setObject(convertCurvesForPlist(), forKey: "curves" as NSString)
        clut.setObject(convertPointColorsForPlist(), forKey: "colors" as NSString)

        if var path = OSIWindowController.browserWindowGraph(serving: vrView)?.database?.clutsDirPath() {
            var isDir: ObjCBool = true
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue {
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            }

            if let fileName = (name as NSString).appendingPathExtension("plist") {
                path = (path as NSString).appendingPathComponent(fileName)
                clut.write(toFile: path, atomically: true)
            }
        }
        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateCLUTMenu, object: name, userInfo: nil)
        volumeView?.controller()?.setCurCLUTMenu(name)
    }

    @objc(presetFromFileWithName:)
    public class func presetFromFile(withName name: String) -> NSDictionary? {
        guard let CLUTsPath = BrowserDatabaseSource.process.browserDatabase?.clutsDirPath() else { return nil }
        var path = (CLUTsPath as NSString).appendingPathComponent(name)

        if FileManager.default.fileExists(atPath: path) {
            if (path as NSString).pathExtension == "" {
                // A CLUT of an earlier version, an NSArchiver file: read with
                // only the classes a CLUT holds and checked, as the VR preset
                // previews read it. A refused file is left as it is.
                return RestrictedUnarchiver.legacyCLUT(atPath: path)
            } else {
                return nil
            }
        } else {
            guard let plistPath = (path as NSString).appendingPathExtension("plist") else { return nil }
            path = plistPath
            if FileManager.default.fileExists(atPath: path) {
                // Any machine can leave a .plist here: the CLUT is checked
                // whole, and a malformed one is refused (left out of the menu).
                return RestrictedUnarchiver.plistCLUT(atPath: path)
            } else {
                // look in the resources bundle path
                guard let resourcePath = Bundle.main.resourcePath,
                      let fileName = (name as NSString).appendingPathExtension("plist") else { return nil }
                path = (resourcePath as NSString).appendingPathComponent((CLUTsPath as NSString).lastPathComponent)
                path = (path as NSString).appendingPathComponent(fileName)
                return RestrictedUnarchiver.plistCLUT(atPath: path)
            }
        }
    }

    @objc(loadFromFileWithName:)
    public func loadFromFile(withName name: String) {
        if let clut = CLUTOpacityView.presetFromFile(withName: name) {
            curves = CLUTOpacityView.mutableArray(clut.object(forKey: "curves"))
            pointColors = CLUTOpacityView.mutableArray(clut.object(forKey: "colors"))
            forgetSelection()
            forgetUndoHistory()
        }
    }

    /// The array a preset holds, shared as the former code shared it; an
    /// immutable one is copied, a missing one is empty (a nil array before).
    private class func mutableArray(_ object: Any?) -> NSMutableArray {
        if let array = object as? NSMutableArray { return array }
        if let array = object as? NSArray { return NSMutableArray(array: array) }
        return NSMutableArray()
    }

    // MARK: conversion to plist-compatible types

    @objc public func convertPointColorsForPlist() -> NSArray {
        let convertedPointColors = NSMutableArray()
        for i in 0..<pointColors.count {
            let colors = self.colors(i)
            let newColors = NSMutableArray()
            for j in 0..<colors.count {
                let color = colors.object(at: j) as? NSColor
                newColors.add(convertColor(toDict: color))
            }
            convertedPointColors.add(newColors)
        }
        return convertedPointColors
    }

    @objc public func convertCurvesForPlist() -> NSArray {
        let convertedCurves = NSMutableArray()
        for i in 0..<curves.count {
            let curve = self.curve(i)
            let newCurves = NSMutableArray()
            for j in 0..<curve.count {
                let point = self.point(curve, j)
                newCurves.add(convertPoint(toDict: point))
            }
            convertedCurves.add(newCurves)
        }
        return convertedCurves
    }

    @objc(convertColorToDict:)
    public func convertColor(toDict color: NSColor?) -> NSDictionary {
        let safeColor = color?.usingColorSpace(.genericRGB)
        let dict = NSMutableDictionary()
        dict.setObject(NSNumber(value: Float(safeColor?.redComponent ?? 0)), forKey: "red" as NSString)
        dict.setObject(NSNumber(value: Float(safeColor?.greenComponent ?? 0)), forKey: "green" as NSString)
        dict.setObject(NSNumber(value: Float(safeColor?.blueComponent ?? 0)), forKey: "blue" as NSString)
        return dict
    }

    @objc(convertPointToDict:)
    public func convertPoint(toDict point: NSPoint) -> NSDictionary {
        let dict = NSMutableDictionary()
        dict.setObject(NSNumber(value: Float(point.x)), forKey: "x" as NSString)
        dict.setObject(NSNumber(value: Float(point.y)), forKey: "y" as NSString)
        return dict
    }

    // MARK: conversion from plist

    // The app reads a whole CLUT with RestrictedUnarchiver.plistCLUT, which
    // also checks that curves and colours match. These two convert one half,
    // with the same check of each element: an array holding anything else
    // than curves of points {x, y} or of colours {red, green, blue} in their
    // domain converts to an empty array.

    @objc(convertPointColorsFromPlist:)
    public class func convertPointColorsFromPlist(_ plistPointColor: NSArray?) -> NSMutableArray {
        let convertedPointColors = NSMutableArray()
        guard let plistPointColor = plistPointColor else { return convertedPointColors }
        for i in 0..<plistPointColor.count {
            guard let colors = plistPointColor.object(at: i) as? NSArray else { return NSMutableArray() }
            let newColors = NSMutableArray()
            for j in 0..<colors.count {
                guard let color = RestrictedUnarchiver.plistCLUTColor(colors.object(at: j)) else { return NSMutableArray() }
                newColors.add(color)
            }
            convertedPointColors.add(newColors)
        }
        return convertedPointColors
    }

    @objc(convertCurvesFromPlist:)
    public class func convertCurvesFromPlist(_ plistCurves: NSArray?) -> NSMutableArray {
        let convertedCurves = NSMutableArray()
        guard let plistCurves = plistCurves else { return convertedCurves }
        for i in 0..<plistCurves.count {
            guard let curve = plistCurves.object(at: i) as? NSArray else { return NSMutableArray() }
            let newCurve = NSMutableArray()
            for j in 0..<curve.count {
                guard let point = RestrictedUnarchiver.plistCLUTPoint(curve.object(at: j)) else { return NSMutableArray() }
                newCurve.add(NSValue(point: point))
            }
            convertedCurves.add(newCurve)
        }
        return convertedCurves
    }

    // MARK: - Connection to VRView

    @objc public func setCLUTtoVRView() {
        if windowWillClose { return }
        setCLUTtoVRView(vrViewLowResolution)
        if clutChanged {
            volumeView?.controller()?.setCurCLUTMenu(NSLocalizedString("16-bit CLUT", comment: ""))
        }
    }

    @objc public func setCLUTtoVRViewHighRes() {
        setCLUTtoVRView(false)
    }

    @objc(setCLUTtoVRView:)
    public func setCLUTtoVRView(_ lowRes: Bool) {
        if windowWillClose || settingCLUTtoVRView { return } // closing, or re-entry
        settingCLUTtoVRView = true
        sentInClick = true
        // Without curves, the empty CLUT: the volume turns transparent, as the editor shows it.
        let clut = NSMutableDictionary(capacity: 2)
        clut.setObject(curves, forKey: "curves" as NSString)
        clut.setObject(pointColors, forKey: "colors" as NSString)
        volumeView?.setAdvancedCLUT(clut, lowResolution: lowRes)
        if curves.count > 0 {
            let theCurve = curve(windowingCurveIndex())
            let firstPoint = point(theCurve, 0)
            let lastPoint = point(theCurve, windowedCount(windowingCurveIndex()) - 1)
            let ww = Float(lastPoint.x - firstPoint.x)
            let wl = Float(Double(lastPoint.x + firstPoint.x) / 2.0)

            var savedWl: Float = 0
            var savedWw: Float = 0
            volumeView?.getWLWW(&savedWl, &savedWw)

            if savedWl != wl || savedWw != ww {
                volumeView?.setWLWW(wl, ww)
            }
        }
        settingCLUTtoVRView = false

        if lowRes {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(setCLUTtoVRViewHighRes), object: nil)
            perform(#selector(setCLUTtoVRViewHighRes), with: nil, afterDelay: 0.5)
        } else {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(setCLUTtoVRViewHighRes), object: nil)
        }
    }

    @objc(setWL:ww:)
    public func setWL(_ wl: Float, ww: Float) {
        // The VRView sends it while windowing, curves or none.
        if curves.count == 0 { return }

        let theCurve = mutableCurve(windowingCurveIndex()), n = windowedCount(windowingCurveIndex())
        let firstPoint = point(theCurve, 0)
        let lastPoint = point(theCurve, n - 1)
        let half = Float(Double(lastPoint.x - firstPoint.x) / 2.0)
        let middle = Float(Double(firstPoint.x) + Double(half))

        // wl
        let shiftWL: Float = wl - middle

        //ww
        let shiftWW = Float(Double(firstPoint.x) + Double(shiftWL) - (Double(wl) - 0.5 * Double(ww)))

        var pt: NSPoint
        var factor: Float = 1.0
        for i in 0..<n {
            pt = point(theCurve, i)
            factor = Float(abs(Double(pt.x) - Double(middle)) / Double(half))
            if factor < 0.0 { factor = 0.0 }
            pt.x += CGFloat(shiftWL)
            if Double(i) < Double(n) / 2.0 {
                pt.x -= CGFloat(shiftWW * factor)
            } else {
                pt.x += CGFloat(shiftWW * factor)
            }
            pt = legalizePoint(pt, inCurve: theCurve, at: Int32(i))
            theCurve.replaceObject(at: i, with: NSValue(point: pt))
        }

        for i in 0..<theCurve.count {
            pt = point(theCurve, i)
            pt = legalizePoint(pt, inCurve: theCurve, at: Int32(i))
            theCurve.replaceObject(at: i, with: NSValue(point: pt))
        }
        nothingChanged = false
        clutChanged = true

        vrViewLowResolution = true
        updateView()
    }

    // MARK: - Cursor

    @objc(setCursorLabelWithText:)
    public func setCursorLabelWithText(_ text: String?) {
        if text == "" {
            NSCursor.arrow.set()
            return
        }

        let hotSpot = NSCursor.arrow.hotSpot

        let attrsDictionary: [NSAttributedString.Key: Any] = [.foregroundColor: textLabelColor]

        let label = NSAttributedString(string: text ?? "", attributes: attrsDictionary)
        let labelBounds = label.boundingRect(with: drawingRect.size, options: .usesDeviceMetrics)

        var imageSize = NSCursor.arrow.image.size
        let arrowWidth = Float(imageSize.width)
        imageSize.width += labelBounds.size.width
        let labelPosition = NSMakePoint(CGFloat(arrowWidth - 6), 0.0)

        // draw
        let cursorImage = NSImage(size: imageSize, flipped: false) { _ in
            NSCursor.arrow.image.draw(at: NSMakePoint(0, 0), from: NSRect.zero, operation: .copy, fraction: 1.0)
            NSColor.black.withAlphaComponent(0.5).set()
            __NSRectFill(NSMakeRect(labelPosition.x - 2, labelPosition.y + 1, labelBounds.size.width + 4, 13)) // nicer if the height stays the same when moving the mouse
            label.draw(at: labelPosition)
            return true
        }

        let cursor = NSCursor(image: cursorImage, hotSpot: hotSpot)
        cursor.set()
    }
}
