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
import simd

/// The stretched and straightened views of the curved MPR, as the Stenosis
/// tool sees them: where the centerline crosses a relative position, and the
/// relative position under a point, in the view's coordinates.
@MainActor @objc(HorosStenosisPathView)
public protocol StenosisPathView: AnyObject {
    @objc(stenosisViewPointForRelativePosition:)
    func stenosisViewPoint(forRelativePosition relativePosition: CGFloat) -> NSPoint
    @objc(stenosisRelativePositionForViewPoint:)
    func stenosisRelativePosition(forViewPoint viewPoint: NSPoint) -> CGFloat
}

/// The Stenosis tool of the curved MPR window: a stretch of the centerline,
/// chosen by a drag on the stretched (or straightened) view, measured section
/// by section (see Stenosis), with the area along it, the NASCET degree by
/// area and by diameter, and the lumen outlined on the middle transverse view.
///
/// Calcified plaque is taken out of the lumen each section's centerline
/// finds, never added to it: the calcium the lumen encloses, and a margin
/// around calcium, by a limit and a margin beside the lumen edge on the strip.
/// Calcium dimmer than the limit stays in the lumen, and is erased by hand
/// on the middle transverse view, for the section it shows.
///
/// It is a button of the window's toolbar, not a ROI and not a ToolMode: those
/// are shared by every viewer. On, it takes the mouse on the stretched view,
/// and on the middle transverse view while its eraser is on; off, every view
/// works as before.
@MainActor @objc(HorosStenosisTool)
public final class StenosisTool: NSObject {

    private weak var controller: CPRController?

    @objc public let toolbarButton: NSButton
    @objc public private(set) var isActive = false

    /// The stretch, in relative positions of the centerline, in the order it
    /// was dragged: the end is taken as distal.
    private(set) var start: Double?
    private(set) var end: Double?
    /// The reference, in mm from the start of the stretch.
    private(set) var reference: ClosedRange<Double>?
    /// The proximal reference of a stretch measured as a coronary artery,
    /// which is read against one on each side of the narrowing; nil for a
    /// carotid, read against the distal one alone.
    private(set) var proximalReference: ClosedRange<Double>?
    private(set) var settings = Stenosis.Settings()
    private(set) var sections: [Stenosis.Section] = []
    private(set) var result: Stenosis.Result?
    /// The plaque of the stretch, when it was measured as a coronary artery
    /// and some section of it has fat around its vessel.
    private(set) var plaque: Stenosis.Plaque?
    private(set) var computing = false
    /// The contrast of the reference the sections were measured with, which
    /// calcium has to be brighter than a share of too: a section measured
    /// again alone keeps it, and moving the reference measures the stretch
    /// again.
    private var contrast: Float?

    private enum Drag { case none, stretch(anchor: Double), start, end, referenceStart, referenceEnd, proximalStart, proximalEnd }
    private var drag = Drag.none

    private let queue = DispatchQueue(label: "Stenosis sections", qos: .userInitiated)
    private var generation = 0
    private var measuredPathNodes: NSArray?

    /// What was erased by hand from the lumen of a section, kept by where the
    /// section is on the centerline: it goes back onto the section there
    /// every time the stretch is measured again, until it is reset, a new
    /// stretch is dragged or the path itself changes.
    private struct Correction {
        var relativePosition: Double
        var strokes: [Stenosis.Erasure]
    }
    private var corrections: [Correction] = []
    /// Whether a drag on the middle transverse view erases from the lumen.
    private(set) var isErasing = false
    /// The eraser's radius, in mm.
    static let eraserRadius = 0.4

    private var pathOverlays: [StenosisPathOverlay] = []
    private var sectionOverlay: StenosisSectionOverlay?
    private var strip: StenosisStrip?

    init(controller: CPRController) {
        self.controller = controller
        toolbarButton = NSButton(title: NSLocalizedString("Stenosis", comment: "Curved MPR toolbar: the stenosis measuring tool"), target: nil, action: nil)
        super.init()
        toolbarButton.setButtonType(.pushOnPushOff)
        toolbarButton.bezelStyle = .texturedRounded
        toolbarButton.toolTip = NSLocalizedString("Drag along the curved MPR to measure a stenosis by its cross-sectional area (NASCET)", comment: "Curved MPR toolbar: tooltip of the Stenosis button")
        toolbarButton.target = self
        toolbarButton.action = #selector(toggle(_:))
        toolbarButton.sizeToFit()
    }

    // MARK: - On and off

    @objc func toggle(_ sender: Any?) {
        setActive(toolbarButton.state == .on)
    }

    @objc public func setActive(_ active: Bool) {
        toolbarButton.state = active ? .on : .off
        guard active != isActive, let controller, let cprView = controller.cprView else { return }
        isActive = active
        if active {
            pathOverlays = cprView.stenosisReformationViews().map { view in
                let overlay = StenosisPathOverlay(tool: self, pathView: view)
                overlay.frame = view.bounds
                overlay.autoresizingMask = [.width, .height]
                view.addSubview(overlay)
                return overlay
            }
            if let transverse = controller.middleTransverseView {
                let overlay = StenosisSectionOverlay(tool: self, transverseView: transverse)
                overlay.frame = transverse.bounds
                overlay.autoresizingMask = [.width, .height]
                transverse.addSubview(overlay)
                sectionOverlay = overlay
            }
            let strip = StenosisStrip(tool: self)
            self.strip = strip
            cprView.stenosisStrip = strip
            refresh()
        } else {
            pathOverlays.forEach { $0.removeFromSuperview() }
            pathOverlays = []
            sectionOverlay?.removeFromSuperview()
            sectionOverlay = nil
            isErasing = false
            cprView.stenosisStrip = nil
            strip = nil
        }
    }

    // MARK: - The mouse on the stretched view

    enum Phase { case down, dragged, up }

    /// Takes the stretched view's mouse while the tool is on: a drag marks a
    /// new stretch, and near one of its lines moves that line. Returns whether
    /// the tool took the event.
    @objc(handleMouseDown:inView:)
    public func handleMouseDown(_ event: NSEvent, in view: NSView) -> Bool { handle(event, .down, view) }
    @objc(handleMouseDragged:inView:)
    public func handleMouseDragged(_ event: NSEvent, in view: NSView) -> Bool { handle(event, .dragged, view) }
    @objc(handleMouseUp:inView:)
    public func handleMouseUp(_ event: NSEvent, in view: NSView) -> Bool { handle(event, .up, view) }

