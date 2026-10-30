//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXDatabase
import IsiXDICOMFile
@_spi(IsiXHost) import IsiXPluginKit

/// The local database as plugins of API version 1 reach it: the active local
/// DicomDatabase, read and changed on its main context. Plugins get copies
/// (IsiXStudy, IsiXSeries, IsiXDatabaseImage, IsiXAlbum); no managed object
/// crosses to them. A change is checked by the rules of IsiXDatabase
/// (PluginDatabaseEdits, PluginAlbumRules) before anything is set, goes
/// through the objects' own setters, as the user's edits do, and is saved;
/// a refused value changes nothing.
extension IsiXPluginHost: IsiXDatabaseBackend {

    // MARK: records

    private func database() throws -> DicomDatabase {
        guard let database = DicomDatabase.activeLocal() else { throw IsiXPluginError.noDatabase }
        return database
    }

    private static func comments(_ object: NSManagedObject) -> [String] {
        PluginDatabaseEdits.commentKeys.map { (object.value(forKey: $0) as? String) ?? "" }
    }

    private static func study(_ study: DicomStudy) -> IsiXStudy? {
        guard let uid = study.studyInstanceUID, !uid.isEmpty else { return nil }
        let series = (study.series as NSSet?)?.allObjects.compactMap { $0 as? DicomSeries } ?? []
        let modalities = Array(Set(series.compactMap(\.modality).filter { !$0.isEmpty })).sorted()
        var record = IsiXStudy(studyInstanceUID: uid, patientID: study.patientID, patientName: study.name,
                               studyDescription: study.studyName, studyDate: study.date,
                               modalities: modalities.isEmpty ? (study.modality.map { [$0] } ?? []) : modalities,
                               seriesCount: series.count)
        record.accessionNumber = study.accessionNumber
        record.studyID = study.id
        record.patientBirthDate = study.dateOfBirth
        record.patientSex = study.patientSex
        record.referringPhysician = study.referringPhysician
        record.performingPhysician = study.performingPhysician
        record.institutionName = study.institutionName
        record.dateAdded = study.dateAdded
        record.imageCount = study.numberOfImages?.intValue ?? 0
        record.comments = comments(study)
        record.state = study.stateText?.intValue ?? 0
        record.report = study.reportURL.flatMap { $0.isEmpty ? nil : $0 }
        record.isLocked = study.lockedStudy?.boolValue ?? false
        return record
    }

    private static func seriesUID(_ series: DicomSeries) -> String? {
        series.seriesDICOMUID ?? series.seriesInstanceUID
    }

    private static func series(_ series: DicomSeries, study uid: String) -> IsiXSeries? {
        guard let seriesUID = seriesUID(series) else { return nil }
        var record = IsiXSeries(seriesInstanceUID: seriesUID, studyInstanceUID: uid,
                                seriesDescription: series.seriesDescription ?? series.name, modality: series.modality,
                                seriesNumber: series.id?.intValue, imageCount: series.numberOfImages?.intValue ?? 0)
        record.seriesDate = series.date
        record.sopClassUID = series.seriesSOPClassUID
        record.comments = comments(series)
        record.state = series.stateText?.intValue ?? 0
        return record
    }

    private static func series(_ series: DicomSeries) -> IsiXSeries? {
        guard let uid = series.study?.studyInstanceUID else { return nil }
        return Self.series(series, study: uid)
    }

    static func image(_ image: DicomImage) -> IsiXDatabaseImage? {
        guard let sop = image.sopInstanceUID(), let series = image.series, let seriesUID = seriesUID(series),
              let studyUID = series.study?.studyInstanceUID else { return nil }
        return IsiXDatabaseImage(sopInstanceUID: sop, seriesInstanceUID: seriesUID, studyInstanceUID: studyUID,
                                 instanceNumber: image.instanceNumber?.intValue, frame: image.frameID?.intValue ?? 0,
                                 numberOfFrames: max(image.numberOfFrames?.intValue ?? 1, 1),
                                 file: image.completePath().map { URL(fileURLWithPath: $0) }, modality: image.modality,
                                 columns: image.width()?.intValue ?? 0, rows: image.height()?.intValue ?? 0,
                                 sliceLocation: image.sliceLocation?.doubleValue, isKeyImage: image.isKeyImage()?.boolValue ?? false,
                                 comments: comments(image), date: image.date)
    }

