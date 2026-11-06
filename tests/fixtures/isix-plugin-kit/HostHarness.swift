//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A host for tests/test-isix-plugin-kit.py: the application's loading path
// (inspection by IsiXPluginLoading, loading, entry resolution and the kit's
// runtime), with a synthetic viewer in place of the application's. It prints
// one JSON object with what happened; the test checks it.
//
//     HostHarness <example.isixplugin> <probe.isixplugin> <refused.isixplugin>...

import AppKit
import MachO
@_spi(IsiXHost) import IsiXPluginKit
import IsiXPluginLoading

@MainActor
final class FakeViewer: IsiXViewerBackend {
    let viewerID = IsiXViewerID(rawValue: UUID())
    var isOpen = true
    let columns = 8, rows = 6
    var slices: [[Float]]
    var tokens: [UInt64]
    var current = 2
    var stored: [IsiXROI] = []
    var redraws = 0
    let rowDirection = IsiXVector3(x: 0.6, y: 0.8, z: 0)
    let columnDirection = IsiXVector3(x: 0, y: 0, z: -1)

    init(sliceCount: Int = 4) {
        slices = (0..<sliceCount).map { s in
            (0..<6).flatMap { r in (0..<8).map { c in Float(s * 100 + r * 10 + c) } }
        }
        tokens = Array(repeating: 1, count: sliceCount)
    }

