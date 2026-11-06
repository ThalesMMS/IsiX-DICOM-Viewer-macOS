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

/// A study with one series of `count` images, numbered from 1.
private func makeSeries(_ count: Int, in context: NSManagedObjectContext) -> (study: NSManagedObject, series: NSManagedObject, images: [NSManagedObject]) {
    let study = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
    study.setValue("Study", forKey: "name")
    let series = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
    series.setValue("1.2.3", forKey: "seriesInstanceUID")
    series.setValue("T1 dynamic", forKey: "name")
    series.setValue(NSNumber(value: count), forKey: "numberOfImages")
    series.setValue(Data([1, 2, 3]), forKey: "thumbnail")
    series.setValue(study, forKey: "study")
    let images = (1...count).map { number -> NSManagedObject in
        let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
        image.setValue(NSNumber(value: number), forKey: "instanceNumber")
        image.setValue("\(number).dcm", forKey: "pathString")
        image.setValue(series, forKey: "series")
        return image
    }
    return (study, series, images)
}

@Suite @MainActor struct SeriesReparseTests {

    @Test func reparseIn3DMakesOneSeriesPerGroupAndDeletesTheOriginal() throws {
        let context = try makeDatabaseContext()
        let (study, original, images) = makeSeries(6, in: context)
        // Three sub-series of two images each, as "Reparse in 3D" hands them.
        let groups = [Array(images[0..<2]), Array(images[2..<4]), Array(images[4..<6])]
        let made = SeriesReparse.write(groups: groups, seriesOf: groups.last?.last, in: context)
        try context.save()

        #expect(made.count == 3)
        #expect(made.map { $0.value(forKey: "seriesInstanceUID") as? String } == ["1.2.3RP-1", "1.2.3RP-2", "1.2.3RP-3"])
        for (series, group) in zip(made, groups) {
            #expect(series.value(forKey: "study") as? NSManagedObject === study)
            #expect(series.value(forKey: "name") as? String == "T1 dynamic")
            #expect((series.value(forKey: "numberOfImages") as? NSNumber)?.intValue == 0)
            #expect(series.value(forKey: "thumbnail") == nil)
            let moved = (series.value(forKey: "images") as? Set<NSManagedObject>) ?? []
            #expect(moved == Set(group))
        }
        #expect(original.isDeleted || original.managedObjectContext == nil)
        let remaining = try fetch("Series", in: context)
        #expect(Set(remaining) == Set(made))
        #expect(Set((study.value(forKey: "series") as? Set<NSManagedObject>) ?? []) == Set(made))
        // The images moved: the database has the same images, each in a series.
        let all = try fetch("Image", in: context)
        #expect(Set(all) == Set(images))
        #expect(all.allSatisfy { $0.value(forKey: "series") != nil })
    }

    @Test func reparseIn4DGroupsByTime() throws {
        let context = try makeDatabaseContext()
        let (_, _, images) = makeSeries(6, in: context)
        // Two positions of three times: "Reparse in 4D" makes one series per time.
        let byPosition = [Array(images[0..<3]), Array(images[3..<6])]
        let groups = (0..<3).map { time in byPosition.map { $0[time] } }
        let made = SeriesReparse.write(groups: groups, seriesOf: byPosition.last?.last, in: context)
        try context.save()

        #expect(made.count == 3)
        #expect(made.map { $0.value(forKey: "seriesInstanceUID") as? String } == ["1.2.3RP-1", "1.2.3RP-2", "1.2.3RP-3"])
        for (series, group) in zip(made, groups) {
            #expect(((series.value(forKey: "images") as? Set<NSManagedObject>) ?? []) == Set(group))
        }
        #expect(try fetch("Series", in: context).count == 3)
        let all = try fetch("Image", in: context)
        #expect(Set(all) == Set(images))
        #expect(all.allSatisfy { $0.value(forKey: "series") != nil })
    }

    @Test func anImageWithoutASeriesWritesNothing() throws {
        let context = try makeDatabaseContext()
        let image = NSEntityDescription.insertNewObject(forEntityName: "Image", into: context)
        try context.save()
        #expect(SeriesReparse.write(groups: [[image]], seriesOf: image, in: context).isEmpty)
        #expect(SeriesReparse.write(groups: [], seriesOf: nil, in: context).isEmpty)
        #expect(!context.hasChanges)
    }
}