    private static func album(_ album: DicomAlbum, studyCount: Int) -> IsiXAlbum {
        IsiXAlbum(name: album.name ?? "", isSmart: album.smartAlbum?.boolValue ?? false, studyCount: studyCount)
    }

    // MARK: fetching

    private func fetch(_ entity: String, _ predicate: NSPredicate) throws -> [NSManagedObject] {
        ((try database().objects(forEntity: entity, predicate: predicate) as NSArray?) ?? []).compactMap { $0 as? NSManagedObject }
    }

    private func fetchStudy(_ uid: String) throws -> DicomStudy? {
        try fetch(DicomDatabaseStudyEntityName, NSPredicate(format: "studyInstanceUID == %@", uid)).compactMap { $0 as? DicomStudy }.first
    }

    /// The database's series of this DICOM series: the database may have
    /// split one series in several.
    private func fetchSeries(_ uid: String) throws -> [DicomSeries] {
        try fetch(DicomDatabaseSeriesEntityName, NSPredicate(format: "seriesDICOMUID == %@ OR (seriesDICOMUID == nil AND seriesInstanceUID == %@)", uid, uid))
            .compactMap { $0 as? DicomSeries }
    }

    private func fetchImages(_ sop: String) throws -> [DicomImage] {
        guard let encoded = DicomImage.sopInstanceUIDEncode(sop) else { return [] }
        return try fetch(DicomDatabaseImageEntityName, NSPredicate(format: "compressedSopInstanceUID IN %@", [encoded] as NSArray))
            .compactMap { $0 as? DicomImage }.filter { $0.sopInstanceUID() == sop }
    }

    private static func sortedImages(_ images: [DicomImage]) -> [DicomImage] {
        images.sorted { ($0.instanceNumber?.intValue ?? 0, $0.frameID?.intValue ?? 0) < ($1.instanceNumber?.intValue ?? 0, $1.frameID?.intValue ?? 0) }
    }

    private func albumObjects() throws -> [DicomAlbum] {
        ((try database().albums() as NSArray?) ?? []).compactMap { $0 as? DicomAlbum }
    }

    private func album(named name: String) throws -> DicomAlbum {
        guard let album = try albumObjects().first(where: { $0.name == name }) else { throw IsiXPluginError.notFound("album named \(name)") }
        return album
    }

    private func studies(of album: DicomAlbum) throws -> [DicomStudy] {
        if album.smartAlbum?.boolValue ?? false {
            guard let predicate = DicomDatabase.predicate(forSmartAlbumFilter: album.predicateString) else { return [] }
            return try fetch(DicomDatabaseStudyEntityName, predicate).compactMap { $0 as? DicomStudy }
        }
        return ((album.studies as NSSet?)?.allObjects ?? []).compactMap { $0 as? DicomStudy }
    }

    /// The plugin API's error for a refusal of the database's rules.
    private static func refusal(_ error: any Error) -> any Error {
        switch error as? PluginDatabaseRefusal {
        case .invalid(let reason): return IsiXPluginError.invalidValue(reason)
        case .notFound(let what): return IsiXPluginError.notFound(what)
        case nil: return error
        }
    }

    /// Saves the main context; a failure is thrown.
    private func save(_ database: DicomDatabase) throws {
        var error: NSError?
        guard database.save(&error) else {
            throw IsiXPluginError.hostFailure("The database could not be saved: \(error?.localizedDescription ?? "unknown error").")
        }
    }

    /// Applies checked values to the objects, saving after each.
    private func apply(_ values: [String: Any?], to objects: [NSManagedObject]) throws {
        let database = try database()
        for object in objects {
            try PluginDatabaseEdits.apply(values, to: object) { try save(database) }
        }
    }

    // MARK: IsiXDatabaseBackend: reading

