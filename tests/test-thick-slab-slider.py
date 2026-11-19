#!/usr/bin/env python3
"""Exercise the MPR and CPR slab bindings and the 2D slab slider's real AppKit input geometry.

The 2D slider keeps the images asked for and shows the scale of the slab at
the image the viewer shows (IsiXImaging's StackFusionScale): its track runs
from the thickness of one image to that of the series, in millimetres, on the
linear or the logarithmic curve, and is the same at every image; its marks are
stops; its bubble writes the scale's text, the toolbar's. Checked with series
of 2 mm slices every 2 mm and every 1 mm, the two a user recorded: two images
read 4.0 and 3.0 mm, a request for more images than are left reads what is
fused and stands where the images left end, the track beyond them drawn faded
and out of the knob's way, the last image has one stop that a click does not
change, and a slab that is off reads one image at the thin end. A third
recording: with the request still, the knob stays where it is from one image
of the series to the next.
"""
import private_tmpdir  # noqa: F401
import harness_defaults  # the harness's preferences stay in its own process
import isix_modules
import os
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
configuration = os.environ.get('HOROS_TEST_CONFIGURATION', 'Debug')
assert configuration in ('Debug', 'Release'), configuration
controller = (root / 'Horos/Sources/MPRController.swift').read_text()
curved = (root / 'Horos/Sources/CPRController.swift').read_text()