    private func handle(_ event: NSEvent, _ phase: Phase, _ view: NSView) -> Bool {
        guard isActive, let pathView = view as? StenosisPathView else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        let position = Double(pathView.stenosisRelativePosition(forViewPoint: point))
        switch phase {
        case .down:
            drag = line(near: point, in: pathView) ?? .stretch(anchor: position)
            if case .stretch = drag { start = position; end = position; reference = nil; proximalReference = nil; sections = []; result = nil; corrections = []; contrast = nil }
        case .dragged, .up:
            move(drag, to: position)
            if phase == .up {
                if case .stretch = drag, let start, let end, abs(end - start) * length < 1 {
                    // A click, not a drag: no stretch.
                    self.start = nil; self.end = nil
                }
                drag = .none
                refresh()
            }
        }
        redraw()
        return true
    }

    private var length: Double { Double(controller?.curvedPath?.bezierPath?.length() ?? 0) }

    /// Positions in mm from the start converted to relative positions of the centerline.
    func relativePosition(ofStretchPosition mm: Double) -> Double? {
        guard let start, let end, length > 0 else { return nil }
        return start + (end >= start ? 1 : -1) * mm / length
    }

    private func stretchPosition(ofRelativePosition t: Double) -> Double {
        guard let start, let end else { return 0 }
        return (end >= start ? 1 : -1) * (t - start) * length
    }

    var stretchLength: Double {
        guard let start, let end else { return 0 }
        return abs(end - start) * length
    }

    /// The lines of the stretch near a point, as positions to drag.
    private func line(near point: NSPoint, in view: StenosisPathView) -> Drag? {
        var candidates: [(Drag, Double)] = []
        if let start { candidates.append((.start, start)) }
        if let end { candidates.append((.end, end)) }
        if let reference {
            if let t = relativePosition(ofStretchPosition: reference.lowerBound) { candidates.append((.referenceStart, t)) }
            if let t = relativePosition(ofStretchPosition: reference.upperBound) { candidates.append((.referenceEnd, t)) }
        }
        if let proximalReference {
            if let t = relativePosition(ofStretchPosition: proximalReference.lowerBound) { candidates.append((.proximalStart, t)) }
            if let t = relativePosition(ofStretchPosition: proximalReference.upperBound) { candidates.append((.proximalEnd, t)) }
        }
        let near = candidates.map { ($0.0, StenosisPathOverlay.distance(from: point, toLineAt: CGFloat($0.1), in: view)) }
            .filter { $0.1 < 6 }.min { $0.1 < $1.1 }
        return near?.0
    }

    private func move(_ drag: Drag, to position: Double) {
        let t = min(max(position, 0), 1)
        switch drag {
        case .none: break
        case .stretch(let anchor): start = anchor; end = t
        case .start: start = t
        case .end: end = t
        case .referenceStart, .referenceEnd:
            guard let current = reference else { return }
            let mm = min(max(stretchPosition(ofRelativePosition: t), 0), stretchLength)
            if case .referenceStart = drag { reference = min(mm, current.upperBound)...current.upperBound }
            else { reference = current.lowerBound...max(mm, current.lowerBound) }
        case .proximalStart, .proximalEnd:
            guard let current = proximalReference else { return }
            let mm = min(max(stretchPosition(ofRelativePosition: t), 0), stretchLength)
            if case .proximalStart = drag { proximalReference = min(mm, current.upperBound)...current.upperBound }
            else { proximalReference = current.lowerBound...max(mm, current.lowerBound) }
        }
    }

    // MARK: - Measuring

    /// The lumen edge, as a fraction of the centerline's intensity.
    func setLowerFraction(_ value: Double) {
        settings.lowerFraction = value
        refresh()
    }

    /// The calcium limit, as a fraction of each section's centerline
    /// intensity: what is brighter is left out of the lumen, and is calcium
    /// where it is also brighter than the same fraction of the reference's.
    func setUpperFraction(_ value: Double) {
        settings.upperFraction = value
        refresh()
    }

    /// The margin around the calcium left out with it, in mm.
    func setCalciumMargin(_ value: Double) {
        settings.calciumMargin = value
        refresh()
    }

    /// The vessel the stretch is measured as: its limits, and for a coronary
    /// artery a proximal reference beside the distal one. The choice stays
    /// with the tool, as its sliders do.
    func setVessel(_ vessel: Stenosis.Vessel) {
        guard vessel != settings.vessel else { return }
        settings.measure(as: vessel)
        if settings.plaque != nil { settings.plaque = Stenosis.PlaqueLimits(bands: storedPlaqueBands) }
        proximalReference = nil
        refresh()
    }

    /// The limits of the plaque's bands kept in the preferences, in HU: the
    /// lipid-rich, the fibro-fatty and the fibrous plaque's upper ones.
    private static let bandKeys = [ReconstructionPreferences.stenosisPlaqueLipidLimit, ReconstructionPreferences.stenosisPlaqueFibroFattyLimit,
                                   ReconstructionPreferences.stenosisPlaqueFibrousLimit]
    private var storedPlaqueBands: [Float] {
        guard let store = controller?.preferenceStore else { return [] }
        return Self.bandKeys.map { store[$0] }
    }

    /// The bands the plaque is read with: three limits that rise, above the
    /// fat. Others are refused and the bands stay; those taken are kept in
    /// the preferences, for every window and the next launch.
    @objc public var plaqueBands: [NSNumber] {
        get { (settings.plaque?.bands ?? Stenosis.PlaqueLimits.defaultBands).map { NSNumber(value: $0) } }
        set { setPlaqueBands(newValue.map(\.floatValue)) }
    }

    @discardableResult
    func setPlaqueBands(_ bands: [Float]) -> Bool {
        let limits = Stenosis.PlaqueLimits(bands: bands)
        guard limits.bands == bands else { return false }
        if let store = controller?.preferenceStore {
            for (key, value) in zip(Self.bandKeys, bands) { store.set(value, for: key) }
        }
        if settings.plaque != nil, settings.plaque != limits {
            settings.plaque = limits
            refresh()
        }
        return true
    }

    // MARK: - Correcting a section by hand

    func setErasing(_ erasing: Bool) {
        isErasing = erasing
        redraw()
    }

    /// The correction of a section, when it has one: the one within half a
    /// step of it along the centerline.
    private func correctionIndex(for section: Stenosis.Section) -> Int? {
        corrections.firstIndex { abs($0.relativePosition - section.relativePosition) * length <= settings.step / 2 + 1e-6 }
    }

    /// The strokes that took part of the lumen of the shown section, for drawing.
    var currentStrokes: [Stenosis.Erasure] {
        currentSection.flatMap { correctionIndex(for: $0) }.map { corrections[$0].strokes } ?? []
    }

    /// Takes a stroke of the eraser out of the lumen of the shown section. A
    /// section where no lumen was found has nothing to erase.
    func erase(_ stroke: Stenosis.Erasure) {
        guard let section = currentSection, section.isValid || section.corrected, !stroke.points.isEmpty else { return }
        if let index = correctionIndex(for: section) {
            corrections[index].strokes.append(stroke)
        } else {
            corrections.append(Correction(relativePosition: section.relativePosition, strokes: [stroke]))
        }
        measureCurrentSection()
    }