    func databaseSelection() throws -> IsiXDatabaseSelection {
        _ = try database()
        let selection = BrowserController.currentBrowser()?.databaseSelection() ?? []
        var studies: [IsiXStudy] = [], series: [IsiXSeries] = []
        for item in selection {
            if let study = item as? DicomStudy, let record = Self.study(study),
               !studies.contains(where: { $0.studyInstanceUID == record.studyInstanceUID }) {
                studies.append(record)
            } else if let item = item as? DicomSeries, let record = Self.series(item),
                      !series.contains(where: { $0.seriesInstanceUID == record.seriesInstanceUID }) {
                series.append(record)
            }
        }
        return IsiXDatabaseSelection(studies: studies, series: series)
    }

    func studies(matching query: IsiXStudyQuery) throws -> [IsiXStudy] {
        let search = PluginStudyQuery(studyInstanceUID: query.studyInstanceUID, patientID: query.patientID,
                                      patientName: query.patientName, accessionNumber: query.accessionNumber,
                                      studyDescription: query.studyDescription, modality: query.modality, comment: query.comment,
                                      dateFrom: query.studyDateFrom, dateTo: query.studyDateTo, state: query.state, limit: query.limit)
        let request: NSFetchRequest<NSManagedObject>
        do { request = try search.fetchRequest() } catch { throw Self.refusal(error) }
        guard let context = try database().managedObjectContext else { throw IsiXPluginError.noDatabase }
        do {
            return try context.fetch(request).compactMap { ($0 as? DicomStudy).flatMap(Self.study) }
        } catch {
            throw IsiXPluginError.hostFailure("The database could not be searched: \(error.localizedDescription)")
        }
    }

    func seriesRecords(inStudy studyInstanceUID: String) throws -> [IsiXSeries] {
        guard let study = try fetchStudy(studyInstanceUID) else { return [] }
        return ((study.series as NSSet?)?.allObjects ?? []).compactMap { $0 as? DicomSeries }
            .compactMap { Self.series($0, study: studyInstanceUID) }
            .sorted { ($0.seriesNumber ?? 0, $0.seriesInstanceUID) < ($1.seriesNumber ?? 0, $1.seriesInstanceUID) }
    }

    func seriesRecord(withInstanceUID uid: String) throws -> IsiXSeries? {
        try fetchSeries(uid).lazy.compactMap(Self.series).first
    }

    func images(inSeries seriesInstanceUID: String) throws -> [IsiXDatabaseImage] {
        let images = try fetchSeries(seriesInstanceUID).flatMap { (($0.images as NSSet?)?.allObjects ?? []).compactMap { $0 as? DicomImage } }
        return Self.sortedImages(images).compactMap(Self.image)
    }

    func images(withSOPInstanceUID uid: String) throws -> [IsiXDatabaseImage] {
        Self.sortedImages(try fetchImages(uid)).compactMap(Self.image)
    }

    func albums() throws -> [IsiXAlbum] {
        try albumObjects().map { Self.album($0, studyCount: try studies(of: $0).count) }
    }

    func studies(inAlbum name: String) throws -> [IsiXStudy] {
        try studies(of: album(named: name)).compactMap(Self.study)
            .sorted { ($0.studyDate ?? .distantPast, $0.studyInstanceUID) > ($1.studyDate ?? .distantPast, $1.studyInstanceUID) }
    }

    func openViewer(forSeries seriesInstanceUID: String) throws -> (any IsiXViewerBackend)? {
        guard let series = try fetchSeries(seriesInstanceUID).first else { throw IsiXPluginError.notFound("series \(seriesInstanceUID)") }
        guard let browser = BrowserController.currentBrowser() else { throw IsiXPluginError.noDatabase }
        guard let viewer = browser.loadSeries(series, nil, true, keyImagesOnly: false) else { return nil }
        let adapter = IsiXViewerAdapter(viewer: viewer, identities: identities)
        return adapter.isOpen ? adapter : nil
    }

    // MARK: IsiXDatabaseBackend: changing

