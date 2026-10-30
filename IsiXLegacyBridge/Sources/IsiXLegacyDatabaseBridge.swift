//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The database as the kit's Objective-C classes (DicomStudy, DicomSeries,
// DicomImage, DicomAlbum, DicomDatabase, BrowserController, DICOMExport)
// reach it: IsiXPluginKit's IsiXDatabase, its records turned into
// dictionaries under the attribute names of the legacy database (name,
// studyName, stateText, comment2, completePath...), which the legacy objects
// answer and which key-value coding and NSPredicate read.
//
// Every call goes to the application at once and returns copies; a change
// the application refuses is recorded as the failure of the command that
// runs, as the viewer calls are, and changes nothing.

import AppKit
import IsiXPluginKit

/// The kinds of database object, as the legacy entities name them.
@objc enum IsiXLegacyEntity: Int {
    case study, series, image, album
}

@MainActor
@objc final class IsiXLegacyDatabaseBridge: NSObject {
    @objc nonisolated static let shared = IsiXLegacyDatabaseBridge()

    /// Files the kit wrote for the plugin (derived images, DICOM objects
    /// before they are imported), removed when the plugin is unloaded.
    private var temporaryFiles: [URL] = []

    nonisolated override private init() {
        super.init()
    }

    // MARK: access

    private func database() throws -> IsiXDatabase {
        guard let context = IsiXLegacyState.shared.context else { throw IsiXPluginError.pluginInactive }
        return try context.database()
    }

