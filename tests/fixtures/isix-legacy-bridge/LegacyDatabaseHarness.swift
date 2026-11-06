//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A host for tests/test-isix-legacy-database.py: the application's loading
// path (IsiXPluginLoading and the kit's runtime) with a synthetic database
// and a synthetic viewer, running legacy database plugins ported with
// IsiXLegacyBridge. The database checks changes with the application's own
// rules (IsiXDatabase's PluginDatabaseEdits and PluginAlbumRules), writes
// derived images as JSON descriptions and reads the DICOM files plugins
// write. It prints one JSON object; the test checks it.
//
//     LegacyDatabaseHarness <plugin.isixplugin>...
//
// Plugins are recognised by their bundle name: FloatDICOMExport,
// VolumeGenerator, DatabaseProbe* (the test's own probe), and BullsEye and
// Coronary (tests/test-isix-legacy-ported-plugins.py).

import AppKit
@_spi(IsiXHost) import IsiXPluginKit
import IsiXPluginLoading
import IsiXDatabase

let studyUID = "1.2.826.0.1.3680043.9.1544.1"
let seriesUID = "1.2.826.0.1.3680043.9.1544.1.1"
func sopUID(_ slice: Int) -> String { "1.2.826.0.1.3680043.9.1544.1.1.\(slice + 1)" }
func sample(_ s: Int, _ r: Int, _ c: Int) -> Float { Float(-50 + 7 * s + 3 * r + c) }

// MARK: a DICOM file, as far as the test reads one

/// The elements of a Part 10 file in little endian, explicit or implicit VR,
/// by tag; sequences are not expected.
func readDICOM(_ url: URL) -> [UInt32: Data]? {
    guard let data = try? Data(contentsOf: url), data.count > 132,
          String(decoding: data[128..<132], as: UTF8.self) == "DICM" else { return nil }
    func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    var elements: [UInt32: Data] = [:]
    var offset = 132
    var explicit = true
    let long: Set<String> = ["OB", "OW", "OF", "SQ", "UT", "UN", "UC", "UR"]
    while offset + 8 <= data.count {
        let tag = UInt32(u16(offset)) << 16 | UInt32(u16(offset + 2))
        let inMeta = tag >> 16 == 2
        let vr = String(decoding: data[(offset + 4)..<(offset + 6)], as: UTF8.self)
        var length: Int, start: Int
        if inMeta || explicit {
            if long.contains(vr) { length = u32(offset + 8); start = offset + 12 } else { length = u16(offset + 6); start = offset + 8 }
        } else {
            length = u32(offset + 4); start = offset + 8
        }
        guard length >= 0, start + length <= data.count else { return nil }
        elements[tag] = data.subdata(in: start..<(start + length))
        offset = start + length
        if tag == 0x0002_0010 {
            explicit = text(elements[tag]) != "1.2.840.10008.1.2"
        }
    }
    return elements
}

func text(_ data: Data?) -> String? {
    data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0")) }
}

// MARK: the synthetic application

@MainActor
final class FakeViewer: IsiXViewerBackend {
    let viewerID = IsiXViewerID(rawValue: UUID())
    var isOpen = true
    let columns = 6, rows = 4, sliceCount = 3
    var current = 1

    func slice(_ value: Int?) throws -> Int {
        let s = value ?? current
        guard (0..<sliceCount).contains(s) else { throw IsiXPluginError.sliceOutOfRange(s) }
        return s
    }

    func seriesSummary() throws -> IsiXSeriesSummary {
        IsiXSeriesSummary(sliceCount: sliceCount, phaseCount: 1, currentSlice: current, currentPhase: 0,
                          studyInstanceUID: studyUID, seriesInstanceUID: seriesUID, seriesDescription: "Synthetic CT", modality: "CT")
    }

    func currentPosition() throws -> IsiXSlicePosition { IsiXSlicePosition(slice: current, phase: 0) }
    func setCurrentSlice(_ slice: Int) throws { current = try self.slice(slice) }

    func geometry(slice value: Int?, phase: Int?) throws -> IsiXImageGeometry {
        let s = try slice(value)
        return IsiXImageGeometry(columns: columns, rows: rows, columnSpacing: 0.5, rowSpacing: 0.5,
                                 imagePosition: IsiXVector3(x: 0, y: 0, z: Double(s)),
                                 rowDirection: IsiXVector3(x: 1, y: 0, z: 0), columnDirection: IsiXVector3(x: 0, y: 1, z: 0),
                                 sliceThickness: 1, sliceInterval: 1, sliceLocation: Double(s))
    }

