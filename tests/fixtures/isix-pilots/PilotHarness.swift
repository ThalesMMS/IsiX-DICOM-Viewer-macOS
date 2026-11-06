//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A host for tests/test-isix-pilot-plugins.py: the application's loading path
// (IsiXPluginLoading's inspection, the bundle load, entry resolution and the
// kit's runtime) with synthetic viewers and a synthetic database, built from
// the same formulas as the fixture generators. Each pilot runs its command;
// what it did is measured here, against the application's own T2 Fit Map and
// ROI Enhancement engines (compiled into this harness from the app's sources)
// or against an analytic reference, and printed as one JSON object.
//
//     PilotHarness <InvertData> <T2FitMap> <ROIEnhancement> <PointsToLine> <JPEGToDICOM> <work folder>

import AppKit
import ImageIO
import UniformTypeIdentifiers
@_spi(IsiXHost) import IsiXPluginKit
import IsiXPluginLoading

// MARK: synthetic viewer and host

@MainActor
final class FakeViewer: IsiXViewerBackend {
    struct Slot {
        var geometry: IsiXImageGeometry
        var attributes: IsiXImageAttributes
        var pixels: IsiXPixelData
        var token: UInt64 = 1
    }

    let viewerID = IsiXViewerID(rawValue: UUID())
    var isOpen = true
    /// [phase][slice]
    var slots: [[Slot]]
    var slice = 0
    var phase = 0
    var level = IsiXWindowLevel(center: 40, width: 400)
    var stored: [IsiXROI] = []
    var commits = 0
    /// Closes the viewer once this many commits were made: a user closing it mid-run.
    var closeAfterCommits: Int?
    weak var host: FakeHost?

    init(slots: [[Slot]]) {
        self.slots = slots
    }

    private func slot(_ s: Int?, _ p: Int?) throws -> (Int, Int) {
        guard isOpen else { throw IsiXPluginError.viewerClosed }
        let p = p ?? phase
        guard slots.indices.contains(p) else { throw IsiXPluginError.phaseOutOfRange(p) }
        let s = s ?? slice
        guard slots[p].indices.contains(s) else { throw IsiXPluginError.sliceOutOfRange(s) }
        return (s, p)
    }

    func seriesSummary() throws -> IsiXSeriesSummary {
        _ = try slot(nil, nil)
        return IsiXSeriesSummary(sliceCount: slots[0].count, phaseCount: slots.count, currentSlice: slice, currentPhase: phase,
                                 studyInstanceUID: "1.2.826.0.1.3680043.10.1188.1", seriesInstanceUID: "1.2.826.0.1.3680043.10.1188.2",
                                 seriesDescription: "Synthetic", modality: slots[0][0].attributes.modality)
    }

    func currentPosition() throws -> IsiXSlicePosition {
        _ = try slot(nil, nil)
        return IsiXSlicePosition(slice: slice, phase: phase)
    }

    func setCurrentSlice(_ value: Int) throws { slice = try slot(value, nil).0 }

    func image(slice s: Int?, phase p: Int?) throws -> IsiXImage {
        let (s, p) = try slot(s, p)
        let item = slots[p][s]
        return IsiXImage(version: IsiXImageVersion(viewer: viewerID, slice: s, phase: p, token: item.token),
                         geometry: item.geometry, attributes: item.attributes, pixels: item.pixels)
    }

    func windowLevel() throws -> IsiXWindowLevel { _ = try slot(nil, nil); return level }

    func setWindowLevel(_ windowLevel: IsiXWindowLevel) throws { _ = try slot(nil, nil); level = windowLevel }

    func commit(_ pixels: IsiXPixelData, replacing version: IsiXImageVersion) throws {
        let (s, p) = try slot(version.slice, version.phase)
        guard version.viewer == viewerID, version.hostToken == slots[p][s].token else { throw IsiXPluginError.staleImage }
        slots[p][s].pixels = pixels
        slots[p][s].token += 1
        commits += 1
        if let limit = closeAfterCommits, commits >= limit {
            isOpen = false
        }
    }

    func rois(slice s: Int?, phase p: Int?) throws -> [IsiXROI] {
        let (s, p) = try slot(s, p)
        return stored.filter { $0.slice == s && $0.phase == p }
    }

