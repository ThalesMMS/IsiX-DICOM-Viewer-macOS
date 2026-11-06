//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A host for tests/test-isix-legacy-bridge.py: the application's loading path
// (IsiXPluginLoading's inspection, the bundle load, entry resolution and the
// kit's runtime) with synthetic viewers, running legacy plugins ported with
// IsiXLegacyBridge. It prints one JSON object; the test checks it.
//
//     LegacyHarness <plugin.isixplugin>...
//
// Plugins are recognised by their bundle name: CardiacTaggingMRI, ROIRotation,
// ROICorrectDisplayTextualData, Vertebra, and KitProbe* (the test's own probe);
// tests/test-isix-legacy-dynamic-access.py adds DynamicProbe* and
// VolumeCalculator, and compiles in classes named as the application's and
// a database for the host (tests/fixtures/isix-legacy-dynamic/DynamicAccessHost.swift);
// tests/test-isix-legacy-ported-plugins.py adds grid and SpineCounter.

import AppKit
import MachO
@_spi(IsiXHost) import IsiXPluginKit
import IsiXPluginLoading

/// Value of the synthetic series: slice s, row r, column c.
func sample(_ s: Int, _ r: Int, _ c: Int) -> Float { Float(10 + 3 * s + 2 * r + c) }

@MainActor
final class FakeViewer: IsiXViewerBackend {
    let viewerID = IsiXViewerID(rawValue: UUID())
    var isOpen = true
    let columns: Int, rows: Int
    var slices: [[Float]]
    var tokens: [UInt64]
    var current: Int
    var stored: [IsiXROI] = []
    /// The masks of the brush ROIs a plugin made.
    var masks: [IsiXROIID: IsiXROIMask] = [:]
    var level = IsiXWindowLevel(center: 40, width: 400)
    var commits = 0
    unowned let host: FakeHost

    init(host: FakeHost, columns: Int = 6, rows: Int = 4, slices: [[Float]], current: Int = 0) {
        self.host = host
        self.columns = columns
        self.rows = rows
        self.slices = slices
        self.tokens = Array(repeating: 1, count: slices.count)
        self.current = current
    }

    static func series(sliceCount: Int, columns: Int = 6, rows: Int = 4) -> [[Float]] {
        (0..<sliceCount).map { s in (0..<rows).flatMap { r in (0..<columns).map { c in sample(s, r, c) } } }
    }

    func geometry(_ slice: Int) -> IsiXImageGeometry {
        IsiXImageGeometry(columns: columns, rows: rows, columnSpacing: 0.5, rowSpacing: 0.75,
                          imagePosition: IsiXVector3(x: -10, y: 20, z: 30 + 2 * Double(slice)),
                          rowDirection: IsiXVector3(x: 1, y: 0, z: 0), columnDirection: IsiXVector3(x: 0, y: 1, z: 0),
                          sliceThickness: 2, sliceInterval: 2, sliceLocation: 2 * Double(slice))
    }

    private func slice(_ slice: Int?, _ phase: Int?) throws -> Int {
        guard isOpen else { throw IsiXPluginError.viewerClosed }
        if let phase, phase != 0 { throw IsiXPluginError.phaseOutOfRange(phase) }
        let s = slice ?? current
        guard slices.indices.contains(s) else { throw IsiXPluginError.sliceOutOfRange(s) }
        return s
    }

    func seriesSummary() throws -> IsiXSeriesSummary {
        _ = try slice(nil, nil)
        return IsiXSeriesSummary(sliceCount: slices.count, phaseCount: 1, currentSlice: current, currentPhase: 0,
                                 studyInstanceUID: "1.2.3", seriesInstanceUID: "1.2.3.4", seriesDescription: "Synthetic", modality: "MR")
    }

    func currentPosition() throws -> IsiXSlicePosition { IsiXSlicePosition(slice: try slice(nil, nil), phase: 0) }
    func setCurrentSlice(_ value: Int) throws { current = try slice(value, nil) }

    func image(slice value: Int?, phase: Int?) throws -> IsiXImage {
        let s = try slice(value, phase)
        return IsiXImage(version: IsiXImageVersion(viewer: viewerID, slice: s, phase: 0, token: tokens[s]), geometry: geometry(s),
                         attributes: IsiXImageAttributes(modality: "MR", sopInstanceUID: "1.2.3.4.\(s)", echoTime: 20),
                         pixels: .float32(try IsiXPixelBuffer(width: columns, height: rows, samples: slices[s])))
    }