    func attributes(slice value: Int?, phase: Int?) throws -> IsiXImageAttributes {
        IsiXImageAttributes(modality: "CT", studyInstanceUID: studyUID, seriesInstanceUID: seriesUID, sopInstanceUID: sopUID(try slice(value)))
    }

    func values(_ s: Int) -> [Float] { (0..<rows).flatMap { r in (0..<columns).map { c in sample(s, r, c) } } }

    func image(slice value: Int?, phase: Int?) throws -> IsiXImage {
        let s = try slice(value)
        return IsiXImage(version: IsiXImageVersion(viewer: viewerID, slice: s, phase: 0, token: 1),
                         geometry: try geometry(slice: s, phase: 0), attributes: try attributes(slice: s, phase: 0),
                         pixels: .float32(try IsiXPixelBuffer(width: columns, height: rows, samples: values(s))))
    }

    func windowLevel() throws -> IsiXWindowLevel { IsiXWindowLevel(center: 40, width: 400) }
    func setWindowLevel(_ windowLevel: IsiXWindowLevel) throws {}
    func commit(_ pixels: IsiXPixelData, replacing version: IsiXImageVersion) throws { throw IsiXPluginError.staleImage }
    func rois(slice: Int?, phase: Int?) throws -> [IsiXROI] { [] }
    func addROI(_ draft: IsiXROIDraft) throws -> IsiXROI { throw IsiXPluginError.unsupportedROIKind(draft.kind) }
    func removeROI(_ id: IsiXROIID) throws { throw IsiXPluginError.roiNotFound }
    func statistics(of id: IsiXROIID) throws -> IsiXROIStatistics { throw IsiXPluginError.roiNotFound }
    func setNeedsDisplay() {}
}

/// A derived image as the synthetic database wrote it.
struct DerivedFile: Codable {
    var study: String, source: String?, series: String, seriesNumber: Int?, description: String, instance: Int
    var width: Int, height: Int, values: [Float]?, spacing: [Double]?
    /// A colour image's samples: red, green, blue and alpha of each pixel.
    var rgba: [UInt8]? = nil
}

@MainActor
final class FakeHost: IsiXHostBackend, IsiXDatabaseBackend {
    var viewers: [FakeViewer] = []
    var studies: [IsiXStudy] = []
    var series: [IsiXSeries] = []
    var images: [IsiXDatabaseImage] = []
    var albumList: [(name: String, smart: Bool, studies: [String])] = [("Today", true, [])]
    var selected: [String] = [studyUID]
    var derived: [DerivedFile] = []
    var importedDICOM: [[String: Any]] = []
    var opened: [String] = []
    let folder: URL

    init(folder: URL) {
        self.folder = folder
        var study = IsiXStudy(studyInstanceUID: studyUID, patientID: "LEGACY-1", patientName: "SYNTH^LEGACY", studyDescription: "Database probe",
                              studyDate: Date(timeIntervalSince1970: 1_700_000_000), modalities: ["CT"], seriesCount: 1)
        study.imageCount = 3
        studies = [study]
        series = [IsiXSeries(seriesInstanceUID: seriesUID, studyInstanceUID: studyUID, seriesDescription: "Synthetic CT", modality: "CT",
                             seriesNumber: 1, imageCount: 3)]
        for s in 0..<3 {
            let file = folder.appendingPathComponent("source-\(s).dcm")
            try? Data("synthetic".utf8).write(to: file)
            images.append(IsiXDatabaseImage(sopInstanceUID: sopUID(s), seriesInstanceUID: seriesUID, studyInstanceUID: studyUID,
                                            instanceNumber: s + 1, frame: 0, numberOfFrames: 1, file: file, modality: "CT",
                                            columns: 6, rows: 4, sliceLocation: Double(s), isKeyImage: false,
                                            comments: ["", "", "", ""], date: nil))
        }
    }

    func frontmostViewer() -> (any IsiXViewerBackend)? { viewers.first }
    func openViewers() -> [any IsiXViewerBackend] { viewers }
    func viewer(withID id: IsiXViewerID) -> (any IsiXViewerBackend)? { viewers.first { $0.viewerID == id } }
    func parentWindow(forViewer id: IsiXViewerID?) -> NSWindow? { nil }
    func commandsDidChange() {}

    // MARK: reading

    func refusal(_ error: any Error) -> any Error {
        switch error as? PluginDatabaseRefusal {
        case .invalid(let reason): return IsiXPluginError.invalidValue(reason)
        case .notFound(let what): return IsiXPluginError.notFound(what)
        case nil: return error
        }
    }

