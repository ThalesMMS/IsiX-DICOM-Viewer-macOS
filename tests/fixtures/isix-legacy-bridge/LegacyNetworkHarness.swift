//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A host for tests/test-isix-legacy-network.py: the application's loading
// path (IsiXPluginLoading and the kit's runtime) with a synthetic database,
// viewer and network, running legacy network and integration plugins ported
// with IsiXLegacyBridge. The network takes only the nodes of a synthetic
// Locations, by the application's own rules (IsiXDICOMNetwork's
// PluginNetworkAccess and PluginQueryKeys), and records each send and C-FIND
// instead of opening an association. It delivers the events of an import, a
// viewer and its ROIs, posts the application's own notifications with an
// object of the application's kind (which must never reach a plugin), calls
// an XML-RPC method, and prints one JSON object; the test checks it.
//
//     LegacyNetworkHarness <scratch folder> <plugin.isixplugin>...
//
// Plugins are recognised by their bundle name: Exec, XploreReports, SSH and
// NetworkProbe* (the test's own probe).

import AppKit
@_spi(IsiXHost) import IsiXPluginKit
import IsiXPluginLoading
import IsiXDICOMNetwork

let studyUID = "1.2.826.0.1.3680043.9.1546.1"
let seriesUID = "1.2.826.0.1.3680043.9.1546.1.1"
func sopUID(_ index: Int) -> String { "1.2.826.0.1.3680043.9.1546.1.1.\(index + 1)" }

/// A Part 10 file in explicit VR little endian with the attributes Exec reads.
func writeDICOM(_ url: URL, sop: String, instance: Int) throws {
    var data = Data(count: 128)
    data.append(Data("DICM".utf8))
    func element(_ group: UInt16, _ element: UInt16, _ vr: String, _ value: String) -> Data {
        var bytes = Data(value.utf8)
        if bytes.count % 2 == 1 { bytes.append(vr == "UI" ? 0 : 0x20) }
        var out = Data()
        for v in [group, element] { out.append(UInt8(v & 0xff)); out.append(UInt8(v >> 8)) }
        out.append(Data(vr.utf8))
        out.append(UInt8(bytes.count & 0xff)); out.append(UInt8(bytes.count >> 8))
        return out + bytes
    }
    var meta = element(0x0002, 0x0002, "UI", "1.2.840.10008.5.1.4.1.1.7") + element(0x0002, 0x0003, "UI", sop)
        + element(0x0002, 0x0010, "UI", "1.2.840.10008.1.2.1")
    var length = Data([0x02, 0x00, 0x00, 0x00]) + Data("UL".utf8) + Data([0x04, 0x00])
    length.append(contentsOf: withUnsafeBytes(of: UInt32(meta.count).littleEndian, Array.init))
    meta = length + meta
    data += meta
    data += element(0x0008, 0x0016, "UI", "1.2.840.10008.5.1.4.1.1.7") + element(0x0008, 0x0018, "UI", sop)
        + element(0x0008, 0x0060, "CS", "OT") + element(0x0010, 0x0010, "PN", "NET^PROBE") + element(0x0010, 0x0020, "LO", "NET-1")
        + element(0x0010, 0x0030, "DA", "19700101") + element(0x0020, 0x000D, "UI", studyUID) + element(0x0020, 0x000E, "UI", seriesUID)
        + element(0x0020, 0x0013, "IS", "\(instance)")
    try data.write(to: url)
}

// MARK: the synthetic application

@MainActor
final class FakeViewer: IsiXViewerBackend {
    let viewerID = IsiXViewerID(rawValue: UUID())
    var isOpen = true
    let columns = 4, rows = 4, sliceCount = 2
    var current = 0
    let roi = IsiXROI(id: IsiXROIID(rawValue: UUID()), kind: .rectangle, name: "Host ROI", comment: "", slice: 0, phase: 0,
                      points: [IsiXPixelPoint(x: 0.5, y: 0.5), IsiXPixelPoint(x: 2.5, y: 0.5), IsiXPixelPoint(x: 2.5, y: 2.5),
                               IsiXPixelPoint(x: 0.5, y: 2.5)], patientPoints: [])

