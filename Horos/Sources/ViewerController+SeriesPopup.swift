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

// The series menu of the 2D viewer (the series popup button of the
// toolbar and the series item of the contextual menu), the selection of a
// series from it or from the series list, and the window's file: the
// patient's studies with their series, most recent first.

/// The size of the pictures of the series menu.
let seriesPopupPictureSize: CGFloat = 35

/// The arrow of the studies that are only on a PACS, made once.
nonisolated(unsafe) var seriesListRetrieveImage: NSImage? = nil

/// The retrieve arrow, made the first time it is needed at `side` points.
func seriesListMakeRetrieveImage(side: CGFloat) {
    if seriesListRetrieveImage == nil {
        seriesListRetrieveImage = Bundle.main.path(forResource: "DownArrowGreyRev", ofType: "pdf").flatMap { NSImage(contentsOfFile: $0) }
        seriesListRetrieveImage?.size = NSSize(width: side, height: side)
    }
}

/// `[a isEqualToString: b]`: NO when either is nil.
func viewerSameString(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a as? NSString, let b = b as? String else { return false }
    return a.isEqual(to: b)
}

/// `[NSPredicate predicateWithFormat: format, arguments…]`, a nil argument
/// passed as nil.
func viewerPredicate(_ format: String, _ arguments: AnyObject?...) -> NSPredicate {
    let list: [CVarArg] = arguments.map { argument -> CVarArg in
        if let object = argument as? NSObject { return object }
        return Int(0)
    }
    return withVaList(list) { NSPredicate(format: format, arguments: $0) }
}

/// `[object selector]` of a method returning an object, sent as Objective-C
/// sends it: an object that does not implement it raises.
func viewerSendObject(_ object: AnyObject, _ selectorName: String) -> AnyObject? {
    (object as? NSObject)?.perform(NSSelectorFromString(selectorName))?.takeUnretainedValue()
}

/// `[a compare: b options: …] == NSOrderedSame` as Objective-C sends it: a
/// nil receiver answers 0, the same.
fileprivate func viewerComparesSame(_ a: String?, _ b: String?) -> Bool {
    guard let a = a as NSString? else { return true }
    typealias Compare = @convention(c) (AnyObject, Selector, AnyObject?, UInt) -> Int
    let selector = #selector(NSString.compare(_:options:))
    let compare = unsafeBitCast(a.method(for: selector), to: Compare.self)
    let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    return compare(a, selector, b as NSString?, options.rawValue) == ComparisonResult.orderedSame.rawValue
}

/// N2LocalizedSingularPluralCount of N2Stuff.h.
func viewerSingularPluralCount(_ count: Int, _ singular: String, _ plural: String) -> String {
    String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal), count == 1 ? singular : plural)
}

/// `[colors objectAtIndex: …]` of a study's colour, inverted for an
/// inverted display.
func seriesListStudyColor(studyIndex: Int, inverted: Bool) -> NSColor? {
    let colors = (ViewerController.studyColors() as NSArray?) ?? NSArray()
    guard let index = SeriesListStudyNumbers.colorIndex(studyIndex: studyIndex, colorCount: colors.count),
          var color = colors.object(at: index) as? NSColor else { return nil }
    if inverted {
        color = NSColor(calibratedRed: 1.0 - color.redComponent, green: 1.0 - color.greenComponent, blue: 1.0 - color.blueComponent, alpha: color.alphaComponent)
    }
    return color
}

/// The patient line of a study of the list or the menu.
func seriesListPatientLine(_ name: Any?, dateOfBirth: Any?, separator: String, viewerStudy: DicomStudy) -> String {
    SeriesListTitles.patientLine(name: name as? String, hasDateOfBirth: name != nil && dateOfBirth != nil,
                                 formattedDateOfBirth: { UserDefaults.formatDate(dateOfBirth as? Date) },
                                 separator: separator, isViewerPatient: { viewerSameString($0, viewerStudy.name) },
                                 showsPatientName: AnnotationLevel.currentLevelShowsPatientName)
}

/// The date and time of a study, as the list and the menu write it.
func seriesListDateText(_ date: Date?) -> String? {
    date.map { UserDefaults.dateTimeFormatter().string(from: $0) }
}

