//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreData
import Foundation
import Testing
@testable import IsiXDatabase

/// An image whose key-image flag is set through `isKeyImage` and stored in
/// `storedIsKeyImage`, as the database's image is.
@objc(PluginAccessTestImage)
final class PluginAccessTestImage: NSManagedObject {
    @objc var isKeyImage: NSNumber? {
        get { value(forKey: "storedIsKeyImage") as? NSNumber }
        set { setValue(newValue, forKey: "storedIsKeyImage") }
    }
}

/// A SQLite store with the attributes of the database's Study, Series,
/// Image and Album entities that plugins read, search and change.
final class PluginAccessStore {
    let folder: URL
    let model: NSManagedObjectModel
    let context: NSManagedObjectContext

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model = Self.makeModel()
        context = try Self.open(model: model, at: folder)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    static func open(model: NSManagedObjectModel, at folder: URL) throws -> NSManagedObjectContext {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                           at: folder.appendingPathComponent("Database.sql"), options: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    /// A second context on the same file, as the next launch would see it.
    func reopened() throws -> NSManagedObjectContext { try Self.open(model: model, at: folder) }

    static func makeModel() -> NSManagedObjectModel {
        func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let made = NSAttributeDescription()
            made.name = name
            made.attributeType = type
            made.isOptional = true
            return made
        }
        func relationship(_ name: String, to destination: NSEntityDescription, many: Bool) -> NSRelationshipDescription {
            let made = NSRelationshipDescription()
            made.name = name
            made.destinationEntity = destination
            made.minCount = 0
            made.maxCount = many ? 0 : 1
            made.isOptional = true
            made.deleteRule = .nullifyDeleteRule
            return made
        }
        let comments = PluginDatabaseEdits.commentKeys
        let study = NSEntityDescription(), series = NSEntityDescription(), image = NSEntityDescription(), album = NSEntityDescription()
        study.name = "Study"; series.name = "Series"; image.name = "Image"; album.name = "Album"
        image.managedObjectClassName = "PluginAccessTestImage"
        let studySeries = relationship("series", to: series, many: true), seriesStudy = relationship("study", to: study, many: false)
        let seriesImages = relationship("images", to: image, many: true), imageSeries = relationship("series", to: series, many: false)
        let studyAlbums = relationship("albums", to: album, many: true), albumStudies = relationship("studies", to: study, many: true)
        studySeries.inverseRelationship = seriesStudy; seriesStudy.inverseRelationship = studySeries
        seriesImages.inverseRelationship = imageSeries; imageSeries.inverseRelationship = seriesImages
        studyAlbums.inverseRelationship = albumStudies; albumStudies.inverseRelationship = studyAlbums
        study.properties = ["name", "patientID", "accessionNumber", "studyName", "studyInstanceUID", "reportURL"]
            .map { attribute($0, .stringAttributeType) } + comments.map { attribute($0, .stringAttributeType) }
            + [attribute("date", .dateAttributeType), attribute("stateText", .integer32AttributeType),
               attribute("lockedStudy", .booleanAttributeType), studySeries, studyAlbums]
        series.properties = [attribute("seriesInstanceUID", .stringAttributeType), attribute("modality", .stringAttributeType),
                             attribute("stateText", .integer32AttributeType)] + comments.map { attribute($0, .stringAttributeType) }
            + [seriesStudy, seriesImages]
        image.properties = [attribute("instanceNumber", .integer32AttributeType), attribute("storedIsKeyImage", .booleanAttributeType)]
            + comments.map { attribute($0, .stringAttributeType) } + [imageSeries]
        album.properties = [attribute("name", .stringAttributeType), attribute("smartAlbum", .booleanAttributeType), albumStudies]
        let model = NSManagedObjectModel()
        model.entities = [study, series, image, album]
        return model
    }

    @discardableResult
    func study(_ uid: String, name: String, date: Date, modalities: [String] = ["CT"], comment: String? = nil) -> NSManagedObject {
        let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
        study.setValue(uid, forKey: "studyInstanceUID")
        study.setValue(name, forKey: "name")
        study.setValue(date, forKey: "date")
        study.setValue(comment, forKey: "comment")
        study.setValue("ID-\(uid)", forKey: "patientID")
        for (index, modality) in modalities.enumerated() {
            let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
            series.setValue("\(uid).\(index + 1)", forKey: "seriesInstanceUID")
            series.setValue(modality, forKey: "modality")
            series.setValue(study, forKey: "study")
            let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
            image.setValue(1, forKey: "instanceNumber")
            image.setValue(series, forKey: "series")
        }
        return study
    }

