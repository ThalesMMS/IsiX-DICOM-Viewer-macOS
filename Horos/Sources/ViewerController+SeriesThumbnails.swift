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

import Cocoa
import IsiXImaging

// The series list of the 2D viewer: a thumbnail cell for each of the
// patient's studies and for each series of a shown study (with the
// placeholders of the series a DICOMweb node's rule left out), its colours
// and frames for the series shown in this and other windows, the
// comparatives button, the clicks on its cells, and the list's scrolling
// kept in step with the other viewers of the study.

/// Set while a viewer scrolls the other viewers' lists: their scrolling is
/// not to be answered.
nonisolated(unsafe) fileprivate var viewBoundsDidChangeProtect = false

/// The frame of a thumbnail cell in the colour of the window that shows its
/// series, when the list identifies series by colours.
@MainActor fileprivate func setThumbnailFrame(_ cell: NSCell?, _ color: NSColor?) {
    if let cell = cell as? ThumbnailCell {
        cell.frameColor = SeriesListIdentification.showsColors(in: UserDefaults.standard) ? color : nil
        cell.windowNumber = 0
    }
}

/// The number of the window that shows the series of a thumbnail cell.
@MainActor fileprivate func setThumbnailWindowNumber(_ cell: NSCell?, _ number: NSNumber?) {
    if let cell = cell as? ThumbnailCell {
        cell.windowNumber = number?.intValue ?? 0
    }
}

/// `[object isHidden]` of a study of the list, nil when it does not answer.
fileprivate func seriesListIsHidden(_ object: AnyObject) -> Bool? {
    let selector = NSSelectorFromString("isHidden")
    guard let object = object as? NSObject, object.responds(to: selector) else { return nil }
    typealias Send = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(object.method(for: selector), to: Send.self)(object, selector)
}

/// `[dictionary setObject: object forKey: key]`: a nil object raises.
fileprivate func seriesListSet(_ dictionary: NSMutableDictionary, _ object: Any?, _ key: NSAttributedString.Key) {
    _ = dictionary.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: object, with: key.rawValue as NSString)
}

/// The picture of a cell at the size the database font preference asks:
/// set (as image and alternate image) or, for another preference, left.
@MainActor fileprivate func setSizedPicture(_ cell: NSButtonCell?, _ image: NSImage?) {
    switch SeriesListPictureSize.of(fontSize: UserDefaults.standard.integer(forKey: "dbFontSize")) {
    case .scaled(let factor):
        cell?.image = image?.imageByScalingProportionallyUsingNSImage(Float(factor))
        cell?.alternateImage = image?.imageByScalingProportionallyUsingNSImage(Float(factor))
    case .unscaled:
        cell?.image = image
        cell?.alternateImage = image
    case .none:
        break
    }
}

extension ViewerController {

    /// The index of the series shown in the current time point among the
    /// list's cells, NSNotFound when it is not there.
    fileprivate func seriesListCurrentSeriesIndex() -> Int {
        let objects = ((horos_previewMatrix?.cells as NSArray?)?.value(forKeyPath: "representedObject.object") as? NSArray) ?? NSArray()
        let series = ((horos_fileList(at: Int(horos_curMovieIndex)) as NSArray?)?.object(at: 0) as? NSObject)?.value(forKey: "series")
        guard let series else { return NSNotFound }
        return objects.index(of: series)
    }
}

public extension ViewerController {