    func geometry(slice value: Int?, phase: Int?) throws -> IsiXImageGeometry { geometry(try slice(value, phase)) }
    func windowLevel() throws -> IsiXWindowLevel { _ = try slice(nil, nil); return level }
    func setWindowLevel(_ windowLevel: IsiXWindowLevel) throws { _ = try slice(nil, nil); level = windowLevel }

    func commit(_ pixels: IsiXPixelData, replacing version: IsiXImageVersion) throws {
        let s = try slice(version.slice, version.phase)
        guard version.viewer == viewerID, version.hostToken == tokens[s] else { throw IsiXPluginError.staleImage }
        guard case .float32(let buffer) = pixels else { throw IsiXPluginError.dimensionMismatch }
        slices[s] = buffer.samples
        tokens[s] += 1
        commits += 1
    }

    func rois(slice value: Int?, phase: Int?) throws -> [IsiXROI] {
        let s = try slice(value, phase)
        return stored.filter { $0.slice == s }
    }

    private func check(_ kind: IsiXROIKind, _ points: [IsiXPixelPoint]) throws {
        switch kind {
        case .point: guard points.count == 1 else { throw IsiXPluginError.invalidROI("points") }
        case .line, .rectangle, .oval: guard points.count == 2 else { throw IsiXPluginError.invalidROI("points") }
        case .polygon: guard points.count >= 3 else { throw IsiXPluginError.invalidROI("points") }
        case .polyline: guard points.count >= 2 else { throw IsiXPluginError.invalidROI("points") }
        default: throw IsiXPluginError.unsupportedROIKind(kind)
        }
    }

    func addROI(_ draft: IsiXROIDraft) throws -> IsiXROI {
        let s = try slice(draft.slice, draft.phase)
        if draft.kind == .brush {
            guard let mask = draft.mask, mask.count > 0 else { throw IsiXPluginError.invalidROI("mask") }
            let roi = IsiXROI(id: IsiXROIID(rawValue: UUID()), kind: .brush, name: draft.name ?? "", comment: "",
                              slice: s, phase: 0, points: [], patientPoints: [])
            stored.append(roi)
            masks[roi.id] = mask
            return roi
        }
        try check(draft.kind, draft.points)
        let g = geometry(s)
        let roi = IsiXROI(id: IsiXROIID(rawValue: UUID()), kind: draft.kind, name: draft.name ?? "", comment: "",
                          slice: s, phase: 0, points: draft.points, patientPoints: draft.points.map { g.patientPoint(of: $0) })
        stored.append(roi)
        return roi
    }

    /// Puts a ROI in the viewer as the user would draw it.
    @discardableResult
    func draw(_ kind: IsiXROIKind, _ points: [IsiXPixelPoint], slice: Int, name: String, selected: Bool = false,
              showsTextBox: Bool = true) -> IsiXROI {
        let g = geometry(slice)
        let roi = IsiXROI(id: IsiXROIID(rawValue: UUID()), kind: kind, name: name, comment: "", slice: slice, phase: 0,
                          points: points, patientPoints: points.map { g.patientPoint(of: $0) }, isSelected: selected, showsTextBox: showsTextBox)
        stored.append(roi)
        return roi
    }

    func updateROI(_ id: IsiXROIID, _ update: IsiXROIUpdate) throws -> IsiXROI {
        _ = try slice(nil, nil)
        guard let index = stored.firstIndex(where: { $0.id == id }) else { throw IsiXPluginError.roiNotFound }
        var roi = stored[index]
        let kind = update.kind ?? roi.kind
        if kind != roi.kind && !(kind == .polygon && (roi.kind == .rectangle || roi.kind == .oval)) {
            throw IsiXPluginError.invalidROI("kind")
        }
        if let points = update.points {
            try check(kind, points)
            roi.points = points
            roi.patientPoints = points.map { geometry(roi.slice).patientPoint(of: $0) }
            roi.kind = kind
        }
        if let name = update.name { roi.name = name }
        if let comment = update.comment { roi.comment = comment }
        if let selected = update.isSelected { roi.isSelected = selected }
        if let shows = update.showsTextBox { roi.showsTextBox = shows }
        stored[index] = roi
        return roi
    }

    func removeROI(_ id: IsiXROIID) throws {
        _ = try slice(nil, nil)
        guard stored.contains(where: { $0.id == id }) else { throw IsiXPluginError.roiNotFound }
        stored.removeAll { $0.id == id }
    }

