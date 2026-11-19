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

import AppKit
import IsiXImaging
import IsiXPreferences

/// The 2D viewer keeps its slice-count value and bounds: what the user asked
/// for, in images, the unit of the projection controller, of the scroll
/// wheel, of the reslice and of the saved thickness. What the user sees is
/// the scale of the slab at the image shown (`stackScale`), in millimetres:
/// the track runs from the thickness of one image to that of the images left
/// to the end of the series, the knob stands where the thickness fused is,
/// the marks are thicknesses the knob stops at, and the bubble writes what
/// the toolbar does.
@objc(HorosThickSlabSlider)
public class HorosThickSlabSlider: HorosCellSlider {
    /// The preferences of the process graph, whose curve of the ruler the slider reads and observes.
    let preferenceStore: UserDefaults = PreferencesSource.process.preferences
    private var observesScalePreference = false
    private let valueBubble = SliderValueBubble()
    private var hoverArea: NSTrackingArea?
    private var pointerInside = false

    fileprivate var storesNormalizedPosition: Bool { false }

    /// The curve of the ruler the user chose: logarithmic, or linear.
    fileprivate var isExponential: Bool { self.preferenceStore[ReconstructionPreferences.logarithmicThickSlabSlider] }

    fileprivate var scale: ThickSlabSliderScale {
        ThickSlabSliderScale(minimum: minValue, maximum: maxValue, exponential: isExponential)
    }

    /// The scale of the 2D viewer's slab at the image it shows, given by the
    /// viewer at every change of image, series or slab. Without one the
    /// slider has no track to read: its knob stays at the thin end.
    public var stackScale: StackFusionScale? {
        didSet { if stackScale != oldValue { scaleDidChange() } }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observeScalePreference()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeScalePreference()
    }

    private func observeScalePreference() {
        self.preferenceStore.addObserver(self, forKeyPath: ReconstructionPreferences.logarithmicThickSlabSlider.name,
                                    options: .new, context: nil)
        observesScalePreference = true
    }

    isolated deinit {
        valueBubble.hide()
        if observesScalePreference {
            self.preferenceStore.removeObserver(self, forKeyPath: ReconstructionPreferences.logarithmicThickSlabSlider.name)
        }
    }

    public override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                                  change: [NSKeyValueChangeKey: Any]?,
                                                  context: UnsafeMutableRawPointer?) {
        guard keyPath == ReconstructionPreferences.logarithmicThickSlabSlider.name else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { needsDisplay = true }
        } else {
            DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
        }
    }

    /// The 2D knob stands at the thickness fused: at the thick end for a
    /// request the image shown cannot hold whole, at the thin end while the
    /// slab is off.
    public override var fraction: CGFloat {
        if storesNormalizedPosition { return super.fraction }
        guard isEnabled, let stackScale else { return 0 }
        return CGFloat(stackScale.position(ofCount: integerValue, exponential: isExponential))
    }

    /// A slider with no marks in its nib has none; one with marks has the
    /// ruler of its scale, however many the nib counted.
    public override var tickMarkFractions: [CGFloat] {
        let length = isHorizontalSlider ? trackRect.width : trackRect.height
        guard length > 0, numberOfTickMarks >= 2 else { return [] }
        let spacing = Self.markSpacing / Double(length)
        if storesNormalizedPosition { return scale.tickPositions(minimumSpacing: spacing).map { CGFloat($0) } }
        guard let stackScale else { return [] }
        let exponential = isExponential
        return stackScale.tickCounts(minimumSpacing: spacing, exponential: exponential)
            .map { CGFloat(stackScale.position(ofCount: $0, exponential: exponential)) }
    }

    /// The least distance between two marks, in points: the main marks only.
    private static let markSpacing = 8.0

    public override var highlightsSelectedTickMarks: Bool { true }

    /// How close to a mark, in points, a click lands on it: half a pixel at 1x.
    /// Where several stops share one pixel (the thick end of a long series, or
    /// of the logarithmic curve) the mark is the stop the user aims at; where
    /// every stop has a pixel of its own, the stops beside a mark stay
    /// reachable.
    private static let markSnap: CGFloat = 0.5

    /// The knob stops at the thicknesses whole numbers of images make (2D) or
    /// at whole millimeters (MPR, CPR), on either curve, the ends of the scale
    /// kept as they are; a click on a mark lands on the mark's own stop.
    public override func value(at point: NSPoint) -> Double {
        let track = trackRect
        let length = isHorizontalSlider ? track.width : track.height
        let offset = isHorizontalSlider ? point.x - track.minX : point.y - track.minY
        var position = length > 0 ? Double(min(1, max(0, offset / length))) : 0
        if length > 0, let mark = tickMarkFractions.min(by: { abs($0 * length - offset) < abs($1 * length - offset) }),
           abs(mark * length - offset) <= Self.markSnap {
            position = Double(mark)
        }
        guard storesNormalizedPosition else { return requestedCount(at: position) }
        let curve = scale
        return curve.position(for: curve.wholeThickness(at: position))
    }

    /// The images asked for by a pointer at `position` of the track: those of
    /// the stop there. The thick end, the images left at the image shown,
    /// leaves a request for those or more as it is: a click or a drag that
    /// ends there does not cut what the series holds elsewhere, and the last
    /// image, whose only stop it is, changes nothing.
    private func requestedCount(at position: Double) -> Double {
        guard let stackScale else { return doubleValue }
        let count = stackScale.count(at: position, exponential: isExponential)
        if count >= stackScale.available, integerValue >= stackScale.available { return doubleValue }
        return Double(count)
    }

    // MARK: - The value above the knob

    /// The thickness as the bubble above the knob writes it: the one fused
    /// at the image shown, the text of the toolbar; that of one image while
    /// the slab is off.
    @objc public var valueText: String {
        stackScale?.text(requested: isEnabled ? integerValue : 1) ?? ""
    }

    /// VoiceOver reads the thickness, not the count of images behind it.
    public override func accessibilityValueDescription() -> String? {
        storesNormalizedPosition ? super.accessibilityValueDescription() : valueText
    }

    /// The text the bubble shows now; nil while it shows nothing.
    @objc public var shownValueText: String? { valueBubble.shownText }

    /// The bubble's frame on screen; a zero rectangle while it is not shown.
    @objc public var shownValueFrame: NSRect { valueBubble.shownFrame ?? .zero }

    /// The bubble is there while the pointer is on the slider or drags its
    /// knob, and follows the knob: the value, the knob and the marks it has
    /// passed always say the same thickness.
    /// A drag through one slice turns the slab off and the slider with it, and
    /// back on past it: the bubble follows the drag throughout, the value
    /// included, and a hover only on an enabled slider.
    private func refreshValueBubble() {
        if window != nil, isTrackingMouse || (isEnabled && pointerInside) {
            valueBubble.show(valueText, above: knobCenter, of: self)
        } else {
            valueBubble.hide()
        }
    }

    public override func valueDidChange() {
        super.valueDidChange()
        refreshValueBubble()
    }

    /// The slab's action turns the slider off at one slice and on again past
    /// it, after the value that brought it there was shown.
    public override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { refreshValueBubble() } }
    }

    /// The bounds of the ruler changed: the same knob says another thickness.
    fileprivate func scaleDidChange() {
        needsDisplay = true
        refreshValueBubble()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        refreshValueBubble()
    }

    public override func mouseExited(with event: NSEvent) {
        pointerInside = false
        refreshValueBubble()
    }

    public override func mouseDown(with event: NSEvent) {
        // The drag is tracked inside: the knob may leave the slider's bounds
        // with the pointer, and no exit is delivered meanwhile.
        super.mouseDown(with: event)
        if let window {
            pointerInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        refreshValueBubble()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        pointerInside = false
        valueBubble.hide()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        pointerInside = false
        valueBubble.hide()
    }
}

