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

import Foundation

/// The images of a study by SOP instance UID, and by UID and frame.
///
/// The image a ROI SR belongs to was looked for by filtering every image of
/// the study with a predicate, once per SR: for a study with ROIs on most of
/// its slices, as many passes over the study as it has such slices. Measured
/// in the application (Debug, Apple Silicon) on a study of 1002 images with a
/// ROI on each of 461 slices: 645 ms of filtering alone, against 45 ms for
/// the whole list - reading the 461 SRs included - with one pass.
///
/// A lookup answers what the filter's first result was: the first image, in
/// the order the images were given, whose `sopInstanceUID` is the one asked
/// for - and whose `frameID` is the frame, when a frame other than 0 is asked
/// for. A nil UID finds the first image that has none.
struct StudyImageIndex {
    private struct Key: Hashable {
        let uid: NSString?
        let frame: NSNumber?
    }

    private var first: [Key: AnyObject] = [:]

    /// Reads `sopInstanceUID` and `frameID` of each image once, by key-value
    /// coding, as the predicate did.
    init(images: NSArray?) {
        guard let images else { return }
        first.reserveCapacity(images.count)
        for case let image as AnyObject in images {
            let uid = image.value(forKey: "sopInstanceUID") as? NSString
            let whole = Key(uid: uid, frame: nil)
            if first[whole] == nil { first[whole] = image }
            if let frame = image.value(forKey: "frameID") as? NSNumber {
                let framed = Key(uid: uid, frame: frame)
                if first[framed] == nil { first[framed] = image }
            }
        }
    }

    /// The image with this UID; of this frame, unless the frame is 0.
    func image(sopInstanceUID uid: String?, frame: Int32) -> AnyObject? {
        first[Key(uid: uid as NSString?, frame: frame == 0 ? nil : NSNumber(value: frame))]
    }
}