    @objc(matrixPreviewRetrieveExcludedSeries:)
    func matrixPreviewRetrieveExcludedSeries(_ sender: Any!) {
        let placeholder = ((sender as? NSMatrix)?.selectedCell()?.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object
        if let placeholder = placeholder as? ExcludedSeries {
            DCMTKQueryNode.retrieveExcludedSeries(placeholder)
        }
    }

    @objc(excludedSeriesDidChange:)
    func excludedSeriesDidChange(_ note: Notification!) {
        if horos_windowWillClose || matrixIsVisible() == false { return }
        buildMatrixPreview(false)
    }

    @objc(matrixPreviewPressed:)
    func matrixPreviewPressed(_ sender: Any!) {
        let cell = (sender as? NSMatrix)?.selectedCell() as? ThumbnailCell

        cell?.lineBreakMode = .byWordWrapping
        cell?.font = NSFont.boldSystemFont(ofSize: CGFloat(BrowserController.currentBrowser()?.fontSize("dbSmallMatrixFont") ?? 0))

        cell?.imagePosition = .imageBelow
        cell?.isTransparent = false
        cell?.isEnabled = true

        cell?.setButtonType(.momentaryPushIn)
        cell?.bezelStyle = .shadowlessSquare
        cell?.highlightsBy = .contentsCellMask
        cell?.imageScaling = .scaleProportionallyDown
        cell?.isBordered = true

        let series = ((sender as? NSMatrix)?.selectedCell()?.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object

        loadSelectedSeries(series, rightClick: cell?.rightClick ?? false)
    }

    @objc(matrixPreviewSwitchHidden:)
    func matrixPreviewSwitchHidden(_ sender: Any!) {
        let curStudy = ((sender as? NSMatrix)?.selectedCell()?.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object

        if let study = curStudy as? DicomStudy {
            // A local study.
            if NSApplication.shared.currentEvent?.modifierFlags.contains(.command) == true {
                BrowserController.currentBrowser()?.databaseOpenStudy(study)
            } else {
                study.setHidden(!study.isHidden())

                for case let v as ViewerController in (ViewerController.getDisplayed2DViewers() as NSArray?) ?? NSArray() {
                    if viewerSameString(v.studyInstanceUID(), studyInstanceUID()) {
                        v.buildMatrixPreview(false)
                    } else {
                        v.buildMatrixPreview(true)
                    }
                }
            }
        } else if let node = curStudy as? DCMTKStudyQueryNode {
            // A study on a PACS.
            BrowserController.currentBrowser()?.retrieveComparativeStudy(node, select: false, open: false)
        }
    }

    @objc(checkBuiltMatrixPreview)
    func checkBuiltMatrixPreview() {
        if checkFrameSize() == true && horos_matrixPreviewBuilt == false {
            if window?.isKeyWindow == true {
                buildMatrixPreview(true)
            } else {
                buildMatrixPreview(false)
            }
        }
    }

    /// Red.
    @objc(_selectedItemColor)
    class func _selectedItemColor() -> NSColor {
        NSColor(calibratedRed: 252.0 / 255, green: 177.0 / 255, blue: 141.0 / 255, alpha: 1)
    }

    /// Yellow.
    @objc(_openItemColor)
    class func _openItemColor() -> NSColor {
        NSColor(calibratedRed: 249.0 / 255, green: 240.0 / 255, blue: 140.0 / 255, alpha: 1)
    }

    @objc(buildMatrixPreview:)
    func buildMatrixPreview(_ showSelected: Bool) {
        // Done later by -checkBuiltMatrixPreview: a faster opening.
        if window?.isVisible != true { return }
        if horos_windowWillClose { return }

        // The series menu builds all its items later, when needed.
        horos_needsToBuildSeriesPopupMenu = true
        horos_needsToBuildSeriesMatrix = true

        let inverted = ViewerController.horos_DisplayUseInvertedPolarity()

        horos_seriesPopupMenu?.menu?.removeAllItems()
        let menuItem = NSMenuItem(title: "", action: #selector(ViewerController.seriesPopupSelect(_:)), keyEquivalent: "")
        var img = (currentSeries()?.primitiveValue(forKey: "thumbnail") as? Data).flatMap { NSImage(data: $0) }

        if inverted {
            img = img?.imageInverted()
        }

        menuItem.image = img?.imageByScalingProportionallyToSizeUsingNSImage(NSSize(width: seriesPopupPictureSize, height: seriesPopupPictureSize))
        horos_seriesPopupMenu?.menu?.addItem(menuItem)
        horos_seriesPopupContextualMenu?.title = currentSeries()?.name ?? NSLocalizedString("Unnamed", comment: "")

        if matrixIsVisible() == false {
            return
        }

        var hasComparatives = false, hasComparativesNewerThanMostRecentLoaded = false
        var returned = false

        if let e = viewerObjCTry({
            let db = BrowserController.currentBrowser()?.database
            var index = 0
            let curImage = (horos_fileList(at: 0) as NSArray?)?.object(at: 0) as? NSObject
            let origin = horos_previewMatrix?.superview?.bounds.origin ?? .zero

            let visible = checkFrameSize()

            horos_matrixPreviewBuilt = visible

            horos_previewMatrixScrollView?.postsBoundsChangedNotifications = true

            guard let study = curImage?.value(forKeyPath: "series.study") as? DicomStudy else {
                horos_previewMatrix?.renewRows(0, columns: 0)
                horos_previewMatrix?.sizeToCells()
                horos_matrixPreviewBuilt = false
                returned = true
                return
            }

            let viewerSeries = seriesListViewerSeries(checkingNil: false)

            let found = seriesListPatientStudies(of: study, database: db, selectingInBrowser: false)

            seriesListMakeRetrieveImage(side: seriesPopupPictureSize)

            if let studiesArray = found, studiesArray.count != 0 {
                let showsSeriesColors = SeriesListIdentification.showsColors(in: UserDefaults.standard)
                let seriesWindowColors = ViewerController.horosSeriesWindowColors()
                let seriesWindowNumbers = ViewerController.horosSeriesWindowNumbers()
                let excludedSeriesOfStudies = NSMutableDictionary()

                var i = 0
                let listed = seriesListStudies(NSArray(array: studiesArray as [AnyObject]), viewerStudy: study, database: db) { s, children in
                    if s.isHidden() == false {
                        i += children.count
                    }

                    // The series a DICOMweb node's rule left out, after them.
                    let excluded = BrowserController.horosExcludedSeries(ofLocalStudy: s, database: db?.dataBaseDirPath ?? "")
                    excludedSeriesOfStudies.setObject(excluded, forKey: NSValue(nonretainedObject: s))
                    if s.isHidden() == false {
                        i += excluded.count
                    }
                }
                hasComparatives = listed.hasComparatives
                hasComparativesNewerThanMostRecentLoaded = listed.hasComparativesNewerThanLoaded
                let allStudiesArray = listed.all
                let shownStudies = listed.shown

                horos_previewMatrix?.cellClass = ThumbnailCell.self

                // One column down a side strip or in the floating panel, one
                // row across a docked top or bottom strip; the cell size never
                // changes, so the thumbnails scroll instead of being squeezed.
                // The cells are filled by their position in the list, which is
                // the same in both.
                if let matrix = horos_previewMatrix {
                    SeriesListLayout.layOut(matrix, count: i + shownStudies.count,
                                            placement: SeriesListLayout.storedPlacement(in: UserDefaults.standard),
                                            floating: UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList"))
                }

                for case let cell as NSButtonCell in horos_previewMatrix?.cells ?? [] {
                    cell.lineBreakMode = .byWordWrapping
                    cell.font = NSFont.boldSystemFont(ofSize: CGFloat(BrowserController.currentBrowser()?.fontSize("dbSmallMatrixFont") ?? 0))
                    cell.backgroundColor = nil
                    setThumbnailFrame(cell, nil)

                    cell.representedObject = nil

                    cell.imagePosition = .imageBelow
                    cell.isTransparent = false
                    cell.isEnabled = true

                    cell.setButtonType(.momentaryPushIn)
                    cell.bezelStyle = .shadowlessSquare
                    cell.highlightsBy = .contentsCellMask
                    cell.imageScaling = .scaleProportionallyDown
                    cell.isBordered = true

                    cell.title = ""

                    cell.image = nil

                    cell.target = self
                }

                for case var curStudy as AnyObject in shownStudies {
                    let cell = horos_previewMatrix.flatMap { SeriesListLayout.cell(of: $0, at: index) } as? NSButtonCell

                    let curStudyIndexAll = allStudiesArray.index(of: curStudy)
                    let curStudyIndex = shownStudies.index(of: curStudy)

                    cell?.representedObject = O2ViewerThumbnailsMatrixRepresentedObject.object(curStudy, children: listed.shownSeries.object(at: curStudyIndex) as? NSArray)
                    cell?.action = #selector(ViewerController.matrixPreviewSwitchHidden(_:))

                    if curStudy is DCMTKStudyQueryNode && viewerSameString((curStudy as? NSObject)?.value(forKey: "studyInstanceUID"), study.studyInstanceUID) {
                        // For the current study, always take the local images.
                        curStudy = study
                    }

                    let isViewerStudy = viewerSameString((curStudy as? NSObject)?.value(forKey: "studyInstanceUID"), study.studyInstanceUID)
                    cell?.backgroundColor = isViewerStudy ? nil : SeriesListColors.otherStudy

                    let series = listed.shownSeries.object(at: curStudyIndex) as? NSArray ?? NSArray()
                    var images: NSArray? = nil

                    if let localStudy = curStudy as? DicomStudy {
                        if let e = viewerObjCTry({
                            images = BrowserController.currentBrowser()?.imagesArray(localStudy, preferredObject: Int32(bitPattern: oAny.rawValue)) as NSArray?

                            if series.count != (images?.count ?? 0) {
                                N2LogStackTraceMessage("[series count] != [images count] : You should not be here......")
                            }

                            let name = ((localStudy as NSObject).value(forKey: "studyName") as? NSString)?.stringByTruncating(toLength: 34) as String?

                            let states = (BrowserController.statesArray() as NSArray?) ?? NSArray()
                            let stateIndex = SeriesListStudyNumbers.stateIndex(ViewerSender.intValue((localStudy as NSObject).value(forKey: "stateText")), stateCount: states.count)
                            let stateText = stateIndex.flatMap { states.object(at: $0) as? String } ?? ""
                            var comment = (localStudy as NSObject).value(forKey: "comment") as? NSString ?? ""
                            comment = comment.withTruncatingToLength(32) as NSString

                            let modality = (localStudy as NSObject).value(forKey: "modality") as? String ?? "OT:"

                            var action: String? = nil
                            if (cell?.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object is DCMTKStudyQueryNode {
                                // This is an incomplete study.
                                setSizedPicture(cell, seriesListRetrieveImage)

                                cell?.imagePosition = .imageOverlaps
                                cell?.imageScaling = .scaleProportionallyDown
                            } else {
                                if localStudy.isHidden() {
                                    action = NSLocalizedString("Show Series", comment: "")
                                } else {
                                    action = NSLocalizedString("Hide Series", comment: "")
                                }
                            }

                            let patName = seriesListPatientLine((localStudy as NSObject).value(forKey: "name"),
                                                                dateOfBirth: (localStudy as NSObject).value(forKey: "dateOfBirth"),
                                                                separator: "\r", viewerStudy: study)

                            let seriesCount = String(format: "%d %@", Int32(truncatingIfNeeded: series.count),
                                                     series.count == 1 ? NSLocalizedString("series", comment: "one series, singular")
                                                                       : NSLocalizedString("series", comment: "zero or 2 or more series, plural"))
                            let components = SeriesListTitles.cellLines(
                                number: String(format: " %d ", SeriesListStudyNumbers.number(studyIndex: curStudyIndexAll)), patient: patName, name: name,
                                date: seriesListDateText(localStudy.date),
                                modalityAndSeries: String(format: NSLocalizedString("%@: %@", comment: "semicolon separator for spacing"), modality, seriesCount),
                                state: stateText, comment: comment as String, action: action)

                            let finalString = NSMutableAttributedString(string: components.joined(separator: "\r"))

                            let attribs = NSMutableDictionary()
                            attribs[NSAttributedString.Key.font] = NSFont.boldSystemFont(ofSize: CGFloat(BrowserController.currentBrowser()?.fontSize("viewerNumberFont") ?? 0))

                            let bkgColor = seriesListStudyColor(studyIndex: curStudyIndexAll, inverted: inverted)

                            seriesListSet(attribs, bkgColor, .backgroundColor)
                            let numberLength = (components[0] as NSString).length
                            finalString.setAttributes(attribs as? [NSAttributedString.Key: Any], range: NSRange(location: 0, length: numberLength))

                            attribs[NSAttributedString.Key.font] = NSFont.boldSystemFont(ofSize: CGFloat(BrowserController.currentBrowser()?.fontSize("dbSmallMatrixFont") ?? 0))
                            attribs.removeObject(forKey: NSAttributedString.Key.backgroundColor)
                            finalString.setAttributes(attribs as? [NSAttributedString.Key: Any], range: NSRange(location: numberLength, length: finalString.length - numberLength))

                            finalString.setAlignment(.center, range: NSRange(location: 0, length: finalString.length))
                            cell?.attributedTitle = finalString
                        }) {
                            _N2LogExceptionImpl(e, false, "-[ViewerController buildMatrixPreview:]")
                        }
                        index += 1
                    }

                    if let node = curStudy as? DCMTKQueryNode {
                        // A study on a PACS.
                        if let e = viewerObjCTry({
                            let local = db?.objects(forEntity: db?.studyEntity(),
                                                    predicate: viewerPredicate("studyInstanceUID = %@ AND patientID = %@", viewerSendObject(node, "studyInstanceUID"),
                                                                               viewerSendObject(node, "patientID"))) as NSArray?
                            if (local?.count ?? 0) != 0 {
                                images = BrowserController.currentBrowser()?.imagesArray(local?.object(at: 0), preferredObject: Int32(bitPattern: oAny.rawValue)) as NSArray?
                            }

                            let name = ((node as NSObject).value(forKey: "studyName") as? NSString)?.stringByTruncating(toLength: 34) as String? ?? ""
                            let modality = (node as NSObject).value(forKey: "modality") as? String ?? "OT"

                            let patName = seriesListPatientLine((node as NSObject).value(forKey: "name"),
                                                                dateOfBirth: (node as NSObject).value(forKey: "dateOfBirth"),
                                                                separator: "\r", viewerStudy: study)

                            // No state nor comment for a study on a PACS.
                            cell?.title = SeriesListTitles.comparativeCellLines(patient: patName, name: name, date: seriesListDateText(node.date() as Date?),
                                                                                modality: modality).joined(separator: "\r")

                            setSizedPicture(cell, seriesListRetrieveImage)

                            cell?.imagePosition = .imageOverlaps
                            cell?.imageScaling = .scaleProportionallyDown
                        }) {
                            _N2LogExceptionImpl(e, false, "-[ViewerController buildMatrixPreview:]")
                        }
                        index += 1
                    }

                    if seriesListIsHidden(curStudy) != true {
                        for i in 0..<series.count {
                            let curSeries = series.object(at: i) as! DicomSeries

                            let cell = horos_previewMatrix.flatMap { SeriesListLayout.cell(of: $0, at: index) } as? NSButtonCell

                            cell?.backgroundColor = isViewerStudy ? nil : SeriesListColors.otherStudy

                            cell?.representedObject = O2ViewerThumbnailsMatrixRepresentedObject.object(curSeries)
                            cell?.font = NSFont.systemFont(ofSize: CGFloat(BrowserController.currentBrowser()?.fontSize("dbSmallMatrixFont") ?? 0))
                            cell?.action = #selector(ViewerController.matrixPreviewPressed(_:))
                            cell?.lineBreakMode = .byCharWrapping

                            var name = (curSeries as NSObject).value(forKey: "name") as? NSString

                            if (name?.length ?? 0) > 18 {
                                cell?.font = NSFont.boldSystemFont(ofSize: CGFloat(BrowserController.currentBrowser()?.fontSize("viewerSmallCellFont") ?? 0))
                                name = name?.stringByTruncating(toLength: 34)
                            }

                            let fileCount = ViewerSender.intValue((curSeries as NSObject).value(forKey: "noFiles"))
                            let frames = { () -> Int32 in
                                ViewerSender.intValue((((curSeries as NSObject).value(forKey: "images") as? NSSet)?.anyObject() as? NSObject)?.value(forKey: "numberOfFrames"))
                            }
                            let counted = SeriesListImageCount.of(
                                fileCount: fileCount,
                                rawFileCount: { ViewerSender.intValue((curSeries as NSObject).value(forKey: "rawNoFiles")) },
                                frames: {
                                    // One image: its frames, an exception logged.
                                    guard fileCount == 1 else { return frames() }
                                    var count: Int32 = 0
                                    if let e = viewerObjCTry({ count = frames() }) {
                                        _N2LogExceptionImpl(e, true, "-[ViewerController buildMatrixPreview:]")
                                    }
                                    return count
                                })
                            func word(_ kind: SeriesListImageCount.Kind) -> String {
                                switch kind {
                                case .image: return NSLocalizedString("Image", comment: "")
                                case .images: return NSLocalizedString("Images", comment: "")
                                case .frames: return NSLocalizedString("Frames", comment: "Frames: for example, 50 Frames in a series")
                                case .object: return NSLocalizedString("Object", comment: "")
                                case .objects: return NSLocalizedString("Objects", comment: "")
                                }
                            }

                            if name == nil {
                                name = ""
                            }

                            let seriesDateText = curSeries.displayDate.map { UserDefaults.formatDateTime($0) ?? "(null)" } ?? ""
                            cell?.title = String(format: "%@\r%@\r%@", name!, seriesDateText,
                                                 viewerSingularPluralCount(Int(counted.count), word(counted.singular), word(counted.plural)))

                            if showsSeriesColors && viewerSeries.contains(curSeries) {
                                cell?.backgroundColor = SeriesListColors.shown
                            } else if showsSeriesColors && blending()?.currentSeries() === curSeries {
                                cell?.backgroundColor = SeriesListColors.fused
                            }
                            // Shown in a window: framed in that window's colour.
                            setThumbnailFrame(cell, seriesWindowColors?.object(forKey: curSeries) as? NSColor)
                            setThumbnailWindowNumber(cell, seriesWindowNumbers?.object(forKey: curSeries) as? NSNumber)

                            if visible {
                                var img = seriesListThumbnail(of: curSeries, images: images, index: i, function: "-[ViewerController buildMatrixPreview:]")

                                if inverted {
                                    img = img?.imageInverted()
                                }

                                setSizedPicture(cell, img)
                            }

                            index += 1
                        }

                        for case let excluded as ExcludedSeries in (excludedSeriesOfStudies.object(forKey: NSValue(nonretainedObject: curStudy)) as? NSArray) ?? NSArray() {
                            let cell = horos_previewMatrix.flatMap { SeriesListLayout.cell(of: $0, at: index) } as? NSButtonCell
                            cell?.backgroundColor = viewerSameString((curStudy as? NSObject)?.value(forKey: "studyInstanceUID"), study.studyInstanceUID) ? nil : SeriesListColors.otherStudy
                            cell?.representedObject = O2ViewerThumbnailsMatrixRepresentedObject.object(excluded)
                            cell?.font = NSFont.systemFont(ofSize: CGFloat(BrowserController.currentBrowser()?.fontSize("dbSmallMatrixFont") ?? 0))
                            cell?.action = #selector(ViewerController.matrixPreviewRetrieveExcludedSeries(_:))
                            cell?.lineBreakMode = .byCharWrapping
                            let title = excluded.title(studyDate: (curStudy as? NSObject)?.value(forKey: "date") as? Date)
                            let attributes = NSMutableDictionary()
                            seriesListSet(attributes, cell?.font, .font)
                            seriesListSet(attributes, NSColor.disabledControlTextColor, .foregroundColor)
                            cell?.attributedTitle = NSAttributedString(string: title, attributes: attributes as? [NSAttributedString.Key: Any])
                            if visible {
                                var img: NSImage? = excluded.image(size: NSSize(width: 70, height: 70))
                                switch UserDefaults.standard.integer(forKey: "dbFontSize") {
                                case -1: img = img?.imageByScalingProportionallyUsingNSImage(0.6)
                                case 1: img = img?.imageByScalingProportionallyUsingNSImage(1.3)
                                default: break
                                }
                                cell?.image = img
                                cell?.alternateImage = img
                            }
                            index += 1
                        }
                    } else {
                        // The series are hidden: the study's cell is coloured
                        // when its series are selected.
                        var framed = false
                        for i in 0..<series.count {
                            let curSeries = series.object(at: i) as! DicomSeries

                            // The first of its series shown in a window frames the study.
                            if framed == false && (seriesWindowColors?.object(forKey: curSeries) != nil || seriesWindowNumbers?.object(forKey: curSeries) != nil) {
                                setThumbnailFrame(cell, seriesWindowColors?.object(forKey: curSeries) as? NSColor)
                                setThumbnailWindowNumber(cell, seriesWindowNumbers?.object(forKey: curSeries) as? NSNumber)
                                framed = true
                            }

                            if showsSeriesColors && viewerSeries.contains(curSeries) {
                                cell?.backgroundColor = SeriesListColors.shown
                                break
                            } else if showsSeriesColors && blending()?.currentSeries() === curSeries {
                                cell?.backgroundColor = SeriesListColors.fused
                                break
                            }
                        }
                    }
                }
            }

            horos_previewMatrix?.sizeToCells()

            if showSelected {
                let index = seriesListCurrentSeriesIndex()

                if index != NSNotFound, let matrix = horos_previewMatrix {
                    SeriesListLayout.scroll(matrix, toCellAt: index)
                }
            } else {
                horos_previewMatrixScrollView?.contentView.scroll(to: origin)
                if let contentView = horos_previewMatrixScrollView?.contentView {
                    horos_previewMatrixScrollView?.reflectScrolledClipView(contentView)
                }
            }

            horos_previewMatrix?.needsDisplay = true
        }) {
            _N2LogExceptionImpl(e, true, "-[ViewerController buildMatrixPreview:]")
        }

        // The comparatives button, as the @finally of the former method set it.
        let button = horos_comparativesButton
        button?.isEnabled = hasComparatives

        let listsComparatives = flagListPODComparatives?.boolValue ?? false
        let state = SeriesListComparativesButton.state(hasComparatives: hasComparatives, newerThanLoaded: hasComparativesNewerThanMostRecentLoaded,
                                                       listsComparatives: listsComparatives)
        var color = NSColor.white
        var tip = ""

        if state.checked {
            button?.title = String(format: "✓ %@", NSLocalizedString("Comparatives", comment: ""))
        } else {
            button?.title = NSLocalizedString("Comparatives", comment: "")
        }
        switch state.tint {
        case .plain: break
        case .available: color = type(of: self)._openItemColor()
        case .newer: color = type(of: self)._selectedItemColor()
        }
        switch state.hint {
        case .available: tip = NSLocalizedString("There are PACS On-Demand comparatives", comment: "")
        case .newer: tip = NSLocalizedString("There are more recent PACS On-Demand comparatives", comment: "")
        case nil: break
        }

        if let clickHides = state.clickHides {
            if !tip.isEmpty {
                tip += ", "
            }

            if clickHides {
                tip += NSLocalizedString("Click here to hide them", comment: "")
            } else {
                tip += NSLocalizedString("Click here to show them", comment: "")
            }
        }
        if let button {
            let attributes = NSMutableDictionary(dictionary: button.attributedTitle.attributes(at: 0, effectiveRange: nil))
            attributes[NSAttributedString.Key.foregroundColor] = color
            button.attributedTitle = NSAttributedString(string: button.title, attributes: attributes as? [NSAttributedString.Key: Any])
            button.toolTip = tip
        }

        // Whether the button would show: computed as before, not used.
        if UserDefaults.standard.bool(forKey: "searchForComparativeStudiesOnDICOMNodes") && database?.isReadOnly == false && database?.isLocal() == true {
            _ = BrowserController.comparativeServers()
        }

        if returned { return }

        for case let v as DCMView in (imageViews() as NSArray?) ?? NSArray() {
            v.computeColor()
        }

        buildSeriesPopup()

        horos_needsToBuildSeriesMatrix = false
    }

    @objc(matrixPreviewSelectCurrentSeries)
    func matrixPreviewSelectCurrentSeries() {
        showCurrentThumbnail(self)
    }

    @objc(showCurrentThumbnail:)
    func showCurrentThumbnail(_ sender: Any!) {
        let index = seriesListCurrentSeriesIndex()

        if index != NSNotFound, let matrix = horos_previewMatrix {
            SeriesListLayout.scroll(matrix, toCellAt: index)
        }
    }

    @objc(buildMatrixPreview)
    func buildMatrixPreview() {
        buildMatrixPreview(true)
    }

    @objc(syncThumbnails)
    func syncThumbnails() {
        viewBoundsDidChangeProtect = true

        for case let v as ViewerController in (ViewerController.getDisplayed2DViewers() as NSArray?) ?? NSArray() {
            var same = false

            if UserDefaults.standard.bool(forKey: "SyncSeriesListForAllComparativeStudies") {
                same = viewerSameString(v.currentStudy()?.patientUID, currentStudy()?.patientUID)
            } else {
                same = viewerSameString(v.studyInstanceUID(), studyInstanceUID())
            }

            if v !== self && same {
                let clipView = v.previewMatrixScrollView()?.contentView
                var proposedBounds = clipView?.bounds ?? .zero
                proposedBounds.origin = horos_previewMatrix?.superview?.bounds.origin ?? .zero
                if let clipView {
                    clipView.scroll(to: clipView.constrainBoundsRect(proposedBounds).origin)
                }
                if let contentView = v.previewMatrixScrollView()?.contentView {
                    v.previewMatrixScrollView()?.reflectScrolledClipView(contentView)
                }
            }
        }

        viewBoundsDidChangeProtect = false
    }

    @objc(ViewBoundsDidChange:)
    func ViewBoundsDidChange(_ note: Notification!) {
        if viewBoundsDidChangeProtect == false {
            viewBoundsDidChangeProtect = true

            if (note.object as AnyObject?) === horos_previewMatrixScrollView?.contentView {
                var syncThumbnails = UserDefaults.standard.bool(forKey: "syncPreviewList")

                if NSApplication.shared.currentEvent?.modifierFlags.contains(.command) == true {
                    syncThumbnails = !syncThumbnails
                }

                if syncThumbnails {
                    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(ViewerController.syncThumbnails), object: nil)
                    perform(#selector(ViewerController.syncThumbnails), with: nil, afterDelay: 0.1)
                }
            }

            viewBoundsDidChangeProtect = false
        }
    }

    @objc(ViewFrameDidChange:)
    func ViewFrameDidChange(_ note: Notification!) {
        if horos_windowWillClose {
            return
        }

        if let subviews = horos_splitView?.subviews, subviews.count > 1 {
            if (note.object as AnyObject?) === subviews[1] {
                if matrixIsVisible() && horos_matrixPreviewBuilt == false {
                    buildMatrixPreview()
                }
            }
        }
    }
}
