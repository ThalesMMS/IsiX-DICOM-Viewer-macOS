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

import Accelerate
import AppKit
import IsiXDatabase
import IsiXImaging

// The sizes of the browser's text and rows, which follow the "dbFontSize"
// preference (IsiXDatabase's BrowserFontSizes and BrowserRowHeights), and the
// image conversion the 3D viewers ask the class for.

extension BrowserController {

    /// The size of a kind of text ("dbFont", "dbSeriesFont", "threadNameSize"...)
    /// for the size preference; 12, logged, for an unknown kind or size.
    @objc(fontSize:)
    public nonisolated func fontSize(_ type: String!) -> Float {
        return BrowserController.fontSize(of: type.flatMap(BrowserFontKind.init(rawValue:)), named: type)
    }

    nonisolated static func fontSize(of kind: BrowserFontKind?, named name: String?) -> Float {
        let mode = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "dbFontSize"))
        // The system's control sizes are asked only for the text that uses
        // them: the study list asks for its sizes at every cell.
        let controls = mode == 0 && (kind == .threadNameSize || kind == .threadNameStatus)
        if let kind, let size = BrowserFontSizes.size(of: kind, mode: mode,
                                                       smallControl: controls ? Float(NSFont.systemFontSize(for: .small)) : 0,
                                                       miniControl: controls ? Float(NSFont.systemFontSize(for: .mini)) : 0) {
            return size
        }
        BrowserObjC.logStackTrace("********* fontSize not found for type: \(name ?? "(null)")")
        return BrowserFontSizes.fallback
    }

    /// The study row's size, for every cell of the study list.
    func horos_studyRowFontSize() -> Float {
        return BrowserController.fontSize(of: .dbFont, named: "dbFont")
    }

    /// A series row's size, for every cell of the study list.
    func horos_seriesRowFontSize() -> Float {
        return BrowserController.fontSize(of: .dbSeriesFont, named: "dbSeriesFont")
    }

    /// The row heights of the lists and the thumbnails' cell size for the size
    /// preference; another size leaves the views as they are.
    @objc(setTableViewRowHeight)
    public func setTableViewRowHeight() {
        let mode = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "dbFontSize"))
        guard let heights = BrowserRowHeights.forMode(mode, horizontalHistory: BrowserClassState.horizontalHistory) else { return }
        windowOutlets.albumTable?.rowHeight = heights.albums
        windowOutlets.sourcesTableView?.rowHeight = heights.sources
        windowOutlets.databaseOutline?.rowHeight = heights.studyList
        windowOutlets.comparativeTable?.rowHeight = heights.history
        windowOutlets.activityTableView?.rowHeight = heights.activity
        windowOutlets.oMatrix?.cellSize = heights.thumbnailCell
    }

    /// The reports' mode, the "REPORTSMODE" preference as a number, for every
    /// cell of the study list, read without bridging the string to Swift
    /// (BrowserController+CAPI.m).
    static func horos_reportsMode() -> Int32 {
        return HorosBrowserReportsMode()
    }

    /// Converts a float image to unsigned 16-bit integers ("FTo16U") or back
    /// ("16UToF"), in bands, one per processor, and returns when every band is
    /// done. The buffers are vImage_Buffer: the generated interface names
    /// them as pointers, so that its readers need not import Accelerate.
    @objc(multiThreadedImageConvert:::::)
    public nonisolated class func multiThreadedImageConvert(_ what: String!, _ src: UnsafeMutableRawPointer!,
                                                            _ dst: UnsafeMutableRawPointer!, _ offset: Float, _ scale: Float) {
        ParallelImageConversion.convert(ParallelImageConversion.Kind(name: what),
                                        src: UnsafePointer(src.assumingMemoryBound(to: vImage_Buffer.self)),
                                        dst: UnsafePointer(dst.assumingMemoryBound(to: vImage_Buffer.self)),
                                        offset: offset, scale: scale) { _ in
            NSLog("****** unknown vImageThread what: %@", what ?? "(null)")
        }
    }
}
