//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A host for tests/test-isix-legacy-viewer-events.py: the application's
// loading path (IsiXPluginLoading's inspection, the bundle load, entry
// resolution, the plugin runtime) with synthetic viewers that, as the
// application does, announce their events: ROIs added, changed, selected and
// removed, another image shown, the viewer closing. It gives the plugins
// mouse and key events and lets them draw over an image, as the application's
// image view does, and prints one JSON object; the test checks it.
//
//     ViewerHarness <plugin.isixplugin>...
//
// Plugins are recognised by their bundle name: ViewerProbe and
// ReactivationProbe (the tests' own legacy plugins), VolumeCalculator,
// CardiacStatistics and NMSegmentation.

import AppKit
@_spi(IsiXHost) import IsiXPluginKit
import IsiXPluginLoading

@MainActor
final class FakeViewer: IsiXViewerBackend {
    let viewerID = IsiXViewerID(rawValue: UUID())
    var isOpen = true
    let columns: Int, rows: Int
    let spacing: (column: Double, row: Double)
    /// Per phase, per slice: the samples, row by row.
    var phases: [[[Float]]]
    var current: Int
    var phase = 0
    var stored: [IsiXROI] = []
    var level = IsiXWindowLevel(center: 40, width: 400)
    unowned let host: FakeHost

    init(host: FakeHost, columns: Int, rows: Int, spacing: (Double, Double) = (1, 1), phases: [[[Float]]], current: Int = 0) {
        self.host = host
        self.columns = columns
        self.rows = rows
        self.spacing = (spacing.0, spacing.1)
        self.phases = phases
        self.current = current
    }

    var slices: [[Float]] { phases[phase] }

    func geometry(_ slice: Int) -> IsiXImageGeometry {
        IsiXImageGeometry(columns: columns, rows: rows, columnSpacing: spacing.column, rowSpacing: spacing.row,
                          imagePosition: IsiXVector3(x: -10, y: 20, z: 30 + 2 * Double(slice)),
                          rowDirection: IsiXVector3(x: 1, y: 0, z: 0), columnDirection: IsiXVector3(x: 0, y: 1, z: 0),
                          sliceThickness: 2, sliceInterval: 2, sliceLocation: 2 * Double(slice))
    }

    private func slice(_ slice: Int?, _ phase: Int?) throws -> (Int, Int) {
        guard isOpen else { throw IsiXPluginError.viewerClosed }
        let p = phase ?? self.phase
        guard phases.indices.contains(p) else { throw IsiXPluginError.phaseOutOfRange(p) }
        let s = slice ?? current
        guard phases[p].indices.contains(s) else { throw IsiXPluginError.sliceOutOfRange(s) }
        return (s, p)
    }

    func seriesSummary() throws -> IsiXSeriesSummary {
        _ = try slice(nil, nil)
        return IsiXSeriesSummary(sliceCount: slices.count, phaseCount: phases.count, currentSlice: current, currentPhase: phase,
                                 studyInstanceUID: "1.2.3", seriesInstanceUID: "1.2.3.4", seriesDescription: "Synthetic", modality: "MR")
    }

    func currentPosition() throws -> IsiXSlicePosition { IsiXSlicePosition(slice: try slice(nil, nil).0, phase: phase) }
    func setCurrentSlice(_ value: Int) throws { current = try slice(value, nil).0 }
    func setCurrentPhase(_ value: Int) throws { phase = try slice(nil, value).1 }

    func image(slice value: Int?, phase p: Int?) throws -> IsiXImage {
        let (s, q) = try slice(value, p)
        return IsiXImage(version: IsiXImageVersion(viewer: viewerID, slice: s, phase: q, token: 1), geometry: geometry(s),
                         attributes: IsiXImageAttributes(modality: "MR", sopInstanceUID: "1.2.3.4.\(q).\(s)"),
                         pixels: .float32(try IsiXPixelBuffer(width: columns, height: rows, samples: phases[q][s])))
    }

    func geometry(slice value: Int?, phase p: Int?) throws -> IsiXImageGeometry { geometry(try slice(value, p).0) }
    func windowLevel() throws -> IsiXWindowLevel { _ = try slice(nil, nil); return level }
    func setWindowLevel(_ windowLevel: IsiXWindowLevel) throws { level = windowLevel }
    func commit(_ pixels: IsiXPixelData, replacing version: IsiXImageVersion) throws { throw IsiXPluginError.staleImage }