    func databaseSelection() throws -> IsiXDatabaseSelection {
        IsiXDatabaseSelection(studies: studies.filter { selected.contains($0.studyInstanceUID) }, series: [])
    }

    func studies(matching query: IsiXStudyQuery) throws -> [IsiXStudy] {
        studies.filter { study in
            (query.studyInstanceUID.map { $0 == study.studyInstanceUID } ?? true)
                && (query.patientName.map { (study.patientName ?? "").localizedCaseInsensitiveContains($0) } ?? true)
        }
    }

    func seriesRecords(inStudy uid: String) throws -> [IsiXSeries] { series.filter { $0.studyInstanceUID == uid } }
    func seriesRecord(withInstanceUID uid: String) throws -> IsiXSeries? { series.first { $0.seriesInstanceUID == uid } }
    func images(inSeries uid: String) throws -> [IsiXDatabaseImage] { images.filter { $0.seriesInstanceUID == uid } }
    func images(withSOPInstanceUID uid: String) throws -> [IsiXDatabaseImage] { images.filter { $0.sopInstanceUID == uid } }

    func albums() throws -> [IsiXAlbum] { albumList.map { IsiXAlbum(name: $0.name, isSmart: $0.smart, studyCount: $0.studies.count) } }

    func studies(inAlbum name: String) throws -> [IsiXStudy] {
        guard let album = albumList.first(where: { $0.name == name }) else { throw IsiXPluginError.notFound("album \(name)") }
        return studies.filter { album.studies.contains($0.studyInstanceUID) }
    }

    func openViewer(forSeries uid: String) throws -> (any IsiXViewerBackend)? {
        guard series.contains(where: { $0.seriesInstanceUID == uid }) else { throw IsiXPluginError.notFound("series \(uid)") }
        opened.append(uid)
        return nil
    }

    // MARK: changing, with the application's rules

    static func apply(_ values: [String: Any?], comments: inout [String]) {
        for (index, key) in PluginDatabaseEdits.commentKeys.enumerated() where values.keys.contains(key) {
            comments[index] = (values[key] ?? nil) as? String ?? ""
        }
    }

    func updateStudy(_ uid: String, _ update: IsiXStudyUpdate) throws -> IsiXStudy {
        guard let index = studies.firstIndex(where: { $0.studyInstanceUID == uid }) else { throw IsiXPluginError.notFound("study \(uid)") }
        let values: [String: Any?]
        do {
            values = try PluginDatabaseEdits.studyValues(comments: update.comments, state: update.state, report: update.report,
                                                         isLocked: update.isLocked)
        } catch { throw refusal(error) }
        var study = studies[index]
        if study.comments.count < 4 { study.comments += Array(repeating: "", count: 4 - study.comments.count) }
        Self.apply(values, comments: &study.comments)
        if let state = values["stateText"] as? NSNumber { study.state = state.intValue }
        if values.keys.contains("reportURL") { study.report = (values["reportURL"] ?? nil) as? String }
        if let locked = values["lockedStudy"] as? NSNumber { study.isLocked = locked.boolValue }
        studies[index] = study
        return study
    }

    func updateSeries(_ uid: String, _ update: IsiXSeriesUpdate) throws -> IsiXSeries {
        guard let index = series.firstIndex(where: { $0.seriesInstanceUID == uid }) else { throw IsiXPluginError.notFound("series \(uid)") }
        let values: [String: Any?]
        do { values = try PluginDatabaseEdits.seriesValues(comments: update.comments, state: update.state) } catch { throw refusal(error) }
        var record = series[index]
        if record.comments.count < 4 { record.comments += Array(repeating: "", count: 4 - record.comments.count) }
        Self.apply(values, comments: &record.comments)
        if let state = values["stateText"] as? NSNumber { record.state = state.intValue }
        series[index] = record
        return record
    }

    func updateImage(_ uid: String, frame: Int, _ update: IsiXImageUpdate) throws -> IsiXDatabaseImage {
        guard let index = images.firstIndex(where: { $0.sopInstanceUID == uid && $0.frame == frame }) else { throw IsiXPluginError.notFound("image \(uid)") }
        let values: [String: Any?]
        do { values = try PluginDatabaseEdits.imageValues(isKeyImage: update.isKeyImage, comments: update.comments) } catch { throw refusal(error) }
        Self.apply(values, comments: &images[index].comments)
        if let key = values["isKeyImage"] as? NSNumber { images[index].isKeyImage = key.boolValue }
        return images[index]
    }