    /// Takes back the last stroke on the shown section.
    func undoErasure() {
        guard let section = currentSection, let index = correctionIndex(for: section) else { return }
        corrections[index].strokes.removeLast()
        if corrections[index].strokes.isEmpty { corrections.remove(at: index) }
        measureCurrentSection()
    }

    /// Gives the shown section back its automatic lumen.
    func resetCurrentSection() {
        guard let section = currentSection, let index = correctionIndex(for: section) else { return }
        corrections.remove(at: index)
        measureCurrentSection()
    }

    /// Measures the shown section again, alone: a stroke changes no other.
    /// The places of the stretch go with it, as the ring of a stent's struts
    /// is told along the vessel: alone, the section would lose it.
    private func measureCurrentSection() {
        guard !computing, let index = currentSectionIndex, let volume = controller?.stenosisVolumeData else {
            refresh()
            return
        }
        let strokes = correctionIndex(for: sections[index]).map { corrections[$0].strokes } ?? []
        let places = sections.indices.map { i in
            Stenosis.Place(position: sections[i].position, relativePosition: sections[i].relativePosition, frame: sections[i].frame,
                           erasures: i == index ? strokes : [])
        }
        let settings = self.settings
        let contrast = self.contrast
        // As the stretch was measured: no place of it is sampled again to tell.
        let stented = sections[index].stretchHoldsStent
        let job = StenosisJob(volume: volume)
        let current = generation
        redraw()
        queue.async {
            let measured = job.measure(section: index, of: places, settings: settings, contrast: contrast, stented: stented)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard current == self.generation, index < self.sections.count, let again = measured else { return }
                    self.sections[index] = again
                    self.updateResult()
                }
            }
        }
    }

    /// Measures the stretch again, off the main thread; the reference keeps
    /// its place when it still fits, and is the distal quarter otherwise.
    func refresh() {
        generation += 1
        guard isActive, let controller, let start, let end, let path = controller.curvedPath,
              let volume = controller.stenosisVolumeData,
              let flattened = path.bezierPath?.mutableCopy() as? N3MutableBezierPath, flattened.elementCount() >= 2 else {
            sections = []; result = nil; computing = false; contrast = nil
            redraw()
            return
        }
        flattened.subdivide(N3BezierDefaultSubdivideSegmentLength)
        flattened.flatten(N3BezierDefaultFlatness)
        let length = Double(flattened.length())
        let stretch = abs(end - start) * length
        if reference == nil || reference!.upperBound > stretch + 0.01 { reference = Stenosis.defaultReference(stretch: stretch) }
        if settings.vessel != .coronary {
            proximalReference = nil
        } else if proximalReference == nil || proximalReference!.upperBound > stretch + 0.01 {
            proximalReference = Stenosis.defaultProximalReference(stretch: stretch)
        }
        measuredPathNodes = path.nodes.copy() as? NSArray

        let settings = self.settings
        let count = Int((stretch / settings.step).rounded(.down)) + 1
        let direction = end >= start ? 1.0 : -1.0
        let initialNormal = path.initialNormal
        // The frames as the transverse views take them, on the main thread,
        // where the path lives.
        var frames: [StenosisJob.Frame] = (0..<count).map { i in
            let position = min(Double(i) * settings.step, stretch)
            let t = CGFloat(start + direction * position / length)
            let point = flattened.vector(atRelativePosition: t)
            let tangent = flattened.tangent(atRelativePosition: t)
            let normal = flattened.normal(atRelativePosition: t, initialNormal: initialNormal)
            return (position, Double(t), Stenosis.Frame(point: SIMD3(Double(point.x), Double(point.y), Double(point.z)),
                                                        tangent: SIMD3(Double(tangent.x), Double(tangent.y), Double(tangent.z)),
                                                        normal: SIMD3(Double(normal.x), Double(normal.y), Double(normal.z))), [])
        }
        // What was erased by hand goes back onto the section nearest to where
        // it was erased, when that section is within half a step of it.
        for correction in corrections {
            guard let nearest = frames.indices.min(by: { abs(frames[$0].1 - correction.relativePosition) < abs(frames[$1].1 - correction.relativePosition) }),
                  abs(frames[nearest].1 - correction.relativePosition) * length <= settings.step / 2 + 1e-6 else { continue }
            frames[nearest].3 += correction.strokes
        }
        let measured = frames
        let measuredReference = reference, measuredProximal = proximalReference
        computing = true
        redraw()
        let job = StenosisJob(volume: volume)
        let current = generation
        queue.async {
            let (sections, contrast) = job.measure(frames: measured, settings: settings, reference: measuredReference, proximalReference: measuredProximal, contrast: nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard current == self.generation else { return }
                    self.sections = sections
                    self.contrast = contrast
                    self.computing = false
                    self.updateResult()
                }
            }
        }
    }

    private func updateResult() {
        result = reference.flatMap { distal in
            proximalReference.map { Stenosis.result(of: sections, proximal: $0, distal: distal) } ?? Stenosis.result(of: sections, reference: distal)
        }
        plaque = settings.plaque.flatMap { Stenosis.plaque(of: sections, step: settings.step, limits: $0) }
        redraw()
    }

    /// The path changed in another view: measure again when its nodes did;
    /// a moved transverse section only needs its outline drawn again.
    @objc public func curvedPathDidChange() {
        guard isActive else { return }
        if let nodes = controller?.curvedPath?.nodes, let measured = measuredPathNodes, !nodes.isEqual(to: measured as! [Any]) {
            // Another path: what was erased was erased on sections that are no longer there.
            corrections = []
            refresh()
        } else {
            redraw()
        }
    }

    /// A view of the window drew: its overlay follows its zoom and pan.
    @objc public func viewDidDraw(_ view: NSView) {
        guard isActive else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.pathOverlays.first { $0.superview === view }?.needsDisplay = true
                if self.sectionOverlay?.superview === view { self.sectionOverlay?.needsDisplay = true }
            }
        }
    }

    private func redraw() {
        pathOverlays.forEach { $0.needsDisplay = true }
        sectionOverlay?.needsDisplay = true
        strip?.update()
    }

    /// The section shown in the middle transverse view, when it is one of the stretch.
    var currentSection: Stenosis.Section? { currentSectionIndex.map { sections[$0] } }

    private var currentSectionIndex: Int? {
        guard let t = controller?.curvedPath?.transverseSectionPosition, !sections.isEmpty else { return nil }
        let nearest = sections.indices.min { abs(sections[$0].relativePosition - Double(t)) < abs(sections[$1].relativePosition - Double(t)) }
        guard let nearest, abs(sections[nearest].relativePosition - Double(t)) * length <= settings.step else { return nil }
        return nearest
    }

    /// Moves the middle transverse section to a position of the stretch.
    func showSection(atStretchPosition mm: Double) {
        guard let t = relativePosition(ofStretchPosition: mm) else { return }
        controller?.stenosisMoveTransverseSection(to: CGFloat(t))
        redraw()
    }

    var currentStretchPosition: Double? {
        guard let t = controller?.curvedPath?.transverseSectionPosition, start != nil else { return nil }
        let mm = stretchPosition(ofRelativePosition: Double(t))
        return (0...stretchLength).contains(mm) ? mm : nil
    }

    // MARK: - Summary

    var summary: StenosisSummary? {
        guard let result, let reference else { return nil }
        return StenosisSummary(stretchLength: stretchLength, result: result, reference: reference, settings: settings, plaque: plaque)
    }

    /// Read-only, for scripting and checks: the summary as copied, whether a
    /// measure is under way, how many sections were measured, and the outline
    /// shown on the middle transverse view, in patient space, with its area
    /// in mm² (−1 when the view shows no section of the stretch) and whether
    /// its lumen was corrected by hand.
    @objc public var summaryText: String? { summary?.text }
    /// "carotid" or "coronary"; an unknown name changes nothing.
    @objc public var vesselName: String {
        get { settings.vessel.rawValue }
        set { if let vessel = Stenosis.Vessel(rawValue: newValue) { setVessel(vessel) } }
    }
    @objc public var shownSectionArea: Double { currentSection?.area ?? -1 }
    @objc public var shownSectionIsCorrected: Bool { currentSection?.corrected ?? false }
    @objc public var isMeasuring: Bool { computing }
    @objc public var measuredSectionCount: Int { sections.count }
    @objc public var shownSectionOutline: [NSValue] {
        (currentSection?.contour ?? []).compactMap { NSValue(n3Vector: N3VectorMake(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z))) }
    }

    /// Saves the strip and the summary in the study, as a Secondary Capture in
    /// a series of its own; a beep when there is nothing to save or it could
    /// not be written. Returns whether it was saved.
    @discardableResult
    func saveCapture(of strip: NSView) -> Bool {
        let stamp = DateFormatter()
        // The character set of the study may not encode a localized date.
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let description = String(format: NSLocalizedString("Stenosis - %@", comment: "Stenosis: the series of a saved capture; the argument is when it was saved"), stamp.string(from: Date()))
        // A file of the series measured, which names the study: the window's pixels, asked as any 3D window's.
        let window: Window3DController? = controller
        guard let summary, let image = StenosisCapture.image(of: strip, summary: summary.text),
              StenosisCapture.save(image, sourceFile: (window?.pixList()?.lastObject as? DCMPix)?.srcFile, description: description,
                                   into: DicomDatabase.activeLocal()) else {
            NSSound.beep()
            return false
        }
        return true
    }

    func copySummary() {
        guard let summary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary.text, forType: .string)
    }
}

