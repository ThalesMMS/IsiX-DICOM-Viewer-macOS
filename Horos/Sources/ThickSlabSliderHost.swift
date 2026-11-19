//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXImaging
import IsiXPreferences

/// A 3D MPR or curved MPR window and its slab controls. The window keeps the
/// thickness in millimeters, from the finest spacing of its volume
/// (thickSlabThinEnd) to the whole volume (dcmIntervalMax). The slider binds a
/// position from 0 to 1 on the curve the LogarithmicThickSlabSlider
/// preference chooses, linear or exponential, and the field beside it the
/// thickness within those ends (thickSlabFieldThickness). dcmIntervalMin is
/// the least interval of the window's export fields, a little under the thin
/// end (ThickSlabSliderScale.intervalFieldMinimum).
@MainActor
protocol ThickSlabSliderHost: NSObject {
    var dcmIntervalMin: Float { get set }
    var dcmIntervalMax: Float { get set }
    /// The thinnest slab of the window, in millimeters, exactly.
    var thickSlabThinEnd: Double { get set }
    var thickSlabSlider: HorosMPRThickSlabSlider? { get }
    var preferenceStore: any PreferenceStore { get }
    func getClippingRangeThicknessInMm() -> Float
    func setClippingRangeThicknessInMm(_ c: Float)
}

/// The thick end of the slab of a volume whose size is not known, as the
/// windows had it for every volume.
private let unknownVolumeSlabMaximum = 100.0

extension ThickSlabSliderHost {
    /// The thick end of the slab: the whole volume of `pixList`, the series
    /// the window reconstructs, along its longest side. Its width and height
    /// are its pixels times their spacing, its depth its slices times their
    /// interval, or their thickness when the series gives no interval.
    static func slabVolumeMaximum(of pixList: [DCMPix]) -> Float {
        guard let first = pixList.first else { return Float(unknownVolumeSlabMaximum) }
        let interval = first.sliceInterval != 0 ? abs(first.sliceInterval) : abs(first.sliceThickness)
        let sides = [Double(first.pwidth) * abs(first.pixelSpacingX), Double(first.pheight) * abs(first.pixelSpacingY),
                     Double(pixList.count) * interval]
        return Float(ThickSlabSliderScale.volumeMaximum(sides: sides, fallback: unknownVolumeSlabMaximum))
    }

    /// The thin end of the slab: the finest spacing of the volume of `pixList`.
    static func slabThinEnd(of pixList: [DCMPix]) -> Double {
        guard let first = pixList.first else { return 1 }
        return ThickSlabSliderScale.thinEnd(sliceInterval: first.sliceInterval, sliceThickness: first.sliceThickness,
                                            pixelSpacingX: first.pixelSpacingX, pixelSpacingY: first.pixelSpacingY)
    }

    /// Opens the window's slab for the series it reconstructs: its ends, and
    /// then the thinnest slab, a single sample of the volume.
    func openSlab(of pixList: [DCMPix]) {
        let thinEnd = Self.slabThinEnd(of: pixList)
        thickSlabThinEnd = thinEnd
        dcmIntervalMin = Float(ThickSlabSliderScale.intervalFieldMinimum(thinEnd: thinEnd))
        dcmIntervalMax = Self.slabVolumeMaximum(of: pixList)
        setClippingRangeThicknessInMm(Float(thinEnd))
    }

    var thickSlabSliderScale: ThickSlabSliderScale {
        ThickSlabSliderScale(minimum: thickSlabThinEnd, maximum: Double(dcmIntervalMax),
                             exponential: preferenceStore[ReconstructionPreferences.logarithmicThickSlabSlider])
    }

    /// The knob's position for the window's thickness. Only the slider binds
    /// it, as the window's thickSlabSliderPosition; every other consumer keeps
    /// the millimeters, also when the curve changes.
    var slabSliderPosition: Double {
        get { thickSlabSliderScale.position(for: Double(getClippingRangeThicknessInMm())) }
        set { setClippingRangeThicknessInMm(Float(thickSlabSliderScale.thickness(at: newValue))) }
    }

