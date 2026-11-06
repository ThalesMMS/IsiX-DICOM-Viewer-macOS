//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Synthetic metadata-only Core Data fixture for database sorting, not image viewing.
// Usage: swift tools/generate-date-sort-database.swift MODEL.mom NEW-Database.sql [search-albums]
//
// With "search-albums", the 20,000 studies have varied names (accents
// included), patient IDs, accession numbers, descriptions, comments,
// modalities and dates spread from now back over two years, two studies per
// patient, and the database has regular and smart albums: a fixture for the
// browser's search, time interval and albums. It is deterministic but for the
// dates, which count back from the moment it runs.
import Foundation
import CoreData

let variant = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : nil
guard CommandLine.arguments.count == 3 || variant == "search-albums" else { fatalError("Expected model and new database paths") }
let target = URL(fileURLWithPath: CommandLine.arguments[2])
guard !FileManager.default.fileExists(atPath: target.path) else { fatalError("Destination must not exist") }
let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let hashes = model.entityVersionHashesByName
for entity in model.entities { entity.managedObjectClassName = "NSManagedObject" }
precondition(hashes == model.entityVersionHashesByName, "Fixture must preserve model compatibility")
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: target,
                                  options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]])
let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator
context.undoManager = nil

func searchAndAlbums() {
    let families = ["SILVA", "SOUZA", "M\u{00DC}LLER", "MULLER", "\u{017B}\u{00D3}\u{0141}W", "ZOLW", "O'NEILL", "NGUYEN",
                    "GARC\u{00CD}A", "SMITH", "JOHNSON", "TANAKA", "DUBOIS", "ROSSI", "KOWALSKI", "SANTOS"]
    let givens = ["ANA", "JOAO", "MARIA", "PEDRO", "JULIA", "LUCAS", "SOFIA", "MIGUEL", "ANNE", "PAUL", "YUKI", "OLGA"]
    let modalities = ["CT", "MR", "US", "CR", "PT\\CT", "MR", "CT", "DX", "MG", "NM"]
    let descriptions = ["CHEST", "HEAD WITHOUT CONTRAST", "ABDOMEN", "KNEE LEFT", "PELVIS", "SPINE LUMBAR", "BRAIN PERFUSION",
                        "THORAX FOLLOW-UP"]
    let now = Date()
    var studies: [NSManagedObject] = []
    for i in 0..<20_000 {
        let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
        let patient = i / 2
        let name = families[patient % families.count] + "^" + givens[(patient / families.count) % givens.count]
            + String(format: "%03d", patient % 997)
        // Hours back from now: a fifth within two days, the others over two years.
        let hours = i % 5 == 0 ? Double((i * 7) % 48) + 0.5 : Double((i * 37) % 17_520) + 0.5
        let date = now.addingTimeInterval(-hours * 3600)
        for (key, value) in ["name": name, "patientID": String(format: "SYN-%06d", patient),
                             "patientUID": String(format: "SYN-%06d", patient) + name,
                             "studyInstanceUID": "1.2.826.0.1.3680043.10.543.418.\(i+1)",
                             "studyName": descriptions[i % descriptions.count], "modality": modalities[i % modalities.count],
                             "accessionNumber": String(format: "ACC%07d", i * 3), "id": String(format: "S%05d", i),
                             "comment": i % 9 == 0 ? "follow-up \(i % 4)" : "",
                             "institutionName": i % 2 == 0 ? "SYNTHETIC CLINIC" : "SYNTHETIC HOSPITAL",
                             "referringPhysician": "DR^" + givens[i % givens.count]] {
            study.setValue(value, forKey: key)
        }
        study.setValue(false, forKey: "expanded")
        study.setValue(1, forKey: "numberOfImages")
        study.setValue(true, forKey: "hasDICOM")
        study.setValue(date, forKey: "date")
        study.setValue(date, forKey: "dateAdded")
        let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
        series.setValue(study, forKey: "study")
        series.setValue(descriptions[(i + 3) % descriptions.count], forKey: "name")
        series.setValue(modalities[i % modalities.count], forKey: "modality")
        series.setValue("1.2.826.0.1.3680043.10.543.418.\(i+1).1", forKey: "seriesDICOMUID")
        series.setValue(1, forKey: "id")
        series.setValue(1, forKey: "numberOfImages")
        series.setValue(date, forKey: "date")
        studies.append(study)
    }
    for (name, step) in [("Synthetic every 7th", 7), ("Synthetic every 13th", 13)] {
        let album = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context)
        album.setValue(name, forKey: "name")
        album.setValue(false, forKey: "smartAlbum")
        album.mutableSetValue(forKey: "studies").addObjects(from: stride(from: 0, to: studies.count, by: step).map { studies[$0] })
    }
    for (name, format) in [("Synthetic CT", "modality CONTAINS[cd] \"CT\""),
                           ("Synthetic last week", "date >= CAST($WEEK, \"NSDate\")"),
                           ("Synthetic today", "date >= $NSDATE_TODAY"),
                           ("Synthetic SILVA or MR", "name BEGINSWITH[cd] \"SILVA\" OR modality == \"MR\"")] {
        let album = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context)
        album.setValue(name, forKey: "name")
        album.setValue(true, forKey: "smartAlbum")
        album.setValue(format, forKey: "predicateString")
    }
}

func dateSorting() throws {
    let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    for i in 0..<20_000 {
        let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
        let identifier = String(format: "LOCAL-SORT-%05d", i)
        for (key, value) in ["name": identifier, "patientID": identifier, "patientUID": identifier,
                             "studyInstanceUID": "1.2.826.0.1.3680043.10.543.62.\(i+1)",
                             "studyName": "Synthetic date sorting", "modality": "MR"] {
            study.setValue(value, forKey: key)
        }
        study.setValue(false, forKey: "expanded")
        study.setValue(10, forKey: "numberOfImages")
        study.setValue(true, forKey: "hasDICOM")
        // Five thousand missing dates; fifteen thousand repeated across three days.
        let acquisition: Date? = i % 4 == 0 ? nil : date.addingTimeInterval(Double(i % 4) * 86400)
        study.setValue(acquisition, forKey: "date")
        study.setValue(date, forKey: "dateAdded")
        let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
        series.setValue(study, forKey: "study")
        series.setValue("Synthetic metadata only", forKey: "name")
        series.setValue("MR", forKey: "modality")
        series.setValue("1.2.826.0.1.3680043.10.543.62.\(i+1).1", forKey: "seriesDICOMUID")
        series.setValue(1, forKey: "id")
        series.setValue(10, forKey: "numberOfImages")
        series.setValue(acquisition, forKey: "date")
        for j in 0..<10 {
            let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
            image.setValue(series, forKey: "series")
            image.setValue(j+1, forKey: "instanceNumber")
            image.setValue(acquisition, forKey: "date")
            image.setValue("MR", forKey: "storedModality")
            image.setValue(1, forKey: "storedNumberOfFrames")
            image.setValue("dcm", forKey: "storedExtension")
        }
        if i % 200 == 199 { try context.save(); context.reset() }
    }
}

if variant == "search-albums" {
    searchAndAlbums()
} else {
    try dateSorting()
}
try context.save()
for entity in ["Study", "Series", "Image", "Album"] {
    print("\(entity)=\(try context.count(for: NSFetchRequest(entityName: entity)))")
}