/// The patient's studies (from the browser's history of comparatives when it
/// is this patient's, or from the database, most recent first), the studies
/// of a PACS replaced by their local copy, and the series of each.
struct SeriesListStudies {
    /// The patient's studies, all of them, and the series of each.
    var all: NSArray
    var series: NSMutableArray
    /// The studies the list shows, with the series of each.
    var shown: NSArray
    var shownSeries: NSArray
    var hasComparatives: Bool
    var hasComparativesNewerThanLoaded: Bool
}

extension ViewerController {

    /// The series of each time point of the viewer.
    func seriesListViewerSeries(checkingNil: Bool) -> NSMutableArray {
        let viewerSeries = NSMutableArray()
        for i in 0..<Int(horos_maxMovieIndex) {
            let series = ((horos_fileList(at: i) as NSArray?)?.object(at: 0) as? NSObject)?.value(forKey: "series")
            if checkingNil {
                if let series { viewerSeries.add(series) }
            } else {
                viewerArrayAdd(series, to: viewerSeries)
            }
        }
        return viewerSeries
    }

    /// The patient's studies of `study`, as the series menu and the list
    /// look for them.
    func seriesListPatientStudies(of study: DicomStudy, database db: DicomDatabase?, selectingInBrowser: Bool) -> NSArray? {
        var searchString = (study as NSObject).value(forKey: "patientUID") as? NSString
        let predicate: NSPredicate
        if (searchString?.length ?? 0) == 0 || viewerSameString(searchString, "0") {
            searchString = (study as NSObject).value(forKey: "name") as? NSString
            predicate = viewerPredicate("(name == %@)", searchString)
        } else {
            predicate = viewerPredicate("(patientUID BEGINSWITH[cd] %@)", searchString)
        }

        // The browser's history, with the distant studies, when it is this
        // patient's.
        let browser = BrowserController.currentBrowser()
        if viewerComparesSame(browser?.comparativePatientUID, study.patientUID) && BrowserController.currentBrowser()?.comparativeStudies != nil {
            return BrowserController.currentBrowser()?.comparativeStudies as NSArray?
        }
        if selectingInBrowser {
            if BrowserController.currentBrowser()?.selectThisStudy(study) != true {
                NSLog("---- buildSeriesPopup - history not found")
            }
        }
        let studies = db?.objects(forEntity: db?.studyEntity(), predicate: predicate) as NSArray?
        return studies?.sortedArray(using: [NSSortDescriptor(key: "date", ascending: false)]) as NSArray?
    }

    /// The studies, the local copy of a PACS study when there is one, and the
    /// series of each; `excluded` collects the placeholders of the series a
    /// DICOMweb node left out of a local study, `seriesCount` the cells the
    /// list needs.
    func seriesListStudies(_ studiesArray: NSArray, viewerStudy study: DicomStudy, database db: DicomDatabase?,
                           countingCells: ((DicomStudy, NSArray) -> Void)?) -> SeriesListStudies {
        let seriesArray = NSMutableArray()
        for case var s as AnyObject in studiesArray {
            if s is DCMTKStudyQueryNode && viewerSameString((s as? NSObject)?.value(forKey: "studyInstanceUID"), study.studyInstanceUID) {
                // For the current study, always take the local images.
                s = study
            } else if let node = s as? DCMTKStudyQueryNode {
                // And still, if there are local series, display them.
                let local = db?.objects(forEntity: db?.studyEntity(),
                                        predicate: viewerPredicate("studyInstanceUID = %@ AND patientID = %@", viewerSendObject(node, "studyInstanceUID"),
                                                                   viewerSendObject(node, "patientID"))) as NSArray?
                if (local?.count ?? 0) != 0, let first = local?.object(at: 0) as AnyObject? { s = first }
            }

            if let local = s as? DicomStudy {
                viewerArrayAdd(BrowserController.currentBrowser()?.childrenArray(local), to: seriesArray)
                countingCells?(local, seriesArray.lastObject as? NSArray ?? NSArray())
            } else if s is DCMTKStudyQueryNode {
                seriesArray.add(NSArray())
            }
        }

        var counts: [Int] = []
        for index in 0..<studiesArray.count {
            counts.append((seriesArray.object(at: index) as? NSArray)?.count ?? 0)
        }
        let selection = SeriesListStudySelection.select(notLoaded: (studiesArray as [AnyObject]).map { $0 is DCMTKQueryNode },
                                                        seriesCounts: counts,
                                                        listsComparatives: { self.flagListPODComparatives?.boolValue ?? false })
        let shown = NSMutableArray(), shownSeries = NSMutableArray()
        for index in selection.shown {
            shown.add(studiesArray.object(at: index))
            shownSeries.add(seriesArray.object(at: index))
        }
        return SeriesListStudies(all: studiesArray, series: seriesArray, shown: shown, shownSeries: shownSeries,
                                 hasComparatives: selection.hasComparatives,
                                 hasComparativesNewerThanLoaded: selection.hasComparativesNewerThanLoaded)
    }