    func createAlbum(named name: String) throws -> IsiXAlbum {
        let checked: String
        do { checked = try PluginAlbumRules.newAlbumName(name, existing: albumList.map(\.name)) } catch { throw refusal(error) }
        albumList.append((checked, false, []))
        return IsiXAlbum(name: checked, isSmart: false, studyCount: 0)
    }

    func change(_ uids: [String], _ name: String, add: Bool) throws {
        guard let index = albumList.firstIndex(where: { $0.name == name }) else { throw IsiXPluginError.notFound("album \(name)") }
        do { try PluginAlbumRules.checkMembershipChange(albumName: name, isSmart: albumList[index].smart) } catch { throw refusal(error) }
        for uid in uids where !studies.contains(where: { $0.studyInstanceUID == uid }) { throw IsiXPluginError.notFound("study \(uid)") }
        albumList[index].studies = add ? Array(Set(albumList[index].studies + uids)).sorted() : albumList[index].studies.filter { !uids.contains($0) }
    }

    func addStudies(_ uids: [String], toAlbum name: String) throws { try change(uids, name, add: true) }
    func removeStudies(_ uids: [String], fromAlbum name: String) throws { try change(uids, name, add: false) }

    // MARK: writing and importing

    func writeDerivedSeriesNow(_ request: IsiXDerivedSeriesRequest) throws -> [URL] {
        guard studies.contains(where: { $0.studyInstanceUID == request.studyInstanceUID }) else {
            throw IsiXPluginError.notFound("study \(request.studyInstanceUID)")
        }
        if let source = request.sourceSOPInstanceUID, !images.contains(where: { $0.sopInstanceUID == source && $0.studyInstanceUID == request.studyInstanceUID }) {
            throw IsiXPluginError.invalidValue("The image \(source) is not of the study.")
        }
        var urls: [URL] = []
        for (index, image) in request.images.enumerated() {
            let geometry = request.geometries?[index]
            var file = DerivedFile(study: request.studyInstanceUID, source: request.sourceSOPInstanceUID,
                                   series: request.seriesInstanceUID ?? UUID().uuidString, seriesNumber: request.seriesNumber,
                                   description: request.seriesDescription, instance: request.firstInstanceNumber + index,
                                   width: 0, height: 0, values: nil, spacing: geometry.map { [$0.columnSpacing, $0.rowSpacing] })
            switch image {
            case .float32(let buffer): (file.width, file.height, file.values) = (buffer.width, buffer.height, buffer.samples)
            case .rgba8(let buffer): (file.width, file.height, file.rgba) = (buffer.width, buffer.height, buffer.samples)
            @unknown default: throw IsiXPluginError.invalidValue("pixels")
            }
            derived.append(file)
            let url = folder.appendingPathComponent("derived-\(derived.count).json")
            try JSONEncoder().encode(file).write(to: url)
            urls.append(url)
        }
        return urls
    }

    func addImage(study: String, patient: String?, series uid: String, description: String?, modality: String?, sop: String,
                  instance: Int?, columns: Int, rows: Int, file: URL) -> IsiXDatabaseImage {
        if !studies.contains(where: { $0.studyInstanceUID == study }) {
            studies.append(IsiXStudy(studyInstanceUID: study, patientID: nil, patientName: patient, studyDescription: nil, studyDate: nil,
                                     modalities: modality.map { [$0] } ?? [], seriesCount: 0))
        }
        if !series.contains(where: { $0.seriesInstanceUID == uid }) {
            series.append(IsiXSeries(seriesInstanceUID: uid, studyInstanceUID: study, seriesDescription: description, modality: modality,
                                     seriesNumber: nil, imageCount: 0))
        }
        let image = IsiXDatabaseImage(sopInstanceUID: sop, seriesInstanceUID: uid, studyInstanceUID: study, instanceNumber: instance,
                                      frame: 0, numberOfFrames: 1, file: file, modality: modality, columns: columns, rows: rows,
                                      sliceLocation: nil, isKeyImage: false, comments: ["", "", "", ""], date: nil)
        images.append(image)
        return image
    }

