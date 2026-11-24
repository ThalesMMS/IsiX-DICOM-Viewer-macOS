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
        /// One of the viewer's time points shows it: in the colour of the
        /// study the viewer's window stands for among the patient's open
        /// studies, the colour of its frame and of its fill in the series list.
        case shown(SeriesIdentity.Study)
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
    /// Which of the patient's open studies the viewer's window shows, as the
    /// frame of its active view has it: the current one, or a previous one.
    /// The series the viewer shows are highlighted in that study's colour.
    public var windowStudy: SeriesIdentity.Study

    public init(studies: [Study], windowStudy: SeriesIdentity.Study = .current) {
        self.studies = studies
        self.windowStudy = windowStudy
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

    /// An item of the series submenu of the contextual menu.
    public enum ContextualItem: Sendable, Equatable {
        /// A study's line; its series, if it has any here, are the items after it.
        case study(Int)
        case series(study: Int, series: Int)
        /// A study whose series are in a submenu of its own item, in their order.
        case folded(Int)
        case separator
    }

    /// The items of the series submenu of the contextual menu. A submenu
    /// opens at its first item and cannot be opened scrolled, so with every
    /// series of every study in one list the series shown, of an older
    /// study, was below the screen's edge. Here the studies the viewer shows
    /// a series of keep their series in line, and each other study that has
    /// series is one item with them in its submenu: the studies stay in
    /// their order, and the series shown is in sight. With one study, or
    /// with no series shown, the list is the popup's.
    public var contextualItems: [ContextualItem] {
        let open = studies.map { study in study.series.contains { $0.isShown } }
        guard studies.count > 1, open.contains(true) else {
            return items.map { item in
                switch item {
                case .study(let study): return .study(study)
                case .series(let study, let series): return .series(study: study, series: series)
                case .separator: return .separator
                }
            }
        }
        var result: [ContextualItem] = []
        for (index, study) in studies.enumerated() {
            if open[index] {
                if let last = result.last, last != .separator { result.append(.separator) }
                result.append(.study(index))
                result += study.series.indices.map { .series(study: index, series: $0) }
                if index != studies.count - 1 { result.append(.separator) }
            } else {
                result.append(study.series.isEmpty ? .study(index) : .folded(index))
            }
        }
        return result
    }

    /// The item the popup selects: the last series the viewer shows; nil
    /// when it shows none of them.
    public var selectedItem: Int? {
        items.lastIndex { item in
            guard case .series(let study, let series) = item else { return false }
            return studies[study].series[series].isShown
        }
    }

    /// The background of a series' title: shown, in the colour of the study
    /// of the viewer's window; else fused; else the colour of the study of
    /// the window that shows it.
    public func highlight(of series: Series) -> Highlight {
        if series.isShown { return .shown(windowStudy) }
        if series.isFused { return .fused }
        if series.hasWindowColour { return .windowColour }
        return .none
    }

    /// The title of a series' item: its name and its number of images, which
    /// `images` writes in the language of the menu ("120 images").
    public static func title(of series: Series, images: (Int) -> String = englishImages) -> String {
        series.name + " / " + images(series.imageCount)
    }

    /// A number of images as English writes it: "1 image", "1,200 images".
    public static func englishImages(_ count: Int) -> String {
        let number = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        return number + " " + (count == 1 ? "image" : "images")
    }
}