    func addROI(_ draft: IsiXROIDraft) throws -> IsiXROI {
        let (s, p) = try slot(draft.slice, draft.phase)
        let g = slots[p][s].geometry
        let roi = IsiXROI(id: IsiXROIID(rawValue: UUID()), kind: draft.kind, name: draft.name ?? "", comment: "",
                          slice: s, phase: p, points: draft.points, patientPoints: draft.points.map { g.patientPoint(of: $0) })
        stored.append(roi)
        return roi
    }

    func removeROI(_ id: IsiXROIID) throws {
        _ = try slot(nil, nil)
        stored.removeAll { $0.id == id }
    }

    /// Rectangles only: the pixels whose centres lie inside, edges included.
    private func measure(_ roi: IsiXROI, on item: Slot) throws -> IsiXROIStatistics {
        guard roi.kind == .rectangle, case .float32(let pixels) = item.pixels else { throw IsiXPluginError.unsupportedROIKind(roi.kind) }
        let (a, b) = (roi.points[0], roi.points[1])
        var values: [Double] = []
        for r in 0..<pixels.height where Double(r) >= min(a.y, b.y) && Double(r) <= max(a.y, b.y) {
            for c in 0..<pixels.width where Double(c) >= min(a.x, b.x) && Double(c) <= max(a.x, b.x) {
                values.append(Double(pixels[c, r]))
            }
        }
        guard !values.isEmpty else { throw IsiXPluginError.invalidROI("empty") }
        let mean = values.reduce(0, +) / Double(values.count)
        let deviation = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        let g = item.geometry
        return IsiXROIStatistics(mean: mean, standardDeviation: deviation, minimum: values.min()!, maximum: values.max()!,
                                 sum: values.reduce(0, +), area: abs(b.x - a.x) * g.columnSpacing * abs(b.y - a.y) * g.rowSpacing, length: nil)
    }

    func statistics(of id: IsiXROIID) throws -> IsiXROIStatistics {
        _ = try slot(nil, nil)
        guard let roi = stored.first(where: { $0.id == id }) else { throw IsiXPluginError.roiNotFound }
        return try measure(roi, on: slots[roi.phase][roi.slice])
    }

    func statistics(of id: IsiXROIID, slice s: Int, phase p: Int) throws -> IsiXROIStatistics {
        let (s, p) = try slot(s, p)
        guard let roi = stored.first(where: { $0.id == id }) else { throw IsiXPluginError.roiNotFound }
        return try measure(roi, on: slots[p][s])
    }

    func openDerivedSeries(_ series: IsiXDerivedSeries) throws -> any IsiXViewerBackend {
        var derived: [Slot] = []
        for image in series.images {
            let (s, p) = try slot(image.sourceSlice, image.sourcePhase)
            var item = slots[p][s]
            guard case .float32(let source) = item.pixels, source.width == image.pixels.width, source.height == image.pixels.height else {
                throw IsiXPluginError.dimensionMismatch
            }
            item.pixels = .float32(image.pixels)
            item.token = 1
            derived.append(item)
        }
        let viewer = FakeViewer(slots: [derived])
        viewer.host = host
        host?.viewers.append(viewer)
        return viewer
    }

    func setNeedsDisplay() {}

    /// Moves a ROI, as a drag in the viewer would.
    func move(_ id: IsiXROIID, to points: [IsiXPixelPoint]) {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
        let g = slots[stored[index].phase][stored[index].slice].geometry
        stored[index].points = points
        stored[index].patientPoints = points.map { g.patientPoint(of: $0) }
    }
}

@MainActor
final class FakeHost: IsiXHostBackend {
    var viewers: [FakeViewer] = []
    var selected: [IsiXStudy] = []
    var writes: [IsiXDerivedSeriesRequest] = []
    var written: [URL] = []
    var imported: [[URL]] = []
    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    func frontmostViewer() -> (any IsiXViewerBackend)? { viewers.first { $0.isOpen } }
    func openViewers() -> [any IsiXViewerBackend] { viewers.filter { $0.isOpen } }
    func viewer(withID id: IsiXViewerID) -> (any IsiXViewerBackend)? { viewers.first { $0.isOpen && $0.viewerID == id } }
    func parentWindow(forViewer id: IsiXViewerID?) -> NSWindow? { nil }
    func selectedStudies() async throws -> [IsiXStudy] { selected }
    func study(withInstanceUID uid: String) async throws -> IsiXStudy? { selected.first { $0.studyInstanceUID == uid } }
    func series(inStudy studyInstanceUID: String) async throws -> [IsiXSeries] { [] }