    /// The mean of the pixels whose centres lie in the rectangle's bounding box.
    func statistics(of id: IsiXROIID) throws -> IsiXROIStatistics {
        _ = try slice(nil, nil)
        guard let roi = stored.first(where: { $0.id == id }) else { throw IsiXPluginError.roiNotFound }
        let xs = roi.points.map(\.x), ys = roi.points.map(\.y)
        var values: [Double] = []
        for r in 0..<rows where Double(r) >= ys.min()! && Double(r) <= ys.max()! {
            for c in 0..<columns where Double(c) >= xs.min()! && Double(c) <= xs.max()! {
                values.append(Double(slices[roi.slice][r * columns + c]))
            }
        }
        let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        return IsiXROIStatistics(mean: mean, standardDeviation: 0, minimum: values.min() ?? 0, maximum: values.max() ?? 0,
                                 sum: values.reduce(0, +), area: nil, length: nil)
    }

    func setNeedsDisplay() {}

    func openDerivedSeries(_ series: IsiXDerivedSeries) throws -> any IsiXViewerBackend {
        let viewer = FakeViewer(host: host, columns: columns, rows: rows, slices: series.images.map { $0.pixels.samples })
        viewer.derivedFrom = series.images.map(\.sourceSlice)
        host.viewers.append(viewer)
        return viewer
    }

    var derivedFrom: [Int] = []
}

@MainActor
final class FakeHost: IsiXHostBackend {
    var viewers: [FakeViewer] = []
    /// The window the viewers' commands get to attach sheets to.
    var window: NSWindow?
    func frontmostViewer() -> (any IsiXViewerBackend)? { viewers.first { $0.isOpen } }
    func openViewers() -> [any IsiXViewerBackend] { viewers.filter { $0.isOpen } }
    func viewer(withID id: IsiXViewerID) -> (any IsiXViewerBackend)? { viewers.first { $0.isOpen && $0.viewerID == id } }
    func parentWindow(forViewer id: IsiXViewerID?) -> NSWindow? { window }
    func selectedStudies() async throws -> [IsiXStudy] { throw IsiXPluginError.noDatabase }
    func study(withInstanceUID uid: String) async throws -> IsiXStudy? { throw IsiXPluginError.noDatabase }
    func series(inStudy studyInstanceUID: String) async throws -> [IsiXSeries] { throw IsiXPluginError.noDatabase }
    func importFiles(at urls: [URL]) async throws -> IsiXImportResult { throw IsiXPluginError.noDatabase }
    func commandsDidChange() {}
}

/// A 32 x 32 series of five images: 40 everywhere, 80 in column 0 and a
/// 10 x 10 square of 2000 at columns and rows 4 to 13, the same on every image.
func squarePhantom() -> [[Float]] {
    let image = (0..<32).flatMap { r in (0..<32).map { c -> Float in
        (4...13).contains(r) && (4...13).contains(c) ? 2000 : c == 0 ? 80 : 40 } }
    return Array(repeating: image, count: 5)
}

func message(_ error: any Error) -> String {
    if let error = error as? IsiXEntryError { return "entry: " + error.message }
    return IsiXUserMessage(for: error)
}

