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

import Foundation

/// What the 2D viewer's series menu (the series popup of its toolbar, copied
/// into the contextual menu) lists, in values: an item for each study the
/// series list shows, the items of its series after it, a separator between
/// studies; the title, picture and highlight of each item, and the item the
/// popup selects. The application reads the database objects once into this
/// and makes the menu's items from it.
public struct SeriesMenuModel: Sendable, Equatable {

    /// The picture of a study's item.
    public enum StudyPicture: Sendable, Equatable {
        /// A study of the database: its number, on the colour of its place
        /// among the patient's studies (`studyIndex`, NSNotFound when it is
        /// not among them).
        case number(studyIndex: Int)
        /// A study on a PACS: the arrow of a study to retrieve.
        case retrieve
    }

    /// The background of a series' title.
    public enum Highlight: Sendable, Equatable {
        case none
        /// One of the viewer's time points shows it.
        case shown
        /// The viewer fuses it.
        case fused
        /// Another window shows it: that window's colour, half transparent.
        case windowColour
    }

    /// A series of a listed study.
    public struct Series: Sendable, Equatable {
        /// Its name as the menu writes it (already shortened).
        public var name: String
        public var imageCount: Int
        public var isShown: Bool
        public var isFused: Bool
        /// A window shows it, in a colour of its own.
        public var hasWindowColour: Bool

        public init(name: String, imageCount: Int, isShown: Bool, isFused: Bool, hasWindowColour: Bool) {
            self.name = name
            self.imageCount = imageCount
            self.isShown = isShown
            self.isFused = isFused
            self.hasWindowColour = hasWindowColour
        }
    }

    /// A listed study.
    public struct Study: Sendable, Equatable {
        /// Its line; nil when the study could not be read, and its item
        /// stays without a title.
        public var title: String?
        /// Its picture; nil when the study could not be read.
        public var picture: StudyPicture?
        /// The viewer's own study, listed as found on a PACS: the menu shows
        /// its database copy, and a separator follows it even when it is the
        /// last study.
        public var isViewerStudyOnPACS: Bool
        public var series: [Series]

        public init(title: String?, picture: StudyPicture?, isViewerStudyOnPACS: Bool, series: [Series]) {
            self.title = title
            self.picture = picture
            self.isViewerStudyOnPACS = isViewerStudyOnPACS
            self.series = series
        }
    }

    /// An item of the menu.
    public enum Item: Sendable, Equatable {
        case study(Int)
        case series(study: Int, series: Int)
        case separator
    }

    /// The studies the menu lists, most recent first.
    public var studies: [Study]

    public init(studies: [Study]) {
        self.studies = studies
    }

    /// The items in the order of the menu: each study, its series, then a
    /// separator unless the study is the last one (the viewer's study listed
    /// from a PACS keeps its separator there too).
    public var items: [Item] {
        var items: [Item] = []
        for (index, study) in studies.enumerated() {
            items.append(.study(index))
            items += study.series.indices.map { .series(study: index, series: $0) }
            if index != studies.count - 1 || study.isViewerStudyOnPACS {
                items.append(.separator)
            }
        }
        return items
    }

    /// The item the popup selects: the last series the viewer shows; nil
    /// when it shows none of them.
    public var selectedItem: Int? {
        items.lastIndex { item in
            guard case .series(let study, let series) = item else { return false }
            return studies[study].series[series].isShown
        }
    }

    /// The background of a series' title: shown, else fused, else the colour
    /// of the study of the window that shows it.
    public func highlight(of series: Series) -> Highlight {
        if series.isShown { return .shown }
        if series.isFused { return .fused }
        if series.hasWindowColour { return .windowColour }
        return .none
    }

    /// The title of a series' item: its name and its number of images.
    public static func title(of series: Series) -> String {
        let count = NumberFormatter.localizedString(from: NSNumber(value: series.imageCount), number: .decimal)
        return series.name + " / " + count + " " + (series.imageCount == 1 ? "image" : "images")
    }
}