    func updateStudy(_ studyInstanceUID: String, _ update: IsiXStudyUpdate) throws -> IsiXStudy {
        guard let study = try fetchStudy(studyInstanceUID) else { throw IsiXPluginError.notFound("study \(studyInstanceUID)") }
        let values: [String: Any?]
        do {
            values = try PluginDatabaseEdits.studyValues(comments: update.comments, state: update.state, report: update.report,
                                                         isLocked: update.isLocked)
        } catch { throw Self.refusal(error) }
        try apply(values, to: [study])
        guard let record = Self.study(study) else { throw IsiXPluginError.notFound("study \(studyInstanceUID)") }
        return record
    }

    func updateSeries(_ seriesInstanceUID: String, _ update: IsiXSeriesUpdate) throws -> IsiXSeries {
        let series = try fetchSeries(seriesInstanceUID)
        guard !series.isEmpty else { throw IsiXPluginError.notFound("series \(seriesInstanceUID)") }
        let values: [String: Any?]
        do { values = try PluginDatabaseEdits.seriesValues(comments: update.comments, state: update.state) } catch { throw Self.refusal(error) }
        try apply(values, to: series)
        guard let record = Self.series(series[0]) else { throw IsiXPluginError.notFound("series \(seriesInstanceUID)") }
        return record
    }

    func updateImage(_ sopInstanceUID: String, frame: Int, _ update: IsiXImageUpdate) throws -> IsiXDatabaseImage {
        guard let image = try fetchImages(sopInstanceUID).first(where: { ($0.frameID?.intValue ?? 0) == frame }) else {
            throw IsiXPluginError.notFound("image \(sopInstanceUID), frame \(frame)")
        }
        let values: [String: Any?]
        do { values = try PluginDatabaseEdits.imageValues(isKeyImage: update.isKeyImage, comments: update.comments) } catch {
            throw Self.refusal(error)
        }
        try apply(values, to: [image])
        guard let record = Self.image(image) else { throw IsiXPluginError.notFound("image \(sopInstanceUID)") }
        return record
    }

    func createAlbum(named name: String) throws -> IsiXAlbum {
        let database = try database()
        let existing = try albumObjects()
        let checked: String
        do { checked = try PluginAlbumRules.newAlbumName(name, existing: existing.compactMap(\.name)) } catch { throw Self.refusal(error) }
        guard let context = database.managedObjectContext,
              let album = NSEntityDescription.insertNewObject(forEntityName: DicomDatabaseAlbumEntityName, into: context) as? DicomAlbum else {
            throw IsiXPluginError.noDatabase
        }
        album.name = checked
        album.smartAlbum = NSNumber(value: false)
        album.index = NSNumber(value: existing.count)
        do {
            try save(database)
        } catch {
            context.delete(album)
            throw error
        }
        BrowserController.currentBrowser()?.refreshAlbums()
        return Self.album(album, studyCount: 0)
    }

    /// Adds or removes the studies, all of them or none.
    private func changeMembership(_ uids: [String], album name: String, add: Bool) throws {
        let database = try database()
        let album = try album(named: name)
        do { try PluginAlbumRules.checkMembershipChange(albumName: name, isSmart: album.smartAlbum?.boolValue ?? false) } catch {
            throw Self.refusal(error)
        }
        var studies: [DicomStudy] = []
        for uid in uids {
            guard let study = try fetchStudy(uid) else { throw IsiXPluginError.notFound("study \(uid)") }
            studies.append(study)
        }
        let before = Set(((album.studies as NSSet?)?.allObjects ?? []).compactMap { $0 as? DicomStudy })
        for study in studies {
            if add { album.addStudiesObject(study) } else { album.removeStudiesObject(study) }
        }
        do {
            try save(database)
        } catch {
            let now = Set(((album.studies as NSSet?)?.allObjects ?? []).compactMap { $0 as? DicomStudy })
            for study in now.subtracting(before) { album.removeStudiesObject(study) }
            for study in before.subtracting(now) { album.addStudiesObject(study) }
            throw error
        }
        BrowserController.currentBrowser()?.refreshAlbums()
    }