/// MPR bindings already convert the slider's 0…1 value into millimeters.
/// These bounds describe its ruler, and let the knob stop at whole millimeters.
@objc(HorosMPRThickSlabSlider)
public final class HorosMPRThickSlabSlider: HorosThickSlabSlider {
    @objc public var minimumThickness: Double = 0 { didSet { scaleDidChange() } }
    @objc public var maximumThickness: Double = 0 { didSet { scaleDidChange() } }

    fileprivate override var storesNormalizedPosition: Bool { true }

    fileprivate override var scale: ThickSlabSliderScale {
        ThickSlabSliderScale(minimum: minimumThickness, maximum: maximumThickness,
                             exponential: self.preferenceStore[ReconstructionPreferences.logarithmicThickSlabSlider])
    }

    /// Millimeters, as the window's thickness field and the annotation of its
    /// panels write them (SlabThicknessText).
    public override var valueText: String {
        SlabThicknessText.text(scale.thickness(at: doubleValue))
    }
}

/// The slab controls of a window that asks for its slab in images and
/// switches it off by a control of its own (the orthogonal MPR): the images
/// asked for, two at least, and what the slider and the field beside it show
/// of them at the image shown.
///
/// The request changes when the user picks a thickness, not when the slab is
/// switched off nor where the series has fewer images left: there the bar
/// shows the thickness fused, and the request is whole again where the series
/// has the images.
@MainActor struct StackSlabBar {
    var requested = 2

    /// The track from two images to those left and the thickness fused, in
    /// millimeters, by one text for the bubble and the field. Off, both are
    /// disabled at the thickness that will be fused; at the last image, which
    /// has no slab, the slider has nothing to choose.
    func show(_ scale: StackFusionScale?, active: Bool, slider: NSSlider?, field: NSTextField?) {
        if let slider {
            (slider as? HorosThickSlabSlider)?.stackScale = scale
            let shown = min(requested, Int(slider.maxValue))
            if slider.integerValue != shown { slider.integerValue = shown }
            slider.isEnabled = active && (scale?.available ?? 0) > 1
        }
        field?.stringValue = scale?.text(requested: requested) ?? ""
        field?.textColor = active ? .controlTextColor : .disabledControlTextColor
    }

    /// Takes a request: the images of the stop the window's own slider
    /// stands on, or `images`, the intValue of any other sender (a plugin's).
    /// False when the slider stays on the stop already applied: a drag that
    /// changes nothing makes nothing again.
    mutating func take(_ images: Int, from sender: Any?, slider: NSSlider?, applied: Int) -> Bool {
        let fromSlider = slider != nil && (sender as AnyObject?) === slider
        let asked = max(2, fromSlider ? slider?.integerValue ?? 2 : images)
        defer { requested = asked }
        return !(fromSlider && asked == requested && applied == asked)
    }
}
