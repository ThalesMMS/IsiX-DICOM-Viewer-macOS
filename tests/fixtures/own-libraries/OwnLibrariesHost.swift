//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A host for tests/test-plugin-own-libraries.py. It links ITK the way the
// application does (the application's static archive, compiled with default
// visibility into an executable that exports its symbols) and loads a plugin
// through the application's loading path: inspection by IsiXPluginLoading, the
// bundle load, entry resolution and activation by the kit's runtime. It prints
// one JSON object with what each side's copy of ITK held at each step.
//
//     OwnLibrariesHost <plugin.isixplugin> [<mangled symbol>...]

import AppKit
import Darwin
import MachO
@_spi(IsiXHost) import IsiXPluginKit
import IsiXPluginLoading

@MainActor
final class Host: IsiXHostBackend {
    func frontmostViewer() -> (any IsiXViewerBackend)? { nil }
    func openViewers() -> [any IsiXViewerBackend] { [] }
    func viewer(withID id: IsiXViewerID) -> (any IsiXViewerBackend)? { nil }
    func parentWindow(forViewer id: IsiXViewerID?) -> NSWindow? { nil }
    func selectedStudies() async throws -> [IsiXStudy] { throw IsiXPluginError.noDatabase }
    func study(withInstanceUID uid: String) async throws -> IsiXStudy? { throw IsiXPluginError.noDatabase }
    func series(inStudy studyInstanceUID: String) async throws -> [IsiXSeries] { throw IsiXPluginError.noDatabase }
    func importFiles(at urls: [URL]) async throws -> IsiXImportResult { throw IsiXPluginError.noDatabase }
    func commandsDidChange() {}
}

func json(_ text: UnsafePointer<CChar>) -> Any {
    (try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))) ?? String(cString: text)
}

func imageOf(_ address: UnsafeRawPointer?) -> String {
    var info = Dl_info()
    guard let address, dladdr(address, &info) != 0, let name = info.dli_fname else { return "" }
    return String(cString: name)
}

func isMapped(_ path: String) -> Bool {
    let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    return (0..<_dyld_image_count()).contains { index in
        _dyld_get_image_name(index).map { URL(fileURLWithPath: String(cString: $0)).resolvingSymlinksInPath().path == wanted } ?? false
    }
}

/// Where each symbol resolves in the whole process, and whether the plugin's
/// image exports it.
func lookups(_ symbols: [String], pluginExecutable: String?) -> [String: Any] {
    let handle = pluginExecutable.flatMap { dlopen($0, RTLD_NOW | RTLD_NOLOAD) }
    var result: [String: Any] = [:]
    for symbol in symbols {
        let name = symbol.hasPrefix("_") ? String(symbol.dropFirst()) : symbol
        result[symbol] = ["process": imageOf(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { UnsafeRawPointer($0) }),
                          "exportedByPlugin": handle.map { dlsym($0, name) != nil } ?? false]
    }
    return result
}

@MainActor
func run() -> [String: Any] {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let url = URL(fileURLWithPath: arguments[0])
    let symbols = Array(arguments.dropFirst())
    var result: [String: Any] = ["hostImage": URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path]

    // The host's ITK is in use, with its own settings, before the plugin loads.
    result["hostBefore"] = json(isix_host_probe_configure(3))
    result["lookupsBefore"] = lookups(symbols, pluginExecutable: nil)

    let inspection = PluginInspector().inspect(bundleAt: url)
    guard inspection.isLoadable, let manifest = inspection.manifest else {
        result["diagnostics"] = inspection.diagnostics.map { "\($0)" }
        let folder = url.appendingPathComponent("Contents/MacOS")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        result["mapped"] = files.contains { isMapped(folder.appendingPathComponent($0).path) }
        result["hostAfter"] = json(isix_host_probe_report())
        return result
    }
    let executable = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(manifest.executableName)
    result["pluginImage"] = executable.resolvingSymlinksInPath().path
    guard let bundle = Bundle(url: url) else { result["error"] = "no bundle"; return result }
    do {
        try bundle.loadAndReturnError()
        let type = try IsiXPluginRuntime.resolveEntry(named: manifest.principalClass, executableURL: executable)
        let info = IsiXPluginInfo(identifier: manifest.identifier, name: manifest.name, version: manifest.version, bundleURL: url,
                                  capabilities: Set(manifest.capabilities.map(IsiXCapability.init(rawValue:))))
        let runtime = IsiXPluginRuntime(info: info, bundle: bundle, entry: type, host: Host())
        try runtime.activate()
        result["state"] = "\(runtime.state)"
        // The plugin activated: it reported, then set its copy to 8 threads
        // and its own output window.
        result["hostAfterActivation"] = json(isix_host_probe_report())
        // The host changes its settings again; the plugin reports.
        result["hostReconfigured"] = json(isix_host_probe_configure(5))
        try runtime.run(commandID: "report")
        let reports = runtime.instance.map { String(describing: $0) } ?? ""
        result["plugin"] = (try? JSONSerialization.jsonObject(with: Data(reports.utf8))) ?? reports
        result["hostFinal"] = json(isix_host_probe_report())
        result["lookupsAfter"] = lookups(symbols, pluginExecutable: executable.path)
    } catch {
        result["error"] = "\(error)"
    }
    return result
}

let data = MainActor.assumeIsolated {
    try! JSONSerialization.data(withJSONObject: run(), options: [.prettyPrinted, .sortedKeys])
}
print(String(decoding: data, as: UTF8.self))