    func fetch(_ entity: String, in context: NSManagedObjectContext? = nil, _ format: String? = nil, _ arguments: Any...) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        if let format { request.predicate = NSPredicate(format: format, argumentArray: arguments) }
        return try (context ?? self.context).fetch(request)
    }
}

private struct SaveFailure: Error {}

@Suite struct PluginDatabaseEditsTests {

    @Test func refusedValuesChangeNothing() throws {
        let store = try PluginAccessStore()
        let study = store.study("1.2.1", name: "DOE^JANE", date: Date(timeIntervalSince1970: 0), comment: "first")
        try store.context.save()

        // Each refusal comes before anything is changed.
        let refusals: [(() throws -> [String: Any?], String)] = [
            ({ try PluginDatabaseEdits.studyValues(comments: [0: "kept"], state: 9, report: nil, isLocked: nil) }, "state 9"),
            ({ try PluginDatabaseEdits.studyValues(comments: [4: "x"], state: nil, report: nil, isLocked: nil) }, "field 5"),
            ({ try PluginDatabaseEdits.studyValues(comments: [0: String(repeating: "a", count: 10241)], state: nil, report: nil, isLocked: nil) }, "long"),
            ({ try PluginDatabaseEdits.studyValues(comments: [0: "a\u{0}b"], state: nil, report: nil, isLocked: nil) }, "null"),
            ({ try PluginDatabaseEdits.studyValues(comments: [:], state: -1, report: nil, isLocked: nil) }, "state -1"),
            ({ try PluginDatabaseEdits.studyValues(comments: [:], state: nil, report: "report.pdf", isLocked: nil, fileExists: { _ in true }) }, "relative"),
            ({ try PluginDatabaseEdits.studyValues(comments: [:], state: nil, report: "/no/such/file", isLocked: nil, fileExists: { _ in false }) }, "missing"),
            ({ try PluginDatabaseEdits.studyValues(comments: [:], state: nil, report: "http://", isLocked: nil) }, "no host"),
            ({ try PluginDatabaseEdits.seriesValues(comments: [-1: "x"], state: nil) }, "series field 0"),
        ]
        for (make, label) in refusals {
            #expect(throws: PluginDatabaseRefusal.self, "\(label)") { _ = try make() }
        }
        #expect(!store.context.hasChanges)
        #expect(study.value(forKey: "comment") as? String == "first")
        let reread = try store.fetch("Study", in: store.reopened())
        #expect(reread.count == 1 && reread[0].value(forKey: "comment") as? String == "first")
        #expect(reread[0].value(forKey: "stateText") == nil)
    }

    @Test func acceptedValuesAreSavedAndReadBack() throws {
        let store = try PluginAccessStore()
        let report = store.folder.appendingPathComponent("report.pdf")
        try Data("%PDF".utf8).write(to: report)
        let study = store.study("1.2.2", name: "ROE^RICHARD", date: Date(timeIntervalSince1970: 0), comment: "old")
        try store.context.save()

        let values = try PluginDatabaseEdits.studyValues(comments: [0: "", 1: "second"], state: 2, report: report.path, isLocked: true)
        try PluginDatabaseEdits.apply(values, to: study) { try store.context.save() }
        let reread = try store.fetch("Study", in: store.reopened())[0]
        #expect(reread.value(forKey: "comment") == nil)
        #expect(reread.value(forKey: "comment2") as? String == "second")
        #expect((reread.value(forKey: "stateText") as? NSNumber)?.intValue == 2)
        #expect(reread.value(forKey: "reportURL") as? String == report.path)
        #expect((reread.value(forKey: "lockedStudy") as? NSNumber)?.boolValue == true)

        // A web address is a report too, and an empty text removes it.
        try PluginDatabaseEdits.apply(try PluginDatabaseEdits.studyValues(comments: [:], state: nil, report: "https://example.org/r?id=1", isLocked: nil), to: study) { try store.context.save() }
        #expect(study.value(forKey: "reportURL") as? String == "https://example.org/r?id=1")
        try PluginDatabaseEdits.apply(try PluginDatabaseEdits.studyValues(comments: [:], state: nil, report: "", isLocked: nil), to: study) { try store.context.save() }
        #expect(try store.fetch("Study", in: store.reopened())[0].value(forKey: "reportURL") == nil)

        let image = try store.fetch("Image")[0]
        try PluginDatabaseEdits.apply(try PluginDatabaseEdits.imageValues(isKeyImage: true, comments: [3: "four"]), to: image) { try store.context.save() }
        let rereadImage = try store.fetch("Image", in: store.reopened())[0]
        #expect((rereadImage.value(forKey: "storedIsKeyImage") as? NSNumber)?.boolValue == true)
        #expect(rereadImage.value(forKey: "comment4") as? String == "four")
    }