driver = r'''
import AppKit
import IsiXImaging
import IsiXPreferences

/// The process graph of the application, which hands the preferences to the slider and the MPR.
final class ProcessGraph: Sendable {
    static let process = ProcessGraph()
    var preferences: UserDefaults { UserDefaults.standard }
}
func check(_ ok: Bool, _ message: String) {
    if !ok { fflush(stdout); fatalError(message) }
}
func near(_ a: Double, _ b: Double, _ message: String, tolerance: Double = 1e-9) {
    check(abs(a - b) <= tolerance * max(1, abs(b)), "\(message): \(a) != \(b)")
}
for bounds in [(0.01, 100.0), (0.137, 100.0), (1.0, 200.0), (2.0, 2.1)] {
    for exponential in [false, true] {
        let scale = ThickSlabSliderScale(minimum: bounds.0, maximum: bounds.1, exponential: exponential)
        check(scale.thickness(at: 0) == bounds.0, "minimum endpoint")
        check(scale.thickness(at: 1) == bounds.1, "maximum endpoint")
        near(scale.thickness(at: 0.5), exponential ? sqrt(bounds.0 * bounds.1) : (bounds.0 + bounds.1) / 2, "midpoint")
        for p in stride(from: 0.0, through: 1.0, by: 0.01) {
            near(scale.position(for: scale.thickness(at: p)), p, "position roundtrip")
            let mm = bounds.0 + (bounds.1 - bounds.0) * p
            near(scale.thickness(at: scale.position(for: mm)), mm, "millimeter roundtrip")
        }
        check(scale.thickness(at: -1) == bounds.0 && scale.thickness(at: 2) == bounds.1, "position clamps")
        check(scale.position(for: -1) == 0 && scale.position(for: .infinity) == 1, "millimeter clamps")
        check(scale.thickness(at: .nan) == bounds.0 && scale.position(for: .nan) == 0, "NaN stays finite")
    }
}
let zero = ThickSlabSliderScale(minimum: 0, maximum: 100, exponential: true)
near(zero.thickness(at: 0.5), 50, "zero lower bound falls back to linear")
for bounds in [(0.0, 0.0), (3.0, 2.0), (Double.nan, Double.infinity)] {
    let scale = ThickSlabSliderScale(minimum: bounds.0, maximum: bounds.1, exponential: true)
    check(scale.thickness(at: 0.5).isFinite && scale.position(for: 1) == 0, "uninitialized or invalid bounds")
    check(scale.tickPositions(minimumSpacing: 0.02).isEmpty, "no ruler without a range")
}

// The MPR's knob stops at whole millimeters; its ends stay what they are.
for exponential in [false, true] {
    let scale = ThickSlabSliderScale(minimum: 0.6, maximum: 100, exponential: exponential)
    check(scale.wholeThickness(at: 0) == 0.6 && scale.wholeThickness(at: 1) == 100, "the ends of the scale are kept")
    var last = 0.6
    for p in stride(from: 0.001, through: 0.999, by: 0.001) {
        let mm = scale.wholeThickness(at: p)
        check(mm == 0.6 || mm == mm.rounded(), "whole millimeters above the slice interval: \(mm)")
        check(mm >= last && abs(mm - scale.thickness(at: p)) <= 0.5 + 1e-9, "the nearest one, never going back")
        last = mm
    }
}
check(ThickSlabSliderScale(minimum: 0.3, maximum: 100, exponential: true).wholeThickness(at: 0.01) == 0.3,
      "nothing rounds below the thin end")

// Compile the windows' slab binding (ThickSlabSliderHost.swift) with a
// millimeter storage double in place of each window's VRView. This exercises
// KVC, KVO, and the float boundary used by the renderer.
_ = NSApplication.shared
final class DCMPix: NSObject {
    var pwidth = 0, pheight = 0
    var pixelSpacingX = 0.0, pixelSpacingY = 0.0, sliceInterval = 0.0, sliceThickness = 0.0
}
@MainActor
class WindowDouble: NSObject {
    // The thin end of 0.625 mm slices, and the bound of the export's interval fields under it.
    var thickSlabThinEnd = 0.625
    var dcmIntervalMin: Float = 0.619
    var dcmIntervalMax: Float = 100
    var millimeters: Float = 10
    var writes = 0
    let preferenceStore: any PreferenceStore = PreferencesSource.process.preferences
    var thickSlabSlider: HorosMPRThickSlabSlider? = HorosMPRThickSlabSlider(frame: NSRect(x: 0, y: 0, width: 114, height: 17))
    func getClippingRangeThicknessInMm() -> Float { millimeters }
    func setClippingRangeThicknessInMm(_ value: Float) {
        millimeters = value
        writes += 1
        (self as? any ThickSlabSliderHost)?.refreshThickSlabSliderPosition()
    }
}
final class MPRController: WindowDouble {}
final class CPRController: WindowDouble {}
final class KnobUpdates: NSObject {
    var count = 0
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) { count += 1 }
}
let defaults = UserDefaults.standard
let key = ThickSlabSliderScale.defaultsKey
let original = defaults.object(forKey: key)
defer {
    if let original { defaults.set(original, forKey: key) }
    else { defaults.removeObject(forKey: key) }
}
// The windows are the main actor's, as this code is.
MainActor.assumeIsolated {
let hosts: [(String, any WindowDouble & ThickSlabSliderHost)] = [("MPR", MPRController()), ("CPR", CPRController())]
for (name, host) in hosts {
    func knob() -> Double { host.value(forKey: "thickSlabSliderPosition") as! Double }
    defaults.removeObject(forKey: key)
    check(!defaults.bool(forKey: key), "unset preference is linear")
    let updates = KnobUpdates()
    host.addObserver(updates, forKeyPath: "thickSlabSliderPosition", options: [.new], context: nil)
    let linearPosition = knob()
    defaults.set(true, forKey: key)
    host.refreshThickSlabSliderPosition()
    check(host.thickSlabSlider!.minimumThickness == host.thickSlabThinEnd, "\(name) ruler starts at the exact thin end, not at the export's bound")
    near(host.thickSlabSlider!.maximumThickness, Double(host.dcmIntervalMax), "\(name) ruler maximum follows renderer bounds")
    check(host.millimeters == 10 && host.writes == 0 && updates.count == 1, "\(name): changing scale only refreshes the knob")
    check(knob() > linearPosition, "\(name) exponential knob position")
    host.setValue(0.5, forKey: "thickSlabSliderPosition")
    near(Double(host.millimeters), sqrt(host.thickSlabThinEnd * Double(host.dcmIntervalMax)), "\(name) KVC writes mm", tolerance: 1e-6)
    defaults.set(false, forKey: key)
    let mm = host.millimeters
    host.refreshThickSlabSliderPosition()
    check(host.millimeters == mm && host.writes == 1, "\(name) returning to linear preserves mm")
    host.setValue(0.5, forKey: "thickSlabSliderPosition")
    near(Double(host.millimeters), (host.thickSlabThinEnd + Double(host.dcmIntervalMax)) / 2, "\(name) linear KVC midpoint", tolerance: 1e-6)
    // The curve preference, as the shared defaults controller reports it, moves the knob.
    let scaleObserver = ThickSlabSliderScaleObserver(host: host)
    let (before, writes) = (updates.count, host.writes)
    scaleObserver.observeValue(forKeyPath: nil, of: nil, change: nil, context: nil)
    check(updates.count == before + 1 && host.writes == writes, "\(name): the curve preference moves the knob, not the thickness")
    host.removeObserver(updates, forKeyPath: "thickSlabSliderPosition")

    // The bubble, the field and the window say one thickness, on either curve.
    let formatter = ThickSlabFieldFormatter()
    func field() -> String { formatter.string(for: host.value(forKey: "thickSlabFieldThickness")) ?? "?" }
    @MainActor func agrees(_ what: String) {
        let slider = host.thickSlabSlider!
        slider.doubleValue = knob()
        check(slider.valueText == SlabThicknessText.text(Double(host.millimeters)), "\(name) \(what): the bubble says the window's slab: \(slider.valueText) for \(host.millimeters)")
        check(slider.valueText == field() + " mm", "\(name) \(what): the bubble and the field say one number: \(slider.valueText) and \(field())")
    }
    let fieldUpdates = KnobUpdates()
    host.addObserver(fieldUpdates, forKeyPath: "thickSlabFieldThickness", options: [.new], context: nil)
    for exponential in [false, true] {
        defaults.set(exponential, forKey: key)
        host.refreshThickSlabSliderPosition()
        // The left end of the track is the thin end itself: no slab of 0.619 mm.
        host.setValue(0.0, forKey: "thickSlabSliderPosition")
        check(host.millimeters == Float(host.thickSlabThinEnd), "\(name): the left end is the exact thin end: \(host.millimeters)")
        agrees("at the thin end")
        host.setValue(1.0, forKey: "thickSlabSliderPosition")
        check(host.millimeters == host.dcmIntervalMax, "\(name): the right end is the whole volume")
        agrees("at the thick end")
        for millimeters in [2.0, 3.0, 10.0] {
            host.setValue(host.thickSlabSliderScale.position(for: millimeters), forKey: "thickSlabSliderPosition")
            near(Double(host.millimeters), millimeters, "\(name): the knob at \(millimeters) mm", tolerance: 1e-5)
            agrees("at \(millimeters) mm")
        }
        // A thickness typed beyond an end goes to the end; nothing is refused.
        let seen = fieldUpdates.count
        host.setValue(0.3, forKey: "thickSlabFieldThickness")
        check(host.millimeters == Float(host.thickSlabThinEnd) && knob() == 0, "\(name): 0.3 typed is the thin end: \(host.millimeters)")
        check(fieldUpdates.count > seen, "\(name): the field is told the thickness kept")
        agrees("0.3 typed")
        host.setValue(500.0, forKey: "thickSlabFieldThickness")
        check(host.millimeters == host.dcmIntervalMax && knob() == 1, "\(name): 500 typed is the thick end: \(host.millimeters)")
        agrees("500 typed")
        // The thin end read back from its own text, two decimals of 0.625, is the thin end.
        host.setValue(SlabThicknessText.value(of: SlabThicknessText.number(host.thickSlabThinEnd))!, forKey: "thickSlabFieldThickness")
        check(host.millimeters == Float(host.thickSlabThinEnd), "\(name): the thin end's own text is the thin end: \(host.millimeters)")
        agrees("the thin end typed")
        // The slab is the number the field shows.
        host.setValue(12.375, forKey: "thickSlabFieldThickness")
        check(host.millimeters == Float(12.4), "\(name): 12.375 typed is 12.4 mm in the window: \(host.millimeters)")
        agrees("12.375 typed")
    }
    host.removeObserver(fieldUpdates, forKeyPath: "thickSlabFieldThickness")
    defaults.set(false, forKey: key)
    // A slab read from a file stays within the ends; none (0) is the thin end.
    check(host.slabWithinEnds(0) == Float(0.625) && host.slabWithinEnds(.nan) == Float(0.625) && host.slabWithinEnds(0.3) == Float(0.625)
          && host.slabWithinEnds(7) == 7 && host.slabWithinEnds(900) == 100, "\(name): a file's slab within the ends")

    // The opening: the ends of the series, then its thinnest slab.
    let opened = DCMPix()
    (opened.pwidth, opened.pheight, opened.pixelSpacingX, opened.pixelSpacingY, opened.sliceInterval, opened.sliceThickness) = (256, 256, 0.7, 0.7, -1, 2)
    host.openSlab(of: Array(repeating: opened, count: 120))
    check(host.thickSlabThinEnd == 0.7 && host.millimeters == Float(0.7) && host.dcmIntervalMax == 180, "\(name) opens at the finest spacing: \(host.millimeters)")
    check(abs(host.dcmIntervalMin - 0.699) < 1e-6, "\(name): the export's interval keeps its slack under the thin end: \(host.dcmIntervalMin)")
    check(host.thickSlabSlider!.minimumThickness == 0.7 && knob() == 0, "\(name) opens with the knob at the left end")
    agrees("at the opening")
    // A window opened without a usable geometry still has a thin end above zero.
    host.openSlab(of: [DCMPix()])
    check(host.thickSlabThinEnd == 1 && host.millimeters == 1 && host.dcmIntervalMax == 100, "\(name) opens at 1 mm when the series says nothing")
    host.openSlab(of: [])
    check(host.thickSlabThinEnd == 1 && host.millimeters == 1, "\(name) opens at 1 mm without a series")
}
// The field's formatter: the bubble's number without its unit, a comma or a point read, and no text refused for its range.
do {
    let formatter = ThickSlabFieldFormatter()
    for millimeters in [0.625, 0.7, 1, 2.8, 12.375, 359] {
        check(formatter.string(for: NSNumber(value: millimeters)) == SlabThicknessText.number(millimeters), "the field writes \(millimeters) as the bubble does")
    }
    check(formatter.string(for: "text") == nil, "the field writes numbers only")
    for (text, value) in [("0,62", 0.62), ("0.62", 0.62), ("0,62 mm", 0.62), ("500", 500), ("0.3", 0.3), ("12,375", 12.375)] {
        var object: AnyObject?
        check(formatter.getObjectValue(&object, for: text, errorDescription: nil) && (object as? NSNumber)?.doubleValue == value, "the field reads \(text)")
    }
    var object: AnyObject?
    check(!formatter.getObjectValue(&object, for: "thick", errorDescription: nil) && !formatter.getObjectValue(&object, for: "", errorDescription: nil),
          "the field refuses what is not a number")
}
// The thick end is the whole volume along its longest side, in whole millimeters.
let pix = DCMPix()
(pix.pwidth, pix.pheight, pix.pixelSpacingX, pix.pixelSpacingY, pix.sliceInterval) = (512, 512, 0.7, 0.7, -1.25)
check(MPRController.slabVolumeMaximum(of: Array(repeating: pix, count: 1400)) == 1750, "a long volume: its slices, whichever their order")
(pix.sliceInterval, pix.sliceThickness) = (0, 0.625)
check(CPRController.slabVolumeMaximum(of: Array(repeating: pix, count: 100)) == 359,
      "a short volume: its width; the slice thickness stands for a missing interval")
check(MPRController.slabVolumeMaximum(of: []) == 100 && CPRController.slabVolumeMaximum(of: [DCMPix()]) == 100,
      "a volume whose size is unknown keeps 100 mm")
}
print("PASS: mapping, midpoint, endpoints, roundtrips, clamping, KVC and scale changes preserving mm in the MPR and the CPR; the volume's maximum")

final class SliderProbe: HorosThickSlabSlider {
    var redraws = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set { if newValue { redraws += 1 }; super.needsDisplay = newValue }
    }
}
// The 2D slider keeps the images asked for and shows the scale of the slab at
// the image the viewer shows (StackFusionScale): series of 2 mm slices every
// 2 mm and every 1 mm, as the viewer hands them over.
let english = Locale(identifier: "en_US")
func stack(_ count: Int, every interval: Double, thickness: Double, current: Int, towardsStart: Bool = false) -> StackFusionScale {
    StackFusionScale(positions: (0..<count).map { Double($0) * interval }, current: current, towardsStart: towardsStart,
                     sliceThickness: thickness, fallbackInterval: interval, capacity: count)
}
let slider = SliderProbe(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
slider.minValue = 1
slider.maxValue = 60
slider.controlSize = .mini
slider.isContinuous = true
slider.numberOfTickMarks = 45
slider.integerValue = 20
let track = slider.trackRect
func point(_ fraction: Double) -> NSPoint {
    NSPoint(x: track.minX + track.width * fraction, y: slider.bounds.midY)
}
// Before the viewer gives a scale there is no track to read.
check(slider.valueText == "" && slider.fraction == 0 && slider.tickMarkFractions.isEmpty, "a slider without a scale shows nothing")
check(slider.value(at: point(0.7)) == 20, "a slider without a scale changes nothing")

let whole = stack(60, every: 2, thickness: 2, current: 0)
slider.stackScale = whole
func thickness(_ slider: HorosThickSlabSlider) -> Double { slider.stackScale!.thickness(requested: slider.integerValue) }
check(slider.valueText == whole.text(requested: 20) && whole.text(requested: 20, locale: english) == "40.0 mm", "2D value is in millimetres: \(slider.valueText)")
check(slider.accessibilityValueDescription() == slider.valueText, "VoiceOver reads the thickness")
defaults.set(false, forKey: key)
let linearMarks = slider.tickMarkFractions
near(Double(slider.fraction), (40.0 - 2) / (120 - 2), "2D linear knob stands where its thickness is")
check(abs(whole.thickness(requested: Int(slider.value(at: point(0.5)))) - 61) <= 1, "2D linear: the stop nearest to the middle of the track, 61 mm")
// The linear marks are equal steps of millimetres from the thin end, 12 mm here, and the thick end.
slider.integerValue = 1
check(linearMarks.map { whole.thickness(requested: Int(slider.value(at: point(Double($0))))) } == [2, 14, 26, 38, 50, 62, 74, 86, 98, 110, 120],
      "2D linear marks are equally spaced in millimetres")
defaults.set(true, forKey: key)
let exponentialMarks = slider.tickMarkFractions
check(exponentialMarks != linearMarks, "2D marks change with the curve")
// The exponential marks draw the curve: far apart at the thin end, each step
// shorter than the one before, and the last two as close as a third of the
// linear distance allows. They are more than the linear ruler's, and are not
// stops; the linear marks stay evenly spaced.
let exponentialGaps = zip(exponentialMarks, exponentialMarks.dropFirst()).map { Double($1 - $0) }
check(exponentialMarks.count > linearMarks.count && exponentialMarks.count <= 17 && exponentialMarks.first == 0 && exponentialMarks.last == 1,
      "2D exponential ruler has both ends and more marks than the linear one: \(exponentialMarks.count)")
check(zip(exponentialGaps, exponentialGaps.dropFirst()).allSatisfy { $1 < $0 }, "2D exponential marks gather towards the thick end: \(exponentialGaps)")
check((exponentialGaps.last ?? 0) * Double(track.width) >= 8.0 / 3 - 1e-9 && (exponentialGaps.last ?? 1) * Double(track.width) < 8,
      "2D exponential marks are dense at the thick end and told apart: \(exponentialGaps)")
check(exponentialGaps[0] < 1.0 / 3, "2D exponential ruler leaves the thin end no bare third of the track: \(exponentialGaps[0])")
let linearGaps = zip(linearMarks, linearMarks.dropFirst()).map { Double($1 - $0) }.dropLast()
check((linearGaps.max() ?? 1) - (linearGaps.min() ?? 0) < 1e-6, "2D linear marks are evenly spaced: \(linearGaps)")
near(slider.value(at: point(0.5)), 8, "2D logarithmic midpoint: 16 mm, the stop nearest to the geometric mean of 2 and 120 mm")
check(slider.value(at: point(0.75)) - slider.value(at: point(0.5)) > slider.value(at: point(0.5)) - slider.value(at: point(0.25)),
      "2D logarithmic: increasing sensitivity")
// Every mark is where the knob stops: a click on a mark puts the knob on it,
// and the bubble writes the mark's thickness.
for (exponential, marks) in [(false, linearMarks), (true, exponentialMarks)] {
    defaults.set(exponential, forKey: key)
    check(marks.count >= 6 && marks.count <= (exponential ? 17 : 12) && marks.first == 0 && marks.last == 1, "2D main marks only, both ends: \(marks.count)")
    for (left, right) in zip(marks, marks.dropFirst()) {
        // The exponential ruler lets its marks gather: a third of the linear distance.
        check((right - left) * track.width >= (exponential ? 8.0 / 3 : 8) - 1e-9, "2D marks stay apart")
    }
    // A mark of the linear ruler is where the knob stops: a click on it puts
    // the knob on it. Those of the exponential ruler are not stops.
    for mark in exponential ? [] : marks {
        slider.integerValue = 30
        slider.doubleValue = slider.value(at: point(Double(mark)))
        near(slider.doubleValue, slider.doubleValue.rounded(), "2D marks are whole numbers of images")
        check(abs(slider.fraction - mark) * track.width < 0.01, "2D knob stands on the mark it is put on")
        check(slider.valueText == whole.text(requested: slider.integerValue) && slider.valueText.contains("mm"),
              "2D bubble on a mark writes the mark's thickness: \(slider.valueText)")
    }
    check(slider.highlightsSelectedTickMarks, "2D ruler shows selected thickness")
    check(slider.minValue == 1 && slider.maxValue == 60, "2D same bounds in both modes: the images that can be asked for")
    slider.integerValue = 30
    check(slider.value(at: point(-1)) == 1 && slider.value(at: point(2)) == 60, "2D reachable endpoints: one image and the series")
    var last = -1.0
    for count in 1...60 {
        slider.integerValue = count
        let knob = Double(slider.fraction)
        check(knob > last, "2D every image more moves the knob")
        last = knob
        // A stop within half a point of a mark gives way to the mark: there
        // the stops are closer than a pixel, and the mark is the one aimed at.
        let mark = slider.tickMarkFractions.map(Double.init).min { abs($0 - knob) < abs($1 - knob) } ?? -1
        let marked = !exponential && abs(mark - knob) * Double(track.width) <= 0.5
        let expected = marked ? whole.count(at: mark, exponential: exponential) : count
        // The thick end keeps a request that already holds it.
        slider.integerValue = count == 60 ? 59 : 60
        near(slider.value(at: point(knob)), Double(expected), "2D programmatic value and knob roundtrip")
    }
    near(last, 1, "2D the series is the thick end: no track beyond it")
}

// The two recordings, through the slider: the bubble writes what the scale does.
slider.maxValue = 80
slider.stackScale = stack(80, every: 1, thickness: 2, current: 40, towardsStart: true)
for (images, text) in [(2, "3.0 mm"), (6, "7.0 mm"), (10, "11.0 mm"), (26, "27.0 mm"), (80, "42.0 mm")] {
    slider.integerValue = images
    check(slider.stackScale!.text(requested: images, locale: english) == text && slider.valueText == slider.stackScale!.text(requested: images),
          "2 mm every 1 mm, \(images) images: \(slider.valueText)")
}
slider.maxValue = 60
let rest = stack(60, every: 2, thickness: 2, current: 34, towardsStart: true)
slider.stackScale = rest
for (images, text) in [(2, "4.0 mm"), (5, "10.0 mm"), (20, "40.0 mm"), (26, "52.0 mm"), (46, "70.0 mm"), (60, "70.0 mm")] {
    slider.integerValue = images
    check(rest.text(requested: images, locale: english) == text && slider.valueText == rest.text(requested: images),
          "2 mm every 2 mm, \(images) images: \(slider.valueText)")
    check((slider.fraction == slider.reachableFraction) == (images >= 35), "the knob is where the images left end from the 35 of them on")
}
defaults.set(false, forKey: key)
near(Double(slider.reachableFraction), (70.0 - 2) / (120 - 2), "35 images of 60 left: the knob goes as far as 70 of the 120 mm")

// The series scrolls under a request that stays: the knob and the marks do
// not move, in either direction of the slab, on either curve; the bubble
// reads the same thickness while the series has the images.
for exponential in [false, true] {
    defaults.set(exponential, forKey: key)
    for towardsStart in [false, true] {
        slider.integerValue = 5
        slider.stackScale = stack(60, every: 2, thickness: 2, current: towardsStart ? 59 : 0, towardsStart: towardsStart)
        let still = (slider.fraction, slider.tickMarkFractions, slider.valueText)
        check(slider.reachableFraction == 1, "the whole series before the image: the whole track")
        var reach = CGFloat(2)
        for left in stride(from: 59, through: 5, by: -1) {
            slider.stackScale = stack(60, every: 2, thickness: 2, current: towardsStart ? left - 1 : 60 - left, towardsStart: towardsStart)
            check(slider.fraction == still.0 && slider.tickMarkFractions == still.1 && slider.valueText == still.2,
                  "\(left) images left: the knob, the marks and the bubble stay")
            check(slider.reachableFraction < reach && slider.reachableFraction >= slider.fraction, "the reach comes down to the knob, never under it")
            reach = slider.reachableFraction
        }
        check(reach == slider.fraction, "five images left: the request is all of them")
        // Fewer images left than asked for: the knob comes down with the reach, and the bubble reads what is fused.
        slider.stackScale = stack(60, every: 2, thickness: 2, current: towardsStart ? 2 : 57, towardsStart: towardsStart)
        check(slider.fraction == slider.reachableFraction && slider.fraction < still.0 && slider.fraction > 0 && slider.integerValue == 5,
              "three images left: the knob at the reach, the request kept")
        check(slider.stackScale!.text(requested: 5, locale: english) == "6.0 mm" && slider.valueText == slider.stackScale!.text(requested: 3),
              "and the bubble reads the three: \(slider.valueText)")
        check(slider.tickMarkFractions == still.1, "the marks of the series are still there")
    }
}
defaults.set(false, forKey: key)
slider.stackScale = rest

final class ActionTarget: NSObject {
    var counts: [Int] = []
    var tracked: [Bool] = []
    @objc func changed(_ sender: HorosCellSlider) { counts.append(sender.integerValue); tracked.append(sender.isTrackingMouse) }
}
let target = ActionTarget()
slider.target = target
slider.action = #selector(ActionTarget.changed(_:))
slider.isEnabled = true
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 40),
                      styleMask: [], backing: .buffered, defer: false)
window.contentView!.addSubview(slider)
func click(_ fraction: Double) {
    let location = slider.convert(point(fraction), to: nil)
    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 0)!
    NSApp.postEvent(up, atStart: true)
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                 eventNumber: 0, clickCount: 1, pressure: 1)!
    slider.mouseDown(with: down)
}
// A request for more images than are left: the knob and the bubble show what
// is fused, and the thick end keeps the request, for where the series has it.
defaults.set(false, forKey: key)
slider.integerValue = 46
let limit = Double(slider.reachableFraction)
check(slider.fraction == slider.reachableFraction && limit < 1 && slider.valueText == rest.text(requested: 35),
      "a request beyond the images left stands at the reach and shows what is fused: \(slider.valueText)")
check([limit, (limit + 1) / 2, 1, 2].allSatisfy { slider.value(at: point($0)) == 46 }, "the reach and the track beyond it keep a larger request")
for place in [limit, (limit + 1) / 2, 1] { click(place) }
check(target.counts.isEmpty && slider.integerValue == 46, "a click at the reach or beyond it sends no action and keeps the request")
// A smaller request does not pass the reach either: beyond it, it takes the images left.
slider.integerValue = 10
check(slider.value(at: point((limit + 1) / 2)) == 35 && slider.value(at: point(1)) == 35, "the knob does not pass the reach")
slider.integerValue = 46
slider.stackScale = stack(60, every: 2, thickness: 2, current: 50, towardsStart: true)
check(slider.fraction < 1 && slider.stackScale!.text(requested: slider.integerValue, locale: english) == "92.0 mm"
      && slider.valueText == slider.stackScale!.text(requested: 46), "where the series has them, the request is whole again: \(slider.valueText)")
slider.stackScale = rest
let below = Int(slider.value(at: point(0.5)))
check(below > 1 && below < 35, "any other stop replaces the request: \(below)")
click(0.5)
check(target.counts == [below] && slider.integerValue == below, "2D action receives the images of the stop, not a position")
check(target.tracked == [true] && !slider.isTrackingMouse, "the action can tell the mouse's drag, which is over afterwards")

// The last image in the slab's direction has one stop, its own thickness: the
// knob at the thin end of the series' track, none of it within reach, and a
// click changes nothing.
let lastImage = stack(60, every: 2, thickness: 2, current: 0, towardsStart: true)
slider.integerValue = 10
slider.stackScale = lastImage
check(slider.fraction == 0 && slider.reachableFraction == 0 && slider.tickMarkFractions == linearMarks, "one stop: the thin end, on the track of the series")
check(lastImage.text(requested: 10, locale: english) == "2.0 mm" && slider.valueText == lastImage.text(requested: 10), "one stop reads one slice: \(slider.valueText)")
for place in [-1, 0, 0.4, 1, 2] { check(slider.value(at: point(place)) == 10, "one stop: a click changes nothing") }
click(0.8)
check(target.counts == [below] && slider.integerValue == 10 && slider.isEnabled, "one stop: no action, the request kept and the slab left on")

// The track beyond the images left is drawn faded, and whole up to them; a
// knob at the reach is drawn whole on both sides of it.
do {
    func drawn() -> NSBitmapImageRep {
        let bitmap = slider.bitmapImageRepForCachingDisplay(in: slider.bounds)!
        slider.cacheDisplay(in: slider.bounds, to: bitmap)
        return bitmap
    }
    func strength(_ bitmap: NSBitmapImageRep, at fraction: Double, offset: CGFloat = 0) -> CGFloat {
        let scale = CGFloat(bitmap.pixelsWide) / slider.bounds.width
        let place = point(fraction)
        return bitmap.colorAt(x: Int(((place.x + offset) * scale).rounded(.down)), y: Int((place.y * scale).rounded(.down)))?.alphaComponent ?? -1
    }
    slider.integerValue = 5
    slider.stackScale = whole
    let open = drawn()
    slider.stackScale = rest
    let cut = drawn()
    let reach = Double(slider.reachableFraction)
    check(slider.fraction < slider.reachableFraction && reach < 0.9, "the knob short of the reach, the reach short of the end")
    let (before, beyond) = ((Double(slider.fraction) + reach) / 2, (reach + 1) / 2)
    check(strength(open, at: before) > 0 && strength(open, at: before) == strength(open, at: beyond), "a track within reach is one strength all along")
    check(strength(cut, at: before) == strength(open, at: before), "up to the reach the track is as it was")
    let faded = strength(cut, at: beyond) / strength(open, at: beyond)
    check(faded > 0.15 && faded < 0.6, "beyond the reach the track is there, faded: \(faded)")
    check(strength(cut, at: reach, offset: -2) == strength(open, at: before) && strength(cut, at: reach, offset: 2) < strength(open, at: before),
          "the track changes at the reach")
    // The knob at the reach: as strong to the right of its centre as to the left.
    slider.integerValue = 46
    let stopped = drawn()
    check(slider.fraction == slider.reachableFraction, "the knob at the reach")
    check(strength(stopped, at: reach, offset: 3) > 0.9 && strength(stopped, at: reach, offset: -3) > 0.9, "a knob at the reach is whole")
    check(strength(stopped, at: beyond) == strength(cut, at: beyond), "and the track after it is faded")
}

// A slab switched off: the knob at the thin end and the thickness of one image, the request kept.
slider.stackScale = whole
slider.integerValue = 20
slider.isEnabled = false
check(slider.fraction == 0 && slider.valueText == whole.text(requested: 1) && slider.integerValue == 20, "a slab that is off reads one image")
check(!slider.tickMarkFractions.isEmpty, "and keeps the marks of its scale")
slider.isEnabled = true
near(Double(slider.fraction), (40.0 - 2) / (120 - 2), "switched on again, the knob is back at the request")

slider.integerValue = 11
target.counts = [11]
slider.removeFromSuperview()
let redraws = slider.redraws
// The harness keeps this write in the process, where the defaults tell no
// observer; they are told here as a write to the persistent domain tells them.
defaults.willChangeValue(forKey: key)
defaults.set(true, forKey: key)
defaults.didChangeValue(forKey: key)
let until = Date(timeIntervalSinceNow: 0.1)
while Date() < until { RunLoop.current.run(mode: .default, before: until) }
check(slider.redraws > redraws, "2D preference change refreshes knob drawing")
check(slider.integerValue == 11 && target.counts == [11], "2D toggle never sends a projection action")
window.contentView!.addSubview(slider)
let curved = Int(slider.value(at: point(0.46)))
click(0.46)
check(target.counts.count == 2 && target.counts[1] == curved && curved != 11, "2D logarithmic click gives the images of its stop, in the original action units")
// The image shown changes under a still knob: the same request reads another thickness, and the knob follows.
let before = (slider.valueText, slider.fraction, slider.redraws)
slider.stackScale = stack(80, every: 1, thickness: 2, current: 0)
check(slider.valueText != before.0 && slider.fraction != before.1 && slider.redraws > before.2 && slider.integerValue == curved,
      "a new scale moves the knob and the bubble, not the request")
slider.maxValue = 60
slider.stackScale = whole
defaults.set(false, forKey: key)
window.orderOut(nil)
print("PASS: 2D track in millimetres on both curves, marks on stops, the two recordings, a kept request, the last image, a slab off, native click action and curve toggle")

let mpr = HorosMPRThickSlabSlider(frame: NSRect(x: 0, y: 0, width: 114, height: 17))
mpr.minValue = 0
mpr.maxValue = 1
mpr.minimumThickness = 0.5
mpr.maximumThickness = 100
mpr.numberOfTickMarks = 20
mpr.controlSize = .mini
mpr.doubleValue = 0.25
let mprTrack = mpr.trackRect
let mprPoint = NSPoint(x: mprTrack.minX + mprTrack.width * 0.25, y: mpr.bounds.midY)
for exponential in [false, true] {
    defaults.set(exponential, forKey: key)
    // The action keeps the normalized position; the knob stops where a whole millimeter is.
    let scale = ThickSlabSliderScale(minimum: 0.5, maximum: 100, exponential: exponential)
    near(scale.thickness(at: mpr.value(at: mprPoint)), exponential ? 2 : 25, "MPR knob stops at whole millimeters")
    check(abs(mpr.value(at: mprPoint) - 0.25) < 0.02, "MPR action keeps normalized input")
    check(mpr.value(at: NSPoint(x: -50, y: mpr.bounds.midY)) == 0 && mpr.value(at: NSPoint(x: 500, y: mpr.bounds.midY)) == 1,
          "MPR ends stay the slice interval and the maximum")
    near(Double(mpr.fraction), 0.25, "MPR knob is not converted twice")
    let marks = mpr.tickMarkFractions
    check(marks.first == 0 && marks.last == 1, "MPR ruler endpoints")
    for (left, right) in zip(marks, marks.dropFirst()) {
        check((right - left) * mprTrack.width >= (exponential ? 8.0 / 3 : 8) - 1e-9, "MPR marks stay apart")
    }
    // The marks of the exponential ruler draw its curve, each step shorter than the one before; they are not stops.
    let gaps = zip(marks, marks.dropFirst()).map { Double($1 - $0) }
    if exponential { check(zip(gaps, gaps.dropFirst()).allSatisfy { $1 < $0 } && gaps[0] < 1.0 / 3, "MPR exponential marks gather: \(gaps)") }
    for mark in exponential ? [] : Array(marks.dropFirst().dropLast()) {
        let mm = scale.thickness(at: Double(mark))
        near(mm, mm.rounded(), "MPR marks are whole millimeters", tolerance: 1e-6)
        // The knob stops on the mark: a click there leaves it there.
        let onMark = NSPoint(x: mprTrack.minX + mprTrack.width * mark, y: mpr.bounds.midY)
        check(abs(mpr.value(at: onMark) - Double(mark)) * mprTrack.width < 0.01, "MPR knob stands on its marks")
    }
}
let mprMarks = mpr.tickMarkFractions
mpr.maximumThickness = 50
check(mpr.tickMarkFractions != mprMarks, "MPR ruler follows physical bounds")
let ordinary = HorosCellSlider(frame: mpr.frame)
ordinary.numberOfTickMarks = 5
check(ordinary.tickMarkFractions == [0, 0.25, 0.5, 0.75, 1], "ordinary sliders retain uniform marks")
check(!ordinary.highlightsSelectedTickMarks, "ordinary slider appearance unchanged")
mpr.numberOfTickMarks = 0
check(mpr.tickMarkFractions.isEmpty, "a slider without marks in its nib has none")

// The value above the knob: there while the pointer is on the slider, in the
// slider's unit, and following the knob.
defaults.set(false, forKey: key)
mpr.maximumThickness = 347.3
mpr.isEnabled = true
let mprScale = ThickSlabSliderScale(minimum: 0.5, maximum: 347.3, exponential: false)
mpr.doubleValue = mprScale.position(for: 36)
check(mpr.valueText.contains("36") && mpr.valueText.contains("mm"), "MPR value is in millimeters: \(mpr.valueText)")
check(mpr.valueText == SlabThicknessText.text(36), "in the text the field and the annotation share: \(mpr.valueText)")
mpr.doubleValue = 0
check(mpr.valueText.contains("5") && !mpr.valueText.contains("36"), "the thin end keeps its decimals: \(mpr.valueText)")
mpr.minimumThickness = 0.625
check(mpr.valueText == SlabThicknessText.text(0.625) && SlabThicknessText.text(0.625, locale: Locale(identifier: "it_IT")) == "0,62 mm",
      "the thin end is the exact one, written with two decimals: \(mpr.valueText)")
mpr.minimumThickness = 0.5
slider.integerValue = 20
check(slider.valueText == whole.text(requested: 20), "2D value is the thickness of its images")
check(slider.shownValueText == nil, "no value is shown while the pointer is elsewhere")
let bubbleHost = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 40), styleMask: [], backing: .buffered, defer: false)
bubbleHost.contentView!.addSubview(slider)
func pointer(_ type: NSEvent.EventType) -> NSEvent {
    NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: bubbleHost.windowNumber,
                           context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
}
slider.mouseEntered(with: pointer(.mouseEntered))
check(slider.shownValueText == whole.text(requested: 20), "the value is shown while the pointer is on the slider")
func knobOnScreen() -> CGFloat { bubbleHost.convertPoint(toScreen: slider.convert(slider.knobCenter, to: nil)).x }
check(abs(slider.shownValueFrame.midX - knobOnScreen()) <= 1, "centred on the knob")
check(slider.shownValueFrame.minY >= bubbleHost.convertPoint(toScreen: slider.convert(NSPoint(x: 0, y: slider.bounds.minY), to: nil)).y,
      "and above the slider")
slider.integerValue = 50
check(slider.shownValueText == whole.text(requested: 50) && abs(slider.shownValueFrame.midX - knobOnScreen()) <= 1, "the value follows the knob")
// Another image under a still pointer: the bubble says the new thickness at once.
slider.stackScale = rest
check(slider.shownValueText == rest.text(requested: 50) && rest.text(requested: 50, locale: english) == "70.0 mm"
      && abs(slider.shownValueFrame.midX - knobOnScreen()) <= 1, "the bubble follows the image shown: \(slider.shownValueText ?? "nil")")
slider.stackScale = whole
// One slice turns the slab off and the slider with it; past it both come back.
slider.isEnabled = false
check(slider.shownValueText == nil, "a slider turned off under the pointer shows nothing")
slider.integerValue = 2
slider.isEnabled = true
check(slider.shownValueText == whole.text(requested: 2), "turned on again under the pointer, it shows its value at once")
slider.mouseExited(with: pointer(.mouseExited))
check(slider.shownValueText == nil, "and leaves with the pointer")
slider.mouseEntered(with: pointer(.mouseEntered))
slider.removeFromSuperview()
check(slider.shownValueText == nil, "a slider taken from its window shows nothing")
bubbleHost.orderOut(nil)
print("PASS: thickness ruler follows units, exponential mapping and bounds; the knob stops on its marks; the value is shown above it")
'''