    /// The thumbnail of a series: the one stored, or one made from its image
    /// (stored when the preferences say so), or the missing file picture.
    func seriesListThumbnail(of curSeries: DicomSeries, images: NSArray?, index: Int, function: String) -> NSImage? {
        var img = (curSeries.primitiveValue(forKey: "thumbnail") as? Data).flatMap { NSImage(data: $0) }
        if img == nil {
            if let e = viewerObjCTry({
                // [images objectAtIndex: i]: out of the images, it raises here.
                let image = images?.object(at: index) as AnyObject?
                let path = (image as? NSObject)?.value(forKey: "completePath") as? String
                let seriesID = ViewerSender.intValue((image as? NSObject)?.value(forKeyPath: "series.id"))
                let dcmPix = DCMPix(path: path, 0, 0, nil, 0, Int(seriesID),
                                    isBonjour: BrowserController.currentBrowser()?.isCurrentDatabaseBonjour ?? false,
                                    imageObj: image as? NSManagedObject)
                dcmPix?.checkLoad()
                if let dcmPix, dcmPix.notAbleToLoadImage == false {
                    img = dcmPix.generateThumbnailImage(withWW: 0, wl: 0)
                    if let made = img {
                        if UserDefaults.standard.bool(forKey: "StoreThumbnailsInDB") {
                            curSeries.thumbnail = BrowserController.produceJPEGThumbnail(made)
                        }
                    } else {
                        img = NSImage(named: "FileNotFound.tif")
                    }
                } else {
                    img = NSImage(named: "FileNotFound.tif")
                }
            }) {
                _N2LogExceptionImpl(e, true, function)
                img = NSImage(named: "FileNotFound.tif")
            }
        }
        return img
    }
}

public extension ViewerController {