    func slice(_ value: Int?) throws -> Int {
        let s = value ?? current
        guard (0..<sliceCount).contains(s) else { throw IsiXPluginError.sliceOutOfRange(s) }
        return s
    }

    func seriesSummary() throws -> IsiXSeriesSummary {
        IsiXSeriesSummary(sliceCount: sliceCount, phaseCount: 1, currentSlice: current, currentPhase: 0,
                          studyInstanceUID: studyUID, seriesInstanceUID: seriesUID, seriesDescription: "Network series", modality: "OT")
    }

    func currentPosition() throws -> IsiXSlicePosition { IsiXSlicePosition(slice: current, phase: 0) }
    func setCurrentSlice(_ slice: Int) throws { current = try self.slice(slice) }

    func geometry(slice value: Int?, phase: Int?) throws -> IsiXImageGeometry {
        let s = try slice(value)
        return IsiXImageGeometry(columns: columns, rows: rows, columnSpacing: 1, rowSpacing: 1,
                                 imagePosition: IsiXVector3(x: 0, y: 0, z: Double(s)),
                                 rowDirection: IsiXVector3(x: 1, y: 0, z: 0), columnDirection: IsiXVector3(x: 0, y: 1, z: 0),
                                 sliceThickness: 1, sliceInterval: 1, sliceLocation: Double(s))
    }

    func attributes(slice value: Int?, phase: Int?) throws -> IsiXImageAttributes {
        IsiXImageAttributes(modality: "OT", studyInstanceUID: studyUID, seriesInstanceUID: seriesUID, sopInstanceUID: sopUID(try slice(value)))
    }

    func image(slice value: Int?, phase: Int?) throws -> IsiXImage {
        let s = try slice(value)
        return IsiXImage(version: IsiXImageVersion(viewer: viewerID, slice: s, phase: 0, token: 1),
                         geometry: try geometry(slice: s, phase: 0), attributes: try attributes(slice: s, phase: 0),
                         pixels: .float32(try IsiXPixelBuffer(width: columns, height: rows, samples: [Float](repeating: 1, count: 16))))
    }

    func windowLevel() throws -> IsiXWindowLevel { IsiXWindowLevel(center: 40, width: 400) }
    func setWindowLevel(_ windowLevel: IsiXWindowLevel) throws {}
    func commit(_ pixels: IsiXPixelData, replacing version: IsiXImageVersion) throws {}
    func rois(slice: Int?, phase: Int?) throws -> [IsiXROI] { try self.slice(slice) == 0 ? [roi] : [] }
    func addROI(_ draft: IsiXROIDraft) throws -> IsiXROI { throw IsiXPluginError.unsupportedROIKind(draft.kind) }
    func removeROI(_ id: IsiXROIID) throws {}
    func statistics(of id: IsiXROIID) throws -> IsiXROIStatistics { throw IsiXPluginError.roiNotFound }
    func setNeedsDisplay() {}
}

/// What the synthetic network was asked, from any thread.
final class NetworkLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

@MainActor
final class FakeHost: IsiXHostBackend, IsiXDatabaseBackend, IsiXNetworkBackend, IsiXXMLRPCBackend {
    var viewers: [FakeViewer] = []
    var study: IsiXStudy
    var images: [IsiXDatabaseImage] = []
    var runtimes: [IsiXPluginRuntime] = []
    nonisolated let log = NetworkLog()
    /// Locations: a node with Send and Query/Retrieve, one with Send only, and one turned off.
    nonisolated(unsafe) let servers: [Any] = [
        ["AETitle": "LOCALPACS", "Address": "127.0.0.1", "Port": 11112, "Description": "Local test PACS", "Send": true, "QR": true],
        ["AETitle": "SENDONLY", "Address": "localhost", "Port": 11113, "Send": true, "QR": false],
        ["AETitle": "OFFNODE", "Address": "127.0.0.1", "Port": 11114, "Activated": false],
    ]

    init(folder: URL) throws {
        study = IsiXStudy(studyInstanceUID: studyUID, patientID: "NET-1", patientName: "NET^PROBE", studyDescription: "Network study",
                          studyDate: nil, modalities: ["OT"], seriesCount: 1)
        for index in 0..<2 {
            let file = folder.appendingPathComponent("image-\(index).dcm")
            try writeDICOM(file, sop: sopUID(index), instance: index + 1)
            images.append(IsiXDatabaseImage(sopInstanceUID: sopUID(index), seriesInstanceUID: seriesUID, studyInstanceUID: studyUID,
                                            instanceNumber: index + 1, frame: 0, numberOfFrames: 1, file: file, modality: "OT",
                                            columns: 4, rows: 4, sliceLocation: Double(index), isKeyImage: false, comments: [], date: nil))
        }
    }

