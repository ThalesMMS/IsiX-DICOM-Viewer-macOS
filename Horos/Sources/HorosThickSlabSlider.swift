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

/// The 2D viewer keeps its slice-count value and bounds. Only mouse position
/// and knob geometry use the selected curve, so scroll, reslice and saved
/// thickness continue to use the same units as the projection controller.
@objc(HorosThickSlabSlider)
public class HorosThickSlabSlider: HorosCellSlider {
    private var observesScalePreference = false

    fileprivate var storesNormalizedPosition: Bool { false }

    fileprivate var scale: ThickSlabSliderScale {
        ThickSlabSliderScale(minimum: minValue, maximum: maxValue,
                             exponential: UserDefaults.standard.bool(forKey: ThickSlabSliderScale.defaultsKey))
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
        UserDefaults.standard.addObserver(self, forKeyPath: ThickSlabSliderScale.defaultsKey,
                                         options: .new, context: nil)
        observesScalePreference = true
    }

    isolated deinit {
        if observesScalePreference {
            UserDefaults.standard.removeObserver(self, forKeyPath: ThickSlabSliderScale.defaultsKey)
        }
    }

    public override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                                  change: [NSKeyValueChangeKey: Any]?,
                                                  context: UnsafeMutableRawPointer?) {
        guard keyPath == ThickSlabSliderScale.defaultsKey else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { needsDisplay = true }
        } else {
            DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
        }
    }

    public override var fraction: CGFloat {
        storesNormalizedPosition ? super.fraction : CGFloat(scale.position(for: doubleValue))
    }

    public override var tickMarkFractions: [CGFloat] {
        let length = isHorizontalSlider ? trackRect.width : trackRect.height
        guard length > 0 else { return [] }
        return scale.tickPositions(count: numberOfTickMarks, minimumSpacing: 6 / Double(length),
                                   integral: !storesNormalizedPosition).map { CGFloat($0) }
    }

    public override var highlightsSelectedTickMarks: Bool { true }

    public override func value(at point: NSPoint) -> Double {
        if storesNormalizedPosition { return super.value(at: point) }
        let curve = scale
        guard curve.exponential else { return super.value(at: point) }
        let track = trackRect
        let position = isHorizontalSlider
            ? (track.width > 0 ? (point.x - track.minX) / track.width : 0)
            : (track.height > 0 ? (point.y - track.minY) / track.height : 0)
        return curve.thickness(at: Double(position)).rounded()
    }
}

/// MPR bindings already convert the slider's 0…1 value into millimeters.
/// These bounds describe its ruler only; input keeps the existing precision.
@objc(HorosMPRThickSlabSlider)
public final class HorosMPRThickSlabSlider: HorosThickSlabSlider {
    @objc public var minimumThickness: Double = 0 { didSet { needsDisplay = true } }
    @objc public var maximumThickness: Double = 0 { didSet { needsDisplay = true } }

    fileprivate override var storesNormalizedPosition: Bool { true }

    fileprivate override var scale: ThickSlabSliderScale {
        ThickSlabSliderScale(minimum: minimumThickness, maximum: maximumThickness,
                             exponential: UserDefaults.standard.bool(forKey: ThickSlabSliderScale.defaultsKey))
    }
}