    /// The thickness the field shows, and takes: what is typed goes to the
    /// nearer end when it is beyond one, and is the number the field writes
    /// for it otherwise (SlabThicknessText.fieldThickness).
    var slabFieldThickness: Double {
        get { Double(getClippingRangeThicknessInMm()) }
        set {
            let kept = SlabThicknessText.fieldThickness(entered: newValue, thinEnd: thickSlabThinEnd, maximum: Double(dcmIntervalMax))
            setClippingRangeThicknessInMm(Float(kept))
            // A field does not read back, within its own change, a value other than the one it gave.
            if kept != newValue { onMainRunLoop { [weak self] in self?.refreshThickSlabSliderPosition() } }
        }
    }

    /// A slab read from a file, within the window's ends: a path saved
    /// without one (0) opens at the thin end.
    func slabWithinEnds(_ thickness: Double) -> Float {
        guard thickness.isFinite else { return Float(thickSlabThinEnd) }
        return Float(min(max(thickness, thickSlabThinEnd), max(thickSlabThinEnd, Double(dcmIntervalMax))))
    }

    /// The ends, the curve or the thickness changed: the slider's ruler
    /// takes the ends, and the knob and the field take the thickness, which
    /// stays as it is.
    func refreshThickSlabSliderPosition() {
        thickSlabSlider?.minimumThickness = thickSlabThinEnd
        thickSlabSlider?.maximumThickness = Double(dcmIntervalMax)
        for key in ["thickSlabSliderPosition", "thickSlabFieldThickness"] {
            willChangeValue(forKey: key)
            didChangeValue(forKey: key)
        }
    }
}

/// The curve of a window's slab slider, observed for as long as the window
/// keeps this: Settings may change it while the window is open.
@MainActor
final class ThickSlabSliderScaleObserver: NSObject {
    private weak var host: (any ThickSlabSliderHost)?

    /// The key path of the preference in the shared defaults controller.
    private static let keyPath = ReconstructionPreferences.controllerKeyPath(ReconstructionPreferences.logarithmicThickSlabSlider)

    init(host: any ThickSlabSliderHost) {
        self.host = host
        super.init()
        NSUserDefaultsController.shared.addObserver(self, forKeyPath: Self.keyPath, options: .new, context: nil)
    }

    isolated deinit {
        NSUserDefaultsController.shared.removeObserver(self, forKeyPath: Self.keyPath)
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // The defaults controller reports a default on the thread that wrote it.
        onMainActor { [weak self] in
            self?.host?.refreshThickSlabSliderPosition()
        }
    }
}

extension MPRController: ThickSlabSliderHost {
    /// The slab slider's binding, MPR.xib's thickSlabSliderPosition key.
    @objc public dynamic var thickSlabSliderPosition: Double {
        get { slabSliderPosition }
        set { slabSliderPosition = newValue }
    }

    /// The thickness field's binding, MPR.xib's thickSlabFieldThickness key.
    @objc public dynamic var thickSlabFieldThickness: Double {
        get { slabFieldThickness }
        set { slabFieldThickness = newValue }
    }
}

extension CPRController: ThickSlabSliderHost {
    /// The slab slider's binding, CPR.xib's thickSlabSliderPosition key.
    @objc public dynamic var thickSlabSliderPosition: Double {
        get { slabSliderPosition }
        set { slabSliderPosition = newValue }
    }

    /// The thickness field's binding, CPR.xib's thickSlabFieldThickness key.
    @objc public dynamic var thickSlabFieldThickness: Double {
        get { slabFieldThickness }
        set { slabFieldThickness = newValue }
    }

    /// The slab the curved path draws: the thickness the window shows, in
    /// millimeters, whatever it is, so the curved views, the slabs drawn over
    /// the planes and a path saved to a file have the slab of the field. The
    /// window gives it to every path it installs and at every change of the
    /// thickness.
    func curvedPathSlabThickness() -> CGFloat {
        let thickness = getClippingRangeThicknessInMm()
        return thickness.isFinite && thickness > 0 ? CGFloat(thickness) : 0
    }
}

/// The formatter of a reconstruction window's thickness field, named in
/// MPR.xib and CPR.xib: the number the slab slider's bubble writes, without
/// its unit, with the user's decimal separator. It reads a comma or a point,
/// and «mm» after the number or not.
@objc(IsiXThickSlabFieldFormatter)
final class ThickSlabFieldFormatter: Formatter {
    override func string(for obj: Any?) -> String? {
        guard let number = obj as? NSNumber else { return nil }
        return SlabThicknessText.number(number.doubleValue)
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        // Without a description the field says what it does of any text that is not a number.
        guard let value = SlabThicknessText.value(of: string) else { return false }
        obj?.pointee = NSNumber(value: value)
        return true
    }
}