    func frontmostViewer() -> (any IsiXViewerBackend)? { viewers.first { $0.isOpen } }
    func openViewers() -> [any IsiXViewerBackend] { viewers.filter(\.isOpen) }
    func viewer(withID id: IsiXViewerID) -> (any IsiXViewerBackend)? { viewers.first { $0.viewerID == id && $0.isOpen } }
    func parentWindow(forViewer id: IsiXViewerID?) -> NSWindow? { nil }
    func commandsDidChange() {}
    func selectedStudies() async throws -> [IsiXStudy] { [study] }
    func study(withInstanceUID uid: String) async throws -> IsiXStudy? { uid == studyUID ? study : nil }
    func series(inStudy uid: String) async throws -> [IsiXSeries] { try seriesRecords(inStudy: uid) }
    func importFiles(at urls: [URL]) async throws -> IsiXImportResult { throw IsiXPluginError.hostFailure("no import here") }

    // MARK: database

    var seriesRecord: IsiXSeries {
        IsiXSeries(seriesInstanceUID: seriesUID, studyInstanceUID: studyUID, seriesDescription: "Network series", modality: "OT",
                   seriesNumber: 1, imageCount: images.count)
    }

    func databaseSelection() throws -> IsiXDatabaseSelection { IsiXDatabaseSelection(studies: [study], series: []) }
    func studies(matching query: IsiXStudyQuery) throws -> [IsiXStudy] {
        query.studyInstanceUID.map { $0 == studyUID } ?? true ? [study] : []
    }
    func seriesRecords(inStudy uid: String) throws -> [IsiXSeries] { uid == studyUID ? [seriesRecord] : [] }
    func seriesRecord(withInstanceUID uid: String) throws -> IsiXSeries? { uid == seriesUID ? seriesRecord : nil }
    func images(inSeries uid: String) throws -> [IsiXDatabaseImage] { uid == seriesUID ? images : [] }
    func images(withSOPInstanceUID uid: String) throws -> [IsiXDatabaseImage] { images.filter { $0.sopInstanceUID == uid } }
    func updateStudy(_ uid: String, _ update: IsiXStudyUpdate) throws -> IsiXStudy {
        guard uid == studyUID else { throw IsiXPluginError.notFound("study \(uid)") }
        if let report = update.report { study.report = report.isEmpty ? nil : report }
        return study
    }
    func updateSeries(_ uid: String, _ update: IsiXSeriesUpdate) throws -> IsiXSeries { throw IsiXPluginError.notFound("series") }
    func updateImage(_ uid: String, frame: Int, _ update: IsiXImageUpdate) throws -> IsiXDatabaseImage { throw IsiXPluginError.notFound("image") }
    func albums() throws -> [IsiXAlbum] { [] }
    func studies(inAlbum name: String) throws -> [IsiXStudy] { [] }
    func createAlbum(named name: String) throws -> IsiXAlbum { throw IsiXPluginError.hostFailure("no albums") }
    func addStudies(_ uids: [String], toAlbum name: String) throws {}
    func removeStudies(_ uids: [String], fromAlbum name: String) throws {}
    func importFilesNow(at urls: [URL]) throws -> IsiXImportResult { throw IsiXPluginError.hostFailure("no import here") }
    func writeDerivedSeriesNow(_ request: IsiXDerivedSeriesRequest) throws -> [URL] { [] }
    func openViewer(forSeries uid: String) throws -> (any IsiXViewerBackend)? { nil }

    // MARK: network, by the application's rules

    nonisolated func networkNodes() throws -> [IsiXDICOMNode] {
        PluginNetworkAccess.nodes(fromServers: servers).map {
            IsiXDICOMNode(id: $0.identifier, name: $0.name, aeTitle: $0.aeTitle, host: $0.host, port: $0.port, usesTLS: $0.usesTLS,
                          acceptsSend: $0.sends, acceptsQuery: $0.queries)
        }
    }