/// The sections of a stretch, measured on the volume off the main thread:
/// the volume is only read, through its inline buffer, which the curved MPR's
/// generators also read from other threads.
private final class StenosisJob: @unchecked Sendable {
    /// A section to measure: its place from the start of the stretch, in mm,
    /// and on the centerline, where it is taken, and what was erased from it.
    typealias Frame = (Double, Double, Stenosis.Frame, [Stenosis.Erasure])

    let volume: CPRVolumeData
    init(volume: CPRVolumeData) { self.volume = volume }

    /// The sections, with calcium told against `contrast`, or, when there is
    /// none, against the contrast of the frames within `reference`, in mm
    /// from the start (of all of them when none of those has a lumen), which
    /// it returns (see `Stenosis.sections(at:settings:reference:contrast:sample:)`).
    func measure(frames: [Frame], settings: Stenosis.Settings, reference: ClosedRange<Double>?,
                 proximalReference: ClosedRange<Double>? = nil, contrast: Float?) -> (sections: [Stenosis.Section], contrast: Float?) {
        let places = frames.map { position, t, frame, erasures in
            Stenosis.Place(position: position, relativePosition: t, frame: frame, erasures: erasures)
        }
        return reading { sample in
            Stenosis.sections(at: places, settings: settings, reference: reference, proximalReference: proximalReference,
                              contrast: contrast, sample: sample)
        } ?? ([], contrast)
    }

    /// The section at `index` of the stretch's `places`, measured again
    /// alone against the stretch's `contrast`, with the ring of a stent's
    /// struts the places around it tell, `stented` saying whether the stretch
    /// holds a stent (see
    /// `Stenosis.section(_:of:settings:contrast:stented:sample:)`); nil when
    /// the volume cannot be read.
    func measure(section index: Int, of places: [Stenosis.Place], settings: Stenosis.Settings,
                 contrast: Float?, stented: Bool) -> Stenosis.Section? {
        reading { sample in
            Stenosis.section(index, of: places, settings: settings, contrast: contrast, stented: stented, sample: sample)
        }
    }

    /// `body` with the volume's samples, interpolated at a point in patient
    /// space; nil when the volume cannot be read.
    private func reading<T>(_ body: ((SIMD3<Double>) -> Float) -> T) -> T? {
        var inline = CPRVolumeDataInlineBuffer()
        guard volume.aquireInlineBuffer(&inline) else {
            volume.releaseInlineBuffer(&inline)
            return nil
        }
        defer { volume.releaseInlineBuffer(&inline) }
        return withUnsafeMutablePointer(to: &inline) { buffer in
            body { p in CPRVolumeDataLinearInterpolatedFloatAtDicomVectorForSwift(buffer, N3VectorMake(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z))) }
        }
    }
}

// MARK: - The chart's content

extension StenosisTool: StenosisChartSource {
    var chartContent: StenosisChartContent? {
        guard stretchLength > 0 else { return nil }
        return StenosisChartContent(
            sections: sections.map {
                .init(position: $0.position, area: $0.area, isValid: $0.isValid, corrected: $0.corrected, lumenTaken: $0.lumenTaken != nil)
            },
            stretchLength: stretchLength,
            references: [proximalReference, reference].compactMap { $0 },
            minimum: result.map { ($0.minimumPosition, $0.minimumArea) },
            current: currentStretchPosition)
    }
}

// MARK: - The lines on the stretched view

/// Over the stretched or straightened view: the start and end of the stretch,
/// the reference, and the narrowest section, each a line across the
/// centerline. The mouse goes through it to the view below.
@MainActor
final class StenosisPathOverlay: NSView {
    private weak var tool: StenosisTool?
    private weak var pathView: (NSView & StenosisPathView)?

