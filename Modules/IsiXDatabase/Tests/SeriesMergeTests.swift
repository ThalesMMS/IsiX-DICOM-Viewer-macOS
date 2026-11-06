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

/// A series of `count` images of `study`, whose files have `fileExtension`.
private func addSeries(_ name: String, _ count: Int, fileExtension: String, to study: NSManagedObject,
                       in context: NSManagedObjectContext) -> (series: NSManagedObject, images: [NSManagedObject]) {
    let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
    series.setValue(name, forKey: "name")
    series.setValue(NSNumber(value: count), forKey: "numberOfImages")
    series.setValue(study, forKey: "study")
    let images = (1...count).map { number -> NSManagedObject in
        let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
        image.setValue(NSNumber(value: number), forKey: "instanceNumber")
        image.setValue(fileExtension, forKey: "extension")
        image.setValue(series, forKey: "series")
        return image
    }
    return (series, images)
}

private func images(of series: NSManagedObject) -> Set<NSManagedObject> {
    (series.value(forKey: "images") as? Set<NSManagedObject>) ?? []
}

@Suite @MainActor struct SeriesMergeTests {

    @Test func anImageStandsForItsSeriesAsTheDestination() throws {
        let context = try makeDatabaseContext()
        let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
        let a = addSeries("A", 3, fileExtension: "dcm", to: study, in: context)
        let b = addSeries("B", 2, fileExtension: "jpg", to: study, in: context)

        // An image of A first, then series B, whose files are not DICOM: the
        // destination is A, the series the image stands for.
        #expect(SeriesMerge.destination(of: [a.images[0], b.series]) === a.series)
        // Only images, as when the thumbnails show a series' images.
        #expect(SeriesMerge.destination(of: [a.images[1], a.images[2]]) === a.series)
        // No DICOM candidate: the series of the first row.
        #expect(SeriesMerge.destination(of: [b.images[0], b.series]) === b.series)
        // The last DICOM candidate wins, an image's series included.
        let c = addSeries("C", 1, fileExtension: "dcm", to: study, in: context)
        #expect(SeriesMerge.destination(of: [c.series, a.images[0]]) === a.series)
        #expect(SeriesMerge.destination(of: [a.images[0], c.series]) === c.series)
        #expect(SeriesMerge.destination(of: []) == nil)
    }

    @Test func mergingIntoAnImagesSeriesMovesTheImagesAndDeletesTheOthers() throws {
        let context = try makeDatabaseContext()
        let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
        let a = addSeries("A", 3, fileExtension: "dcm", to: study, in: context)
        let b = addSeries("B", 2, fileExtension: "jpg", to: study, in: context)
        try context.save()

        let rows = [a.images[0], b.series]
        let destination = try #require(SeriesMerge.destination(of: rows))
        SeriesMerge.merge(rows, into: destination, in: context)
        try context.save()

        #expect(destination === a.series)
        #expect(images(of: a.series) == Set(a.images + b.images))
        #expect(b.series.isDeleted || b.series.managedObjectContext == nil)
        #expect(try fetch("Series", in: context) == [a.series])
        #expect(try fetch("Image", in: context).count == 5)
        #expect((a.series.value(forKey: "numberOfImages") as? NSNumber)?.intValue == 0)
    }

    @Test func eachSeriesMergesOnceAndAStudyRowMergesNothing() throws {
        let context = try makeDatabaseContext()
        let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
        let other = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
        let a = addSeries("A", 2, fileExtension: "dcm", to: study, in: context)
        let b = addSeries("B", 2, fileExtension: "dcm", to: study, in: context)
        let kept = addSeries("Kept", 1, fileExtension: "dcm", to: other, in: context)
        try context.save()

        // B twice (the series and one of its images) and a study row.
        let rows = [b.series, b.images[1], other, a.series]
        let destination = try #require(SeriesMerge.destination(of: rows))
        #expect(destination === a.series)
        SeriesMerge.merge(rows, into: destination, in: context)
        try context.save()

        #expect(images(of: a.series) == Set(a.images + b.images))
        #expect(Set(try fetch("Series", in: context)) == [a.series, kept.series])
        #expect(images(of: kept.series) == Set(kept.images))
    }
}
