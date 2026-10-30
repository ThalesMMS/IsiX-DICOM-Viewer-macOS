//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A host for tests/test-plugin-command-exceptions.py. It is compiled with the
// application's own boundary (Horos/Sources/IsiXPluginCommandGuard.swift and
// IsiXPluginExceptionGuard.mm) and runs commands of the probe plugins through
// it, as IsiXPluginHost does, with a synthetic host in place of the
// application's. It prints one JSON object with what happened.
//
//     ExceptionHarness <probe.isixplugin> <legacy.isixplugin>
//     ExceptionHarness --unguarded <probe.isixplugin> <command id>
//     ExceptionHarness --unguarded-activation <probe.isixplugin> <entry class>
//         runs one command, or an activation, without the boundary: the
//         negative controls.

import AppKit
@_spi(IsiXHost) import IsiXPluginKit
import IsiXPluginLoading

/// A viewer that is only open: the probe's viewer command reads nothing of it.
@MainActor
final class OpenViewer: IsiXViewerBackend {
    let viewerID = IsiXViewerID(rawValue: UUID())
    let isOpen = true
    private func none() -> IsiXPluginError { .hostFailure("synthetic viewer") }
    func seriesSummary() throws -> IsiXSeriesSummary { throw none() }
    func currentPosition() throws -> IsiXSlicePosition { throw none() }
    func setCurrentSlice(_ slice: Int) throws { throw none() }
    func image(slice: Int?, phase: Int?) throws -> IsiXImage { throw none() }
    func windowLevel() throws -> IsiXWindowLevel { throw none() }
    func setWindowLevel(_ windowLevel: IsiXWindowLevel) throws { throw none() }
    func commit(_ pixels: IsiXPixelData, replacing version: IsiXImageVersion) throws { throw none() }
    func rois(slice: Int?, phase: Int?) throws -> [IsiXROI] { throw none() }
    func addROI(_ draft: IsiXROIDraft) throws -> IsiXROI { throw none() }
    func removeROI(_ id: IsiXROIID) throws { throw none() }
    func statistics(of id: IsiXROIID) throws -> IsiXROIStatistics { throw none() }
    func setNeedsDisplay() {}
}

@MainActor
final class SyntheticHost: IsiXHostBackend {
    var viewers: [OpenViewer] = []
    func frontmostViewer() -> (any IsiXViewerBackend)? { viewers.first }
    func openViewers() -> [any IsiXViewerBackend] { viewers }
    func viewer(withID id: IsiXViewerID) -> (any IsiXViewerBackend)? { viewers.first { $0.viewerID == id } }
    func parentWindow(forViewer id: IsiXViewerID?) -> NSWindow? { nil }
    func selectedStudies() async throws -> [IsiXStudy] { throw IsiXPluginError.noDatabase }
    func study(withInstanceUID uid: String) async throws -> IsiXStudy? { throw IsiXPluginError.noDatabase }
    func series(inStudy studyInstanceUID: String) async throws -> [IsiXSeries] { throw IsiXPluginError.noDatabase }
    func importFiles(at urls: [URL]) async throws -> IsiXImportResult { throw IsiXPluginError.noDatabase }
    func commandsDidChange() {}
}

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

/// Inspects, loads and resolves the bundle, as IsiXPluginHost does, with
/// `entry` in place of its principal class when given; activates it unless
/// told not to.
@MainActor
func load(_ path: String, host: SyntheticHost, entry name: String? = nil, activate: Bool = true) -> IsiXPluginRuntime {
    let url = URL(fileURLWithPath: path)
    let inspection = PluginInspector().inspect(bundleAt: url)
    guard inspection.isLoadable, let manifest = inspection.manifest else { fail("\(path): \(inspection.diagnostics)") }
    guard let bundle = Bundle(url: url) else { fail("\(path): no bundle") }
    do {
        try bundle.loadAndReturnError()
        let executable = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(manifest.executableName)
        let entry = try IsiXPluginRuntime.resolveEntry(named: name ?? manifest.principalClass, executableURL: executable)
        let info = IsiXPluginInfo(identifier: manifest.identifier, name: manifest.name, version: manifest.version, bundleURL: url,
                                  capabilities: Set(manifest.capabilities.map(IsiXCapability.init(rawValue:))))
        let runtime = IsiXPluginRuntime(info: info, bundle: bundle, entry: entry, host: host)
        if activate { try runtime.activate() }
        return runtime
    } catch {
        fail("\(path): \(error)")
    }
}

