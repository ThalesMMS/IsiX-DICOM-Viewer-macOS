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
/// It is a button of the window's toolbar, not a ROI and not a ToolMode: those
/// are shared by every viewer. On, it takes the mouse on the stretched view
/// only; off, every view works as before.
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
    private(set) var settings = Stenosis.Settings()
    private(set) var sections: [Stenosis.Section] = []
    private(set) var result: Stenosis.Result?
    private(set) var computing = false

    private enum Drag { case none, stretch(anchor: Double), start, end, referenceStart, referenceEnd }
    private var drag = Drag.none

    private let queue = DispatchQueue(label: "Stenosis sections", qos: .userInitiated)
    private var generation = 0
    private var measuredPathNodes: NSArray?

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
            if case .stretch = drag { start = position; end = position; reference = nil; sections = []; result = nil }
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
        }
    }

    // MARK: - Measuring

    /// The lumen edge, as a fraction of the centerline's intensity.
    func setLowerFraction(_ value: Double) {
        settings.lowerFraction = value
        refresh()
    }

    /// Measures the stretch again, off the main thread; the reference keeps
    /// its place when it still fits, and is the distal quarter otherwise.
    func refresh() {
        generation += 1
        guard isActive, let controller, let start, let end, let path = controller.curvedPath,
              let volume = controller.stenosisVolumeData,
              let flattened = path.bezierPath?.mutableCopy() as? N3MutableBezierPath, flattened.elementCount() >= 2 else {
            sections = []; result = nil; computing = false
            redraw()
            return
        }
        flattened.subdivide(N3BezierDefaultSubdivideSegmentLength)
        flattened.flatten(N3BezierDefaultFlatness)
        let length = Double(flattened.length())
        let stretch = abs(end - start) * length
        if reference == nil || reference!.upperBound > stretch + 0.01 { reference = Stenosis.defaultReference(stretch: stretch) }
        measuredPathNodes = path.nodes.copy() as? NSArray

        let settings = self.settings
        let count = Int((stretch / settings.step).rounded(.down)) + 1
        let direction = end >= start ? 1.0 : -1.0
        let initialNormal = path.initialNormal
        // The frames as the transverse views take them, on the main thread,
        // where the path lives.
        let frames: [(Double, Double, Stenosis.Frame)] = (0..<count).map { i in
            let position = min(Double(i) * settings.step, stretch)
            let t = CGFloat(start + direction * position / length)
            let point = flattened.vector(atRelativePosition: t)
            let tangent = flattened.tangent(atRelativePosition: t)
            let normal = flattened.normal(atRelativePosition: t, initialNormal: initialNormal)
            return (position, Double(t), Stenosis.Frame(point: SIMD3(Double(point.x), Double(point.y), Double(point.z)),
                                                        tangent: SIMD3(Double(tangent.x), Double(tangent.y), Double(tangent.z)),
                                                        normal: SIMD3(Double(normal.x), Double(normal.y), Double(normal.z))))
        }
        computing = true
        redraw()
        let job = StenosisJob(volume: volume)
        let current = generation
        queue.async {
            let sections = job.measure(frames: frames, settings: settings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard current == self.generation else { return }
                    self.sections = sections
                    self.computing = false
                    self.updateResult()
                }
            }
        }
    }

    private func updateResult() {
        result = reference.flatMap { Stenosis.result(of: sections, reference: $0) }
        redraw()
    }

    /// The path changed in another view: measure again when its nodes did;
    /// a moved transverse section only needs its outline drawn again.
    @objc public func curvedPathDidChange() {
        guard isActive else { return }
        if let nodes = controller?.curvedPath?.nodes, let measured = measuredPathNodes, !nodes.isEqual(to: measured as! [Any]) {
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
    var currentSection: Stenosis.Section? {
        guard let t = controller?.curvedPath?.transverseSectionPosition, !sections.isEmpty else { return nil }
        let nearest = sections.min { abs($0.relativePosition - Double(t)) < abs($1.relativePosition - Double(t)) }
        guard let nearest, abs(nearest.relativePosition - Double(t)) * length <= settings.step else { return nil }
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

    var summary: String? {
        guard let result, let reference else { return nil }
        func mm(_ v: Double) -> String { String(format: "%.1f", v) }
        func mm2(_ v: Double) -> String { String(format: "%.1f", v) }
        return [
            String(format: NSLocalizedString("Stenosis, curved MPR stretch of %@ mm", comment: "Stenosis summary, first line"), mm(stretchLength)),
            String(format: NSLocalizedString("Minimum area: %@ mm² at %@ mm", comment: "Stenosis summary"), mm2(result.minimumArea), mm(result.minimumPosition)),
            String(format: NSLocalizedString("Reference area: %@ mm² (%@–%@ mm)", comment: "Stenosis summary"), mm2(result.referenceArea), mm(reference.lowerBound), mm(reference.upperBound)),
            String(format: NSLocalizedString("Mean area of the stretch: %@ mm²", comment: "Stenosis summary"), mm2(result.meanArea)),
            String(format: NSLocalizedString("NASCET by area: %@ %%", comment: "Stenosis summary"), String(format: "%.0f", result.nascetByArea)),
            String(format: NSLocalizedString("Minimum diameter: %@ mm (equivalent %@ mm)", comment: "Stenosis summary"), String(format: "%.2f", result.minimumDiameter), String(format: "%.2f", result.equivalentDiameter)),
            String(format: NSLocalizedString("Reference diameter: %@ mm", comment: "Stenosis summary"), String(format: "%.2f", result.referenceDiameter)),
            String(format: NSLocalizedString("NASCET by diameter: %@ %%", comment: "Stenosis summary"), String(format: "%.0f", result.nascetByDiameter)),
            String(format: NSLocalizedString("Lumen edge at %@ %% of the centerline intensity", comment: "Stenosis summary, last line"), String(format: "%.0f", settings.lowerFraction * 100)),
        ].joined(separator: "\n")
    }

    /// Read-only, for scripting and checks: the summary as copied, whether a
    /// measure is under way, how many sections were measured, and the outline
    /// shown on the middle transverse view, in patient space.
    @objc public var summaryText: String? { summary }
    @objc public var isMeasuring: Bool { computing }
    @objc public var measuredSectionCount: Int { sections.count }
    @objc public var shownSectionOutline: [NSValue] {
        (currentSection?.contour ?? []).compactMap { NSValue(n3Vector: N3VectorMake(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z))) }
    }

    func copySummary() {
        guard let summary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }
}

/// The sections of a stretch, measured on the volume off the main thread:
/// the volume is only read, through its inline buffer, which the curved MPR's
/// generators also read from other threads.
private final class StenosisJob: @unchecked Sendable {
    let volume: CPRVolumeData
    init(volume: CPRVolumeData) { self.volume = volume }

    func measure(frames: [(Double, Double, Stenosis.Frame)], settings: Stenosis.Settings) -> [Stenosis.Section] {
        var inline = CPRVolumeDataInlineBuffer()
        guard volume.aquireInlineBuffer(&inline) else {
            volume.releaseInlineBuffer(&inline)
            return []
        }
        defer { volume.releaseInlineBuffer(&inline) }
        return withUnsafeMutablePointer(to: &inline) { buffer in
            frames.map { position, t, frame in
                Stenosis.section(at: t, position: position, frame: frame, settings: settings) { p in
                    CPRVolumeDataLinearInterpolatedFloatAtDicomVectorForSwift(buffer, N3VectorMake(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z)))
                }
            }
        }
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
            let (a, b) = Self.line(at: CGFloat(t), in: pathView)
            let path = NSBezierPath()
            path.move(to: convert(a, from: pathView)); path.line(to: convert(b, from: pathView))
            path.lineWidth = width
            color.setStroke(); path.stroke()
            (label as NSString).draw(at: convert(a, from: pathView), withAttributes: [.foregroundColor: color, .font: NSFont.boldSystemFont(ofSize: 11)])
        }
        if let reference = tool.reference {
            if let a = tool.relativePosition(ofStretchPosition: reference.lowerBound) { stroke(a, .systemTeal, "R") }
            if let b = tool.relativePosition(ofStretchPosition: reference.upperBound) { stroke(b, .systemTeal, "R") }
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
/// shows, when it is one of the stretch.
@MainActor
final class StenosisSectionOverlay: NSView {
    private weak var tool: StenosisTool?
    private weak var transverseView: CPRTransverseView?

    init(tool: StenosisTool, transverseView: CPRTransverseView) {
        self.tool = tool
        self.transverseView = transverseView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let tool, tool.isActive, let view = transverseView, let section = tool.currentSection, section.contour.count > 2 else { return }
        let path = NSBezierPath()
        for (i, p) in section.contour.enumerated() {
            guard let v = view.stenosisViewPoint(forPatientVector: N3VectorMake(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z))) else { return }
            let point = convert(v.pointValue, from: view)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        path.lineWidth = 1.5
        NSColor.systemYellow.setStroke()
        path.stroke()
        let text = String(format: NSLocalizedString("%@ mm²", comment: "Stenosis: area of the section on the transverse view"), String(format: "%.1f", section.area))
        (text as NSString).draw(at: NSPoint(x: 8, y: 8), withAttributes: [.foregroundColor: NSColor.systemYellow, .font: NSFont.boldSystemFont(ofSize: 12)])
    }
}

// MARK: - The strip below the stretched view

/// Below the stretched view: the area along the stretch, and beside it the
/// numbers, the lumen edge and the copy button.
@MainActor
final class StenosisStrip: NSView {
    static let height: CGFloat = 156
    private weak var tool: StenosisTool?
    private let chart: StenosisChart
    private let numbers = NSTextField(wrappingLabelWithString: "")
    private let edgeLabel = NSTextField(labelWithString: "")
    private let edge = NSSlider(value: 0.5, minValue: 0.3, maxValue: 0.8, target: nil, action: nil)
    private let copy = NSButton(title: NSLocalizedString("Copy Summary", comment: "Stenosis: copies the summary to the clipboard"), target: nil, action: nil)

    init(tool: StenosisTool) {
        self.tool = tool
        chart = StenosisChart(tool: tool)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.height))
        let panelWidth: CGFloat = 300
        chart.frame = NSRect(x: 0, y: 0, width: bounds.width - panelWidth, height: bounds.height)
        chart.autoresizingMask = [.width, .height]
        addSubview(chart)

        let panel = NSView(frame: NSRect(x: bounds.width - panelWidth, y: 0, width: panelWidth, height: bounds.height))
        panel.autoresizingMask = [.minXMargin, .height]
        addSubview(panel)
        numbers.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        numbers.textColor = .labelColor
        numbers.frame = NSRect(x: 8, y: 52, width: panelWidth - 12, height: bounds.height - 56)
        numbers.autoresizingMask = [.height]
        panel.addSubview(numbers)
        edgeLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        edgeLabel.frame = NSRect(x: 8, y: 32, width: 150, height: 16)
        panel.addSubview(edgeLabel)
        edge.controlSize = .small
        edge.numberOfTickMarks = 11
        edge.allowsTickMarkValuesOnly = true
        edge.isContinuous = false
        edge.frame = NSRect(x: 160, y: 30, width: panelWidth - 168, height: 20)
        edge.target = self
        edge.action = #selector(edgeChanged(_:))
        panel.addSubview(edge)
        copy.controlSize = .small
        copy.bezelStyle = .rounded
        copy.sizeToFit()
        copy.frame.origin = NSPoint(x: 4, y: 2)
        copy.target = self
        copy.action = #selector(copySummary(_:))
        panel.addSubview(copy)
        update()
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    @objc func edgeChanged(_ sender: Any?) { tool?.setLowerFraction(edge.doubleValue) }
    @objc func copySummary(_ sender: Any?) { tool?.copySummary() }

    func update() {
        guard let tool else { return }
        edge.doubleValue = tool.settings.lowerFraction
        edgeLabel.stringValue = String(format: NSLocalizedString("Lumen edge: %@ %%", comment: "Stenosis: the lumen threshold, as a percentage of the centerline intensity"), String(format: "%.0f", tool.settings.lowerFraction * 100))
        if tool.start == nil {
            numbers.stringValue = NSLocalizedString("Drag along the stretched view to choose the stretch to measure, from proximal to distal.", comment: "Stenosis: hint before a stretch is chosen")
        } else if tool.computing {
            numbers.stringValue = NSLocalizedString("Measuring…", comment: "Stenosis: while the sections are measured")
        } else if let summary = tool.summary {
            // The summary without its title and last line, which the strip shows elsewhere.
            numbers.stringValue = summary.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")
        } else {
            numbers.stringValue = NSLocalizedString("No lumen found in the stretch or its reference.", comment: "Stenosis: no result")
        }
        copy.isEnabled = tool.summary != nil
        chart.needsDisplay = true
    }
}

/// The area of the lumen along the stretch, with the reference shaded, the
/// narrowest section marked and the middle transverse section's position. A
/// click shows that section in the middle transverse view.
@MainActor
final class StenosisChart: NSView {
    private weak var tool: StenosisTool?

    init(tool: StenosisTool) {
        self.tool = tool
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    private var plot: NSRect { bounds.insetBy(dx: 36, dy: 18).offsetBy(dx: 8, dy: 2) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let tool, !tool.sections.isEmpty else { return }
        let sections = tool.sections
        let stretch = max(tool.stretchLength, 0.001)
        let maximum = max(sections.map(\.area).max() ?? 1, 1)
        let plot = self.plot
        func x(_ mm: Double) -> CGFloat { plot.minX + CGFloat(mm / stretch) * plot.width }
        func y(_ area: Double) -> CGFloat { plot.minY + CGFloat(area / maximum) * plot.height }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]

        if let reference = tool.reference {
            NSColor.systemTeal.withAlphaComponent(0.18).setFill()
            NSRect(x: x(reference.lowerBound), y: plot.minY, width: x(reference.upperBound) - x(reference.lowerBound), height: plot.height).fill()
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath.stroke(plot)
        ("\(Int(maximum.rounded())) mm²" as NSString).draw(at: NSPoint(x: 2, y: plot.maxY - 10), withAttributes: attributes)
        ("0" as NSString).draw(at: NSPoint(x: 2, y: plot.minY - 4), withAttributes: attributes)
        (String(format: "%.0f mm", stretch) as NSString).draw(at: NSPoint(x: plot.maxX - 30, y: 2), withAttributes: attributes)

        let line = NSBezierPath()
        var started = false
        for s in sections where s.isValid {
            let p = NSPoint(x: x(s.position), y: y(s.area))
            if started { line.line(to: p) } else { line.move(to: p); started = true }
        }
        line.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        line.stroke()

        if let result = tool.result {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: x(result.minimumPosition) - 3, y: y(result.minimumArea) - 3, width: 6, height: 6)).fill()
        }
        if let current = tool.currentStretchPosition {
            NSColor.systemYellow.setStroke()
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: x(current), y: plot.minY)); marker.line(to: NSPoint(x: x(current), y: plot.maxY))
            marker.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let tool, tool.stretchLength > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mm = Double((point.x - plot.minX) / plot.width) * tool.stretchLength
        tool.showSection(atStretchPosition: min(max(mm, 0), tool.stretchLength))
        needsDisplay = true
    }
}