    func importFilesNow(at urls: [URL]) throws -> IsiXImportResult {
        var made: [IsiXDatabaseImage] = []
        var failures: [IsiXImportResult.Failure] = []
        for url in urls {
            let copy = folder.appendingPathComponent("db-\(UUID().uuidString)-\(url.lastPathComponent)")
            try? FileManager.default.copyItem(at: url, to: copy)
            if url.pathExtension == "json", let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(DerivedFile.self, from: data) {
                made.append(addImage(study: file.study, patient: nil, series: file.series, description: file.description, modality: "SC",
                                     sop: UUID().uuidString, instance: file.instance, columns: file.width, rows: file.height, file: copy))
            } else if let elements = readDICOM(url) {
                let study = text(elements[0x0020_000D]) ?? "", series = text(elements[0x0020_000E]) ?? ""
                let rows = elements[0x0028_0010].map { Int($0[0]) | Int($0[1]) << 8 } ?? 0
                let columns = elements[0x0028_0011].map { Int($0[0]) | Int($0[1]) << 8 } ?? 0
                let pixels = elements[0x7FE0_0010] ?? Data()
                let instance = text(elements[0x0020_0013]).flatMap { Int($0) }
                importedDICOM.append(["file": url.lastPathComponent, "study": study, "series": series, "rows": rows, "columns": columns,
                                      "instance": instance ?? -1, "pixelBytes": pixels.count,
                                      "words": stride(from: 0, to: pixels.count - 1, by: 2).map { Int(pixels[$0]) | Int(pixels[$0 + 1]) << 8 },
                                      "patient": text(elements[0x0010_0010]) ?? "", "bitsAllocated": elements[0x0028_0100].map { Int($0[0]) } ?? 0,
                                      "frames": text(elements[0x0028_0008]) ?? "", "sopClass": text(elements[0x0008_0016]) ?? "",
                                      "spacing": text(elements[0x0028_0030]) ?? "", "orientation": text(elements[0x0020_0037]) ?? "",
                                      "characterSet": text(elements[0x0008_0005]) ?? "", "seriesDescription": text(elements[0x0008_103E]) ?? "",
                                      "referringPhysician": text(elements[0x0008_0090]) ?? ""])
                made.append(addImage(study: study, patient: text(elements[0x0010_0010]), series: series, description: text(elements[0x0008_103E]),
                                     modality: text(elements[0x0008_0060]), sop: text(elements[0x0008_0018]) ?? UUID().uuidString,
                                     instance: instance, columns: columns, rows: rows, file: copy))
            } else {
                failures.append(.init(file: url, reason: "not DICOM"))
            }
        }
        var result = IsiXImportResult(importedFiles: urls.filter { url in !failures.contains { $0.file == url } },
                                      studyInstanceUIDs: Array(Set(made.map(\.studyInstanceUID))),
                                      seriesInstanceUIDs: Array(Set(made.map(\.seriesInstanceUID))), failures: failures)
        result.images = made
        return result
    }

    func selectedStudies() async throws -> [IsiXStudy] { try databaseSelection().studies }
    func study(withInstanceUID uid: String) async throws -> IsiXStudy? { try studies(matching: IsiXStudyQuery(studyInstanceUID: uid)).first }
    func series(inStudy uid: String) async throws -> [IsiXSeries] { try seriesRecords(inStudy: uid) }
    func importFiles(at urls: [URL]) async throws -> IsiXImportResult { try importFilesNow(at: urls) }
}

// MARK: running plugins

/// The title of the dialog the harness pressed Create in.
nonisolated(unsafe) var pressedDialog = ""

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
func run(_ runtime: IsiXPluginRuntime, _ index: Int) -> String? {
    guard runtime.commands.indices.contains(index) else { return "no command \(index)" }
    do { try runtime.run(commandID: runtime.commands[index].id); return nil } catch { return message(error) }
}

@MainActor
func views(in view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { views(in: $0) }
}