    func addStudies(_ studyInstanceUIDs: [String], toAlbum name: String) throws {
        try changeMembership(studyInstanceUIDs, album: name, add: true)
    }

    func removeStudies(_ studyInstanceUIDs: [String], fromAlbum name: String) throws {
        try changeMembership(studyInstanceUIDs, album: name, add: false)
    }

    // MARK: importing and derived series

    /// Copies each file into the database's data folder under a new name,
    /// then indexes the copies. The plugin's files are only read.
    func importFilesNow(at urls: [URL]) throws -> IsiXImportResult {
        let database = try database()
        var copies: [String] = []
        var sources: [String: URL] = [:]
        var failures: [IsiXImportResult.Failure] = []
        for url in urls {
            guard let destination = database.uniquePathForNewDataFile(withExtension: "dcm") else {
                failures.append(.init(file: url, reason: "The database has no room for a new file."))
                continue
            }
            do {
                try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: destination))
                copies.append(destination)
                sources[destination] = url
            } catch {
                failures.append(.init(file: url, reason: error.localizedDescription))
            }
        }
        let objectIDs = copies.isEmpty ? [] : database.addFiles(atPaths: copies, postNotifications: true, dicomOnly: true,
                                                                  rereadExistingItems: true, generatedByOsiriX: true,
                                                                  importedFiles: true, returnArray: true) ?? []
        var studyUIDs: [String] = [], seriesUIDs: [String] = []
        var indexed = Set<String>()
        var images: [IsiXDatabaseImage] = []
        for objectID in objectIDs {
            guard let image = database.object(withID: objectID) as? DicomImage else { continue }
            if let path = image.completePath() { indexed.insert(path) }
            if let record = Self.image(image) { images.append(record) }
            if let series = image.series, let uid = Self.seriesUID(series), !seriesUIDs.contains(uid) {
                seriesUIDs.append(uid)
            }
            if let uid = image.series?.study?.studyInstanceUID, !studyUIDs.contains(uid) {
                studyUIDs.append(uid)
            }
        }
        var imported: [URL] = []
        for copy in copies {
            guard let source = sources[copy] else { continue }
            if !indexed.contains(copy) {
                failures.append(.init(file: source, reason: "The file was not indexed: it is not a DICOM file the database accepts."))
                try? FileManager.default.removeItem(atPath: copy)
            } else {
                imported.append(source)
            }
        }
        var result = IsiXImportResult(importedFiles: imported, studyInstanceUIDs: studyUIDs, seriesInstanceUIDs: seriesUIDs, failures: failures)
        result.images = images
        return result
    }

    /// Writes the images with the application's DICOM writer, which copies
    /// the patient and study attributes of a file of the study, as a new
    /// series of secondary captures in a new temporary folder.
    func writeDerivedSeriesNow(_ request: IsiXDerivedSeriesRequest) throws -> [URL] {
        guard let study = try fetchStudy(request.studyInstanceUID) else {
            throw IsiXPluginError.notFound("study \(request.studyInstanceUID)")
        }
        let source: String
        if let sop = request.sourceSOPInstanceUID {
            guard let image = try fetchImages(sop).first, let path = image.completePath(), FileManager.default.fileExists(atPath: path) else {
                throw IsiXPluginError.notFound("image \(sop)")
            }
            guard image.series?.study?.studyInstanceUID == request.studyInstanceUID else {
                throw IsiXPluginError.invalidValue("The image \(sop) is not of the study \(request.studyInstanceUID).")
            }
            source = path
        } else {
            let images = ((study.series as NSSet?)?.allObjects ?? []).compactMap { $0 as? DicomSeries }
                .flatMap { (($0.images as NSSet?)?.allObjects ?? []).compactMap { $0 as? DicomImage } }
            guard let found = images.lazy.compactMap({ $0.completePath() }).first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                throw IsiXPluginError.hostFailure("The study has no image file to take the patient and study from.")
            }
            source = found
        }
        for image in request.images {
            switch image {
            case .rgba8(let buffer) where buffer.channels == 4: continue
            case .float32(let buffer) where buffer.channels == 1: continue
            default: throw IsiXPluginError.invalidValue("A derived image is either colour (rgba8) or grayscale (float32, one channel).")
            }
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("IsiX Plugin Files", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let exporter = DICOMExport()
        exporter.setSourceFile(source)
        exporter.setSeriesDescription(request.seriesDescription)
        let now = Calendar.current.dateComponents([.minute, .second], from: Date())
        exporter.beginSeries(withNumber: request.seriesNumber ?? (86532 + (now.minute ?? 0) + (now.second ?? 0)))
        if let uid = request.seriesInstanceUID { exporter.horos_seriesUID = uid }
        exporter.horos_instanceNumber = Int32(clamping: request.firstInstanceNumber)
        if let level = request.windowLevel { exporter.setDefaultWWWL(Int(level.width.rounded()), Int(level.center.rounded())) }
        var files: [URL] = []
        for (index, image) in request.images.enumerated() {
            if let geometry = request.geometries?[index] {
                exporter.setPixelSpacing(Float(geometry.columnSpacing), Float(geometry.rowSpacing))
                exporter.setSliceThickness(geometry.sliceThickness)
                var orientation = geometry.imageOrientation.map(Float.init)
                var position = [geometry.imagePosition.x, geometry.imagePosition.y, geometry.imagePosition.z].map(Float.init)
                exporter.setOrientation(&orientation)
                exporter.setPosition(&position)
                exporter.setSlicePosition(Float(geometry.sliceLocation))
            }
            let path = folder.appendingPathComponent(String(format: "image-%04d.dcm", index + 1)).path
            let written: String?
            switch image {
            case .rgba8(let buffer):
                // The writer reads the samples while it writes: both inside the closure.
                written = buffer.withUnsafeBufferPointer { samples in
                    guard let base = samples.baseAddress else { return nil }
                    _ = exporter.setPixelData(UnsafeMutablePointer(mutating: base), samplesPerPixel: 4, bitsPerSample: 8,
                                              width: buffer.width, height: buffer.height)
                    exporter.setSlope(1)
                    return exporter.writeDCMFile(path)
                }
            case .float32(let buffer):
                // The writer writes the slope with six decimals: the samples are those of that slope.
                let encoded = DerivedImageEncoding.signed16(buffer.samples, slopeDecimals: 6)
                var samples = encoded.samples
                written = samples.withUnsafeMutableBytes { bytes in
                    guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
                    _ = exporter.setPixelData(base, samplesPerPixel: 1, bitsPerSample: 16, width: buffer.width, height: buffer.height)
                    // Setting the pixels makes them unsigned with an offset of -1024: signed, intercept 0, after it.
                    exporter.setSigned(true)
                    exporter.setSlope(Float(encoded.slope))
                    return exporter.writeDCMFile(path)
                }
            @unknown default:
                written = nil
            }
            guard let written else {
                throw IsiXPluginError.hostFailure("Image \(index + 1) could not be written as a DICOM file.")
            }
            files.append(URL(fileURLWithPath: written))
        }
        return files
    }

    // MARK: IsiXHostBackend: the asynchronous forms

    func selectedStudies() async throws -> [IsiXStudy] {
        let selection = try databaseSelection()
        var studies = selection.studies
        for series in selection.series where !studies.contains(where: { $0.studyInstanceUID == series.studyInstanceUID }) {
            if let study = try fetchStudy(series.studyInstanceUID).flatMap(Self.study) { studies.append(study) }
        }
        return studies
    }

    func study(withInstanceUID uid: String) async throws -> IsiXStudy? {
        try fetchStudy(uid).flatMap(Self.study)
    }

    func series(inStudy studyInstanceUID: String) async throws -> [IsiXSeries] {
        try seriesRecords(inStudy: studyInstanceUID)
    }

    func importFiles(at urls: [URL]) async throws -> IsiXImportResult {
        try importFilesNow(at: urls)
    }

    func writeDerivedSeries(_ request: IsiXDerivedSeriesRequest) async throws -> [URL] {
        try writeDerivedSeriesNow(request)
    }
}
