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

/// "Reparse in 3D" and "Reparse in 4D" of the sub-series sheet, as written to
/// the database: one new series of the study per group of images, the images
/// moved into it, and the series they came from deleted.
public enum SeriesReparse {

    /// Writes the reparse of `groups` in `context`, which the caller has
    /// entered. Each group becomes a series with the values of the original
    /// series (the series of `image`, an image of the series reparsed), its
    /// instance UID followed by RP-1, RP-2…, in the original's study; its
    /// images move into it, and the original series, then empty, is deleted.
    /// The database keeps the same images. Nothing is written when `image` has
    /// no series. Returns the new series, in the order of the groups. Not
    /// saved.
    @discardableResult
    public static func write(groups: [[NSManagedObject]], seriesOf image: NSManagedObject?, in context: NSManagedObjectContext) -> [NSManagedObject] {
        // The relationship of an image to its series is `series`. An image
        // answers a key it does not know by looking for a DICOM field of that
        // name, and raises when there is none.
        guard let originalSeries = image?.value(forKey: "series") as? NSManagedObject,
              let seriesEntity = NSEntityDescription.entity(forEntityName: "Series", in: context) else { return [] }
        let seriesAttributes = Array(seriesEntity.attributesByName.keys)

        var created: [NSManagedObject] = []
        for (index, group) in groups.enumerated() {
            let newSeries = NSEntityDescription.insertNewObject(forEntityName: "Series", into: context)
            for name in seriesAttributes {
                let value: Any?
                if name == "seriesInstanceUID" {
                    value = (originalSeries.value(forKey: name) as? NSString)?.appendingFormat("RP-%d", Int32(index + 1))
                } else {
                    value = originalSeries.value(forKey: name)
                }
                if let value { newSeries.setValue(value, forKey: name) }
            }
            newSeries.setValue(originalSeries.value(forKey: "study"), forKey: "study")

            // The images move; nothing is copied. The code this came from also
            // inserted a copy of each image's values and attached it to no
            // series: the copy was never shown, counted or read, and stayed
            // in the database as an image without a series.
            for image in group {
                image.setValue(newSeries, forKey: "series")
            }
            newSeries.setValue(NSNumber(value: 0), forKey: "numberOfImages")
            newSeries.setValue(nil, forKey: "thumbnail")
            created.append(newSeries)
        }
        context.delete(originalSeries)
        return created
    }
}