    func writeDerivedSeries(_ request: IsiXDerivedSeriesRequest) async throws -> [URL] {
        guard selected.contains(where: { $0.studyInstanceUID == request.studyInstanceUID }) else { throw IsiXPluginError.noDatabase }
        writes.append(request)
        let output = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return try request.images.indices.map { index in
            let url = output.appendingPathComponent("image-\(index + 1).dcm")
            try Data("synthetic".utf8).write(to: url)
            written.append(url)
            return url
        }
    }

    func importFiles(at urls: [URL]) async throws -> IsiXImportResult {
        imported.append(urls)
        return IsiXImportResult(importedFiles: urls, studyInstanceUIDs: selected.map(\.studyInstanceUID),
                                seriesInstanceUIDs: ["1.2.826.0.1.3680043.10.1188.\(imported.count + 10)"], failures: [])
    }

    func commandsDidChange() {}
}

// MARK: loading

@MainActor
func load(_ url: URL, host: FakeHost) throws -> IsiXPluginRuntime {
    let inspection = PluginInspector().inspect(bundleAt: url)
    guard inspection.isLoadable, let manifest = inspection.manifest else {
        throw IsiXPluginError.hostFailure("refused: " + inspection.summary)
    }
    guard let bundle = Bundle(url: url) else { throw IsiXPluginError.hostFailure("no bundle") }
    try bundle.loadAndReturnError()
    let executable = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(manifest.executableName)
    let type = try IsiXPluginRuntime.resolveEntry(named: manifest.principalClass, executableURL: executable)
    let info = IsiXPluginInfo(identifier: manifest.identifier, name: manifest.name, version: manifest.version, bundleURL: url,
                              capabilities: Set(manifest.capabilities.map(IsiXCapability.init(rawValue:))))
    let runtime = IsiXPluginRuntime(info: info, bundle: bundle, entry: type, host: host)
    try runtime.activate()
    return runtime
}

@MainActor
func journal(_ runtime: IsiXPluginRuntime) -> String {
    runtime.instance.map { String(describing: $0) } ?? ""
}