    @Test func aFailedSaveRestoresTheObjectAndLeavesOtherChanges() throws {
        let store = try PluginAccessStore()
        let study = store.study("1.2.3", name: "POE^EDGAR", date: Date(timeIntervalSince1970: 0), comment: "before")
        let other = store.study("1.2.4", name: "OTHER", date: Date(timeIntervalSince1970: 0))
        try store.context.save()
        // An unsaved change the user made elsewhere in the window.
        other.setValue("user's unsaved", forKey: "comment")

        let values = try PluginDatabaseEdits.studyValues(comments: [0: "after"], state: 3, report: nil, isLocked: nil)
        #expect(throws: SaveFailure.self) {
            try PluginDatabaseEdits.apply(values, to: study) { throw SaveFailure() }
        }
        #expect(study.value(forKey: "comment") as? String == "before")
        #expect(study.value(forKey: "stateText") == nil)
        #expect(other.value(forKey: "comment") as? String == "user's unsaved")
        // The file still has the values from before.
        let reread = try store.fetch("Study", in: store.reopened(), "studyInstanceUID == %@", "1.2.3")[0]
        #expect(reread.value(forKey: "comment") as? String == "before")
    }
}

@Suite struct PluginStudyQueryTests {

    @Test func criteriaSelectTheStudiesNewestFirst() throws {
        let store = try PluginAccessStore()
        let day: TimeInterval = 86400
        store.study("1.3.1", name: "Müller^Anna", date: Date(timeIntervalSince1970: 10 * day), modalities: ["CT", "SR"], comment: "follow-up")
        store.study("1.3.2", name: "MULLER^BEN", date: Date(timeIntervalSince1970: 20 * day), modalities: ["MR"])
        store.study("1.3.3", name: "SMITH^CAROL", date: Date(timeIntervalSince1970: 30 * day), modalities: ["ct"])
        try store.context.save()

        func uids(_ query: PluginStudyQuery) throws -> [String] {
            try store.context.fetch(query.fetchRequest()).map { $0.value(forKey: "studyInstanceUID") as! String }
        }
        #expect(try uids(PluginStudyQuery()) == ["1.3.3", "1.3.2", "1.3.1"])
        #expect(try uids(PluginStudyQuery(patientName: "muller")) == ["1.3.2", "1.3.1"])
        #expect(try uids(PluginStudyQuery(modality: "CT")) == ["1.3.3", "1.3.1"])
        #expect(try uids(PluginStudyQuery(comment: "FOLLOW")) == ["1.3.1"])
        #expect(try uids(PluginStudyQuery(studyInstanceUID: "1.3.2")) == ["1.3.2"])
        #expect(try uids(PluginStudyQuery(patientID: "ID-1.3.3")) == ["1.3.3"])
        #expect(try uids(PluginStudyQuery(dateFrom: Date(timeIntervalSince1970: 15 * day), dateTo: Date(timeIntervalSince1970: 25 * day))) == ["1.3.2"])
        #expect(try uids(PluginStudyQuery(patientName: "u", limit: 1)) == ["1.3.2"])
        #expect(try uids(PluginStudyQuery(state: 0)).count == 3)
        #expect(try uids(PluginStudyQuery(state: 2)).isEmpty)
        #expect(throws: PluginDatabaseRefusal.self) { _ = try PluginStudyQuery(limit: -1).predicate() }
        #expect(throws: PluginDatabaseRefusal.self) {
            _ = try PluginStudyQuery(dateFrom: Date(timeIntervalSince1970: 2), dateTo: Date(timeIntervalSince1970: 1)).predicate()
        }
    }
}

@Suite struct PluginAlbumRulesTests {

    @Test func names() throws {
        #expect(try PluginAlbumRules.newAlbumName("  Teaching ", existing: ["Other"]) == "Teaching")
        #expect(throws: PluginDatabaseRefusal.self) { _ = try PluginAlbumRules.newAlbumName("   ", existing: []) }
        #expect(throws: PluginDatabaseRefusal.self) { _ = try PluginAlbumRules.newAlbumName("Teaching", existing: ["Teaching"]) }
        #expect(throws: PluginDatabaseRefusal.self) { _ = try PluginAlbumRules.newAlbumName("a\nb", existing: []) }
        #expect(throws: PluginDatabaseRefusal.self) {
            _ = try PluginAlbumRules.newAlbumName(String(repeating: "x", count: 129), existing: [])
        }
    }

    @Test func smartAlbumsKeepTheirStudies() throws {
        #expect(throws: PluginDatabaseRefusal.self) { try PluginAlbumRules.checkMembershipChange(albumName: "Today", isSmart: true) }
        try PluginAlbumRules.checkMembershipChange(albumName: "Mine", isSmart: false)
    }
}