@MainActor
func main() -> [String: Any] {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    var result: [String: Any] = [:]
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("isix-legacy-database-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    for url in CommandLine.arguments.dropFirst().map({ URL(fileURLWithPath: $0) }) {
        let name = url.deletingPathExtension().lastPathComponent
        let folder = scratch.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let host = FakeHost(folder: folder)
        var output: [String: Any] = [:]
        switch name {
        case "FloatDICOMExport":
            let viewer = FakeViewer()
            host.viewers = [viewer]
            guard let runtime = load(url, host: host, output: &output) else { break }
            output["runError"] = run(runtime, 0)
            output["derived"] = host.derived.count
            if let file = host.derived.first {
                output["source"] = file.source ?? ""
                output["study"] = file.study
                output["valuesEqual"] = file.values == viewer.values(viewer.current)
                output["size"] = [file.width, file.height]
            }
            output["importedSeries"] = host.series.count
            output["importedImages"] = host.images.count
        case "BullsEye", "Coronary":
            // tests/test-isix-legacy-ported-plugins.py: the command opens the plugin's
            // window; its "Save DICOM" writes the diagram as an RGB image into the
            // study of the viewer shown.
            let viewer = FakeViewer()
            host.viewers = [viewer]
            guard let runtime = load(url, host: host, output: &output) else { break }
            output["runError"] = run(runtime, 0)
            let controller = NSApp.windows.compactMap(\.windowController)
                .first { NSStringFromClass(type(of: $0)) == "\(name)Controller" }
            output["window"] = controller?.window?.title ?? ""
            _ = controller?.perform(NSSelectorFromString("saveDICOM:"), with: nil)
            output["derivedColour"] = host.derived.filter { $0.rgba != nil }.map { file -> [String: Any] in
                let colours = Set(stride(from: 0, to: file.rgba!.count, by: 4).map { i in file.rgba![i..<i + 3].map(Int.init) })
                return ["description": file.description, "source": file.source ?? "", "width": file.width, "height": file.height,
                        "colours": colours.count]
            }
            controller?.close()
        case "VolumeGenerator":
            guard let runtime = load(url, host: host, output: &output) else { break }
            // The plugin's dialog runs modally: press Create, as the user would.
            let press = Timer(timeInterval: 0.2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    for window in NSApp.windows where window.isVisible && pressedDialog.isEmpty {
                        if let create = views(in: window.contentView).compactMap({ $0 as? NSButton })
                            .first(where: { $0.action == NSSelectorFromString("create:") }) {
                            pressedDialog = window.title
                            create.performClick(nil)
                        }
                    }
                }
            }
            RunLoop.main.add(press, forMode: .modalPanel)
            output["runError"] = run(runtime, 0)
            press.invalidate()
            output["dialog"] = pressedDialog
            output["files"] = host.importedDICOM
            output["opened"] = host.opened
        default:
            // The test's own probe, built with manual reference counting and with ARC.
            guard let runtime = load(url, host: host, output: &output) else { break }
            output["runError"] = run(runtime, 0)
            let study = host.studies.first { $0.studyInstanceUID == studyUID }
            output["stateAfterProbe"] = study?.state ?? -1
            output["commentsAfterProbe"] = study?.comments ?? []
            output["refusedStateError"] = run(runtime, 1) ?? ""
            output["stateAfterRefusal"] = host.studies.first { $0.studyInstanceUID == studyUID }?.state ?? -1
            output["readOnlyError"] = run(runtime, 2) ?? ""
            output["nameAfterRefusal"] = host.studies.first { $0.studyInstanceUID == studyUID }?.patientName ?? ""
            output["albums"] = host.albumList.map { "\($0.name):\($0.studies.joined(separator: ","))" }
            output["derivedFiles"] = host.derived.filter { $0.rgba == nil }.map {
                ["series": $0.series, "instance": $0.instance, "source": $0.source ?? "",
                 "values": ($0.values ?? []).map(Double.init), "spacing": $0.spacing ?? []] as [String: Any] }
            output["derivedColour"] = host.derived.filter { $0.rgba != nil }.map {
                ["description": $0.description, "width": $0.width, "height": $0.height,
                 "rgba": ($0.rgba ?? []).map(Int.init)] as [String: Any] }
            output["importedDICOM"] = host.importedDICOM
            // -exportDICOMFileInt:withName:allViewers: of the image a viewer shows.
            let viewer = FakeViewer()
            host.viewers = [viewer]
            let before = host.derived.count
            output["viewerExportError"] = run(runtime, 3) ?? ""
            output["viewerExport"] = host.derived.dropFirst(before).map {
                ["description": $0.description, "instance": $0.instance, "source": $0.source ?? "", "series": $0.series,
                 "valuesEqual": $0.values == viewer.values(viewer.current), "spacing": $0.spacing ?? []] as [String: Any] }
        }
        output["kitClass"] = NSClassFromString("IsiXLegacy\(name)_BrowserController") != nil
        result[name] = output
    }
    result["unprefixedLegacyClasses"] = ["BrowserController", "DicomStudy", "DicomSeries", "DicomImage", "DicomDatabase", "DICOMExport", "DCMObject"]
        .filter { NSClassFromString($0) != nil }
    return result
}

let data = MainActor.assumeIsolated {
    try! JSONSerialization.data(withJSONObject: main(), options: [.prettyPrinted, .sortedKeys])
}
print(String(decoding: data, as: UTF8.self))
