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

/// "Merge Series" of the browser, as written to the database. The selected
/// rows are series, or the images of a series the thumbnails show; a row
/// stands for its series.
public enum SeriesMerge {

    /// The series a row stands for: a series itself, the series of an image
    /// (its to-one relationship `series`), and, when `studies` is set, one of
    /// the series of a study.
    static func series(of row: NSManagedObject, studies: Bool) -> NSManagedObject? {
        switch row.entity.name {
        case "Series":
            return row
        case "Image":
            return row.value(forKey: "series") as? NSManagedObject
        case "Study" where studies:
            return (row.value(forKey: "series") as? NSSet)?.anyObject() as? NSManagedObject
        default:
            return nil
        }
    }

    /// The series the others merge into: of the series the rows stand for,
    /// the last whose image is a DICOM file (StudyMerge.destinationSeries);
    /// otherwise the series of the first row.
    public static func destination(of rows: [NSManagedObject]) -> NSManagedObject? {
        let candidates = rows.map { series(of: $0, studies: true) }
        if let index = StudyMerge.destinationSeries(
            count: candidates.count,
            isSeries: { candidates[$0] != nil },
            imageExtension: { index in
                let image = (candidates[index]?.value(forKey: "images") as? NSSet)?.anyObject() as? NSManagedObject
                return image?.value(forKey: "extension")
            }) {
            return candidates[index]
        }
        return rows.first.flatMap { series(of: $0, studies: true) }
    }

    /// Moves the images of the series the rows stand for into `destination`
    /// and deletes those series, each once; a study row merges nothing. The
    /// destination's image count is reset for the database to recount. Not
    /// saved.
    public static func merge(_ rows: [NSManagedObject], into destination: NSManagedObject, in context: NSManagedObjectContext) {
        var merged = Set<ObjectIdentifier>()
        for row in rows {
            guard let series = series(of: row, studies: false), series !== destination,
                  merged.insert(ObjectIdentifier(series)).inserted else { continue }
            for case let image as NSManagedObject in (series.value(forKey: "images") as? NSSet)?.allObjects ?? [] {
                image.setValue(destination, forKey: "series")
            }
            context.delete(series)
        }
        destination.setValue(NSNumber(value: 0), forKey: "numberOfImages")
    }
}