    private func attempt<T>(_ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            IsiXLegacyState.shared.record(error)
            return nil
        }
    }

    /// Whether the plugin declared a capability of the database.
    @objc nonisolated var isAvailable: Bool {
        IsiXLegacyOnMain { (try? database()) != nil }
    }

    // MARK: records under the legacy names

    private static func joined(_ modalities: [String]) -> String { modalities.joined(separator: "\\") }

    private static func comments(_ comments: [String], into record: inout [String: Any]) {
        for (index, key) in ["comment", "comment2", "comment3", "comment4"].enumerated() {
            if comments.indices.contains(index), !comments[index].isEmpty { record[key] = comments[index] }
        }
    }

    static func record(_ study: IsiXStudy) -> NSDictionary {
        var record: [String: Any] = ["studyInstanceUID": study.studyInstanceUID, "modality": joined(study.modalities),
                                     "numberOfImages": study.imageCount, "stateText": study.state,
                                     "lockedStudy": study.isLocked, "hasDICOM": true, "type": "Study",
                                     "isixSeriesCount": study.seriesCount]
        record["name"] = study.patientName
        record["patientID"] = study.patientID
        // The legacy database kept one identity per patient; the patient ID stands for it.
        record["patientUID"] = study.patientID
        record["studyName"] = study.studyDescription
        record["date"] = study.studyDate
        record["accessionNumber"] = study.accessionNumber
        record["id"] = study.studyID
        record["dateOfBirth"] = study.patientBirthDate
        record["patientSex"] = study.patientSex
        record["referringPhysician"] = study.referringPhysician
        record["performingPhysician"] = study.performingPhysician
        record["institutionName"] = study.institutionName
        record["dateAdded"] = study.dateAdded
        record["reportURL"] = study.report
        comments(study.comments, into: &record)
        return record as NSDictionary
    }

    static func record(_ series: IsiXSeries) -> NSDictionary {
        var record: [String: Any] = ["seriesDICOMUID": series.seriesInstanceUID, "seriesInstanceUID": series.seriesInstanceUID,
                                     "numberOfImages": series.imageCount, "stateText": series.state, "type": "Series",
                                     "isixStudyInstanceUID": series.studyInstanceUID]
        record["name"] = series.seriesDescription
        record["seriesDescription"] = series.seriesDescription
        record["modality"] = series.modality
        record["id"] = series.seriesNumber
        record["date"] = series.seriesDate
        record["seriesSOPClassUID"] = series.sopClassUID
        comments(series.comments, into: &record)
        return record as NSDictionary
    }

    static func record(_ image: IsiXDatabaseImage) -> NSDictionary {
        var record: [String: Any] = ["sopInstanceUID": image.sopInstanceUID, "frameID": image.frame,
                                     "numberOfFrames": image.numberOfFrames, "width": image.columns, "height": image.rows,
                                     "isKeyImage": image.isKeyImage, "storedIsKeyImage": image.isKeyImage, "type": "Image",
                                     "isixSeriesInstanceUID": image.seriesInstanceUID,
                                     "isixStudyInstanceUID": image.studyInstanceUID]
        record["instanceNumber"] = image.instanceNumber
        record["modality"] = image.modality
        record["sliceLocation"] = image.sliceLocation
        record["date"] = image.date
        if let file = image.file {
            record["completePath"] = file.path
            record["path"] = file.lastPathComponent
            record["extension"] = file.pathExtension
        }
        comments(image.comments, into: &record)
        return record as NSDictionary
    }

    static func record(_ album: IsiXAlbum) -> NSDictionary {
        ["name": album.name, "smartAlbum": album.isSmart, "numberOfStudies": album.studyCount, "type": "Album"] as NSDictionary
    }

    // MARK: reading

    /// The database window's selection: records of studies and of series.
    @objc nonisolated func selection() -> [NSDictionary] {
        IsiXLegacyOnMain {
            attempt {
                let selection = try database().selection()
                return selection.studies.map(Self.record) + selection.series.map(Self.record)
            } ?? []
        }
    }

    @objc nonisolated func allStudies() -> [NSDictionary] {
        IsiXLegacyOnMain { attempt { try database().studies(matching: IsiXStudyQuery()).map(Self.record) } ?? [] }
    }

    @objc nonisolated func study(withInstanceUID uid: String) -> NSDictionary? {
        IsiXLegacyOnMain { attempt { try database().study(withInstanceUID: uid).map(Self.record) } ?? nil }
    }

    @objc nonisolated func series(inStudy uid: String) -> [NSDictionary] {
        IsiXLegacyOnMain { attempt { try database().series(inStudy: uid).map(Self.record) } ?? [] }
    }

    @objc nonisolated func series(withInstanceUID uid: String) -> NSDictionary? {
        IsiXLegacyOnMain { attempt { try database().series(withInstanceUID: uid).map(Self.record) } ?? nil }
    }

    @objc nonisolated func images(inSeries uid: String) -> [NSDictionary] {
        IsiXLegacyOnMain { attempt { try database().images(inSeries: uid).map(Self.record) } ?? [] }
    }

    /// The image of a viewer's image: its SOP Instance UID and frame.
    @objc nonisolated func image(withSOPInstanceUID uid: String, frame: Int) -> NSDictionary? {
        IsiXLegacyOnMain {
            attempt {
                let images = try database().images(withSOPInstanceUID: uid)
                return (images.first { $0.frame == frame } ?? images.first).map(Self.record)
            } ?? nil
        }
    }

    @objc nonisolated func albums() -> [NSDictionary] {
        IsiXLegacyOnMain { attempt { try database().albums().map(Self.record) } ?? [] }
    }

    @objc nonisolated func studies(inAlbum name: String) -> [NSDictionary] {
        IsiXLegacyOnMain { attempt { try database().studies(inAlbum: name).map(Self.record) } ?? [] }
    }

    /// Opens the series in a viewer; false when the application did not.
    @objc nonisolated func openViewer(forSeries uid: String) -> Bool {
        IsiXLegacyOnMain { attempt { _ = try database().openViewer(forSeries: uid); return true } ?? false }
    }

    // MARK: changing

    /// The legacy attributes a plugin may set, and the change of the API each one makes.
    @objc nonisolated static func isEditable(_ key: String, of entity: IsiXLegacyEntity) -> Bool {
        let comments: Set<String> = ["comment", "comment2", "comment3", "comment4"]
        switch entity {
        case .study: return comments.contains(key) || ["stateText", "reportURL", "lockedStudy"].contains(key)
        case .series: return comments.contains(key) || key == "stateText"
        case .image: return comments.contains(key) || key == "isKeyImage" || key == "storedIsKeyImage"
        case .album: return false
        }
    }

    private static func commentIndex(_ key: String) -> Int? {
        ["comment": 0, "comment2": 1, "comment3": 2, "comment4": 3][key]
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case let url as URL: return url.isFileURL ? url.path : url.absoluteString
        default: return ""
        }
    }

    /// A state given as a number or as a number in text; anything else is
    /// not a state, and the application refuses it.
    private static func state(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let number = Int(string.trimmingCharacters(in: .whitespaces)) { return number }
        return value == nil || value is NSNull ? 0 : -1
    }

    private static func flag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return (string as NSString).boolValue }
        return false
    }

    /// Sets one legacy attribute; returns the record as the application has
    /// it afterwards, or nil when it refused the value.
    @objc nonisolated func set(_ value: Any?, forKey key: String, of entity: IsiXLegacyEntity, record: NSDictionary) -> NSDictionary? {
        IsiXLegacyOnMain {
            attempt {
                let database = try database()
                let value = value is NSNull ? nil : value
                switch entity {
                case .study:
                    guard let uid = record["studyInstanceUID"] as? String else { throw IsiXPluginError.notFound("study") }
                    var update = IsiXStudyUpdate()
                    if let index = Self.commentIndex(key) { update.comments[index] = Self.text(value) }
                    else if key == "stateText" { update.state = Self.state(value) }
                    else if key == "reportURL" { update.report = Self.text(value) }
                    else if key == "lockedStudy" { update.isLocked = Self.flag(value) }
                    return Self.record(try database.updateStudy(uid, update))
                case .series:
                    guard let uid = record["seriesDICOMUID"] as? String else { throw IsiXPluginError.notFound("series") }
                    var update = IsiXSeriesUpdate()
                    if let index = Self.commentIndex(key) { update.comments[index] = Self.text(value) }
                    else if key == "stateText" { update.state = Self.state(value) }
                    return Self.record(try database.updateSeries(uid, update))
                case .image:
                    guard let uid = record["sopInstanceUID"] as? String else { throw IsiXPluginError.notFound("image") }
                    var update = IsiXImageUpdate()
                    if let index = Self.commentIndex(key) { update.comments[index] = Self.text(value) }
                    else { update.isKeyImage = Self.flag(value) }
                    let frame = (record["frameID"] as? NSNumber)?.intValue ?? 0
                    return Self.record(try database.updateImage(uid, frame: frame, update))
                case .album:
                    throw IsiXPluginError.invalidValue("An album's \(key) cannot be changed.")
                }
            }
        }
    }

    /// Records the refusal of a change that never reaches the application:
    /// an attribute the plugin may not set.
    @objc nonisolated func refuse(key: String, of entity: IsiXLegacyEntity) {
        IsiXLegacyOnMain {
            let name = ["DicomStudy", "DicomSeries", "DicomImage", "DicomAlbum"][entity.rawValue]
            IsiXLegacyState.shared.record(IsiXPluginError.invalidValue("A plugin cannot change \(key) of a \(name): the database keeps it."))
        }
    }

    /// Records that a legacy call the kit cannot carry out failed.
    @objc nonisolated func fail(_ message: String) {
        IsiXLegacyOnMain { IsiXLegacyState.shared.record(IsiXLegacyError(message)) }
    }

    @objc(createAlbumNamed:) nonisolated func createAlbum(named name: String) -> NSDictionary? {
        IsiXLegacyOnMain { attempt { Self.record(try database().createAlbum(named: name)) } ?? nil }
    }

    @objc nonisolated func addStudies(_ uids: [String], toAlbum name: String, add: Bool) -> Bool {
        IsiXLegacyOnMain {
            attempt {
                if add { try database().addStudies(uids, toAlbum: name) } else { try database().removeStudies(uids, fromAlbum: name) }
                return true
            } ?? false
        }
    }

    // MARK: importing and writing

    /// Imports the files; returns the records of the images made of them.
    /// Files the kit wrote are removed once imported.
    @objc nonisolated func importFiles(_ paths: [String]) -> [NSDictionary] {
        IsiXLegacyOnMain {
            attempt {
                let urls = paths.map { URL(fileURLWithPath: $0) }
                let result = try database().importFiles(at: urls)
                for imported in result.importedFiles where temporaryFiles.contains(imported) {
                    try? FileManager.default.removeItem(at: imported)
                    temporaryFiles.removeAll { $0 == imported }
                }
                if let failure = result.failures.first, result.importedFiles.isEmpty {
                    throw IsiXLegacyError("\(failure.file.lastPathComponent) was not imported: \(failure.reason)")
                }
                return result.images.map(Self.record)
            } ?? []
        }
    }

    /// A new file in the kit's folder for files waiting to be imported.
    @objc nonisolated func temporaryFilePath(extension pathExtension: String) -> String {
        IsiXLegacyOnMain {
            let folder = Self.temporaryFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(pathExtension.isEmpty ? "dcm" : pathExtension)
            temporaryFiles.append(url)
            return url.path
        }
    }

    /// The folder of the files the kit writes for the plugin, which stands for
    /// the database's folders the legacy plugins wrote into.
    @objc nonisolated static var temporaryFolderPath: String { temporaryFolder.path }

    nonisolated static var temporaryFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("IsiX Legacy Plugin Files", isDirectory: true)
            .appendingPathComponent(Bundle(for: IsiXLegacyDatabaseBridge.self).bundleIdentifier ?? "plugin", isDirectory: true)
    }

    /// Writes one image of a derived series with the application's DICOM
    /// writer: `samples` are Float32 values (one per pixel) or RGBA bytes.
    /// The file is moved to `path` when one is given; returns its path.
    @objc nonisolated func writeDerivedImage(study: String, source: String?, seriesUID: String, seriesNumber: NSNumber?,
                                             seriesDescription: String, instanceNumber: Int, samples: Data, width: Int, height: Int,
                                             color: Bool, geometry: [String: Any]?, windowLevel: [NSNumber]?, path: String?) -> String? {
        IsiXLegacyOnMain {
            attempt {
                let pixels: IsiXPixelData
                if color {
                    pixels = .rgba8(try IsiXPixelBuffer(width: width, height: height, channels: 4, samples: [UInt8](samples)))
                } else {
                    let values = samples.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    pixels = .float32(try IsiXPixelBuffer(width: width, height: height, samples: values))
                }
                var request = IsiXDerivedSeriesRequest(studyInstanceUID: study, seriesDescription: seriesDescription, images: [pixels])
                request.sourceSOPInstanceUID = source
                request.seriesInstanceUID = seriesUID
                request.seriesNumber = seriesNumber?.intValue
                request.firstInstanceNumber = instanceNumber
                if let geometry { request.geometries = [Self.geometry(geometry, columns: width, rows: height)] }
                if let windowLevel, windowLevel.count == 2 {
                    request.windowLevel = IsiXWindowLevel(center: windowLevel[1].doubleValue, width: windowLevel[0].doubleValue)
                }
                guard let written = try database().writeDerivedSeries(request).first else {
                    throw IsiXLegacyError("The application wrote no file.")
                }
                guard let path else {
                    temporaryFiles.append(written)
                    return written.path
                }
                let destination = URL(fileURLWithPath: path)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: written, to: destination)
                return destination.path
            } ?? nil
        }
    }

    private static func geometry(_ values: [String: Any], columns: Int, rows: Int) -> IsiXImageGeometry {
        func number(_ key: String, _ fallback: Double = 0) -> Double { (values[key] as? NSNumber)?.doubleValue ?? fallback }
        let orientation = (values["orientation"] as? [NSNumber])?.map(\.doubleValue) ?? [1, 0, 0, 0, 1, 0]
        let position = (values["position"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0]
        return IsiXImageGeometry(columns: columns, rows: rows, columnSpacing: number("spacingX", 1), rowSpacing: number("spacingY", 1),
                                 imagePosition: IsiXVector3(x: position[0], y: position[1], z: position[2]),
                                 rowDirection: IsiXVector3(x: orientation[0], y: orientation[1], z: orientation[2]),
                                 columnDirection: IsiXVector3(x: orientation[3], y: orientation[4], z: orientation[5]),
                                 sliceThickness: number("sliceThickness"), sliceInterval: number("sliceThickness"),
                                 sliceLocation: number("sliceLocation"))
    }

    /// A new UID for a series the kit writes: 2.25 and a random UUID as a decimal number.
    @objc nonisolated static func freshUID() -> String {
        let bytes = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        var digits = [UInt8](repeating: 0, count: 40)
        for byte in bytes {
            var carry = Int(byte)
            for index in digits.indices.reversed() {
                let value = Int(digits[index]) * 256 + carry
                digits[index] = UInt8(value % 10)
                carry = value / 10
            }
        }
        let text = digits.map(String.init).joined().drop(while: { $0 == "0" })
        return "2.25." + (text.isEmpty ? "0" : String(text))
    }

    /// Removes the files the kit wrote that were never imported.
    func removeTemporaryFiles() {
        for file in temporaryFiles { try? FileManager.default.removeItem(at: file) }
        temporaryFiles.removeAll()
    }
}
