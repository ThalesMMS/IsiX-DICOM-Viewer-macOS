/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// The thumbnails of the 2D viewer's series list: what a series cell counts
// and how big its picture is drawn.

/// What a series cell counts: images, the frames of a single multi-frame
/// image, or objects (a series without images).
public struct SeriesListImageCount: Equatable {
    public enum Kind: Equatable {
        case image, images, frames, object, objects
    }

    public var count: Int32
    /// The word for one, and for zero or more than one.
    public var singular: Kind
    public var plural: Kind

    public init(count: Int32, singular: Kind, plural: Kind) {
        self.count = count
        self.singular = singular
        self.plural = plural
    }

    /// A series of `fileCount` images. `frames` is the number of frames of
    /// one of its images, read only for one image or none; `rawFileCount`,
    /// the objects of a series without images, read only then.
    public static func of(fileCount: Int32, rawFileCount: () -> Int32, frames: () -> Int32) -> SeriesListImageCount {
        var result = SeriesListImageCount(count: fileCount, singular: .image, plural: .images)
        if fileCount == 1 {
            let frameCount = frames()
            if frameCount > 1 {
                result.count = frameCount
                result.plural = .frames
            }
        } else if fileCount == 0 {
            result.count = rawFileCount()
            let frameCount = frames()
            if result.count == 1 && frameCount > 1 { result.count = frameCount }
            if result.count == 1 {
                result.singular = .object
            } else {
                result.plural = .objects
            }
        }
        return result
    }
}

/// The size of the pictures of the list for the database font size
/// preference (dbFontSize).
public enum SeriesListPictureSize: Equatable {
    /// Scaled by this factor.
    case scaled(Double)
    /// As it is.
    case unscaled
    /// Not set for this preference.
    case none

    public static func of(fontSize: Int) -> SeriesListPictureSize {
        switch fontSize {
        case -1: return .scaled(0.6)
        case 0: return .unscaled
        case 1: return .scaled(1.3)
        default: return .none
        }
    }
}