    func rois(slice value: Int?, phase p: Int?) throws -> [IsiXROI] {
        let (s, q) = try slice(value, p)
        return stored.filter { $0.slice == s && $0.phase == q }
    }

    func addROI(_ draft: IsiXROIDraft) throws -> IsiXROI {
        let (s, q) = try slice(draft.slice, draft.phase)
        let g = geometry(s)
        let roi = IsiXROI(id: IsiXROIID(rawValue: UUID()), kind: draft.kind, name: draft.name ?? "", comment: "",
                          slice: s, phase: q, points: draft.points, patientPoints: draft.points.map { g.patientPoint(of: $0) })
        stored.append(roi)
        host.announce(.roiChanged(viewerID, roi.id, .added))
        return roi
    }

    /// Puts a ROI in the viewer as the user draws it.
    @discardableResult
    func draw(_ kind: IsiXROIKind, _ points: [IsiXPixelPoint], slice: Int, name: String, selected: Bool = false) -> IsiXROI {
        let g = geometry(slice)
        let roi = IsiXROI(id: IsiXROIID(rawValue: UUID()), kind: kind, name: name, comment: "", slice: slice, phase: phase,
                          points: points, patientPoints: points.map { g.patientPoint(of: $0) }, isSelected: selected)
        stored.append(roi)
        host.announce(.roiChanged(viewerID, roi.id, .added))
        return roi
    }

    func updateROI(_ id: IsiXROIID, _ update: IsiXROIUpdate) throws -> IsiXROI {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { throw IsiXPluginError.roiNotFound }
        var roi = stored[index]
        if let points = update.points {
            roi.points = points
            roi.patientPoints = points.map { geometry(roi.slice).patientPoint(of: $0) }
            roi.kind = update.kind ?? roi.kind
        }
        if let name = update.name { roi.name = name }
        if let comment = update.comment { roi.comment = comment }
        if let selected = update.isSelected { roi.isSelected = selected }
        if let shows = update.showsTextBox { roi.showsTextBox = shows }
        stored[index] = roi
        host.announce(.roiChanged(viewerID, id, update.isSelected == true ? .selected : .modified))
        return roi
    }

    func removeROI(_ id: IsiXROIID) throws {
        guard stored.contains(where: { $0.id == id }) else { throw IsiXPluginError.roiNotFound }
        stored.removeAll { $0.id == id }
        host.announce(.roiChanged(viewerID, id, .removed))
    }

    /// The pixels whose centre lies inside the outline (even-odd), as the
    /// application measures a closed ROI; a line's length in mm.
    func statistics(of id: IsiXROIID) throws -> IsiXROIStatistics {
        guard let roi = stored.first(where: { $0.id == id }) else { throw IsiXPluginError.roiNotFound }
        if roi.kind == .line, roi.points.count == 2 {
            let dx = (roi.points[1].x - roi.points[0].x) * spacing.column, dy = (roi.points[1].y - roi.points[0].y) * spacing.row
            return IsiXROIStatistics(mean: 0, standardDeviation: 0, minimum: 0, maximum: 0, sum: 0, area: nil,
                                     length: (dx * dx + dy * dy).squareRoot())
        }
        var outline = roi.points
        if roi.kind == .rectangle, roi.points.count == 2 {
            let a = roi.points[0], b = roi.points[1]
            outline = [a, IsiXPixelPoint(x: b.x, y: a.y), b, IsiXPixelPoint(x: a.x, y: b.y)]
        }
        var values: [Double] = []
        let image = phases[roi.phase][roi.slice]
        for r in 0..<rows {
            for c in 0..<columns where inside(outline, Double(c), Double(r)) {
                values.append(Double(image[r * columns + c]))
            }
        }
        let sum = values.reduce(0, +)
        let mean = values.isEmpty ? 0 : sum / Double(values.count)
        let deviation = values.isEmpty ? 0 : (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        return IsiXROIStatistics(mean: mean, standardDeviation: deviation, minimum: values.min() ?? 0, maximum: values.max() ?? 0,
                                 sum: sum, area: Double(values.count) * spacing.column * spacing.row, length: nil)
    }

    private func inside(_ outline: [IsiXPixelPoint], _ x: Double, _ y: Double) -> Bool {
        var result = false
        var j = outline.count - 1
        for i in outline.indices {
            let a = outline[i], b = outline[j]
            if (a.y > y) != (b.y > y) && x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x { result.toggle() }
            j = i
        }
        return result
    }

    func setNeedsDisplay() {}
}

@MainActor
final class FakeHost: IsiXHostBackend {
    var viewers: [FakeViewer] = []
    var runtime: IsiXPluginRuntime?
    /// The viewer's window, which a command gets to attach sheets to.
    let window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "Synthetic viewer"
        return window
    }()
    func frontmostViewer() -> (any IsiXViewerBackend)? { viewers.first { $0.isOpen } }
    func openViewers() -> [any IsiXViewerBackend] { viewers.filter { $0.isOpen } }
    func viewer(withID id: IsiXViewerID) -> (any IsiXViewerBackend)? { viewers.first { $0.isOpen && $0.viewerID == id } }
    func parentWindow(forViewer id: IsiXViewerID?) -> NSWindow? { window }
    func selectedStudies() async throws -> [IsiXStudy] { throw IsiXPluginError.noDatabase }
    func study(withInstanceUID uid: String) async throws -> IsiXStudy? { throw IsiXPluginError.noDatabase }
    func series(inStudy studyInstanceUID: String) async throws -> [IsiXSeries] { throw IsiXPluginError.noDatabase }
    func importFiles(at urls: [URL]) async throws -> IsiXImportResult { throw IsiXPluginError.noDatabase }
    func commandsDidChange() {}