    init(tool: StenosisTool, pathView: NSView & StenosisPathView) {
        self.tool = tool
        self.pathView = pathView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The ends of the line across the centerline at a relative position,
    /// `half` points on each side, in the path view's coordinates.
    static func line(at t: CGFloat, in view: StenosisPathView, half: CGFloat = 40) -> (NSPoint, NSPoint) {
        let p = view.stenosisViewPoint(forRelativePosition: t)
        let a = view.stenosisViewPoint(forRelativePosition: max(t - 0.002, 0))
        let b = view.stenosisViewPoint(forRelativePosition: min(t + 0.002, 1))
        var dx = b.x - a.x, dy = b.y - a.y
        let norm = (dx * dx + dy * dy).squareRoot()
        if norm < 0.0001 { dx = 1; dy = 0 } else { dx /= norm; dy /= norm }
        return (NSPoint(x: p.x - dy * half, y: p.y + dx * half), NSPoint(x: p.x + dy * half, y: p.y - dx * half))
    }

    static func distance(from point: NSPoint, toLineAt t: CGFloat, in view: StenosisPathView) -> Double {
        let (a, b) = line(at: t, in: view)
        let ab = SIMD2(Double(b.x - a.x), Double(b.y - a.y)), ap = SIMD2(Double(point.x - a.x), Double(point.y - a.y))
        let u = min(max(simd_dot(ap, ab) / max(simd_dot(ab, ab), 1e-9), 0), 1)
        return simd_length(ap - u * ab)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tool, let pathView, tool.isActive, let start = tool.start, let end = tool.end else { return }
        func stroke(_ t: Double, _ color: NSColor, _ label: String, width: CGFloat = 1.5) {
            let ends = Self.line(at: CGFloat(t), in: pathView)
            let a = convert(ends.0, from: pathView), b = convert(ends.1, from: pathView)
            // A view with no size yet places nothing: a path drawn to a point
            // that is not finite raises.
            guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return }
            let path = NSBezierPath()
            path.move(to: a); path.line(to: b)
            path.lineWidth = width
            color.setStroke(); path.stroke()
            (label as NSString).draw(at: a, withAttributes: [.foregroundColor: color, .font: NSFont.boldSystemFont(ofSize: 11)])
        }
        // One reference is "R"; of two, the proximal is "P" and the distal "D".
        let distalLabel = tool.proximalReference == nil ? "R" : "D"
        if let reference = tool.reference {
            if let a = tool.relativePosition(ofStretchPosition: reference.lowerBound) { stroke(a, .systemTeal, distalLabel) }
            if let b = tool.relativePosition(ofStretchPosition: reference.upperBound) { stroke(b, .systemTeal, distalLabel) }
        }
        if let proximal = tool.proximalReference {
            if let a = tool.relativePosition(ofStretchPosition: proximal.lowerBound) { stroke(a, .systemTeal, "P") }
            if let b = tool.relativePosition(ofStretchPosition: proximal.upperBound) { stroke(b, .systemTeal, "P") }
        }
        if let result = tool.result, let t = tool.relativePosition(ofStretchPosition: result.minimumPosition) {
            stroke(t, .systemRed, "min", width: 1)
        }
        stroke(start, .systemYellow, "1", width: 2)
        stroke(end, .systemYellow, "2", width: 2)
    }
}

// MARK: - The outline on the middle transverse view

/// Over the middle transverse view: the lumen's outline of the section it
/// shows, when it is one of the stretch, and what was erased from it by hand.
/// While the tool erases, it takes the view's drags: each is a stroke of the
/// eraser on that section. Otherwise the mouse goes through it.
@MainActor
final class StenosisSectionOverlay: NSView {
    private weak var tool: StenosisTool?
    private weak var transverseView: CPRTransverseView?
    /// The stroke under way, in patient space, and where the eraser hovers.
    private var stroke: [SIMD3<Double>] = []
    private var hover: NSPoint?

    init(tool: StenosisTool, transverseView: CPRTransverseView) {
        self.tool = tool
        self.transverseView = transverseView
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let tool, tool.isErasing, tool.currentSection != nil else { return nil }
        return super.hitTest(point)
    }

    // MARK: The section's plane in the view

    /// Where a point of patient space falls, in this view's coordinates.
    private func viewPoint(_ p: SIMD3<Double>) -> NSPoint? {
        guard let view = transverseView,
              let value = view.stenosisViewPoint(forPatientVector: N3VectorMake(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z))) else { return nil }
        // A view with no size yet places nothing: a path drawn to a point
        // that is not finite raises.
        let point = convert(value.pointValue, from: view)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }

    /// The section's plane as the view shows it: its center, and a
    /// millimetre along each of its axes, in this view's coordinates.
    private func plane(of section: Stenosis.Section) -> (origin: NSPoint, x: SIMD2<Double>, y: SIMD2<Double>)? {
        let (xAxis, yAxis) = section.frame.axes
        guard let origin = viewPoint(section.frame.point), let x = viewPoint(section.frame.point + xAxis),
              let y = viewPoint(section.frame.point + yAxis) else { return nil }
        return (origin, SIMD2(Double(x.x - origin.x), Double(x.y - origin.y)), SIMD2(Double(y.x - origin.x), Double(y.y - origin.y)))
    }

    /// The point of the section's plane under a point of this view, in patient space.
    private func patientPoint(at point: NSPoint, in section: Stenosis.Section) -> SIMD3<Double>? {
        guard let plane = plane(of: section) else { return nil }
        let determinant = plane.x.x * plane.y.y - plane.x.y * plane.y.x
        guard abs(determinant) > 1e-9 else { return nil }
        let d = SIMD2(Double(point.x - plane.origin.x), Double(point.y - plane.origin.y))
        let u = (d.x * plane.y.y - d.y * plane.y.x) / determinant, v = (plane.x.x * d.y - plane.x.y * d.x) / determinant
        let (xAxis, yAxis) = section.frame.axes
        return section.frame.point + u * xAxis + v * yAxis
    }

    /// The eraser's diameter as the view shows the section, in points.
    private func eraserWidth(in section: Stenosis.Section) -> CGFloat? {
        plane(of: section).map { CGFloat(StenosisTool.eraserRadius * (simd_length($0.x) + simd_length($0.y))) }
    }

    // MARK: The eraser

    override func mouseDown(with event: NSEvent) {
        stroke = []
        extendStroke(event)
    }

    override func mouseDragged(with event: NSEvent) { extendStroke(event) }

    override func mouseUp(with event: NSEvent) {
        extendStroke(event)
        let points = stroke
        stroke = []
        tool?.erase(Stenosis.Erasure(points: points, radius: StenosisTool.eraserRadius))
        needsDisplay = true
    }

    private func extendStroke(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hover = point
        if let section = tool?.currentSection, let p = patientPoint(at: point, in: section) { stroke.append(p) }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil)
        if tool?.isErasing == true { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        if tool?.isErasing == true { needsDisplay = true }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let tool, tool.isActive, let section = tool.currentSection else { return }
        if let width = eraserWidth(in: section) {
            // What was erased, and the stroke under way, as the eraser's trail.
            NSColor.systemRed.withAlphaComponent(0.3).setStroke()
            for trail in tool.currentStrokes.map(\.points) + [stroke] {
                let points = trail.compactMap { viewPoint($0) }
                guard let first = points.first else { continue }
                let path = NSBezierPath()
                path.move(to: first)
                for point in points { path.line(to: point) }
                path.lineWidth = width
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            if tool.isErasing, let hover {
                NSColor.systemRed.setStroke()
                NSBezierPath(ovalIn: NSRect(x: hover.x - width / 2, y: hover.y - width / 2, width: width, height: width)).stroke()
            }
        }
        if section.contour.count > 2 {
            let path = NSBezierPath()
            for (i, p) in section.contour.enumerated() {
                guard let point = viewPoint(p) else { return }
                if i == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close()
            // What the lumen surrounds but leaves out, so the outline shows
            // what the area counts.
            for hole in section.holeContours {
                let points = hole.compactMap { viewPoint($0) }
                guard points.count > 2, points.count == hole.count else { continue }
                path.move(to: points[0])
                for point in points.dropFirst() { path.line(to: point) }
                path.close()
            }
            path.lineWidth = 1.5
            NSColor.systemYellow.setStroke()
            path.stroke()
        }
        // A section whose lumen the calcium exclusion took whole shows its 0.0 mm².
        guard section.isValid || section.corrected || section.lumenTaken != nil else { return }
        let area = StenosisSummary.decimal(1, section.area)
        let text = section.corrected
            ? String(format: NSLocalizedString("%@ mm², corrected by hand", comment: "Stenosis: area of a section whose lumen was corrected by hand, on the transverse view"), area)
            : String(format: NSLocalizedString("%@ mm²", comment: "Stenosis: area of the section on the transverse view"), area)
        // The transverse views are narrow (about 140 pt in the default CPR
        // window): the text wraps to their width instead of running out of them.
        let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemYellow, .font: NSFont.boldSystemFont(ofSize: 12)]
        let width = max(bounds.width - 16, 40)
        let height = ceil((text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                          options: [.usesLineFragmentOrigin], attributes: attributes).height)
        (text as NSString).draw(with: NSRect(x: 8, y: 8, width: width, height: height), options: [.usesLineFragmentOrigin], attributes: attributes)
    }
}