    nonisolated func send(_ request: IsiXSendRequest, toNode id: String) throws -> IsiXSendResult {
        guard PluginNetworkAccess.entry(withIdentifier: id, for: .send, inServers: servers) != nil else {
            log.add("refused send:\(id)")
            throw IsiXPluginError.nodeNotConfigured(id)
        }
        log.add("send:\(id):files=\(request.files.count):sops=\(request.sopInstanceUIDs.count)")
        return IsiXSendResult(sent: request.files.count + request.sopInstanceUIDs.count, failed: 0, failureReason: nil)
    }

    nonisolated func find(_ query: IsiXNetworkQuery, onNode id: String) throws -> [IsiXQueryMatch] {
        guard PluginNetworkAccess.entry(withIdentifier: id, for: .query, inServers: servers) != nil else {
            log.add("refused find:\(id)")
            throw IsiXPluginError.nodeNotConfigured(id)
        }
        let level = PluginQueryKeys.Level(rawValue: query.level.rawValue) ?? .study
        let keys = try PluginQueryKeys.identifier(level: level, filters: .init(patientName: query.patientName, studyInstanceUID: query.studyInstanceUID))
        log.add("find:\(id):\(query.level.rawValue):" + keys.filter { !$0.value.isEmpty }.map { "\($0.keyword)=\($0.value)" }.joined(separator: ","))
        switch query.level {
        case .study:
            return [IsiXQueryMatch(level: .study, values: ["PatientName": "NET^PROBE", "StudyInstanceUID": studyUID, "ModalitiesInStudy": "OT",
                                                           "StudyDate": "20261029", "StudyDescription": "Network study"])]
        case .series:
            return [IsiXQueryMatch(level: .series, values: ["SeriesInstanceUID": seriesUID, "Modality": "OT", "SeriesDescription": "Network series",
                                                            "NumberOfSeriesRelatedInstances": "2", "StudyInstanceUID": studyUID])]
        default:
            return []
        }
    }

    // MARK: XML-RPC

    func xmlRPCMethodNameIsAvailable(_ name: String) -> Bool {
        // Some of the application's own methods.
        guard !["DisplayStudy", "DisplaySeries", "OpenDB", "CloseAllWindows"].contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return false }
        return !runtimes.contains { $0.xmlRPCMethodNames.contains(name) }
    }

    func deliver(_ event: IsiXEvent) {
        for runtime in runtimes { runtime.deliver(event) }
    }
}

// MARK: running plugins

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
    output["capabilities"] = manifest.capabilities.sorted()
    let executable = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(manifest.executableName)
    guard let bundle = Bundle(url: url) else { output["error"] = "no bundle"; return nil }
    do {
        try bundle.loadAndReturnError()
        let type = try IsiXPluginRuntime.resolveEntry(named: manifest.principalClass, executableURL: executable)
        let info = IsiXPluginInfo(identifier: manifest.identifier, name: manifest.name, version: manifest.version, bundleURL: url,
                                  capabilities: Set(manifest.capabilities.map(IsiXCapability.init(rawValue:))))
        let runtime = IsiXPluginRuntime(info: info, bundle: bundle, entry: type, host: host)
        host.runtimes.append(runtime)
        do { try runtime.activate() } catch { output["activationError"] = message(error) }
        output["state"] = "\(runtime.state)"
        output["commands"] = runtime.commands.map { "\($0.title)|\($0.placement)|\($0.requirement)" }
        output["xmlRPCMethods"] = runtime.xmlRPCMethodNames
        return runtime
    } catch {
        output["error"] = message(error)
        return nil
    }
}

@MainActor
func run(_ runtime: IsiXPluginRuntime, _ index: Int) -> String? {
    guard runtime.commands.indices.contains(index) else { return "no command \(index)" }
    do { try runtime.run(commandID: runtime.commands[index].id); return nil } catch { return message(error) }
}

