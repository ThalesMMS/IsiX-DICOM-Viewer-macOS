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

import Foundation

// The rules of the browser's window that need neither AppKit nor the app's
// classes: which of its menu commands apply to the selection and how they are
// titled, the keys of its list, locking studies, the animation of the
// thumbnails' preview, the modifier keys, the list's saved sort, the search
// menu's series description, the default database, and which loaded frame a
// viewer can lend the preview. The app reads the selection, the defaults and
// the views, and gives these rules plain values, or asks them through a
// protocol in the order the former Objective-C asked.
//
// Values follow Objective-C's messages: -boolValue and -intValue of anything
// else than a number or a string are NO and 0, a message to nil answers 0, NO
// or nil, and strings compare code unit by code unit, as -isEqualToString: did.

private func sameText(_ a: Any?, _ b: String) -> Bool {
    guard let a = a as? NSString else { return false }
    return a.isEqual(to: b)
}

/// [value boolValue]: NO for nil and for what is neither a number nor a string.
private func objcBool(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

/// [value intValue]: 0 for nil and for what is neither a number nor a string.
private func objcInt(_ value: Any?) -> Int32 {
    if let number = value as? NSNumber { return number.int32Value }
    if let string = value as? NSString { return string.intValue }
    return 0
}

// MARK: - Modifier keys

public enum BrowserModifierKeys {
    /// The event modifier flags of Carbon's current key modifiers (cmdKey,
    /// shiftKey, optionKey, controlKey): NSEventModifierFlagCommand, Shift,
    /// Option and Control.
    public static func eventFlags(carbonModifiers: UInt32) -> UInt32 {
        var flags: UInt32 = 0
        if carbonModifiers & 0x0100 != 0 { flags |= 1 << 20 }
        if carbonModifiers & 0x0200 != 0 { flags |= 1 << 17 }
        if carbonModifiers & 0x0800 != 0 { flags |= 1 << 19 }
        if carbonModifiers & 0x1000 != 0 { flags |= 1 << 18 }
        return flags
    }
}

// MARK: - The keys of the list

public enum BrowserKeyCommand: Equatable, Sendable {
    /// Delete, Backspace, Forward Delete: delete the selection.
    case delete
    /// Return, Enter, a new line: open the selection.
    case open
    /// Space: play or stop the preview's animation.
    case toggleAnimation
    /// Any other character: select the first patient whose name begins with
    /// what was typed.
    case typeSelect

    /// The command of the first character of a key event.
    public static func of(character c: UInt16) -> BrowserKeyCommand {
        switch c {
        case 0xF728, 0x7F, 0x08, 0xF73E: return .delete
        case 0x0A, 0x03, 0x0D: return .open
        case 0x20: return .toggleAnimation
        default: return .typeSelect
        }
    }
}

// MARK: - Locking studies

public enum StudyLocking {
    /// A study that is not locked: what Lock Studies locks. The lock is read
    /// only for a study.
    public static func locks(type: Any?, locked: () -> Any?) -> Bool {
        sameText(type, "Study") && !objcBool(locked())
    }

    /// A locked study: what Unlock Studies unlocks.
    public static func unlocks(type: Any?, locked: () -> Any?) -> Bool {
        sameText(type, "Study") && objcBool(locked())
    }
}

// MARK: - The preview's animation

public enum PreviewAnimation {
    /// What the selected row of the list animates in the preview.
    public enum Frames: Equatable, Sendable {
        /// The list no longer matches the thumbnails: refresh both.
        case refresh
        /// Whether the preview animates, through how many images or frames.
        case slider(animate: Bool, images: Int)
    }

    /// The images of the selected row: a series of one multi-frame image
    /// (its frames), a series of several images, the thumbnail of a study
    /// (its images, or the frames of its one image). `seriesImageCount` is
    /// the number of images of a series, asked once per test as the former
    /// code did; `firstImageFrames` the frames of its first image; `studyImages`
    /// the images of the selected thumbnail of a study, nil without one.
    public static func frames(type: Any?, seriesImageCount: () -> Int, firstImageFrames: () -> Any?,
                              studyImages: () -> (count: Int, firstFrames: () -> Any?)?) -> Frames {
        if sameText(type, "Series") && seriesImageCount() == 1 && objcInt(firstImageFrames()) > 1 {
            return .slider(animate: true, images: Int(objcInt(firstImageFrames())))
        }
        if sameText(type, "Series") && seriesImageCount() > 1 {
            return .slider(animate: true, images: seriesImageCount())
        }
        if sameText(type, "Study") {
            guard let images = studyImages() else { return .refresh }
            var count = 0
            var animate = false
            if images.count > 0 {
                count = images.count > 1 ? images.count : Int(objcInt(images.firstFrames()))
                animate = images.count > 1 || count > 1
            }
            return .slider(animate: animate, images: count)
        }
        return .slider(animate: false, images: 0)
    }

    public enum SliderChange: Equatable, Sendable {
        /// Disabled, at 0, one tick mark.
        case disable
        /// Enabled from 0 to images - 1, one tick mark per image, at 0.
        case enable(images: Int)
        /// Left as it is: already animating.
        case keep
    }

    /// The slider for what the row animates: an enabled slider is left alone.
    public static func sliderChange(animate: Bool, sliderEnabled: Bool, images: Int) -> SliderChange {
        if !animate { return .disable }
        return sliderEnabled ? .keep : .enable(images: images)
    }
}

// MARK: - A frame a viewer has loaded

public enum PreviewReuse {
    /// The first image of a viewer's file list that is the frame asked for:
    /// the same file and the same frame (a multi-frame file is one row per
    /// frame), nil when there is none.
    public static func index(count: Int, path: (Int) -> Any?, frame: (Int) -> Any?, pathToFind: Any?, frameNumber: Int32) -> Int? {
        for x in 0..<count {
            if let found = path(x) as? NSString, let wanted = pathToFind as? String, found.isEqual(to: wanted),
               objcInt(frame(x)) == frameNumber {
                return x
            }
        }
        return nil
    }
}

// MARK: - The list's saved sort

public enum ListSort {
    /// The sort the list starts with: the saved column and order when the
    /// column is shown (with the selector of the column's own sort), and
    /// otherwise by name, case-insensitive, ascending.
    public enum Restored: Equatable, Sendable {
        case saved(key: String?, ascending: Bool)
        case byName
    }

    public static func restored(saved: NSDictionary?, isVisible: (Any?) -> Bool) -> Restored {
        guard let saved else { return .byName }
        let key = saved.object(forKey: "key")
        guard isVisible(key) else { return .byName }
        return .saved(key: key as? String, ascending: objcBool(saved.object(forKey: "order")))
    }

    /// The sort saved when the window closes: its first descriptor's order and
    /// key; the key may be nil, which ends the dictionary before it.
    public static func saved(ascending: Bool, key: String?) -> NSDictionary {
        let dictionary = NSMutableDictionary()
        dictionary.setObject(NSNumber(value: ascending), forKey: "order" as NSString)
        if let key { dictionary.setObject(key, forKey: "key" as NSString) }
        return dictionary
    }
}

// MARK: - The search menu

public enum SearchMenuTemplate {
    /// The tag of the series description search, which older nibs lack.
    public static let seriesDescriptionTag = 11

    /// Where the series description search goes: after the item tagged 4
    /// (the study description), within the menu. `indexOfTag4` is -1 when the
    /// menu has no such item.
    public static func seriesDescriptionIndex(itemCount: Int, indexOfTag4: Int) -> Int {
        min(itemCount, indexOfTag4 + 1)
    }
}

// MARK: - The default database

public enum DefaultDatabase {
    /// Whether the browser goes back to the local default database: it shows
    /// another one (or none).
    public static func needsReset(shown: String?, defaultPath: String?) -> Bool {
        guard let shown else { return true }
        guard let defaultPath else { return true }
        return !(shown as NSString).isEqual(to: defaultPath)
    }
}

// MARK: - Validating the browser's menu commands

/// What the browser's menu validation asks, each when it needs it.
public protocol BrowserMenuFacts {
    /// The number of selected rows of the list.
    func selectedCount() -> Int
    /// The type and the lock of the selected row at a position of the
    /// selection (0 is the first selected row).
    func selectedType(at position: Int) -> Any?
    func selectedLocked(at position: Int) -> Any?
    /// The database is local, read-only.
    func databaseIsLocal() -> Bool
    func databaseIsReadOnly() -> Bool
    /// The first selected row: whether there is one, and whether its study
    /// (itself or the series' study) has a report.
    func firstSelectedHasItem() -> Bool
    func firstSelectedStudyHasReport() -> Bool
    /// The menu item is in the image tiling menu; the main window is a viewer's.
    func isImageTileMenu() -> Bool
    func mainWindowIsViewer() -> Bool
    /// The COMMENTSAUTOFILL default.
    func commentsAutoFill() -> Bool
    /// The images of the selection with ROIs, with ROIs or key images, key images.
    func roiImageCount() -> Int
    func roisAndKeyImageCount() -> Int
    func keyImageCount() -> Int
    /// The menu item is the thumbnails' menu's.
    func isThumbnailMenuItem() -> Bool
    /// Some file of the selection (of the thumbnails, or of the list) is outside
    /// the database folder.
    func selectionHasLinkedFiles(fromThumbnails: Bool) -> Bool
    /// The first responder is the thumbnails, the list, the history; the item
    /// is in the list's menu.
    func firstResponderIsThumbnails() -> Bool
    func isListMenuItem() -> Bool
    func firstResponderIsList() -> Bool
    func firstResponderIsHistory() -> Bool
    /// The number of selected thumbnails.
    func selectedThumbnailCount() -> Int
    /// The menu item's tag, and the ANNOTATIONS default.
    func itemTag() -> Int
    func annotationsMode() -> Int
}

public enum BrowserMenuValidation {
    public enum Title: Equatable, Sendable {
        case deleteSelectedSeriesThumbnails, deleteSelectedLines, mergeSelectedSeries, mergeSelectedStudies
    }

    public struct Answer: Equatable, Sendable {
        public var enabled: Bool
        /// The title the item takes, if it changes.
        public var title: Title?
        /// The check mark the item takes, if it changes.
        public var checked: Bool?

        public init(enabled: Bool, title: Title? = nil, checked: Bool? = nil) {
            self.enabled = enabled
            self.title = title
            self.checked = checked
        }
    }

    /// The commands that need a local selection: none of them applies without
    /// a selection, or to a study of a DICOM node.
    static func needsLocalSelection(_ action: String) -> Bool {
        switch action {
        case "rebuildThumbnails:", "searchForCurrentPatient:", "viewerDICOM:", "MovieViewerDICOM:",
             "viewerDICOMMergeSelection:", "revealInFinder:", "export2PACS:", "exportQuicktime:", "exportJPEG:",
             "exportTIFF:", "exportDICOMFile:", "sendMail:", "addStudiesToUser:", "sendEmailNotification:",
             "compressSelectedFiles:", "decompressSelectedFiles:", "generateReport:", "deleteReport:",
             "convertReportToPDF:", "convertReportToDICOMSR:", "delItem:", "querySelectedStudy:", "burnDICOM:",
             "anonymizeDICOM:", "viewXML:", "applyRoutingRule:", "regenerateAutoComments:", "unifyStudies:",
             "viewerSubSeriesDICOM:", "viewerReparsedSeries:", "copyToDBFolder:":
            return true
        default:
            return false
        }
    }

    /// The commands that write: none of them applies to a read-only database.
    static func writes(_ action: String) -> Bool {
        switch action {
        case "compressSelectedFiles:", "decompressSelectedFiles:", "generateReport:", "deleteReport:",
             "convertReportToPDF:", "convertReportToDICOMSR:", "delItem:", "regenerateAutoComments:",
             "copyToDBFolder:", "querySelectedStudy:", "unifyStudies:", "retrieveSelectedPODStudies:":
            return true
        default:
            return false
        }
    }

    /// The commands of a local database only.
    static func needsLocalDatabase(_ action: String) -> Bool {
        switch action {
        case "deleteAlbum:", "addAlbum:", "addSmartAlbum:", "addAlbums:", "defaultAlbums:",
             "selectFilesAndFoldersToAdd:", "addURLToDatabase:", "importRawData:", "anonymizeDICOM:",
             "compressSelectedFiles:", "decompressSelectedFiles:":
            return true
        default:
            return false
        }
    }

    /// -validateMenuItem: of the browser, after the report commands, for a
    /// command (its selector's name) and whether the selection holds a study
    /// of a DICOM node.
    public static func validate<Facts: BrowserMenuFacts>(action: String, containsDistantStudy: Bool, facts: Facts) -> Answer {
        if facts.selectedCount() < 1 || containsDistantStudy {
            if containsDistantStudy && action == "querySelectedStudy:" { return Answer(enabled: true) }
            if needsLocalSelection(action) { return Answer(enabled: false) }
        }
        if facts.selectedCount() < 1 || !containsDistantStudy {
            if action == "retrieveSelectedPODStudies:" { return Answer(enabled: false) }
        }
        if facts.databaseIsReadOnly() && writes(action) { return Answer(enabled: false) }
        if !facts.databaseIsLocal() && needsLocalDatabase(action) { return Answer(enabled: false) }

        if action == "convertReportToPDF:" || action == "convertReportToDICOMSR:" {
            if facts.firstSelectedHasItem() && !facts.firstSelectedStudyHasReport() { return Answer(enabled: false) }
        } else if facts.isImageTileMenu() {
            return Answer(enabled: facts.mainWindowIsViewer())
        } else if action == "unifyStudies:" {
            if !facts.databaseIsLocal() { return Answer(enabled: false) }
            return Answer(enabled: facts.selectedCount() > 1)
        } else if action == "regenerateAutoComments:" {
            return Answer(enabled: facts.commentsAutoFill())
        } else if action == "viewerDICOMROIsImages:" {
            if containsDistantStudy { return Answer(enabled: false) }
            if facts.databaseIsLocal() {
                if facts.selectedCount() < 10 && facts.roiImageCount() == 0 { return Answer(enabled: false) }
            } else {
                return Answer(enabled: true)
            }
        } else if action == "viewerKeyImagesAndROIsImages:" || action == "exportROIAndKeyImagesAsDICOMSeries:" {
            if containsDistantStudy { return Answer(enabled: false) }
            if facts.databaseIsLocal() {
                if facts.selectedCount() < 10 && facts.roisAndKeyImageCount() == 0 { return Answer(enabled: false) }
            } else {
                return Answer(enabled: true)
            }
        } else if action == "viewerDICOMKeyImages:" {
            if containsDistantStudy { return Answer(enabled: false) }
            if facts.databaseIsLocal() {
                if facts.selectedCount() < 10 && facts.keyImageCount() == 0 { return Answer(enabled: false) }
            } else {
                return Answer(enabled: true)
            }
        } else if action == "createROIsFromRTSTRUCT:" {
            if containsDistantStudy { return Answer(enabled: false) }
            if !facts.databaseIsLocal() { return Answer(enabled: false) }
        } else if action == "compressSelectedFiles:" || action == "decompressSelectedFiles:" {
            if containsDistantStudy { return Answer(enabled: false) }
        } else if action == "copyToDBFolder:" {
            if containsDistantStudy { return Answer(enabled: false) }
            if !facts.databaseIsLocal() { return Answer(enabled: false) }
            if facts.selectedCount() < 10 {
                return Answer(enabled: facts.selectionHasLinkedFiles(fromThumbnails: facts.isThumbnailMenuItem()))
            }
            return Answer(enabled: true)
        } else if action == "lockStudies:" || action == "unlockStudies:" {
            if containsDistantStudy { return Answer(enabled: false) }
            let count = facts.selectedCount()
            for position in 0..<max(count, 0) {
                let type = facts.selectedType(at: position)
                let locked = { facts.selectedLocked(at: position) }
                if action == "lockStudies:" ? StudyLocking.locks(type: type, locked: locked)
                    : StudyLocking.unlocks(type: type, locked: locked) {
                    return Answer(enabled: true)
                }
            }
            return Answer(enabled: false)
        } else if action == "delItem:" {
            if containsDistantStudy { return Answer(enabled: false) }
            if !facts.databaseIsLocal() { return Answer(enabled: false) }
            // The thumbnails' menu or the thumbnails as first responder, and
            // otherwise too: only the list's menu and the list or the history
            // as first responder name the lines.
            if facts.isThumbnailMenuItem() || facts.firstResponderIsThumbnails() {}
            let lines = facts.isListMenuItem() || facts.firstResponderIsList() || facts.firstResponderIsHistory()
            return Answer(enabled: true, title: lines ? .deleteSelectedLines : .deleteSelectedSeriesThumbnails)
        } else if action == "mergeStudies:" {
            if containsDistantStudy { return Answer(enabled: false) }
            if !facts.databaseIsLocal() { return Answer(enabled: false) }
            let count = facts.selectedCount()
            var onlySeries = true
            for position in 0..<max(count, 0) where !sameText(facts.selectedType(at: position), "Series") {
                onlySeries = false
            }
            let title: Title = onlySeries && count != 0 ? .mergeSelectedSeries : .mergeSelectedStudies
            return Answer(enabled: count > 1, title: title)
        } else if action == "mergeSeries:" {
            if containsDistantStudy { return Answer(enabled: false) }
            if !facts.databaseIsLocal() { return Answer(enabled: false) }
            return Answer(enabled: facts.selectedThumbnailCount() > 1)
        } else if action == "annotMenu:" {
            return Answer(enabled: true, checked: facts.itemTag() == facts.annotationsMode())
        }
        return Answer(enabled: true)
    }
}
