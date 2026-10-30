/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import CoreGraphics
import Foundation

// The sizes of the browser's text and rows for the size preference
// ("dbFontSize": -1 small, 0 regular, 1 large): the font size of each kind of
// text, the row heights of the lists and the thumbnails' cell size. The app
// reads the preference and applies the sizes to its views.

/// The kinds of text whose size follows the preference, by the names the
/// callers ask for.
public enum BrowserFontKind: String, CaseIterable, Sendable {
    case threadNameSize, threadNameStatus, comparativeLineSpace, threadCellLineSpace
    case dbFont, dbComparativeFont, dbAlbumFont, dbSourceFont, dbSeriesFont
    case dbMatrixFont, dbSmallMatrixFont, viewerSmallCellFont, viewerNumberFont
}

public enum BrowserFontSizes {
    /// The size of a kind of text for a size mode, nil for a mode other than
    /// -1, 0 and 1. The regular thread name and status are the system's small
    /// and mini control sizes, which the caller gives.
    public static func size(of kind: BrowserFontKind, mode: Int32, smallControl: Float, miniControl: Float) -> Float? {
        switch mode {
        case -1:
            switch kind {
            case .threadNameSize: return 9
            case .threadNameStatus: return 8
            case .comparativeLineSpace: return 12
            case .threadCellLineSpace: return 10
            case .dbFont: return 10
            case .dbComparativeFont: return 9
            case .dbAlbumFont: return 9
            case .dbSourceFont: return 9
            case .dbSeriesFont: return 8
            case .dbMatrixFont: return 8
            case .dbSmallMatrixFont: return 7.5
            case .viewerSmallCellFont: return 7
            case .viewerNumberFont: return 11
            }
        case 0:
            switch kind {
            case .threadNameSize: return smallControl
            case .threadNameStatus: return miniControl
            case .comparativeLineSpace: return 14
            case .threadCellLineSpace: return 13
            case .dbFont: return 12
            case .dbComparativeFont: return 11
            case .dbAlbumFont: return 11
            case .dbSourceFont: return 11
            case .dbSeriesFont: return 10
            case .dbMatrixFont: return 9
            case .dbSmallMatrixFont: return 8.5
            case .viewerSmallCellFont: return 7.8
            case .viewerNumberFont: return 15
            }
        case 1:
            switch kind {
            case .threadNameSize: return 13
            case .threadNameStatus: return 11
            case .comparativeLineSpace: return 20
            case .threadCellLineSpace: return 19
            case .dbFont: return 15
            case .dbComparativeFont: return 13.5
            case .dbAlbumFont: return 14
            case .dbSourceFont: return 14
            case .dbSeriesFont: return 13
            case .dbMatrixFont: return 13
            case .dbSmallMatrixFont: return 12
            case .viewerSmallCellFont: return 11
            case .viewerNumberFont: return 20
            }
        default:
            return nil
        }
    }

    /// The size a caller gets when the kind or the mode is unknown.
    public static let fallback: Float = 12
}

/// The row heights of the browser's lists and the size of a thumbnail's cell.
public struct BrowserRowHeights: Equatable, Sendable {
    public var albums: CGFloat
    public var sources: CGFloat
    public var studyList: CGFloat
    public var history: CGFloat
    public var activity: CGFloat
    public var thumbnailCell: CGSize

    /// The heights for a size mode, nil for a mode other than -1, 0 and 1
    /// (the views keep theirs). The history is a list of one line per study
    /// above the thumbnails, of two beside them.
    public static func forMode(_ mode: Int32, horizontalHistory: Bool) -> BrowserRowHeights? {
        switch mode {
        case -1:
            return BrowserRowHeights(albums: 13, sources: 13, studyList: 13, history: horizontalHistory ? 13 : 24, activity: 34,
                                     thumbnailCell: CGSize(width: 105 * 0.8, height: 113 * 0.8))
        case 0:
            return BrowserRowHeights(albums: 17, sources: 17, studyList: 17, history: horizontalHistory ? 16 : 29, activity: 38,
                                     thumbnailCell: CGSize(width: 105, height: 113))
        case 1:
            return BrowserRowHeights(albums: 25, sources: 25, studyList: 22, history: horizontalHistory ? 21 : 43, activity: 48,
                                     thumbnailCell: CGSize(width: 105 * 1.3, height: 113 * 1.3))
        default:
            return nil
        }
    }
}

/// The number of files a database folder holds before the next one.
public enum DatabaseFolderSize {
    /// The size and whether to save it: the saved preference, 10000 when none.
    public static func effective(saved: Int32) -> (size: Int32, save: Bool) {
        return saved == 0 ? (10000, true) : (saved, false)
    }
}