    /// The application posts its notifications as things happen; the plugin
    /// host turns them into events at once.
    func announce(_ event: IsiXEvent) { runtime?.deliver(event) }

    /// A click, drag or key on the image of `viewer`, as the image view gives it to the plugins.
    func input(_ kind: IsiXViewerInput.Kind, on viewer: FakeViewer, at point: IsiXPixelPoint, characters: String? = nil) -> Bool {
        guard let runtime, runtime.inputKinds.contains(kind.kinds) else { return false }
        return runtime.handleInput(IsiXViewerInput(kind: kind, viewerID: viewer.viewerID,
                                                   position: IsiXSlicePosition(slice: viewer.current, phase: viewer.phase),
                                                   location: point, locationInWindow: CGPoint(x: point.x * 10, y: point.y * 10),
                                                   clickCount: kind == .keyDown ? 0 : 1, characters: characters, keyCode: characters == nil ? nil : 40))
    }
}

/// Lets the run loop run, for what the kit announces on its next turn.
@MainActor
func settle(_ seconds: Double = 0.2) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func message(_ error: any Error) -> String {
    if let error = error as? IsiXEntryError { return "entry: " + error.message }
    return IsiXUserMessage(for: error)
}

@MainActor
func load(_ url: URL, host: FakeHost, output: inout [String: Any]) -> IsiXPluginRuntime? {
    let inspection = PluginInspector().inspect(bundleAt: url)
    guard inspection.isLoadable, let manifest = inspection.manifest else {
        output["diagnostics"] = inspection.diagnostics.map { "\($0)" }
        return nil
    }
    let executable = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(manifest.executableName)
    guard let bundle = Bundle(url: url) else { output["error"] = "no bundle"; return nil }
    do {
        try bundle.loadAndReturnError()
        let type = try IsiXPluginRuntime.resolveEntry(named: manifest.principalClass, executableURL: executable)
        let info = IsiXPluginInfo(identifier: manifest.identifier, name: manifest.name, version: manifest.version, bundleURL: url,
                                  capabilities: Set(manifest.capabilities.map(IsiXCapability.init(rawValue:))))
        let runtime = IsiXPluginRuntime(info: info, bundle: bundle, entry: type, host: host)
        host.runtime = runtime
        do { try runtime.activate() } catch { output["activationError"] = message(error) }
        output["state"] = "\(runtime.state)"
        return runtime
    } catch {
        output["error"] = message(error)
        return nil
    }
}

@MainActor
func runFirst(_ runtime: IsiXPluginRuntime, _ output: inout [String: Any]) {
    guard let command = runtime.commands.first else { output["runError"] = "no command"; return }
    do { try runtime.run(commandID: command.id) } catch { output["runError"] = message(error) }
}

