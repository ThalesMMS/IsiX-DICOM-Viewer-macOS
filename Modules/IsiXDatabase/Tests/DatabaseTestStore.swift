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

/// The study, series and image entities of the database, with the attributes
/// and relationships the reparse and the merge of series read and write, in
/// an in-memory store.
func makeDatabaseContext() throws -> NSManagedObjectContext {
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
    let study = NSEntityDescription(), series = NSEntityDescription(), image = NSEntityDescription()
    study.name = "Study"; series.name = "Series"; image.name = "Image"
    let studySeries = relationship("series", to: series, many: true), seriesStudy = relationship("study", to: study, many: false)
    let seriesImages = relationship("images", to: image, many: true), imageSeries = relationship("series", to: series, many: false)
    studySeries.inverseRelationship = seriesStudy; seriesStudy.inverseRelationship = studySeries
    seriesImages.inverseRelationship = imageSeries; imageSeries.inverseRelationship = seriesImages
    study.properties = [attribute("name", .stringAttributeType), studySeries]
    series.properties = [attribute("seriesInstanceUID", .stringAttributeType), attribute("name", .stringAttributeType),
                         attribute("numberOfImages", .integer32AttributeType), attribute("thumbnail", .binaryDataAttributeType),
                         seriesStudy, seriesImages]
    image.properties = [attribute("instanceNumber", .integer32AttributeType), attribute("pathString", .stringAttributeType),
                        attribute("extension", .stringAttributeType), imageSeries]
    let model = NSManagedObjectModel()
    model.entities = [study, series, image]
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    return context
}

/// Every object of an entity in the store.
func fetch(_ entity: String, in context: NSManagedObjectContext) throws -> [NSManagedObject] {
    try context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity))
}