    func geometry(_ slice: Int) -> IsiXImageGeometry {
        let normal = rowDirection.cross(columnDirection)
        return IsiXImageGeometry(columns: columns, rows: rows, columnSpacing: 0.75, rowSpacing: 0.5,
                                 imagePosition: IsiXVector3(x: -10, y: 20, z: 30) + normal * (2.0 * Double(slice)),
                                 rowDirection: rowDirection, columnDirection: columnDirection,
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
        return IsiXImage(version: IsiXImageVersion(viewer: viewerID, slice: s, phase: 0, token: tokens[s]),
                         geometry: geometry(s),
                         attributes: IsiXImageAttributes(modality: "MR", seriesInstanceUID: "1.2.3.4", echoTime: 20),
                         pixels: .float32(try IsiXPixelBuffer(width: columns, height: rows, samples: slices[s])))
    }

    func windowLevel() throws -> IsiXWindowLevel { _ = try slice(nil, nil); return IsiXWindowLevel(center: 40, width: 400) }

    func setWindowLevel(_ windowLevel: IsiXWindowLevel) throws { _ = try slice(nil, nil) }

    func commit(_ pixels: IsiXPixelData, replacing version: IsiXImageVersion) throws {
        let s = try slice(version.slice, version.phase)
        guard version.viewer == viewerID, version.hostToken == tokens[s] else { throw IsiXPluginError.staleImage }
        guard case .float32(let buffer) = pixels else { throw IsiXPluginError.dimensionMismatch }
        slices[s] = buffer.samples
        tokens[s] += 1
        redraws += 1
    }

    func rois(slice value: Int?, phase: Int?) throws -> [IsiXROI] {
        let s = try slice(value, phase)
        return stored.filter { $0.slice == s }
    }

    func addROI(_ draft: IsiXROIDraft) throws -> IsiXROI {
        let s = try slice(draft.slice, draft.phase)
        let needed: Int
        switch draft.kind {
        case .point: needed = 1
        case .line, .rectangle, .oval: needed = 2
        default: throw IsiXPluginError.unsupportedROIKind(draft.kind)
        }
        guard draft.points.count == needed else { throw IsiXPluginError.invalidROI("points") }
        let g = geometry(s)
        let roi = IsiXROI(id: IsiXROIID(rawValue: UUID()), kind: draft.kind, name: draft.name ?? "", comment: "",
                          slice: s, phase: 0, points: draft.points, patientPoints: draft.points.map { g.patientPoint(of: $0) })
        stored.append(roi)
        return roi
    }

    func removeROI(_ id: IsiXROIID) throws {
        _ = try slice(nil, nil)
        guard stored.contains(where: { $0.id == id }) else { throw IsiXPluginError.roiNotFound }
        stored.removeAll { $0.id == id }
    }

    func statistics(of id: IsiXROIID) throws -> IsiXROIStatistics {
        _ = try slice(nil, nil)
        guard let roi = stored.first(where: { $0.id == id }), roi.kind == .rectangle else { throw IsiXPluginError.roiNotFound }
        let (a, b) = (roi.points[0], roi.points[1])
        var values: [Double] = []
        for r in 0..<rows where Double(r) >= min(a.y, b.y) && Double(r) <= max(a.y, b.y) {
            for c in 0..<columns where Double(c) >= min(a.x, b.x) && Double(c) <= max(a.x, b.x) {
                values.append(Double(slices[roi.slice][r * columns + c]))
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let deviation = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        let g = geometry(roi.slice)
        return IsiXROIStatistics(mean: mean, standardDeviation: deviation, minimum: values.min()!, maximum: values.max()!,
                                 sum: values.reduce(0, +),
                                 area: abs(b.x - a.x) * g.columnSpacing * abs(b.y - a.y) * g.rowSpacing, length: nil)
    }

    func setNeedsDisplay() { redraws += 1 }
}

@MainActor
final class FakeHost: IsiXHostBackend {
    var viewers: [FakeViewer] = []
    var commandChanges = 0

    func frontmostViewer() -> (any IsiXViewerBackend)? { viewers.first { $0.isOpen } }
    func openViewers() -> [any IsiXViewerBackend] { viewers.filter { $0.isOpen } }
    func viewer(withID id: IsiXViewerID) -> (any IsiXViewerBackend)? { viewers.first { $0.isOpen && $0.viewerID == id } }
    func parentWindow(forViewer id: IsiXViewerID?) -> NSWindow? { nil }
    func selectedStudies() async throws -> [IsiXStudy] { throw IsiXPluginError.noDatabase }
    func study(withInstanceUID uid: String) async throws -> IsiXStudy? { throw IsiXPluginError.noDatabase }
    func series(inStudy studyInstanceUID: String) async throws -> [IsiXSeries] { throw IsiXPluginError.noDatabase }
    func importFiles(at urls: [URL]) async throws -> IsiXImportResult { throw IsiXPluginError.noDatabase }
    func commandsDidChange() { commandChanges += 1 }
}

/// Whether dyld has mapped the file at `path` into this process.
func isMapped(_ path: String) -> Bool {
    let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    for index in 0..<_dyld_image_count() {
        if let name = _dyld_get_image_name(index),
           URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath().path == wanted {
            return true
        }
    }
    return false
}

/// Runs the main run loop until `done` or two seconds pass.
@MainActor
func spin(until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while !done() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

@MainActor
func describe(_ plugin: (any IsiXPlugin)?) -> String {
    plugin.map { String(describing: $0) } ?? ""
}

func message(_ error: any Error) -> String {
    if let error = error as? IsiXEntryError { return "entry: " + error.message }
    return "\(error)"
}

@MainActor
func load(_ url: URL, entry: String? = nil, host: FakeHost, output: inout [String: Any]) -> IsiXPluginRuntime? {
    let inspection = PluginInspector().inspect(bundleAt: url)
    guard inspection.isLoadable, let manifest = inspection.manifest else {
        output["diagnostics"] = inspection.diagnostics.map { "\($0)" }
        output["renamedLegacy"] = inspection.isRenamedLegacyPlugin
        return nil
    }
    let executable = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(manifest.executableName)
    guard let bundle = Bundle(url: url) else { output["error"] = "no bundle"; return nil }
    do {
        try bundle.loadAndReturnError()
        let type = try IsiXPluginRuntime.resolveEntry(named: entry ?? manifest.principalClass, executableURL: executable)
        let info = IsiXPluginInfo(identifier: manifest.identifier, name: manifest.name, version: manifest.version, bundleURL: url,
                                  capabilities: Set(manifest.capabilities.map(IsiXCapability.init(rawValue:))))
        let runtime = IsiXPluginRuntime(info: info, bundle: bundle, entry: type, host: host)
        do {
            try runtime.activate()
        } catch {
            output["activationError"] = message(error)
        }
        output["state"] = "\(runtime.state)"
        output["commands"] = runtime.commands.map { "\($0.id)|\($0.placement)|\($0.requirement)" }
        output["observations"] = runtime.observationCount
        return runtime
    } catch {
        output["error"] = message(error)
        return nil
    }
}

@MainActor
func run() -> [String: Any] {
    let arguments = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
    var result: [String: Any] = ["hostArchitecture": MachOImage.hostArchitecture]

    // The example: commands, viewer, pixels, geometry, ROIs, commit, events, closing, deactivation.
    let host = FakeHost()
    var example: [String: Any] = [:]
    if let runtime = load(arguments[0], host: host, output: &example) {
        let plugin = runtime.instance
        example["commandChanges"] = host.commandChanges
        example["canRunWithoutViewer"] = runtime.canRun(commandID: "inspect-image", frontmostViewerOpen: false)
        do { try runtime.run(commandID: "inspect-image") } catch { example["noViewerError"] = message(error) }
        let viewer = FakeViewer()
        host.viewers = [viewer]
        example["canRunWithViewer"] = runtime.canRun(commandID: "inspect-image", frontmostViewerOpen: true)
        var errors: [String] = []
        for command in ["inspect-image", "mark-centre", "negate-slice"] {
            do { try runtime.run(commandID: command) } catch { errors.append("\(command): \(message(error))") }
        }
        spin { describe(plugin).contains("pixels ") && runtime.runningTaskCount == 0 }
        example["commandErrors"] = errors
        example["roisStored"] = viewer.stored.map { "\($0.kind) \($0.points.map { "\($0.x),\($0.y)" }.joined(separator: " ")) \($0.name)" }
        example["negatedSlice"] = Array(viewer.slices[2].prefix(3))
        example["untouchedSlice"] = Array(viewer.slices[1].prefix(3))

        runtime.deliver(.sliceChanged(viewer.viewerID, IsiXSlicePosition(slice: 3, phase: 0)))
        runtime.deliver(.roiChanged(viewer.viewerID, viewer.stored[0].id, .added))

        // A handle and a snapshot kept across the viewer closing.
        let handle = IsiXViewer(backend: viewer, capabilities: [.viewerRead, .roi])
        let snapshot = try? handle.image()
        do { try handle.commit(snapshot!.pixels, replacing: snapshot!) } catch { example["undeclaredWrite"] = message(error) }
        runtime.deliver(.viewerWillClose(viewer.viewerID))
        viewer.isOpen = false
        var afterClose: [String] = []
        do { _ = try handle.image() } catch { afterClose.append(message(error)) }
        do { _ = try handle.rois() } catch { afterClose.append(message(error)) }
        let writer = IsiXViewer(backend: viewer, capabilities: [.viewerRead, .viewerWrite])
        do { try writer.commit(snapshot!.pixels, replacing: snapshot!) } catch { afterClose.append(message(error)) }
        handle.setNeedsDisplay()
        example["afterClose"] = afterClose
        example["snapshotAfterClose"] = snapshot?.scalarPixels?.samples.count ?? -1
        example["isOpenAfterClose"] = handle.isOpen
        example["canRunAfterClose"] = runtime.canRun(commandID: "inspect-image", frontmostViewerOpen: host.frontmostViewer() != nil)

        runtime.deactivate()
        runtime.deliver(.sliceChanged(viewer.viewerID, IsiXSlicePosition(slice: 1, phase: 0)))
        example["afterDeactivate"] = ["state": "\(runtime.state)", "commands": runtime.commands.count,
                                      "observations": runtime.observationCount, "tasks": runtime.runningTaskCount]
        do { try runtime.run(commandID: "inspect-image") } catch { example["runAfterDeactivate"] = message(error) }
        example["record"] = describe(plugin)
    }
    result["example"] = example

    // The probe bundle: one class per misbehaviour.
    var probe: [String: Any] = [:]
    for entry in ["ProbePlugins.ThrowingPlugin", "ProbePlugins.NotAPlugin", "NSObject", "ThrowingPlugin", "ProbePlugins.Missing"] {
        let probeHost = FakeHost()
        var output: [String: Any] = [:]
        _ = load(arguments[1], entry: entry, host: probeHost, output: &output)
        output["commandChanges"] = probeHost.commandChanges
        probe[entry] = output
    }
    let observerHost = FakeHost()
    let viewer = FakeViewer()
    observerHost.viewers = [viewer]
    var observer: [String: Any] = [:]
    if let runtime = load(arguments[1], entry: "ProbePlugins.ObserverPlugin", host: observerHost, output: &observer) {
        let plugin = runtime.instance
        runtime.deliver(.sliceChanged(viewer.viewerID, IsiXSlicePosition(slice: 1, phase: 0)))
        runtime.deliver(.sliceChanged(viewer.viewerID, IsiXSlicePosition(slice: 2, phase: 0)))
        observer["observationsAfterDrop"] = runtime.observationCount
        try? runtime.run(commandID: "invalidate")
        runtime.deliver(.roiChanged(viewer.viewerID, IsiXROIID(rawValue: UUID()), .modified))
        observer["observationsAfterInvalidate"] = runtime.observationCount
        observer["tasksBeforeDeactivate"] = runtime.runningTaskCount
        runtime.deactivate()
        spin { describe(plugin).contains("cancelled true") }
        observer["record"] = describe(plugin)
        observer["tasksAfterDeactivate"] = runtime.runningTaskCount
    }
    probe["observer"] = observer

    // Input and drawing: what the image view of a viewer gives the plugins.
    let interactionHost = FakeHost()
    let shown = FakeViewer()
    interactionHost.viewers = [shown]
    var interaction: [String: Any] = [:]
    if let runtime = load(arguments[1], entry: "ProbePlugins.InteractionPlugin", host: interactionHost, output: &interaction) {
        let plugin = runtime.instance
        func input(_ kind: IsiXViewerInput.Kind, _ x: Double, _ characters: String? = nil) -> Bool {
            runtime.handleInput(IsiXViewerInput(kind: kind, viewerID: shown.viewerID, position: IsiXSlicePosition(slice: 2, phase: 0),
                                                location: IsiXPixelPoint(x: x, y: 3), characters: characters))
        }
        interaction["inputKinds"] = runtime.inputKinds.rawValue
        interaction["taken"] = [input(.mouseDown, 1), input(.mouseDown, 6), input(.mouseDragged, 1), input(.keyDown, 0, "x"), input(.keyDown, 0, "y")]
        interaction["overlaysBefore"] = runtime.hasOverlays(on: shown.viewerID)
        try? runtime.run(commandID: "overlay")
        interaction["overlaysAfter"] = runtime.hasOverlays(on: shown.viewerID)
        interaction["redrawsForOverlay"] = shown.redraws
        // An 8 x 6 image drawn 4 device pixels a pixel, rows down, the centre of the first pixel at (0, 0).
        if let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 32 * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.translateBy(x: 0, y: 24)
            context.scaleBy(x: 4, y: -4)
            context.translateBy(x: 0.5, y: 0.5)
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            runtime.drawOverlays(IsiXOverlayContext(cgContext: context, viewerID: shown.viewerID,
                                                    position: IsiXSlicePosition(slice: 2, phase: 0), pointSize: 0.5))
            // Each overlay starts from a graphics state of its own, and leaves the host's as it was.
            context.fill(CGRect(x: 6.5, y: 4.5, width: 1, height: 1))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            interaction["greenPixels"] = (0..<6).flatMap { r in (0..<8).compactMap { c -> String? in
                bytes[((4 * r + 2) * 32 + 4 * c + 2) * 4 + 1] > 200 ? "\(c),\(r)" : nil } }
            interaction["bluePixels"] = (0..<6).flatMap { r in (0..<8).compactMap { c -> String? in
                bytes[((4 * r + 2) * 32 + 4 * c + 2) * 4 + 2] > 200 ? "\(c),\(r)" : nil } }
        }
        try? runtime.run(commandID: "drop")
        interaction["inputKindsAfterDrop"] = runtime.inputKinds.rawValue
        interaction["overlaysAfterDrop"] = runtime.hasOverlays(on: shown.viewerID)
        interaction["takenAfterDrop"] = input(.mouseDown, 1)
        try? runtime.run(commandID: "overlay")
        runtime.deactivate()
        interaction["overlaysAfterDeactivate"] = runtime.hasOverlays(on: shown.viewerID)
        interaction["takenAfterDeactivate"] = input(.mouseDown, 1)
        interaction["record"] = describe(plugin)
    }
    probe["interaction"] = interaction
    result["probe"] = probe

    // Bundles refused before loading: none of their code may be mapped.
    var refused: [String: Any] = [:]
    for url in arguments.dropFirst(2) {
        var output: [String: Any] = [:]
        let runtime = load(url, host: FakeHost(), output: &output)
        let executable = url.appendingPathComponent("Contents/MacOS")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: executable.path)) ?? []
        output["mapped"] = files.contains { isMapped(executable.appendingPathComponent($0).path) }
        output["loaded"] = runtime != nil
        refused[url.lastPathComponent] = output
    }
    result["refused"] = refused
    return result
}

let data = MainActor.assumeIsolated {
    try! JSONSerialization.data(withJSONObject: run(), options: [.prettyPrinted, .sortedKeys])
}
print(String(decoding: data, as: UTF8.self))