/// Runs the main run loop until `done` or `seconds` pass.
@MainActor
func spin(_ seconds: Double = 10, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

func axialGeometry(columns: Int, rows: Int, spacing: Double, z: Double) -> IsiXImageGeometry {
    IsiXImageGeometry(columns: columns, rows: rows, columnSpacing: spacing, rowSpacing: spacing,
                      imagePosition: IsiXVector3(x: 0, y: 0, z: z), rowDirection: IsiXVector3(x: 1, y: 0, z: 0),
                      columnDirection: IsiXVector3(x: 0, y: 1, z: 0), sliceThickness: 1, sliceInterval: 0, sliceLocation: z)
}

func floatPixels(_ width: Int, _ height: Int, _ value: (Int, Int) -> Float) -> IsiXPixelData {
    .float32(try! IsiXPixelBuffer(width: width, height: height, samples: (0..<height).flatMap { r in (0..<width).map { c in value(c, r) } }))
}

// MARK: Invert Data

@MainActor
func invertScenario(_ url: URL, folder: URL) -> [String: Any] {
    var out: [String: Any] = [:]
    let host = FakeHost(folder: folder)
    do {
        let runtime = try load(url, host: host)
        // 63 columns: the pixel count of a slice is not a multiple of 4.
        let (w, h) = (63, 63)
        let grey = FakeViewer(slots: [(0..<8).map { s in
            FakeViewer.Slot(geometry: axialGeometry(columns: w, rows: h, spacing: 0.7, z: Double(s)),
                            attributes: IsiXImageAttributes(modality: "CT"),
                            pixels: floatPixels(w, h) { c, r in Float((s * 37 + r * 11 + c * 3) % 4096 - 1024) + 0.25 })
        }])
        grey.host = host
        let original = grey.slots
        host.viewers = [grey]
        try runtime.run(commandID: "invert-data")
        var exact = true
        var compared = 0
        for (p, phase) in grey.slots.enumerated() {
            for (s, item) in phase.enumerated() {
                guard case .float32(let after) = item.pixels, case .float32(let before) = original[p][s].pixels else { exact = false; continue }
                for index in after.samples.indices {
                    if after.samples[index].bitPattern != (-before.samples[index]).bitPattern { exact = false }
                    compared += 1
                }
            }
        }
        out["greyExact"] = exact
        out["greySamples"] = compared
        out["greyLevel"] = [grey.level.center, grey.level.width]

        // Colour, two phases, odd width.
        let (cw, ch) = (5, 3)
        func rgba(_ seed: Int) -> IsiXPixelData {
            .rgba8(try! IsiXPixelBuffer(width: cw, height: ch, channels: 4,
                                        samples: (0..<(cw * ch * 4)).map { UInt8(($0 * 29 + seed * 7) % 256) }))
        }
        let colour = FakeViewer(slots: (0..<2).map { p in (0..<3).map { s in
            FakeViewer.Slot(geometry: axialGeometry(columns: cw, rows: ch, spacing: 1, z: Double(s)),
                            attributes: IsiXImageAttributes(modality: "XC"), pixels: rgba(p * 3 + s))
        } })
        colour.level = IsiXWindowLevel(center: 100, width: 200)
        let colourOriginal = colour.slots
        host.viewers = [colour]
        try runtime.run(commandID: "invert-data")
        var colourExact = true
        for (p, phase) in colour.slots.enumerated() {
            for (s, item) in phase.enumerated() {
                guard case .rgba8(let after) = item.pixels, case .rgba8(let before) = colourOriginal[p][s].pixels else { colourExact = false; continue }
                for index in after.samples.indices {
                    let expected = index % 4 == 3 ? before.samples[index] : 255 - before.samples[index]
                    if after.samples[index] != expected { colourExact = false }
                }
            }
        }
        out["colourExact"] = colourExact
        out["colourLevel"] = [colour.level.center, colour.level.width]

        // The user closes the viewer after the third image: the rest is refused, nothing is touched.
        let closing = FakeViewer(slots: [(0..<6).map { s in
            FakeViewer.Slot(geometry: axialGeometry(columns: 4, rows: 4, spacing: 1, z: Double(s)),
                            attributes: IsiXImageAttributes(modality: "CT"), pixels: floatPixels(4, 4) { c, r in Float(c + r) })
        }])
        closing.closeAfterCommits = 3
        host.viewers = [closing]
        do {
            try runtime.run(commandID: "invert-data")
            out["closedError"] = "none"
        } catch {
            out["closedError"] = "\(error)"
            out["closedMessage"] = IsiXUserMessage(for: error)
        }
        out["closedCommits"] = closing.commits
        out["journal"] = journal(runtime)
        runtime.deactivate()
    } catch {
        out["error"] = "\(error)"
    }
    return out
}

// MARK: T2 Fit Map

let echoTimes: [Double] = [10, 20, 40, 80]
let compartments: [Double] = [40, 80, 120, 200]

func t2Signal(row: Int, column: Int, size: Int, te: Double) -> Float {
    let t2 = compartments[(row < size / 2 ? 0 : 2) + (column < size / 2 ? 0 : 1)]
    return Float((1000 * exp(-te / t2)).rounded(.toNearestOrEven))
}

@MainActor
func t2Scenario(_ url: URL, folder: URL) -> [String: Any] {
    var out: [String: Any] = [:]
    let host = FakeHost(folder: folder)
    do {
        let runtime = try load(url, host: host)
        let size = 32
        // Four echoes at one image position, as tools/generate-t2-phantom-fixture.py writes them.
        let source = FakeViewer(slots: [echoTimes.map { te in
            FakeViewer.Slot(geometry: IsiXImageGeometry(columns: size, rows: size, columnSpacing: 1, rowSpacing: 1,
                                                        imagePosition: IsiXVector3(x: 0, y: 0, z: 0),
                                                        rowDirection: IsiXVector3(x: 1, y: 0, z: 0), columnDirection: IsiXVector3(x: 0, y: 1, z: 0),
                                                        sliceThickness: 5, sliceInterval: 0, sliceLocation: 0),
                            attributes: IsiXImageAttributes(modality: "MR", echoTime: te, repetitionTime: 2000),
                            pixels: floatPixels(size, size) { c, r in t2Signal(row: r, column: c, size: size, te: te) })
        }])
        source.host = host
        host.viewers = [source]
        try runtime.run(commandID: "t2-fit-map")
        spin { host.viewers.count == 2 || journal(runtime).contains("fit failed") }
        guard host.viewers.count == 2, case .float32(let map) = host.viewers[1].slots[0][0].pixels else {
            out["error"] = "no map viewer: " + journal(runtime)
            return out
        }
        // The application's own engine on the same echoes.
        let signals = source.slots[0].map { item -> [Float] in
            if case .float32(let buffer) = item.pixels { return buffer.samples }
            return []
        }
        let native = T2FitMap.fitSeries(signals: signals, echoTimesMilliseconds: echoTimes, width: size, height: size)
        out["nativeCode"] = native.code
        var maxDifference = 0.0
        var zerosMatch = true, capMatch = true
        for (plugin, reference) in zip(map.samples, native.t2Milliseconds) {
            maxDifference = max(maxDifference, abs(Double(plugin) - Double(reference)))
            if (plugin == 0) != (reference == 0) { zerosMatch = false }
            if (plugin >= 2000) != (reference >= 2000) { capMatch = false }
        }
        out["maxDifference"] = maxDifference
        out["zerosMatch"] = zerosMatch
        out["capMatch"] = capMatch
        out["mapImages"] = host.viewers[1].slots[0].count
        var means: [Double] = []
        for quadrant in 0..<4 {
            let rows = quadrant < 2 ? 0..<(size / 2) : (size / 2)..<size
            let columns = quadrant % 2 == 0 ? 0..<(size / 2) : (size / 2)..<size
            var sum = 0.0, count = 0.0
            for r in rows { for c in columns { sum += Double(map[c, r]); count += 1 } }
            means.append(sum / count)
        }
        out["compartmentMeans"] = means
        let derived = host.viewers[1].slots[0][0].geometry, first = source.slots[0][0].geometry
        out["geometryEqual"] = derived == first

        // Cancelled: the viewer closes while the fit runs; no map opens.
        let big = 256
        let second = FakeViewer(slots: [echoTimes.map { te in
            FakeViewer.Slot(geometry: axialGeometry(columns: big, rows: big, spacing: 1, z: 0),
                            attributes: IsiXImageAttributes(modality: "MR", echoTime: te),
                            pixels: floatPixels(big, big) { c, r in t2Signal(row: r, column: c, size: big, te: te) })
        }])
        second.host = host
        host.viewers = [second]
        try runtime.run(commandID: "t2-fit-map")
        runtime.deliver(.viewerWillClose(second.viewerID))
        second.isOpen = false
        spin(5) { runtime.runningTaskCount == 0 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        out["viewersAfterCancel"] = host.viewers.count
        out["tasksAfterCancel"] = runtime.runningTaskCount
        out["journal"] = journal(runtime)
        runtime.deactivate()
    } catch {
        out["error"] = "\(error)"
    }
    return out
}

// MARK: ROI Enhancement

let phaseSeconds: [Double] = [0, 2, 4, 6, 8, 10, 12, 14]
let vesselHU: [Float] = [40, 80, 150, 220, 200, 140, 90, 60]

@MainActor
func roiScenario(_ url: URL, folder: URL) -> [String: Any] {
    var out: [String: Any] = [:]
    let host = FakeHost(folder: folder)
    do {
        let runtime = try load(url, host: host)
        let size = 32
        let inner = (size / 4)..<(size / 4 + size / 2)
        let start = Date(timeIntervalSince1970: 1_789_473_600) // 2026-09-11 12:00:00 UTC
        let viewer = FakeViewer(slots: zip(phaseSeconds, vesselHU).map { seconds, hu in
            [FakeViewer.Slot(geometry: axialGeometry(columns: size, rows: size, spacing: 1, z: 0),
                             attributes: IsiXImageAttributes(modality: "CT", acquisitionDate: start.addingTimeInterval(seconds)),
                             pixels: floatPixels(size, size) { c, r in inner.contains(r) && inner.contains(c) ? hu : 0 })]
        })
        viewer.host = host
        host.viewers = [viewer]
        let roi = try viewer.addROI(IsiXROIDraft(kind: .rectangle, points: [IsiXPixelPoint(x: 8, y: 8), IsiXPixelPoint(x: 23, y: 23)],
                                                 name: "vessel", slice: 0, phase: 0))
        func phases() -> [ROIEnhancement.Phase] {
            zip(phaseSeconds, viewer.slots).map { seconds, slots in
                guard case .float32(let buffer) = slots[0].pixels else { return ROIEnhancement.Phase(timeSeconds: seconds, pixels: [], width: 0, height: 0) }
                return ROIEnhancement.Phase(timeSeconds: seconds, pixels: buffer.samples, width: size, height: size)
            }
        }
        try runtime.run(commandID: "roi-enhancement")
        let native = ROIEnhancement.curves(phases: phases(), regions: [ROIEnhancement.Region(name: "vessel", column: 8, row: 8, width: 16, height: 16)])
        out["first"] = compare(journal(runtime), marker: "computed vessel", native: native.curves.first)

        // The user drags the ROI half out of the vessel: the curve follows.
        viewer.move(roi.id, to: [IsiXPixelPoint(x: 4, y: 4), IsiXPixelPoint(x: 19, y: 19)])
        runtime.deliver(.roiChanged(viewer.viewerID, roi.id, .modified))
        runtime.deliver(.roiChanged(viewer.viewerID, roi.id, .modified))
        spin { journal(runtime).contains("recomputed vessel") }
        let moved = ROIEnhancement.curves(phases: phases(), regions: [ROIEnhancement.Region(name: "vessel", column: 4, row: 4, width: 16, height: 16)])
        out["moved"] = compare(journal(runtime), marker: "recomputed vessel", native: moved.curves.first)
        out["recomputations"] = journal(runtime).components(separatedBy: "recomputed vessel").count - 1

        // Closing the viewer ends the observation; later events reach nothing.
        let observationsBefore = runtime.observationCount
        runtime.deliver(.viewerWillClose(viewer.viewerID))
        viewer.isOpen = false
        let linesAtClose = journal(runtime).split(separator: "\n").count
        runtime.deliver(.roiChanged(viewer.viewerID, roi.id, .modified))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        out["observationsBeforeClose"] = observationsBefore
        out["observationsAfterClose"] = runtime.observationCount
        out["linesAfterClose"] = journal(runtime).split(separator: "\n").count - linesAtClose

        // A 3D series is refused with a reason.
        let flat = FakeViewer(slots: [[FakeViewer.Slot(geometry: axialGeometry(columns: 4, rows: 4, spacing: 1, z: 0),
                                                       attributes: IsiXImageAttributes(modality: "CT"), pixels: floatPixels(4, 4) { _, _ in 1 })]])
        host.viewers = [flat]
        do { try runtime.run(commandID: "roi-enhancement") } catch { out["flatMessage"] = IsiXUserMessage(for: error) }
        out["journal"] = journal(runtime)
        runtime.deactivate()
    } catch {
        out["error"] = "\(error)"
    }
    return out
}

/// The plugin's samples after `marker` in its journal, against the native curve.
func compare(_ journal: String, marker: String, native: ROIEnhancement.Curve?) -> [String: Any] {
    guard let line = journal.split(separator: "\n").last(where: { $0.contains(marker) }), let native else { return ["missing": true] }
    let samples = line.split(separator: " ").compactMap { field -> [Double]? in
        let parts = field.split(separator: ":")
        guard parts.count == 2, let time = Double(parts[0]) else { return nil }
        let values = parts[1].split(separator: "/").compactMap { Double($0) }
        return values.count == 3 ? [time] + values : nil
    }
    var maxMean = 0.0, maxTime = 0.0, maxMinMax = 0.0
    for (sample, reference) in zip(samples, native.samples) {
        maxTime = max(maxTime, abs(sample[0] - reference.timeSeconds))
        maxMean = max(maxMean, abs(sample[2] - reference.mean))
        maxMinMax = max(maxMinMax, abs(sample[1] - reference.min), abs(sample[3] - reference.max))
    }
    return ["samples": samples.count, "nativeSamples": native.samples.count, "maxMeanDifference": maxMean,
            "maxTimeDifference": maxTime, "maxMinMaxDifference": maxMinMax, "means": samples.map { $0[2] }]
}

// MARK: PointsToLine

@MainActor
func pointsScenario(_ url: URL, folder: URL, oblique: Bool) -> [String: Any] {
    var out: [String: Any] = [:]
    let host = FakeHost(folder: folder)
    do {
        let runtime = try load(url, host: host)
        let (size, spacing, interval, count) = (64, 0.5, 2.0, 16)
        let angle = oblique ? 30.0 * Double.pi / 180 : 0
        let row = IsiXVector3(x: 1, y: 0, z: 0)
        let column = IsiXVector3(x: 0, y: cos(angle), z: sin(angle))
        let normal = row.cross(column)
        let viewer = FakeViewer(slots: [(0..<count).map { s in
            FakeViewer.Slot(geometry: IsiXImageGeometry(columns: size, rows: size, columnSpacing: spacing, rowSpacing: spacing,
                                                        imagePosition: IsiXVector3(x: -3, y: 4, z: 5) + normal * (interval * Double(s)),
                                                        rowDirection: row, columnDirection: column, sliceThickness: interval,
                                                        sliceInterval: interval, sliceLocation: interval * Double(s)),
                            attributes: IsiXImageAttributes(modality: "CT"), pixels: floatPixels(size, size) { _, _ in 0 })
        }])
        viewer.host = host
        host.viewers = [viewer]
        let first = try viewer.addROI(IsiXROIDraft(kind: .point, points: [IsiXPixelPoint(x: 10.3, y: 20.7)], slice: 2, phase: 0))
        let second = try viewer.addROI(IsiXROIDraft(kind: .point, points: [IsiXPixelPoint(x: 50.2, y: 40.9)], slice: 13, phase: 0))
        try runtime.run(commandID: "points-to-line")
        let a = first.patientPoints[0], b = second.patientPoints[0]
        let distance = (a - b).length
        let direction = (a - b) * (1 / distance)
        let generated = viewer.stored.filter { $0.name == "generated" }
        out["expectedCount"] = Int(distance.rounded(.down))
        out["count"] = generated.count
        var worstInPlane = 0.0, worstPlane = 0.0, worstRoundTrip = 0.0
        for (index, roi) in generated.enumerated() {
            let target = b + direction * Double(index + 1)
            let g = viewer.slots[0][roi.slice].geometry
            let plane = g.distanceFromPlane(target)
            let projection = target - g.normal * plane
            worstPlane = max(worstPlane, abs(plane))
            worstInPlane = max(worstInPlane, (g.patientPoint(of: roi.points[0]) - projection).length)
            let back = g.pixelPoint(of: g.patientPoint(of: roi.points[0]))
            worstRoundTrip = max(worstRoundTrip, abs(back.x - roi.points[0].x), abs(back.y - roi.points[0].y))
        }
        out["worstInPlane"] = worstInPlane
        out["worstPlaneDistance"] = worstPlane
        out["halfInterval"] = interval / 2
        out["worstRoundTrip"] = worstRoundTrip
        out["tolerance"] = 0.5 * spacing
        // Running again uses the same two points: the generated ones are not inputs.
        try runtime.run(commandID: "points-to-line")
        out["countAfterSecondRun"] = viewer.stored.filter { $0.name == "generated" }.count
        out["journal"] = journal(runtime)
        runtime.deactivate()
    } catch {
        out["error"] = "\(error)"
    }
    return out
}

// MARK: JPEG to DICOM

/// The raster fixture's picture (tools/generate-raster-import-fixture.py):
/// red rising left to right, green top to bottom, blue 64, a white 6x6
/// square at the top left, a black column at x = 61.
func rasterPicture(width: Int = 64, height: Int = 48) -> [UInt8] {
    var samples = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            samples[i] = UInt8(x * 255 / (width - 1))
            samples[i + 1] = UInt8(y * 255 / (height - 1))
            samples[i + 2] = 64
            if x < 6 && y < 6 { samples[i] = 255; samples[i + 1] = 255; samples[i + 2] = 255 }
            if x == 61 { samples[i] = 0; samples[i + 1] = 0; samples[i + 2] = 0 }
        }
    }
    return samples
}