func describe(_ roi: IsiXROI) -> String {
    let points = roi.points.map { String(format: "%.4f,%.4f", $0.x, $0.y) }.joined(separator: " ")
    return "\(roi.kind) \(roi.name) [\(points)] selected \(roi.isSelected) text \(roi.showsTextBox)"
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
        do { try runtime.activate() } catch { output["activationError"] = message(error) }
        output["state"] = "\(runtime.state)"
        output["commands"] = runtime.commands.map { "\($0.title)|\($0.placement)|\($0.requirement)" }
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

/// The views of a window, depth first.
@MainActor
func views(in view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { views(in: $0) }
}

@MainActor
func run() -> [String: Any] {
    _ = NSApplication.shared
    var result: [String: Any] = ["hostArchitecture": MachOImage.hostArchitecture]
    for url in CommandLine.arguments.dropFirst().map({ URL(fileURLWithPath: $0) }) {
        let name = url.deletingPathExtension().lastPathComponent
        let host = FakeHost()
        var output: [String: Any] = [:]
        switch name {
        case "CardiacTaggingMRI":
            let viewer = FakeViewer(host: host, slices: FakeViewer.series(sliceCount: 8))
            host.viewers = [viewer]
            guard let runtime = load(url, host: host, output: &output) else { break }
            runFirst(runtime, &output)
            output["viewers"] = host.viewers.count
            if host.viewers.count == 2 {
                let made = host.viewers[1]
                output["derivedFrom"] = made.derivedFrom
                // The plugin's formula: slice z times slice z + n/2, over the
                // first slice's full window width, each image scaled to the
                // series' maximum, with the maxima kept as whole numbers.
                let half = 4, n = 24
                var expected: [[Float]] = []
                var maxima: [Int] = []
                for z in 0..<half {
                    let a = viewer.slices[z], b = viewer.slices[z + half]
                    let fullww = a.max()! - a.min()!
                    let values = (0..<n).map { b[$0] * a[$0] / fullww }
                    expected.append(values)
                    maxima.append(Int(max(0, values.max()!)))
                }
                let top = Float(maxima.max()!)
                expected = expected.enumerated().map { z, values in values.map { $0 * (top / Float(maxima[z])) } }
                let difference = zip(made.slices, expected).flatMap { zip($0, $1).map { abs($0 - $1) } }.max() ?? -1
                output["maxDifference"] = Double(difference)
                output["sourceUnchanged"] = viewer.slices == FakeViewer.series(sliceCount: 8)
                output["firstValues"] = made.slices[0].prefix(3).map(Double.init)
            }
        case "Vertebra":
            let viewer = FakeViewer(host: host, slices: FakeViewer.series(sliceCount: 5))
            host.viewers = [viewer]
            guard let runtime = load(url, host: host, output: &output) else { break }
            runFirst(runtime, &output)
            output["viewers"] = host.viewers.count
            output["copyEqual"] = host.viewers.count == 2 && host.viewers[1].slices == viewer.slices
        case "ROICorrectDisplayTextualData":
            let first = FakeViewer(host: host, slices: FakeViewer.series(sliceCount: 4))
            let second = FakeViewer(host: host, slices: FakeViewer.series(sliceCount: 3))
            for (viewer, slices) in [(first, [0, 3]), (second, [1])] {
                for slice in slices {
                    viewer.draw(.rectangle, [IsiXPixelPoint(x: 1, y: 1), IsiXPixelPoint(x: 3, y: 2)], slice: slice, name: "box \(slice)", showsTextBox: false)
                    viewer.draw(.line, [IsiXPixelPoint(x: 0, y: 0), IsiXPixelPoint(x: 4, y: 3)], slice: slice, name: "line \(slice)", showsTextBox: false)
                }
            }
            host.viewers = [first, second]
            guard let runtime = load(url, host: host, output: &output) else { break }
            output["textBoxesBefore"] = (first.stored + second.stored).filter(\.showsTextBox).count
            runFirst(runtime, &output)
            output["textBoxesAfter"] = (first.stored + second.stored).filter(\.showsTextBox).count
            output["rois"] = (first.stored + second.stored).count
            output["unchangedOtherwise"] = (first.stored + second.stored).allSatisfy { $0.kind == .rectangle || $0.kind == .line }
        case "NMSegmentation":
            // A region growing in 3D from a seed in the square, as the user
            // would start it from the plugin's window.
            let viewer = FakeViewer(host: host, columns: 32, rows: 32, slices: squarePhantom(), current: 2)
            host.viewers = [viewer]
            host.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                                   backing: .buffered, defer: true)
            host.window?.title = "Synthetic square"
            guard let runtime = load(url, host: host, output: &output) else { break }
            runFirst(runtime, &output)
            let controller = NSApp.windows.compactMap(\.windowController)
                .first { NSStringFromClass(type(of: $0)) == "NMRegionGrowingController" }
            output["window"] = controller?.window?.title ?? ""
            if let controller {
                controller.setValue(6, forKey: "posX")
                controller.setValue(7, forKey: "posY")
                controller.setValue(2, forKey: "posZ")
                (controller.value(forKey: "lowerThresholdBox") as? NSTextField)?.stringValue = "1000"
                (controller.value(forKey: "upperThresholdBox") as? NSTextField)?.stringValue = "3000"
                output["algorithm"] = (controller.value(forKey: "algorithmPopUp") as? NSPopUpButton)?.selectedItem?.tag ?? -1
                _ = controller.perform(NSSelectorFromString("calculate:"), with: nil)
                // The plugin announces the ROIs with "roiChange"; the kit gives
                // them to the viewer on the next turn of the run loop.
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            }
            output["brushes"] = viewer.stored.filter { $0.kind == .brush }.map { roi -> String in
                let mask = viewer.masks[roi.id]
                return "slice \(roi.slice) \(roi.name) mask \(mask?.column ?? -1),\(mask?.row ?? -1) "
                    + "\(mask?.width ?? 0)x\(mask?.height ?? 0) inside \(mask?.count ?? 0)"
            }
            output["otherROIs"] = viewer.stored.filter { $0.kind != .brush }.map(describe)
        case "ROIRotation":
            let viewer = FakeViewer(host: host, slices: FakeViewer.series(sliceCount: 3), current: 1)
            let selected = viewer.draw(.rectangle, [IsiXPixelPoint(x: 2, y: 1), IsiXPixelPoint(x: 6, y: 3)], slice: 1, name: "turned", selected: true)
            let other = viewer.draw(.rectangle, [IsiXPixelPoint(x: 0, y: 0), IsiXPixelPoint(x: 1, y: 1)], slice: 1, name: "kept")
            host.viewers = [viewer]
            guard let runtime = load(url, host: host, output: &output) else { break }
            runFirst(runtime, &output)
            // The command shows the plugin's dialog; type 90 and press OK, as the user would.
            let dialog = NSApp.windows.first { window in views(in: window.contentView).contains { ($0 as? NSButton)?.tag == 1 } }
            output["dialog"] = dialog?.title ?? ""
            if let dialog {
                let all = views(in: dialog.contentView)
                let field = all.compactMap { $0 as? NSTextField }.first { $0.isEditable }
                field?.stringValue = "90"
                (all.compactMap { $0 as? NSButton }.first { $0.tag == 1 })?.performClick(nil)
            }
            let turned = viewer.stored.first { $0.id == selected.id }
            output["turned"] = turned.map(describe) ?? "missing"
            output["kept"] = viewer.stored.first { $0.id == other.id }.map(describe) ?? "missing"
            // The application's rotation: about the rectangle's origin (its
            // first corner, at half coordinates), in the patient's proportions
            // (row spacing / column spacing = 1.5), the corners in the
            // application's order.
            let ratio = 0.75 / 0.5, centre = (x: 2.5, y: 1.5)
            let corners = [(2.5, 1.5), (2.5, 3.5), (6.5, 3.5), (6.5, 1.5)]
            output["expected"] = corners.map { x, y -> String in
                let dx = x - centre.x, dy = y - centre.y
                let nx = -dy * ratio + centre.x, ny = dx / ratio + centre.y
                return String(format: "%.4f,%.4f", nx - 0.5, ny - 0.5)
            }.joined(separator: " ")
        case "grid":
            // tests/test-isix-legacy-ported-plugins.py: a selected rectangle of 8 x 8
            // pixels from (10, 10), and the command "1": one-pixel lines every 8 pixels
            // through the rectangle's corner, on every image, then the ROI goes.
            let viewer = FakeViewer(host: host, columns: 32, rows: 32, slices: squarePhantom(), current: 2)
            viewer.draw(.rectangle, [IsiXPixelPoint(x: 10, y: 10), IsiXPixelPoint(x: 18, y: 18)], slice: 2, name: "cell", selected: true)
            host.viewers = [viewer]
            guard let runtime = load(url, host: host, output: &output) else { break }
            runFirst(runtime, &output)
            let before = squarePhantom()
            var rows = Set<Int>(), columns = Set<Int>(), changedElsewhere = 0
            for (s, image) in viewer.slices.enumerated() {
                for r in 0..<32 where (0..<32).allSatisfy({ image[r * 32 + $0] == 1 }) { rows.insert(r) }
                for c in 0..<32 where (0..<32).allSatisfy({ image[$0 * 32 + c] == 1 }) { columns.insert(c) }
                for r in 0..<32 { for c in 0..<32 where r % 8 != 2 && c % 8 != 2 && image[r * 32 + c] != before[s][r * 32 + c] {
                    changedElsewhere += 1 } }
            }
            output["gridRows"] = rows.sorted()
            output["gridColumns"] = columns.sorted()
            output["changedElsewhere"] = changedElsewhere
            output["roisLeft"] = viewer.stored.map(describe)
        case "SpineCounter":
            // A length ROI named "1", selected: "Switch Spine Type" names it "1 S", as
            // the legacy plugin did on every image of the series.
            let viewer = FakeViewer(host: host, slices: FakeViewer.series(sliceCount: 3), current: 1)
            viewer.draw(.line, [IsiXPixelPoint(x: 0, y: 0), IsiXPixelPoint(x: 4, y: 3)], slice: 1, name: "1", selected: true)
            viewer.draw(.line, [IsiXPixelPoint(x: 1, y: 1), IsiXPixelPoint(x: 2, y: 2)], slice: 2, name: "1")
            viewer.draw(.line, [IsiXPixelPoint(x: 1, y: 1), IsiXPixelPoint(x: 2, y: 2)], slice: 2, name: "2")
            host.viewers = [viewer]
            guard let runtime = load(url, host: host, output: &output) else { break }
            output["commands"] = runtime.commands.map(\.title)
            runFirst(runtime, &output)
            output["names"] = viewer.stored.map(\.name)
        case let probe where probe.hasPrefix("DynamicProbe"):
            // tests/test-isix-legacy-dynamic-access.py: classes, messages and keys by name.
            let viewer = FakeViewer(host: host, slices: FakeViewer.series(sliceCount: 3), current: 1)
            let line = viewer.draw(.line, [IsiXPixelPoint(x: 0, y: 0), IsiXPixelPoint(x: 4, y: 3)], slice: 1, name: "probe line")
            host.viewers = [viewer]
            guard let runtime = load(url, host: host, output: &output) else { break }
            runFirst(runtime, &output)
            output["renamedInViewer"] = viewer.stored.first { $0.id == line.id }?.name ?? "missing"
        case "VolumeCalculator":
            // Two viewers, as the user compares a lesion on two studies: a
            // length ROI, selected, on the image shown in each.
            let first = FakeViewer(host: host, columns: 64, rows: 64, slices: FakeViewer.series(sliceCount: 3, columns: 64, rows: 64), current: 1)
            let second = FakeViewer(host: host, columns: 64, rows: 64, slices: FakeViewer.series(sliceCount: 3, columns: 64, rows: 64), current: 2)
            first.draw(.line, [IsiXPixelPoint(x: 0, y: 0), IsiXPixelPoint(x: 40, y: 0)], slice: 1, name: "before", selected: true)
            second.draw(.line, [IsiXPixelPoint(x: 0, y: 0), IsiXPixelPoint(x: 40, y: 30)], slice: 2, name: "after", selected: true)
            host.viewers = [first, second]
            guard let runtime = load(url, host: host, output: &output) else { break }
            runFirst(runtime, &output)
            let controller = NSApp.windows.compactMap(\.windowController)
                .first { NSStringFromClass(type(of: $0)) == "ControllerVolumeCalculator" }
            output["window"] = controller?.window?.title ?? ""
            for key in ["diameter1", "diameter2", "volume1", "volume2"] {
                output[key] = (controller?.value(forKey: key) as? NSTextField)?.doubleValue ?? -1
            }
            for key in ["change", "changeTime"] {
                output[key] = (controller?.value(forKey: key) as? NSTextField)?.stringValue ?? ""
            }
            // Quitting, as the application does: the plugin is deactivated, then
            // the viewers close, and the plugin's window, still open, hears it.
            runtime.deactivate()
            NotificationCenter.default.post(name: Notification.Name("CloseViewerNotification"), object: nil)
            controller?.close()
        default:
            // The kit's probe, built with manual reference counting and with ARC.
            let viewer = FakeViewer(host: host, slices: FakeViewer.series(sliceCount: 3), current: 2)
            host.viewers = [viewer]
            guard let runtime = load(url, host: host, output: &output) else { break }
            runFirst(runtime, &output)
            output["commits"] = viewer.commits
            output["slice1Doubled"] = viewer.slices[1] == FakeViewer.series(sliceCount: 3)[1].map { $0 * 2 }
            output["othersUnchanged"] = viewer.slices[0] == FakeViewer.series(sliceCount: 3)[0] && viewer.slices[2] == FakeViewer.series(sliceCount: 3)[2]
            output["level"] = [viewer.level.center, viewer.level.width]
            output["roisLeft"] = viewer.stored.map(describe)
        }
        // Each kit class is named after the plugin in the runtime.
        output["kitClass"] = NSClassFromString("IsiXLegacy\(name)_ViewerController") != nil
        result[name] = output
    }
    result["unprefixedLegacyClasses"] = ["PluginFilter", "ViewerController", "DCMPix", "ROI", "DCMView", "MyPoint"]
        .filter { NSClassFromString($0) != nil }
    return result
}

let data = MainActor.assumeIsolated {
    try! JSONSerialization.data(withJSONObject: run(), options: [.prettyPrinted, .sortedKeys])
}
print(String(decoding: data, as: UTF8.self))