// MARK: - The strip below the stretched view

/// Below the stretched view: the area along the stretch, and beside it the
/// numbers, then what tells the lumen from the rest (its edge, the calcium
/// limit and the margin around the calcium), the eraser for the section shown
/// in the middle transverse view, and the copy button.
@MainActor
final class StenosisStrip: NSView {
    static let height: CGFloat = 156
    private weak var tool: StenosisTool?
    private let chart: StenosisChart
    /// The numbers, in a view that scrolls when the notes under them do not
    /// fit the strip's height.
    private let numbersScroll = NSScrollView()
    private let numbers = NSTextView()
    private var numbersEmphasized = false
    /// The sliders and the buttons, top down, in a view that scrolls when the
    /// strip is lower or narrower than they are: the CPR view gives the strip
    /// at most half its height, the chart is served before them in a narrow
    /// one, and the buttons stay within reach.
    private let controlsScroll = NSScrollView()
    /// What the numbers take when the strip has room for them, and what the
    /// controls need in the language shown.
    private static let numbersWidth: CGFloat = 300
    private var controlsWidth: CGFloat = 0
    private let edgeLabel = NSTextField(labelWithString: "")
    private let edge = NSSlider(value: 0.5, minValue: 0.3, maxValue: 0.8, target: nil, action: nil)
    private let limitLabel = NSTextField(labelWithString: "")
    private let limit = NSSlider(value: 1.6, minValue: Stenosis.Settings.calciumLimits.lowerBound,
                                 maxValue: Stenosis.Settings.calciumLimits.upperBound, target: nil, action: nil)
    private let marginLabel = NSTextField(labelWithString: "")
    private let margin = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let erase = NSButton(title: NSLocalizedString("Erase Plaque", comment: "Stenosis: turns on the eraser that takes plaque out of the lumen of the section shown"), target: nil, action: nil)
    private let undo = NSButton(title: NSLocalizedString("Undo Last Stroke", comment: "Stenosis: takes back the last stroke of the eraser on the section shown"), target: nil, action: nil)
    private let reset = NSButton(title: NSLocalizedString("Reset Section", comment: "Stenosis: gives the section shown its automatic lumen back"), target: nil, action: nil)
    private let copy = NSButton(title: NSLocalizedString("Copy Summary", comment: "Stenosis: copies the summary to the clipboard"), target: nil, action: nil)
    private let capture = NSButton(title: NSLocalizedString("Save Capture", comment: "Stenosis: saves an image of the strip and the summary in the study"), target: nil, action: nil)
    private let bands = NSButton(title: NSLocalizedString("Bands…", comment: "Stenosis: opens the limits of the bands the plaque is read with"), target: nil, action: nil)
    private var bandsEditor: StenosisBandsEditor?
    /// The vessel the stretch is measured as, in the order of `Stenosis.Vessel.allCases`.
    private let vessel = NSSegmentedControl(labels: [
        NSLocalizedString("Carotid", comment: "Stenosis: measure the stretch as a carotid artery"),
        NSLocalizedString("Coronary", comment: "Stenosis: measure the stretch as a coronary artery"),
    ], trackingMode: .selectOne, target: nil, action: nil)

    private static func edgeText(_ fraction: Double) -> String {
        String(format: NSLocalizedString("Lumen edge: %@ %%", comment: "Stenosis: the lumen threshold, as a percentage of the centerline intensity"), String(format: "%.0f", fraction * 100))
    }
    private static func limitText(_ fraction: Double) -> String {
        String(format: NSLocalizedString("Calcium limit: %@ %%", comment: "Stenosis: the threshold above which a sample is calcium, as a percentage of the centerline intensity"), String(format: "%.0f", fraction * 100))
    }
    private static func marginText(_ mm: Double) -> String {
        String(format: NSLocalizedString("Calcium margin: %@ mm", comment: "Stenosis: how far around the calcium the lumen is left out with it"), StenosisSummary.decimal(1, mm))
    }