with tempfile.TemporaryDirectory(prefix='horos-thick-slab-slider-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(harness_defaults.SWIFT + driver)
    binary = folder / 'check'
    subprocess.run(['xcrun', 'swiftc', '-O' if configuration == 'Release' else '-Onone',
                    str(root / 'Horos/Sources/SliderValueBubble.swift'),
                    str(root / 'Horos/Sources/HorosCellSlider.swift'),
                    str(root / 'Horos/Sources/HorosThickSlabSlider.swift'),
                    str(root / 'Horos/Sources/ThickSlabSliderHost.swift'),
                    str(root / 'Horos/Sources/MainActorCallbacks.swift'),
                    str(root / 'Horos/Sources/PreferencesSource.swift'),
                    str(folder / 'main.swift'), *isix_modules.module_flags('IsiXImaging', folder / 'modules'), *isix_modules.module_flags('IsiXPreferences', folder / 'modules'),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

# The MPR's and the CPR's slab sliders: the same ruler, bound to the same
# position, in every localization.
windows = {name: list((root / 'Horos/Resources').glob(f'*.lproj/{name}.xib')) for name in ('MPR', 'CPR')}
for name, nibs in windows.items():
    # English and the eight languages that have a copy; Spanish, Italian and Japanese load the English nib.
    assert len(nibs) == 9, f'{name} windows exist in nine languages: {len(nibs)}'
    for path in nibs:
        document = ET.parse(path)
        slider = document.find('.//slider[@id="663"]')
        assert slider is not None, path
        assert slider.get('customClass') == 'HorosMPRThickSlabSlider', path
        assert document.find('.//outlet[@property="thickSlabSlider"]').get('destination') == '663', path
        bindings = slider.findall('./connections/binding')
        assert [(b.get('name'), b.get('keyPath')) for b in bindings] == [
            ('value', 'selection.thickSlabSliderPosition')], path
        cell = slider.find('sliderCell')
        assert float(cell.get('minValue', '0')) == 0 and float(cell.get('maxValue')) == 1, path
        # The ruler is drawn because the nib asks for marks; their number is the scale's.
        assert int(cell.get('numberOfTickMarks', '0')) >= 2, path
        # The thickness field: the window's thickness within its ends, which
        # the window keeps there itself, so nothing typed is refused for its
        # range; written and read by the formatter that shares the bubble's text.
        fields = [f for f in document.findall('.//textField')
                  if any(b.get('keyPath') == 'selection.thickSlabFieldThickness' for b in f.findall('./connections/binding'))]
        assert len(fields) == 1, path
        assert [(b.get('name'), b.get('keyPath')) for b in fields[0].findall('./connections/binding')] == [
            ('value', 'selection.thickSlabFieldThickness')], path
        formatters = list(fields[0].find('textFieldCell'))
        assert [(f.tag, f.get('customClass')) for f in formatters if f.get('key') == 'formatter'] == [
            ('customFormatter', 'IsiXThickSlabFieldFormatter')], path
        assert not [b for b in document.findall('.//binding') if b.get('keyPath') == 'selection.clippingRangeThicknessInMm'], path
        # The export's interval controls of the MPR keep the bounds with the slack.
        bounded = [b for b in document.findall('.//binding') if b.get('keyPath') in ('selection.dcmIntervalMin', 'selection.dcmIntervalMax')]
        assert len(bounded) == (4 if name == 'MPR' else 0), (path, len(bounded))
        keys = [s.text for s in document.findall('.//objectController/declaredKeys/string')]
        assert 'thickSlabSliderPosition' in keys and 'thickSlabFieldThickness' in keys, path

# Both windows take the thick end from the whole volume of the series they open.
for name, source in (('MPR', controller), ('CPR', curved)):
    assert 'self.openSlab(of: pixListStorage[0].object as? [DCMPix] ?? [])' in source, name
    assert 'self.dcmIntervalMax = ' not in source and 'self.dcmIntervalMin' not in source, name
    assert 'var thickSlabThinEnd = 1.0 { didSet { refreshThickSlabSliderPosition() } }' in source, name
host = (root / 'Horos/Sources/ThickSlabSliderHost.swift').read_text()
assert 'ThickSlabSliderScale.volumeMaximum(sides: sides, fallback: unknownVolumeSlabMaximum)' in host
opening = host[host.index('func openSlab(of pixList: [DCMPix]) {'):]
opening = opening[:opening.index('\n    }\n')]
# The ends before the thickness: the window opens at its thin end, already on the ruler.
order = ['thickSlabThinEnd = thinEnd', 'dcmIntervalMin = Float(ThickSlabSliderScale.intervalFieldMinimum(thinEnd: thinEnd))',
         'dcmIntervalMax = Self.slabVolumeMaximum(of: pixList)', 'setClippingRangeThicknessInMm(Float(thinEnd))']
assert [opening.index(step) for step in order] == sorted(opening.index(step) for step in order), opening
assert 'ThickSlabSliderScale(minimum: thickSlabThinEnd, maximum: Double(dcmIntervalMax)' in host
for name in ('MPRController', 'CPRController'):
    assert f'extension {name}: ThickSlabSliderHost {{' in host, name

# The CPR refreshes its ruler as the MPR does: bounds, thickness and curve.
assert 'var dcmIntervalMin: Float = 0 { didSet { refreshThickSlabSliderPosition() } }' in curved
assert 'var dcmIntervalMax: Float = 0 { didSet { refreshThickSlabSliderPosition() } }' in curved
assert 'private lazy var slabScaleObserver = ThickSlabSliderScaleObserver(host: self)' in curved
show = curved[curved.index('override dynamic func showWindow('):]
show = show[:show.index('\n    }\n')]
assert '_ = slabScaleObserver' in show
thickness = curved[curved.index('private func setClippingRangeThicknessValue('):curved.index('private func setClippingRangeModeValue(')]
assert 'refreshThickSlabSliderPosition()' in thickness
assert '_curvedPath?.thickness = curvedPathSlabThickness()' in thickness, 'the path keeps its thickness in mm'
assert 'thickness > 2.0' not in host, 'the curved path has the slab of the window at any thickness'
assert 'return thickness.isFinite && thickness > 0 ? CGFloat(thickness) : 0' in host, 'the path keeps its thickness in mm'

SCALE_PATH = 'ReconstructionPreferences.controllerKeyPath(ReconstructionPreferences.logarithmicThickSlabSlider)'
assert f'addObserver(self, forKeyPath: {SCALE_PATH}' in controller
assert f'removeObserver(self, forKeyPath: {SCALE_PATH}' in controller
assert f'if keyPath == {SCALE_PATH} {{\n                self.refreshThickSlabSliderPosition()\n            }}' in controller
for begin, end in [('var dcmIntervalMin:', 'var dcmIntervalMax:'),
                   ('var dcmIntervalMax:', 'var dcmmN:'),
                   ('private func setClippingRangeThicknessValue(', 'private func setClippingRangeModeValue(')]:
    section = controller[controller.index(begin):controller.index(end)]
    assert 'refreshThickSlabSliderPosition()' in section, begin
print(f'PASS: {sum(map(len, windows.values()))} localized MPR and CPR slider bindings, millimeter fields, the volume maximum and refresh wiring')

# The orthogonal MPR's slab slider is the 2D viewer's component, in every
# localization: its track is the scale the window gives it, not 2 to 128 images.
orthogonal = list((root / 'Horos/Resources').glob('*.lproj/OrthogonalMPR.xib'))
assert len(orthogonal) == 9, f'orthogonal MPR windows exist in nine languages: {len(orthogonal)}'
for path in orthogonal:
    document = ET.parse(path)
    slider = document.find('.//slider[@id="145"]')
    assert slider is not None and slider.get('customClass') == 'HorosThickSlabSlider', path
    assert document.find('.//outlet[@property="thickSlabSlider"]').get('destination') == '145', path
    assert [a.get('selector') for a in slider.findall('./connections/action')] == ['setThickSlab:'], path
    cell = slider.find('sliderCell')
    assert cell.get('maxValue') != '128' and int(cell.get('numberOfTickMarks', '0')) >= 2, path
    field = document.find('.//textField[@id="144"]')
    widths = [c.get('constant') for c in field.findall('./constraints/constraint') if c.get('firstAttribute') == 'width']
    assert widths == ['52'], (path, widths)
print(f'PASS: {len(orthogonal)} localized orthogonal MPR sliders are the 2D component, with a field for millimeters')

viewers = list((root / 'Horos/Resources').glob('*.lproj/Viewer.xib'))
assert viewers, '2D viewer windows exist'
for path in viewers:
    document = ET.parse(path)
    outlet = document.find('.//outlet[@property="sliderFusion"]')
    slider = document.find(f'.//slider[@id="{outlet.get("destination")}"]')
    assert slider.get('customClass') == 'HorosThickSlabSlider', path
    cell = slider.find('sliderCell')
    # One slice, the thin end, is the series as it is: the slider can bring it back.
    assert float(cell.get('minValue')) == 1 and float(cell.get('maxValue')) == 128, path
    assert slider.find('./connections/action').get('selector') == 'sliderFusionAction:', path
print(f'PASS: {len(viewers)} localized 2D sliders preserve bounds and projection action')