    @objc(buildSeriesPopup)
    func buildSeriesPopup() {
        if horos_needsToBuildSeriesPopupMenu == false {
            return
        }

        horos_needsToBuildSeriesPopupMenu = false

        horos_seriesPopupMenu?.menu?.removeAllItems()

        if horos_seriesPopupContextualMenu == nil {
            horos_seriesPopupContextualMenu = NSMenuItem(title: "Displayed Series", action: nil, keyEquivalent: "")
        }

        horos_seriesPopupContextualMenu?.submenu = nil

        let inverted = ViewerController.horos_DisplayUseInvertedPolarity()
        var returned = false

        if let e = viewerObjCTry({
            let db = BrowserController.currentBrowser()?.database
            var index = 0
            let curImage = (horos_fileList(at: 0) as NSArray?)?.object(at: 0) as? NSObject

            guard let study = curImage?.value(forKeyPath: "series.study") as? DicomStudy else {
                returned = true
                return
            }

            let viewerSeries = seriesListViewerSeries(checkingNil: false)

            let found = seriesListPatientStudies(of: study, database: db, selectingInBrowser: true)

            seriesListMakeRetrieveImage(side: 50)

            guard let studiesArray = found, studiesArray.count != 0 else { return }

            let showsSeriesColors = SeriesListIdentification.showsColors(in: UserDefaults.standard)
            let seriesWindowColors = ViewerController.horosSeriesWindowColors()
            let listed = seriesListStudies(NSArray(array: studiesArray as [AnyObject]), viewerStudy: study, database: db, countingCells: nil)
            let allStudiesArray = listed.all
            let shownStudies = listed.shown

            for case var curStudy as AnyObject in shownStudies {
                let cell = NSMenuItem(title: "", action: #selector(ViewerController.seriesPopupSelect(_:)), keyEquivalent: "")
                cell.target = self
                horos_seriesPopupMenu?.menu?.addItem(cell)

                let curStudyIndexAll = allStudiesArray.index(of: curStudy)
                let curStudyIndex = shownStudies.index(of: curStudy)

                cell.representedObject = O2ViewerThumbnailsMatrixRepresentedObject.object(curStudy, children: listed.shownSeries.object(at: curStudyIndex) as? NSArray)

                if curStudy is DCMTKStudyQueryNode && viewerSameString((curStudy as? NSObject)?.value(forKey: "studyInstanceUID"), study.studyInstanceUID) {
                    // For the current study, always take the local images.
                    curStudy = study
                }
                let series = listed.shownSeries.object(at: curStudyIndex) as? NSArray ?? NSArray()
                var images: NSArray? = nil

                if let localStudy = curStudy as? DicomStudy {
                    if let e = viewerObjCTry({
                        images = BrowserController.currentBrowser()?.imagesArray(localStudy, preferredObject: Int32(bitPattern: oAny.rawValue)) as NSArray?

                        if series.count != (images?.count ?? 0) {
                            N2LogStackTraceMessage("[series count] != [images count] : You should not be here......")
                        }

                        let name = ((localStudy as NSObject).value(forKey: "studyName") as? NSString)?.stringByTruncating(toLength: 50) as String?

                        var comment = (localStudy as NSObject).value(forKey: "comment") as? NSString ?? ""
                        comment = comment.withTruncatingToLength(50) as NSString

                        let modality = (localStudy as NSObject).value(forKey: "modality") as? String ?? "OT:"

                        if (cell.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object is DCMTKStudyQueryNode {
                            // This is an incomplete study.
                            cell.image = seriesListRetrieveImage
                        }

                        let patName = seriesListPatientLine((localStudy as NSObject).value(forKey: "name"),
                                                            dateOfBirth: (localStudy as NSObject).value(forKey: "dateOfBirth"),
                                                            separator: " ", viewerStudy: study)

                        let bkgColor = seriesListStudyColor(studyIndex: curStudyIndexAll, inverted: inverted)

                        let s = NSAttributedString(string: String(format: "%d", SeriesListStudyNumbers.number(studyIndex: curStudyIndexAll)),
                                                   attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])

                        let number = NSImage(size: NSSize(width: seriesPopupPictureSize, height: seriesPopupPictureSize), flipped: false) { bounds in
                            bkgColor?.set()
                            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
                            s.draw(at: NSPoint(x: (seriesPopupPictureSize - s.size().width) / 2, y: (seriesPopupPictureSize - s.size().height) / 2))
                            return true
                        }

                        cell.image = number

                        let title = SeriesListTitles.menuTitle(date: seriesListDateText(localStudy.date), patient: patName, name: name,
                                                               modality: modality, comment: comment as String)
                        cell.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
                    }) {
                        _N2LogExceptionImpl(e, false, "-[ViewerController buildSeriesPopup]")
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

                        let name = ((node as NSObject).value(forKey: "studyName") as? NSString)?.stringByTruncating(toLength: 50) as String? ?? ""
                        let modality = (node as NSObject).value(forKey: "modality") as? String ?? "OT"

                        let patName = seriesListPatientLine((node as NSObject).value(forKey: "name"),
                                                            dateOfBirth: (node as NSObject).value(forKey: "dateOfBirth"),
                                                            separator: "\r", viewerStudy: study)

                        let title = SeriesListTitles.menuTitle(date: seriesListDateText(node.date() as Date?), patient: patName, name: name,
                                                               modality: modality, comment: nil)
                        cell.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])

                        cell.image = seriesListRetrieveImage
                    }) {
                        _N2LogExceptionImpl(e, false, "-[ViewerController buildSeriesPopup]")
                    }
                    index += 1
                }

                for i in 0..<series.count {
                    let curSeries = series.object(at: i) as! DicomSeries

                    var attributes: [NSAttributedString.Key: Any] = [:]
                    let cell = NSMenuItem(title: "", action: #selector(ViewerController.seriesPopupSelect(_:)), keyEquivalent: "")
                    cell.target = self
                    horos_seriesPopupMenu?.menu?.addItem(cell)

                    cell.representedObject = O2ViewerThumbnailsMatrixRepresentedObject.object(curSeries)

                    var name = (curSeries as NSObject).value(forKey: "name") as? NSString

                    if (name?.length ?? 0) > 50 {
                        name = name?.stringByTruncating(toLength: 50)
                    }

                    if name == nil {
                        name = ""
                    }

                    if viewerSeries.contains(curSeries) {
                        horos_seriesPopupMenu?.select(cell)
                    }
                    if showsSeriesColors && viewerSeries.contains(curSeries) {
                        attributes[.backgroundColor] = SeriesListColors.shown
                    } else if showsSeriesColors && blending()?.currentSeries() === curSeries {
                        attributes[.backgroundColor] = SeriesListColors.fused
                    } else if let color = seriesWindowColors?.object(forKey: curSeries) as? NSColor {
                        // The colour of the window that shows it.
                        attributes[.backgroundColor] = color.withAlphaComponent(0.5)
                    }

                    attributes[.font] = NSFont.systemFont(ofSize: 14)

                    let title = (name! as String) + String(format: " / %@", viewerSingularPluralCount(curSeries.images?.count ?? 0, "image", "images"))

                    cell.attributedTitle = NSAttributedString(string: title, attributes: attributes)

                    var img = seriesListThumbnail(of: curSeries, images: images, index: i, function: "-[ViewerController buildSeriesPopup]")

                    if inverted {
                        img = img?.imageInverted()
                    }

                    cell.image = img?.imageByScalingProportionallyToSizeUsingNSImage(NSSize(width: seriesPopupPictureSize, height: seriesPopupPictureSize))

                    index += 1
                }

                if curStudy !== shownStudies.lastObject as AnyObject? {
                    horos_seriesPopupMenu?.menu?.addItem(NSMenuItem.separator())
                }
            }
            _ = index
        }) {
            _N2LogExceptionImpl(e, true, "-[ViewerController buildSeriesPopup]")
        }
        if returned { return }