    init(tool: StenosisTool) {
        self.tool = tool
        chart = StenosisChart(source: tool)
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: Self.height))
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let sliderWidth: CGFloat = 132

        // The controls take the width their texts need in the language shown.
        let rows = [(edgeLabel, edge, Self.edgeText(0.8)), (limitLabel, limit, Self.limitText(2)), (marginLabel, margin, Self.marginText(1))]
        let labelWidth = rows.map { ($0.2 as NSString).size(withAttributes: [.font: small]).width }.max().map { ceil($0) + 6 } ?? 150
        erase.setButtonType(.pushOnPushOff)
        for button in [erase, undo, reset, copy, capture, bands] {
            button.controlSize = .small
            button.font = small
            button.bezelStyle = .rounded
            button.target = self
            button.sizeToFit()
        }
        vessel.controlSize = .small
        vessel.font = small
        vessel.segmentStyle = .rounded
        vessel.target = self
        vessel.action = #selector(vesselChanged(_:))
        vessel.sizeToFit()
        let controlsWidth = max(8 + labelWidth + 4 + sliderWidth + 8, 4 + undo.frame.width + 4 + reset.frame.width + 4 + bands.frame.width + 4,
                                4 + erase.frame.width + 8 + vessel.frame.width + 4, 4 + copy.frame.width + 4 + capture.frame.width + 4)
        self.controlsWidth = controlsWidth

        addSubview(chart)
        addSubview(numbersScroll)
        numbersScroll.drawsBackground = false
        numbersScroll.borderType = .noBorder
        numbersScroll.hasVerticalScroller = true
        numbersScroll.autohidesScrollers = true
        numbers.isEditable = false
        numbers.isSelectable = true
        numbers.drawsBackground = false
        numbers.textContainerInset = .zero
        numbers.isVerticallyResizable = true
        numbers.isHorizontallyResizable = false
        numbers.autoresizingMask = [.width]
        numbers.textContainer?.widthTracksTextView = true
        numbers.minSize = .zero
        numbers.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        numbersScroll.documentView = numbers

        let controls = StenosisFlippedView(frame: NSRect(x: 0, y: 0, width: controlsWidth, height: Self.height))
        controlsScroll.drawsBackground = false
        controlsScroll.borderType = .noBorder
        controlsScroll.hasVerticalScroller = true
        controlsScroll.hasHorizontalScroller = true
        controlsScroll.autohidesScrollers = true
        controlsScroll.documentView = controls
        addSubview(controlsScroll)
        arrange()
        for (row, (label, slider, _)) in rows.enumerated() {
            let y = 6 + CGFloat(row) * 24
            label.font = small
            label.frame = NSRect(x: 8, y: y + 2, width: labelWidth, height: 16)
            controls.addSubview(label)
            slider.controlSize = .small
            slider.allowsTickMarkValuesOnly = true
            slider.isContinuous = false
            slider.frame = NSRect(x: 8 + labelWidth + 4, y: y, width: sliderWidth, height: 20)
            slider.target = self
            controls.addSubview(slider)
        }
        edge.numberOfTickMarks = 11
        edge.action = #selector(edgeChanged(_:))
        // A mark every 10 %.
        let limits = Stenosis.Settings.calciumLimits
        limit.numberOfTickMarks = Int(((limits.upperBound - limits.lowerBound) * 10).rounded()) + 1
        limit.action = #selector(limitChanged(_:))
        limit.toolTip = NSLocalizedString("What is brighter than this share of a section's centerline intensity is left out of the lumen, and calcium also brighter than this share of the intensity in the middle of the reference's lumen is left out even where the lumen surrounds it. Calcium dimmer than the limit stays in the area: take it out with Erase Plaque.", comment: "Stenosis: tooltip of the calcium limit; the last sentence says that calcium dimmer than the limit is counted in the area, and that the Erase Plaque button takes it out")
        limitLabel.toolTip = limit.toolTip
        margin.numberOfTickMarks = 11
        margin.action = #selector(marginChanged(_:))
        margin.toolTip = NSLocalizedString("The lumen this close to calcium is left out with it, against the blooming of the calcium.", comment: "Stenosis: tooltip of the calcium margin")
        marginLabel.toolTip = margin.toolTip

        erase.toolTip = NSLocalizedString("Drag over the plaque on the middle transverse view to take it out of the lumen of the section shown there.", comment: "Stenosis: tooltip of the Erase Plaque button")
        // The buttons where the strip at its full height has them: 52, 27 and
        // 2 points above its bottom.
        func above(_ button: NSButton, _ y: CGFloat) -> CGFloat { Self.height - y - button.frame.height }
        erase.action = #selector(eraseChanged(_:))
        erase.frame.origin = NSPoint(x: 4, y: above(erase, 52))
        undo.action = #selector(undoStroke(_:))
        undo.frame.origin = NSPoint(x: 4, y: above(undo, 27))
        reset.action = #selector(resetSection(_:))
        reset.frame.origin = NSPoint(x: undo.frame.maxX + 4, y: above(reset, 27))
        copy.action = #selector(copySummary(_:))
        copy.frame.origin = NSPoint(x: 4, y: above(copy, 2))
        capture.action = #selector(saveCapture(_:))
        capture.frame.origin = NSPoint(x: copy.frame.maxX + 4, y: above(capture, 2))
        capture.toolTip = NSLocalizedString("Saves an image of this strip and of the summary in the study, as a new series.", comment: "Stenosis: tooltip of the Save Capture button")
        bands.action = #selector(editBands(_:))
        bands.frame.origin = NSPoint(x: reset.frame.maxX + 4, y: above(bands, 27))
        bands.toolTip = NSLocalizedString("The limits, in HU, of the bands the plaque of a coronary artery is read with.", comment: "Stenosis: tooltip of the Bands… button")
        for button in [erase, undo, reset, copy, capture, bands] { controls.addSubview(button) }
        vessel.toolTip = NSLocalizedString("The vessel the stretch is measured as. A coronary artery has a narrower lumen, and its narrowing is read by diameter against a reference on each side of it.", comment: "Stenosis: tooltip of the Carotid/Coronary selector")
        vessel.frame.origin = NSPoint(x: erase.frame.maxX + 8, y: erase.frame.midY - vessel.frame.height / 2)
        controls.addSubview(vessel)
        update()
    }

    required init?(coder: NSCoder) { nil }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        arrange()
    }

    /// The chart on the left, then the numbers and the controls, each with
    /// the width `Stenosis.StripLayout` gives it: the chart is served first.
    private func arrange() {
        let widths = Stenosis.StripLayout(width: bounds.width, numbers: Self.numbersWidth, controls: controlsWidth)
        chart.frame = NSRect(x: 0, y: 0, width: widths.chart, height: bounds.height)
        numbersScroll.frame = NSRect(x: widths.chart + 8, y: 4, width: max(widths.numbers - 12, 0), height: max(bounds.height - 8, 0))
        numbers.frame.size.width = numbersScroll.contentSize.width
        controlsScroll.frame = NSRect(x: widths.chart + widths.numbers, y: 0, width: widths.controls, height: bounds.height)
        chart.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    /// A slider's value at its mark, without the binary residue of its position.
    private func value(of slider: NSSlider) -> Double { (slider.doubleValue * 100).rounded() / 100 }

    @objc func edgeChanged(_ sender: Any?) { tool?.setLowerFraction(edge.doubleValue) }
    @objc func limitChanged(_ sender: Any?) { tool?.setUpperFraction(value(of: limit)) }
    @objc func marginChanged(_ sender: Any?) { tool?.setCalciumMargin(value(of: margin)) }
    @objc func eraseChanged(_ sender: Any?) { tool?.setErasing(erase.state == .on) }
    @objc func vesselChanged(_ sender: Any?) {
        let cases = Stenosis.Vessel.allCases
        if cases.indices.contains(vessel.selectedSegment) { tool?.setVessel(cases[vessel.selectedSegment]) }
    }
    @objc func undoStroke(_ sender: Any?) { tool?.undoErasure() }
    @objc func resetSection(_ sender: Any?) { tool?.resetCurrentSection() }
    @objc func copySummary(_ sender: Any?) { tool?.copySummary() }
    @objc func saveCapture(_ sender: Any?) { tool?.saveCapture(of: self) }
    @objc func editBands(_ sender: Any?) {
        guard let tool else { return }
        let editor = StenosisBandsEditor(tool: tool)
        bandsEditor = editor
        editor.show(relativeTo: bands)
    }

    func update() {
        guard let tool else { return }
        edge.doubleValue = tool.settings.lowerFraction
        edgeLabel.stringValue = Self.edgeText(tool.settings.lowerFraction)
        limit.doubleValue = tool.settings.upperFraction
        limitLabel.stringValue = Self.limitText(tool.settings.upperFraction)
        margin.doubleValue = tool.settings.calciumMargin
        marginLabel.stringValue = Self.marginText(tool.settings.calciumMargin)
        vessel.selectedSegment = Stenosis.Vessel.allCases.firstIndex(of: tool.settings.vessel) ?? 0
        let text: String
        if tool.start == nil {
            text = NSLocalizedString("Drag along the stretched view to choose the stretch to measure, from proximal to distal.", comment: "Stenosis: hint before a stretch is chosen")
        } else if tool.computing {
            text = NSLocalizedString("Measuring…", comment: "Stenosis: while the sections are measured")
        } else if let summary = tool.summary {
            // The numbers, and whether calcium above the limit touched the
            // lumen: the sliders beside them show the lumen edge and the limit.
            text = summary.strip.joined(separator: "\n")
        } else {
            text = NSLocalizedString("No lumen found in the stretch or its reference.", comment: "Stenosis: no result")
        }
        // A coronary measure opens with its degree by diameter, which stands out.
        let emphasized = !tool.computing && tool.summary?.opensWithTheDegree == true
        if numbers.string != text || emphasized != numbersEmphasized {
            numbersEmphasized = emphasized
            let shown = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
            if emphasized, let first = text.split(separator: "\n", maxSplits: 1).first {
                shown.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                                   range: NSRange(location: 0, length: (first as NSString).length))
            }
            numbers.textStorage?.setAttributedString(shown)
            numbers.scrollToBeginningOfDocument(nil)
        }
        erase.state = tool.isErasing ? .on : .off
        erase.isEnabled = !tool.sections.isEmpty
        let corrected = !tool.currentStrokes.isEmpty
        undo.isEnabled = corrected
        reset.isEnabled = corrected
        copy.isEnabled = tool.summary != nil
        capture.isEnabled = tool.summary != nil
        bands.isEnabled = tool.settings.plaque != nil
        chart.needsDisplay = true
    }
}