/// Lets the run loop turn until `done` or `seconds` passed.
@MainActor
func wait(_ seconds: Double, until done: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

/// An object of the application's kind, as its own notifications carry.
final class ApplicationObject: NSObject {}

@MainActor
func main() -> [String: Any] {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let arguments = CommandLine.arguments.dropFirst()
    guard let scratchPath = arguments.first else { return ["error": "usage"] }
    let scratch = URL(fileURLWithPath: scratchPath)
    var result: [String: Any] = [:]
    let host: FakeHost
    do { host = try FakeHost(folder: scratch) } catch { return ["error": "\(error)"] }
    let viewer = FakeViewer()
    host.viewers = [viewer]

    var outputs: [String: [String: Any]] = [:]
    var runtimes: [String: IsiXPluginRuntime] = [:]
    for url in arguments.dropFirst().map({ URL(fileURLWithPath: $0) }) {
        let name = url.deletingPathExtension().lastPathComponent
        var output: [String: Any] = [:]
        if let runtime = load(url, host: host, output: &output) { runtimes[name] = runtime }
        outputs[name] = output
    }

    // The probes' main command: nodes, sends, queries, XML-RPC values.
    for (name, runtime) in runtimes where name.hasPrefix("NetworkProbe") {
        outputs[name]?["runError"] = run(runtime, 0) ?? ""
    }
    // SendController sends in the background.
    wait(5) { host.log.all.filter { $0.contains("files=0:sops=2") }.count >= 2 }

    // An import, a viewer and its ROIs, as the application tells of them.
    let added = IsiXImagesAdded(images: host.images, sopInstanceUIDsByCallingAETitle: ["MODALITY": [sopUID(0)]], isComplete: false)
    host.deliver(.imagesAdded(added))
    var complete = added
    complete.isComplete = true
    host.deliver(.imagesAdded(complete))
    host.deliver(.viewerOpened(viewer.viewerID))
    host.deliver(.sliceChanged(viewer.viewerID, IsiXSlicePosition(slice: 1, phase: 0)))
    for change in [IsiXROIChange.added, .modified, .selected, .removed] {
        host.deliver(.roiChanged(viewer.viewerID, viewer.roi.id, change))
    }
    // The kit gives the viewers' events on the next turn of the run loop.
    wait(0.3) { false }
    // The application's own notifications, by the names it posts them under,
    // with its own objects: a ported plugin must not receive them.
    for name in ["roiChange", "removeROI", "roiSelected", "addROI", "CloseViewerNotification", "DCMUpdateCurrentImage", "updateView",
                 "OsirixAddToDBNotification", "OsirixAddToDBCompleteNotification", "OsiriXXMLRPCMessage"] {
        NotificationCenter.default.post(name: Notification.Name(name), object: ApplicationObject(),
                                        userInfo: ["OsiriXAddToDBArray": [ApplicationObject()], "ROI": ApplicationObject()])
    }
    viewer.isOpen = false
    host.deliver(.viewerWillClose(viewer.viewerID))
    wait(1) { false }

    for (name, runtime) in runtimes where name.hasPrefix("NetworkProbe") {
        do {
            outputs[name]?["xmlrpcEcho"] = "\(try runtime.callXMLRPCMethod(named: "ProbeEcho", parameters: [.structure(["text": .string("hello")])]) as Any)"
        } catch {
            outputs[name]?["xmlrpcEcho"] = "error: " + message(error)
        }
        outputs[name]?["unconfiguredError"] = run(runtime, 1) ?? ""
        outputs[name]?["reportError"] = run(runtime, 2) ?? ""
    }
    if let exec = runtimes["Exec"] {
        // The plugin's own command, on the database selection.
        outputs["Exec"]?["runError"] = run(exec, 0) ?? ""
        let file = scratch.appendingPathComponent("exec.txt")
        wait(5) { ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count >= 4 }
        outputs["Exec"]?["lines"] = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).sorted()
    }
    outputs["XploreReports"]?["report"] = host.study.report ?? ""
    result["plugins"] = outputs
    result["network"] = host.log.all
    result["unprefixedLegacyClasses"] = ["SendController", "DCMTKStoreSCU", "DCMNetServiceDelegate", "N2XMLRPC", "DCMTKRootQueryNode"]
        .filter { NSClassFromString($0) != nil }
    return result
}

let data = MainActor.assumeIsolated {
    try! JSONSerialization.data(withJSONObject: main(), options: [.prettyPrinted, .sortedKeys])
}
print(String(decoding: data, as: UTF8.self))