@MainActor
func views(in view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { views(in: $0) }
}

/// The button of an open window whose action is `action`.
@MainActor
func button(action: String) -> NSButton? {
    NSApp.windows.lazy.flatMap { views(in: $0.contentView) }.compactMap { $0 as? NSButton }
        .first { $0.action.map(NSStringFromSelector) == action }
}

@MainActor
func windowController(named name: String) -> NSWindowController? {
    NSApp.windows.compactMap(\.windowController).first { NSStringFromClass(type(of: $0)) == name }
}

/// The samples of an image, row by row, from a value per row and column.
func image(columns: Int, rows: Int, _ value: (Int, Int) -> Float) -> [Float] {
    var samples: [Float] = []
    for r in 0..<rows {
        for c in 0..<columns { samples.append(value(r, c)) }
    }
    return samples
}

func describe(_ roi: IsiXROI) -> String {
    "\(roi.kind) \(roi.name) \(roi.points.count)"
}

@MainActor
func run(itkPlugin: Bool) -> [String: Any] {
    _ = NSApplication.shared
    var result: [String: Any] = [:]
    for url in CommandLine.arguments.dropFirst().map({ URL(fileURLWithPath: $0) }) {
        let name = url.deletingPathExtension().lastPathComponent
        let host = FakeHost()
        var output: [String: Any] = [:]
        switch name {
        case "ViewerProbe":
            // Two phases of three 6 x 4 images: 10 + 3 slice + 2 row + column, plus 100 in phase 1.
            let phase0: [[Float]] = (0..<3).map { s in image(columns: 6, rows: 4) { r, c in Float(10 + 3 * s + 2 * r + c) } }
            let viewer = FakeViewer(host: host, columns: 6, rows: 4, spacing: (0.5, 0.75),
                                    phases: [phase0, phase0.map { $0.map { $0 + 100 } }], current: 2)
            host.viewers = [viewer]
            guard let runtime = load(url, host: host, output: &output) else { break }
            runFirst(runtime, &output)
            output["phaseAtEnd"] = viewer.phase
            output["inputKinds"] = runtime.inputKinds.rawValue
            // The application's own notifications of the kit's names never reach the plugin.
            NotificationCenter.default.post(name: Notification.Name("mouseDown"), object: nil,
                                            userInfo: ["X": 9, "Y": 9, "stopMouseDown": false])
            output["clickTaken"] = host.input(.mouseDown, on: viewer, at: IsiXPixelPoint(x: 2, y: 1))
            output["dragTaken"] = host.input(.mouseDragged, on: viewer, at: IsiXPixelPoint(x: 3, y: 1))
            output["keyKTaken"] = host.input(.keyDown, on: viewer, at: IsiXPixelPoint(x: 0, y: 0), characters: "k")
            output["keyJTaken"] = host.input(.keyDown, on: viewer, at: IsiXPixelPoint(x: 0, y: 0), characters: "j")
            try? viewer.setCurrentSlice(1)
            host.announce(.sliceChanged(viewer.viewerID, IsiXSlicePosition(slice: 1, phase: 0)))
            let box = viewer.draw(.rectangle, [IsiXPixelPoint(x: 1, y: 1), IsiXPixelPoint(x: 3, y: 2)], slice: 1, name: "user box")
            settle()
            _ = try? viewer.updateROI(box.id, IsiXROIUpdate(points: [IsiXPixelPoint(x: 0, y: 0), IsiXPixelPoint(x: 4, y: 3)]))
            settle()
            _ = try? viewer.updateROI(box.id, IsiXROIUpdate(isSelected: true))
            settle()
            try? viewer.removeROI(box.id)
            settle()
            // The image drawn: 6 x 4 pixels of 8 x 8 device pixels, rows down;
            // the plugin API's pixel coordinates put the centre of the first
            // pixel at (0, 0).
            output["drawsOverlays"] = runtime.hasOverlays(on: viewer.viewerID)
            let space = CGColorSpaceCreateDeviceRGB()
            if let context = CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 48 * 4, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.translateBy(x: 0, y: 32)
                context.scaleBy(x: 8, y: -8)
                context.translateBy(x: 0.5, y: 0.5)
                runtime.drawOverlays(IsiXOverlayContext(cgContext: context, viewerID: viewer.viewerID,
                                                        position: IsiXSlicePosition(slice: 1, phase: 0), pointSize: 0.25))
                let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
                // Red where pixel (column, row) is: its centre at (8 c + 4, 8 r + 4) from the top left.
                output["redPixels"] = (0..<4).flatMap { r in (0..<6).compactMap { c -> String? in
                    bytes[((8 * r + 4) * 48 + 8 * c + 4) * 4] > 200 ? "\(c),\(r)" : nil } }
            }
            viewer.isOpen = false
            host.announce(.viewerWillClose(viewer.viewerID))
            settle()
            let report = (NSClassFromString("ViewerProbeFilter") as AnyObject?)?.perform(NSSelectorFromString("report"))?
                .takeUnretainedValue() as? [String: Any] ?? [:]
            output["report"] = report
        case "VolumeCalculator":
            let viewer = FakeViewer(host: host, columns: 32, rows: 32, spacing: (0.5, 0.5),
                                    phases: [Array(repeating: [Float](repeating: 40, count: 32 * 32), count: 3)], current: 1)
            let first = viewer.draw(.line, [IsiXPixelPoint(x: 2, y: 2), IsiXPixelPoint(x: 12, y: 2)], slice: 1, name: "first", selected: true)
            viewer.draw(.line, [IsiXPixelPoint(x: 2, y: 5), IsiXPixelPoint(x: 22, y: 5)], slice: 1, name: "second")
            host.viewers = [viewer]
            guard let runtime = load(url, host: host, output: &output) else { break }
            runFirst(runtime, &output)
            settle()
            func fields() -> [Double] {
                guard let controller = windowController(named: "ControllerVolumeCalculator") else { return [] }
                return ["diameter1", "diameter2", "volume1", "volume2"].map {
                    Double((controller.value(forKey: $0) as? NSTextField)?.floatValue ?? -1)
                }
            }
            output["window"] = windowController(named: "ControllerVolumeCalculator")?.window?.title ?? ""
            output["before"] = fields()
            // The user lengthens the first line in the viewer.
            _ = try? viewer.updateROI(first.id, IsiXROIUpdate(points: [IsiXPixelPoint(x: 2, y: 2), IsiXPixelPoint(x: 17, y: 2)]))
            settle()
            output["afterChange"] = fields()
            try? viewer.removeROI(first.id)
            settle()
            output["afterRemoval"] = fields()
            viewer.isOpen = false
            host.announce(.viewerWillClose(viewer.viewerID))
            settle()
        case "CardiacStatistics":
            // A 64 x 64 image: value = column + 2 row, 1 mm pixels.
            let picture = image(columns: 64, rows: 64) { r, c in Float(c + 2 * r) }
            let viewer = FakeViewer(host: host, columns: 64, rows: 64, phases: [[picture]], current: 0)
            host.viewers = [viewer]
            guard let runtime = load(url, host: host, output: &output) else { break }
            runFirst(runtime, &output)
            output["panel"] = button(action: "startTrackingMouse:") != nil
            button(action: "startTrackingMouse:")?.performClick(nil)
            // Epi point, centre of the ventricle, endo point, RV-LV junction, as the user clicks them.
            let clicks = [(31.5, 11.5), (31.5, 31.5), (31.5, 21.5), (51.5, 31.5)]
            output["clicksTaken"] = clicks.map { host.input(.mouseDown, on: viewer, at: IsiXPixelPoint(x: $0.0, y: $0.1)) }
            settle()
            output["afterClicks"] = viewer.stored.map(describe)
            button(action: "SegmentInter:")?.performClick(nil)
            settle(0.4)
            let sectors = viewer.stored.filter { $0.name.hasPrefix("Sector") }
            output["sectors"] = sectors.map(describe)
            output["sectorComments"] = Set(sectors.map(\.comment)).sorted()
            // The plugin walks the smoothed outlines to cut the sectors; with
            // only the clicked points it found no outline point at some
            // angles and drew to the image's corner.
            output["sectorPointsNearCorner"] = sectors.flatMap(\.points).filter { hypot($0.x + 0.5, $0.y + 0.5) < 2 }.count
            // The plugin's own window with the sectors' table.
            if let manager = windowController(named: "SectorManagerController"),
               let table = views(in: manager.window?.contentView).compactMap({ $0 as? NSTableView }).first,
               let source = table.dataSource, let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("Mean")),
               let names = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("Name")) {
                output["managerWindow"] = manager.window?.title ?? ""
                let rows = source.numberOfRows?(in: table) ?? 0
                output["tableRows"] = rows
                var difference = 0.0
                var shown: [String] = []
                for row in 0..<rows {
                    let name = source.tableView?(table, objectValueFor: names, row: row) as? String ?? ""
                    let mean = (source.tableView?(table, objectValueFor: column, row: row) as? NSNumber)?.doubleValue ?? -1
                    let roi = sectors.first { $0.name == name }
                    let expected = roi.flatMap { try? viewer.statistics(of: $0.id).mean } ?? -9999
                    difference = max(difference, abs(mean - expected))
                    shown.append(String(format: "%@ %.2f", name, mean))
                }
                output["tableMeans"] = shown
                output["tableMaxDifference"] = difference
            }
        case "ReactivationProbe":
            // The plugin activated, deactivated and activated again in this
            // process; each time the image is clicked, another image is shown,
            // a ROI is drawn and images enter the database, as the
            // application announces them.
            let viewer = FakeViewer(host: host, columns: 4, rows: 4,
                                    phases: [Array(repeating: [Float](repeating: 0, count: 16), count: 3)], current: 0)
            host.viewers = [viewer]
            func heard() -> [String] {
                (NSClassFromString("ReactivationProbeFilter") as AnyObject?)?.perform(NSSelectorFromString("takeHeard"))?
                    .takeUnretainedValue() as? [String] ?? []
            }
            func exercise(slice: Int) -> [String] {
                _ = host.input(.mouseDown, on: viewer, at: IsiXPixelPoint(x: 1, y: 1))
                try? viewer.setCurrentSlice(slice)
                host.announce(.sliceChanged(viewer.viewerID, IsiXSlicePosition(slice: slice, phase: 0)))
                viewer.draw(.rectangle, [IsiXPixelPoint(x: 0, y: 0), IsiXPixelPoint(x: 2, y: 2)], slice: slice, name: "box \(slice)")
                host.announce(.imagesAdded(IsiXImagesAdded(images: [], sopInstanceUIDsByCallingAETitle: [:], isComplete: false)))
                settle()
                return heard()
            }
            guard let first = load(url, host: host, output: &output) else { break }
            output["firstState"] = output["state"]
            output["first"] = exercise(slice: 1)
            first.deactivate()
            output["afterDeactivation"] = exercise(slice: 2)
            guard let second = load(url, host: host, output: &output) else { break }
            output["second"] = exercise(slice: 0)
            second.deactivate()
        case "NMSegmentation":
            guard itkPlugin else { break }
            let square = image(columns: 32, rows: 32) { r, c in (4...13).contains(r) && (4...13).contains(c) ? 2000 : 40 }
            let viewer = FakeViewer(host: host, columns: 32, rows: 32, spacing: (0.5, 0.75), phases: [Array(repeating: square, count: 5)], current: 2)
            host.viewers = [viewer]
            guard let runtime = load(url, host: host, output: &output) else { break }
            runFirst(runtime, &output)
            let controller = windowController(named: "NMRegionGrowingController")
            output["window"] = controller?.window?.title ?? ""
            (controller?.value(forKey: "disableClickButton") as? NSButton)?.state = .on
            // A click in the square: the plugin takes it as its seed, and the viewer does nothing else with it.
            output["clickTaken"] = host.input(.mouseDown, on: viewer, at: IsiXPixelPoint(x: 6, y: 7))
            output["seed"] = ["posX", "posY", "posZ"].map { (controller?.value(forKey: $0) as? NSNumber)?.intValue ?? -1 }
            output["seedLabel"] = (controller?.value(forKey: "seedLabel") as? NSTextField)?.stringValue ?? ""
        default:
            break
        }
        output["kitCenter"] = NSClassFromString("IsiXLegacy\(name)_NotificationCenter") != nil
        result[name] = output
    }
    return result
}

let data = MainActor.assumeIsolated {
    try! JSONSerialization.data(withJSONObject: run(itkPlugin: ProcessInfo.processInfo.environment["ISIX_LEGACY_ITK_PLUGIN"] == "1"),
                                options: [.prettyPrinted, .sortedKeys])
}
print(String(decoding: data, as: UTF8.self))