/// The strip's controls, laid out from the top: in a scroll view lower than
/// they are, the sliders show first.
private final class StenosisFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The limits of the bands the plaque is read with, in a pop-over of the
/// strip: three fields, in HU, and a button that brings the usual ones back.
/// A field is taken when its three limits rise above the fat; otherwise the
/// fields go back to the bands in use.
@MainActor
private final class StenosisBandsEditor: NSObject, NSPopoverDelegate {
    private weak var tool: StenosisTool?
    private let popover = NSPopover()
    private var fields: [NSTextField] = []

    init(tool: StenosisTool) {
        self.tool = tool
        super.init()
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let titles = [NSLocalizedString("Lipid-rich or necrotic, up to (HU):", comment: "Stenosis bands: the upper limit of the first band"),
                      NSLocalizedString("Fibro-fatty, up to (HU):", comment: "Stenosis bands: the upper limit of the second band"),
                      NSLocalizedString("Fibrous, up to (HU):", comment: "Stenosis bands: the upper limit of the third band; above it, calcium")]
        let labels = titles.map { title -> NSTextField in
            let label = NSTextField(labelWithString: title)
            label.font = small
            label.sizeToFit()
            return label
        }
        let labelWidth = ceil(labels.map(\.frame.width).max() ?? 160)
        let defaults = NSButton(title: NSLocalizedString("Use Defaults", comment: "Stenosis bands: brings back the usual limits"), target: self, action: #selector(useDefaults(_:)))
        defaults.controlSize = .small
        defaults.font = small
        defaults.bezelStyle = .rounded
        defaults.sizeToFit()
        let width = max(12 + labelWidth + 6 + 64 + 12, 12 + defaults.frame.width + 12)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 12 + 3 * 26 + defaults.frame.height + 12))
        for (row, label) in labels.enumerated() {
            let y = content.bounds.height - 12 - CGFloat(row + 1) * 26 + 4
            label.frame = NSRect(x: 12, y: y + 2, width: labelWidth, height: 16)
            content.addSubview(label)
            let field = NSTextField(frame: NSRect(x: 12 + labelWidth + 6, y: y, width: 64, height: 20))
            field.controlSize = .small
            field.font = small
            field.alignment = .right
            field.target = self
            field.action = #selector(changed(_:))
            content.addSubview(field)
            fields.append(field)
        }
        defaults.frame.origin = NSPoint(x: 12, y: 10)
        content.addSubview(defaults)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        showBands()
    }

    func show(relativeTo button: NSView) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func showBands() {
        guard let tool else { return }
        for (field, limit) in zip(fields, tool.plaqueBands) { field.stringValue = String(Int(limit.floatValue.rounded())) }
    }

    /// The three fields as they are; what is not taken leaves them as the bands in use.
    @objc func changed(_ sender: Any?) {
        _ = tool?.setPlaqueBands(fields.map { Float($0.integerValue) })
        showBands()
    }

    @objc func useDefaults(_ sender: Any?) {
        _ = tool?.setPlaqueBands(Stenosis.PlaqueLimits.defaultBands)
        showBands()
    }

    /// A field edited and left without Return is taken as the pop-over closes.
    func popoverWillClose(_ notification: Notification) { changed(nil) }
}