/// "ran", "failed|<message>" or "raised|<kind>|<type>|<reason>".
func describe(_ outcome: IsiXCommandOutcome) -> String {
    switch outcome {
    case .ran: return "ran"
    case .failed(let error): return "failed|" + IsiXUserMessage(for: error)
    case .raised(let exception): return "raised|\(exception.kind.rawValue)|\(exception.type)|\(exception.reason)"
    }
}

@MainActor
func outcome(_ runtime: IsiXPluginRuntime, _ id: String) -> String {
    describe(runtime.runGuarded(commandID: id))
}

@MainActor
func run() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let host = SyntheticHost()
    if arguments.first == "--unguarded", arguments.count == 3 {
        let runtime = load(arguments[1], host: host)
        try? runtime.run(commandID: arguments[2])
        print("survived")
        return
    }
    if arguments.first == "--unguarded-activation", arguments.count == 3 {
        let runtime = load(arguments[1], host: host, entry: arguments[2], activate: false)
        try? runtime.activate()
        print("survived")
        return
    }
    guard arguments.count == 2 else { fail("usage: ExceptionHarness <probe.isixplugin> <legacy.isixplugin>") }
    var result: [String: Any] = [:]

    let probe = load(arguments[0], host: host)
    var probeOutcomes: [String: String] = [:]
    for id in ["raise-objc", "throw-cxx", "throw-int", "throw-swift", "return"] {
        probeOutcomes[id] = outcome(probe, id)
    }
    probeOutcomes["viewer-without"] = outcome(probe, "viewer")
    host.viewers = [OpenViewer()]
    probeOutcomes["viewer-with"] = outcome(probe, "viewer")
    // The same exception again, and a command after it: the plugin and the host go on.
    probeOutcomes["throw-cxx-again"] = outcome(probe, "throw-cxx")
    probeOutcomes["return-after"] = outcome(probe, "return")
    result["probe"] = ["outcomes": probeOutcomes, "state": "\(probe.state)",
                       "record": probe.instance.map { String(describing: $0) } ?? ""]

    host.viewers = []
    let legacy = load(arguments[1], host: host)
    var legacyOutcomes: [String: String] = [:]
    for (index, command) in legacy.commands.enumerated() {
        legacyOutcomes["\(index):\(command.title)"] = outcome(legacy, command.id)
    }
    legacyOutcomes["again:Return"] = legacy.commands.last.map { outcome(legacy, $0.id) } ?? "missing"
    result["legacy"] = ["outcomes": legacyOutcomes, "state": "\(legacy.state)"]

    // Activations that let an exception escape: refused, and nothing they
    // registered is left; the plugin loaded before still runs its commands.
    var activations: [String: Any] = [:]
    for entry in ["ExceptionProbe.RaisingActivationPlugin", "ExceptionProbe.ThrowingActivationPlugin"] {
        let runtime = load(arguments[0], host: host, entry: entry, activate: false)
        let result = describe(runtime.activateGuarded())
        activations[entry] = ["outcome": result, "state": "\(runtime.state)", "commands": runtime.commands.count,
                              "observations": runtime.observationCount, "tasks": runtime.runningTaskCount,
                              "instance": runtime.instance != nil, "runAfter": describe(runtime.runGuarded(commandID: "never"))]
    }
    activations["probeAfter"] = outcome(probe, "return")
    result["activations"] = activations

    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

@main
enum ExceptionHarness {
    @MainActor static func main() { run() }
}