        horos_seriesPopupContextualMenu?.submenu = horos_seriesPopupMenu?.menu?.copy() as? NSMenu
        horos_seriesPopupContextualMenu?.image = horos_seriesPopupMenu?.selectedItem?.image
        horos_seriesPopupContextualMenu?.title = currentSeries()?.name ?? NSLocalizedString("Unnamed", comment: "")

        for case let v as DCMView in (imageViews() as NSArray?) ?? NSArray() {
            v.computeColor()
        }
    }

    @objc(loadSelectedSeries:rightClick:)
    func loadSelectedSeries(_ series: Any!, rightClick: Bool) {
        var series: AnyObject? = series as AnyObject?
        if let s = series as? DicomStudy {
            let seriesArray = s.imageSeriesContainingPixels(true) as NSArray?
            if (seriesArray?.count ?? 0) != 0 {
                series = seriesArray?.object(at: 0) as AnyObject?
            } else {
                return
            }
        }

        let viewerSeries = seriesListViewerSeries(checkingNil: true)

        let modifiers = NSApplication.shared.currentEvent?.modifierFlags ?? []

        if (rightClick || modifiers.contains(.command)) && horos_FullScreenOn == false {
            if modifiers.contains(.shift) || (BrowserController.currentBrowser()?.is(usingExternalViewer: series as? NSManagedObject) ?? false) == false {
                let c = UserDefaults.standard.bool(forKey: "syncPreviewList")

                UserDefaults.standard.set(false, forKey: "syncPreviewList")

                let newViewer = BrowserController.currentBrowser()?.loadSeries(series as? NSManagedObject, nil, true, keyImagesOnly: horos_displayOnlyKeyImages)
                newViewer?.setHighLighted(1.0)

                if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") == false {
                    showCurrentThumbnail(self)
                }

                if UserDefaults.standard.bool(forKey: "AUTOTILING") {
                    NSApp.sendAction(#selector(AppController.tileWindows(_:)), to: nil, from: self)
                } else {
                    AppController.shared()?.checkAllWindowsAreVisible(self, makeKey: true)
                }

                for i in 0..<NSScreen.screens.count {
                    AppControllerCAPIThumbnailsListPanel(i)?.setThumbnailsView(nil, viewer: nil)
                }

                window?.makeKeyAndOrderFront(self)
                refreshToolbar()
                updateNavigator()

                newViewer?.showCurrentThumbnail(self)

                UserDefaults.standard.set(c, forKey: "syncPreviewList")
                syncThumbnails()
            }
        } else {
            if !viewerSeries.contains(series as Any) {
                var found = false
                var showWindowIfDisplayed = UserDefaults.standard.bool(forKey: "showWindowInsteadOfSwitching")

                if modifiers.contains(.shift) {
                    showWindowIfDisplayed = !showWindowIfDisplayed
                }

                if showWindowIfDisplayed {
                    // Is this series already displayed? Select it.
                    for case let v as ViewerController in (ViewerController.getDisplayed2DViewers() as NSArray?) ?? NSArray() {
                        if v.imageView()?.seriesObj() === series && v !== self {
                            v.window?.makeKeyAndOrderFront(self)
                            v.setHighLighted(1.0)

                            found = true
                        }
                    }
                }

                if found == false {
                    let savedAUTOHIDEMATRIX = UserDefaults.standard.bool(forKey: "AUTOHIDEMATRIX")

                    UserDefaults.standard.set(false, forKey: "AUTOHIDEMATRIX")

                    if modifiers.contains(.shift) || (BrowserController.currentBrowser()?.is(usingExternalViewer: series as? NSManagedObject) ?? false) == false {
                        _ = BrowserController.currentBrowser()?.loadSeries(series as? NSManagedObject, self, true, keyImagesOnly: horos_displayOnlyKeyImages)

                        showCurrentThumbnail(self)
                        updateNavigator()
                    }

                    UserDefaults.standard.set(savedAUTOHIDEMATRIX, forKey: "AUTOHIDEMATRIX")
                }
            } else if series !== ((horos_fileList(at: Int(horos_curMovieIndex)) as NSArray?)?.object(at: 0) as? NSObject)?.value(forKey: "series") as AnyObject? {
                // Select it in 4D.
                let idx = viewerSeries.index(of: series as Any)

                if idx != NSNotFound {
                    setMovieIndex(Int16(truncatingIfNeeded: idx))
                    propagateSettings()
                }
            } else {
                mouseMoved()
            }
        }
    }

    @objc(seriesPopupSelect:)
    @IBAction func seriesPopupSelect(_ sender: NSMenuItem!) {
        var series = (sender.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object as AnyObject?

        if let s = series as? DicomStudy {
            series = (s.imageSeries() as NSArray?)?.object(at: 0) as AnyObject?

            for i in horos_seriesPopupMenu?.menu?.items ?? [] {
                if series === (i.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object as AnyObject? {
                    horos_seriesPopupMenu?.select(i)
                }
            }
        }

        if let node = series as? DCMTKStudyQueryNode {
            // A study on a PACS.
            BrowserController.currentBrowser()?.retrieveComparativeStudy(node, select: true, open: true, showGUI: true, viewer: self)
            return
        }

        loadSelectedSeries(series, rightClick: false)
    }

    @objc(matrixPreviewLoadAllSeries:)
    func matrixPreviewLoadAllSeries(_ sender: Any!) {
    }

    @objc(updateRepresentedFileName)
    func updateRepresentedFileName() {
        let image = (horos_fileList(at: Int(horos_curMovieIndex)) as NSArray?)?.object(at: Int(horos_imageView?.curImage ?? 0)) as? NSManagedObject
        let path = BrowserController.currentBrowser()?.getLocalDCMPath(image, 0)
        window?.representedFilename = path ?? ""
    }

    @objc(window:shouldPopUpDocumentPathMenu:)
    func window(_ sender: NSWindow, shouldPopUpDocumentPathMenu titleMenu: NSMenu) -> Bool {
        updateRepresentedFileName()

        return true
    }

    @objc(viewXML:)
    func viewXML(_ sender: Any!) {
        checkEverythingLoaded()

        let list = horos_fileList(at: Int(horos_curMovieIndex)) as NSArray?
        let path = BrowserController.currentBrowser()?.getLocalDCMPath(list?.object(at: Int(horos_imageView?.curImage ?? 0)) as? NSManagedObject, 0)
        window?.representedFilename = path ?? ""

        let im = list?.object(at: Int(horos_imageView?.curImage ?? 0)) as? DicomImage

        if XMLController.window(for: self) != nil {
            XMLController.window(for: self)?.window?.makeKeyAndOrderFront(self)
        } else {
            let xmlController = XMLController(image: im, windowName: String(format: NSLocalizedString("Meta-Data: %@", comment: ""), window?.title ?? "(null)"), viewer: self)
            // Its +1, as [XMLController alloc] left it: the controller lets
            // itself go when its window closes.
            if let xmlController { _ = Unmanaged.passRetained(xmlController) }
            xmlController?.window?.alphaValue = 0.01

            AppController.shared()?.tileWindows(nil)

            for i in 0..<15 {
                xmlController?.window?.alphaValue = (CGFloat(i) + 1.0) / 15.0
                Thread.sleep(forTimeInterval: 0.03)
            }

            window?.makeKeyAndOrderFront(self)
        }
    }
}