func writeImage(_ samples: [UInt8], width: Int, height: Int, to url: URL, type: UTType) {
    var copy = samples
    let image = copy.withUnsafeMutableBytes { bytes -> CGImage in
        let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    CGImageDestinationFinalize(destination)
}

/// The file's own samples, read by NSBitmapImageRep without colour
/// conversion: the reference a decoded image is compared with.
func referenceSamples(_ url: URL) -> [UInt8] {
    guard let rep = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()) else { return [] }
    var result: [UInt8] = []
    var pixel = [Int](repeating: 0, count: 5)
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            rep.getPixel(&pixel, atX: x, y: y)
            result += [UInt8(pixel[0]), UInt8(pixel[1]), UInt8(pixel[2]), 255]
        }
    }
    return result
}

@MainActor
func jpegScenario(_ url: URL, folder: URL) -> [String: Any] {
    var out: [String: Any] = [:]
    let host = FakeHost(folder: folder.appendingPathComponent("written"))
    do {
        let runtime = try load(url, host: host)
        guard let plugin = runtime.instance as? NSObject else { throw IsiXPluginError.hostFailure("not an NSObject") }
        let inputs = folder.appendingPathComponent("inputs")
        let series = inputs.appendingPathComponent("Holiday pictures")
        try FileManager.default.createDirectory(at: series, withIntermediateDirectories: true)
        let picture = rasterPicture()
        writeImage(picture, width: 64, height: 48, to: inputs.appendingPathComponent("loose.png"), type: .png)
        writeImage(picture, width: 64, height: 48, to: series.appendingPathComponent("b.jpg"), type: .jpeg)
        writeImage(picture, width: 64, height: 48, to: series.appendingPathComponent("a.tiff"), type: .tiff)
        let convert = NSSelectorFromString("convertFilesAtPaths:")

        // No study selected: nothing is written.
        _ = plugin.perform(convert, with: [inputs.appendingPathComponent("loose.png").path])
        spin { journal(runtime).contains("failed") }
        out["withoutSelection"] = host.writes.count

        host.selected = [IsiXStudy(studyInstanceUID: "1.2.826.0.1.3680043.10.1188.7", patientID: "RASTER", patientName: "RASTER^IMPORT",
                                   studyDescription: "raster", studyDate: nil, modalities: ["OT"], seriesCount: 1)]
        _ = plugin.perform(convert, with: [inputs.appendingPathComponent("loose.png").path, series.path])
        spin { journal(runtime).components(separatedBy: "imported into").count - 1 == 2 || journal(runtime).components(separatedBy: "failed").count > 2 }
        out["series"] = host.writes.map { ["study": $0.studyInstanceUID, "description": $0.seriesDescription, "images": $0.images.count] as [String: Any] }
        var checks: [[String: Any]] = []
        // In conversion order: the loose file, then the folder's files by name.
        var files = [inputs.appendingPathComponent("loose.png"), series.appendingPathComponent("a.tiff"), series.appendingPathComponent("b.jpg")]
        for request in host.writes {
            for image in request.images {
                guard case .rgba8(let buffer) = image, !files.isEmpty else { continue }
                let reference = referenceSamples(files.removeFirst())
                guard reference.count == buffer.samples.count else {
                    checks.append(["series": request.seriesDescription, "referenceSamples": reference.count])
                    continue
                }
                var total = 0, worst = 0
                var pictureWorst = 0
                for index in buffer.samples.indices where index % 4 != 3 {
                    pictureWorst = max(pictureWorst, abs(Int(buffer.samples[index]) - Int(picture[index])))
                    let difference = abs(Int(buffer.samples[index]) - Int(reference[index]))
                    total += difference
                    worst = max(worst, difference)
                }
                let opaque = stride(from: 3, to: buffer.samples.count, by: 4).allSatisfy { buffer.samples[$0] == 255 }
                checks.append(["series": request.seriesDescription, "width": buffer.width, "height": buffer.height,
                               "maxErrorFromPicture": pictureWorst,
                               "meanError": Double(total) / Double(buffer.width * buffer.height * 3), "maxError": worst,
                               "topLeftWhite": buffer[0, 0, 0] > 240 && buffer[0, 0, 1] > 240 && buffer[0, 0, 2] > 240,
                               "bottomLeftDark": buffer[0, 47, 0] < 16, "opaque": opaque])
            }
        }
        out["images"] = checks
        out["importedBatches"] = host.imported.map(\.count)
        out["temporaryFilesLeft"] = host.written.filter { FileManager.default.fileExists(atPath: $0.path) }.count
        out["journal"] = journal(runtime)
        runtime.deactivate()
    } catch {
        out["error"] = "\(error)"
    }
    return out
}

// MARK: main

@MainActor
func run() -> [String: Any] {
    let arguments = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
    let work = arguments[5]
    return [
        "hostArchitecture": MachOImage.hostArchitecture,
        "InvertData": invertScenario(arguments[0], folder: work),
        "T2FitMap": t2Scenario(arguments[1], folder: work),
        "ROIEnhancement": roiScenario(arguments[2], folder: work),
        "PointsToLine": ["axial": pointsScenario(arguments[3], folder: work, oblique: false),
                         "oblique": pointsScenario(arguments[3], folder: work, oblique: true)],
        "JPEGToDICOM": jpegScenario(arguments[4], folder: work.appendingPathComponent("jpeg")),
    ]
}

let data = MainActor.assumeIsolated {
    try! JSONSerialization.data(withJSONObject: run(), options: [.prettyPrinted, .sortedKeys])
}
print(String(decoding: data, as: UTF8.self))
