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
import IsiXPreferences

// The series menu of the 2D viewer (the series popup button of the toolbar and
// the series item of the contextual menu), the selection of a series from it
// or from the series list, and the window's file: the patient's studies with
// their series, most recent first. SeriesMenuPresenter builds the menu from a
// SeriesMenuModel (IsiXImaging) and answers its choices; it reaches the
// database window through SeriesMenuBrowsing, the browser's comparative
// studies taken from the viewer's graph. The viewer keeps the selectors the
// nib, the menus and plugins send, as a façade over the presenter.

/// The size of the pictures of the series menu.
let seriesPopupPictureSize: CGFloat = 35

/// The arrow of the studies that are only on a PACS, made once: the series
/// menu and the series list make it on the main actor.
@MainActor var seriesListRetrieveImage: NSImage? = nil

/// The retrieve arrow, made the first time it is needed at `side` points.
@MainActor func seriesListMakeRetrieveImage(side: CGFloat) {
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
    let colors = ViewerController.studyColors() ?? []
    guard let index = SeriesListStudyNumbers.colorIndex(studyIndex: studyIndex, colorCount: colors.count),
          var color = colors[index] as? NSColor else { return nil }
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
/// of a PACS replaced by their local copy, and the series of each. The series
/// list keeps them as the arrays its cells and their represented objects take.
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

// MARK: - The database window

/// What the series menu asks of the database window, besides the comparative
/// studies the series list asks for: the history of the patient it holds, the
/// series of a study, opening a series in a viewer, retrieving a comparative
/// study from its PACS, the file of an image. The menu reaches the browser only
/// through this.
@MainActor protocol SeriesMenuBrowsing: ComparativeStudiesProviding {
    /// The browser's history of comparative studies, when it is the history
    /// of `patientUID` (compared as the browser compares them); nil otherwise.
    func history(ofPatient patientUID: String?) -> [Any]?
    /// Selects `study` in the browser; false when it is not found there.
    func select(_ study: DicomStudy) -> Bool
    /// The series of a study, as the browser lists them.
    func series(of study: DicomStudy) -> [Any]?
    /// `series` opens in an external viewer (a DICOM node's viewer) rather
    /// than in a 2D viewer.
    func usesExternalViewer(for series: NSManagedObject?) -> Bool
    /// Opens `series` in `viewer`, or in a new viewer when it is nil.
    func load(_ series: NSManagedObject?, into viewer: ViewerController?, keyImagesOnly: Bool) -> ViewerController?
    /// Retrieves a comparative study from its PACS, selects it and opens it in `viewer`.
    func retrieveAndOpen(_ study: DCMTKStudyQueryNode, in viewer: ViewerController)
}

/// The browser of the process graph, asked at each call, as the menu's
/// database window.
extension BrowserComparativeStudies: SeriesMenuBrowsing {
    private var currentBrowser: BrowserController? {
        processGraph.currentBrowser
    }

    func history(ofPatient patientUID: String?) -> [Any]? {
        let browser = currentBrowser
        guard viewerComparesSame(browser?.comparativePatientUID, patientUID) else { return nil }
        return browser?.comparativeStudies
    }

    func select(_ study: DicomStudy) -> Bool {
        // The window keeps the database it shows: showing another closes every
        // viewer, and the list selects its viewer's study each time it is built.
        currentBrowser?.selectThisStudy(study, switchingDatabase: false) ?? false
    }

    func series(of study: DicomStudy) -> [Any]? {
        currentBrowser?.childrenArray(study)
    }

    func usesExternalViewer(for series: NSManagedObject?) -> Bool {
        currentBrowser?.is(usingExternalViewer: series) ?? false
    }

    func load(_ series: NSManagedObject?, into viewer: ViewerController?, keyImagesOnly: Bool) -> ViewerController? {
        currentBrowser?.loadSeries(series, viewer, true, keyImagesOnly: keyImagesOnly)
    }

    func retrieveAndOpen(_ study: DCMTKStudyQueryNode, in viewer: ViewerController) {
        currentBrowser?.retrieveComparativeStudy(study, select: true, open: true, showGUI: true, viewer: viewer)
    }
}

// MARK: - The presenter

/// Builds the series menu of a 2D viewer and answers its choices, made for one
/// call over the viewer's graph.
@MainActor final class SeriesMenuPresenter {
    /// Held strongly for the length of a call: the viewer's teardown, which
    /// its deinit runs, reaches the menu through the series list, and forming
    /// an unowned or weak reference to an object being deallocated traps.
    let viewer: ViewerController
    let processGraph: ProcessGraph
    let browser: any SeriesMenuBrowsing
    let preferences: UserDefaults

    /// showWindowInsteadOfSwitching: choosing a series another window shows
    /// brings that window forward (Shift does the other).
    static let showsWindowInsteadOfSwitching = PreferenceKey<Bool>("showWindowInsteadOfSwitching")

    init(viewer: ViewerController, processGraph: ProcessGraph) {
        self.viewer = viewer
        self.processGraph = processGraph
        browser = BrowserComparativeStudies(processGraph: processGraph)
        preferences = processGraph.preferences
    }

    /// The series of each time point of the viewer.
    func viewerSeries(checkingNil: Bool) -> NSMutableArray {
        let viewerSeries = NSMutableArray()
        for i in 0..<Int(viewer.horos_maxMovieIndex) {
            let series = (viewer.horos_fileList(at: i)?.object(at: 0) as? DicomImage)?.series
            if checkingNil {
                if let series { viewerSeries.add(series) }
            } else {
                viewerArrayAdd(series, to: viewerSeries)
            }
        }
        return viewerSeries
    }

    /// The database of the viewer's study, where the series menu and the
    /// list look for the patient's studies: the browser may show another one
    /// beside the viewer, a local one beside a viewer of a shared study or
    /// the reverse, which has neither the study nor its patient's.
    func database(of study: DicomStudy) -> DicomDatabase? {
        BrowserDatabaseSource(processGraph: processGraph).database(of: study)
    }

    /// The patient's studies of `study`, as the series menu and the list
    /// look for them: the browser's history, with the distant studies, when
    /// it is this patient's and the browser shows `db`, or else the patient's
    /// studies of `db`, most recent first.
    func patientStudies(of study: DicomStudy, database db: DicomDatabase?, selectingInBrowser: Bool) -> NSArray? {
        var searchString = study.patientUID as NSString?
        let predicate: NSPredicate
        if (searchString?.length ?? 0) == 0 || viewerSameString(searchString, "0") {
            searchString = study.name as NSString?
            predicate = viewerPredicate("(name == %@)", searchString)
        } else {
            predicate = viewerPredicate("(patientUID BEGINSWITH[cd] %@)", searchString)
        }

        if browser.database === db, let history = browser.history(ofPatient: study.patientUID) {
            return history as NSArray
        }
        // A study of a database the browser does not show is not selected
        // (select(_:)): the list is built again when a viewer closes, and
        // showing that database would close the other viewers.
        if selectingInBrowser {
            if !browser.select(study) {
                NSLog("---- buildSeriesPopup - history not found")
            }
        }
        let studies = db?.objects(forEntity: db?.studyEntity(), predicate: predicate) as NSArray?
        return studies?.sortedArray(using: [NSSortDescriptor(key: "date", ascending: false)]) as NSArray?
    }

    /// The studies, the local copy of a PACS study when there is one, and the
    /// series of each; `countingCells` is told the series of each local study.
    func studies(_ studiesArray: NSArray, viewerStudy study: DicomStudy, database db: DicomDatabase?,
                 countingCells: ((DicomStudy, NSArray) -> Void)?) -> SeriesListStudies {
        let seriesArray = NSMutableArray()
        for case var s as AnyObject in studiesArray {
            if s is DCMTKStudyQueryNode && viewerSameString(Self.studyUID(s), study.studyInstanceUID) {
                // For the current study, always take the local images.
                s = study
            } else if let node = s as? DCMTKStudyQueryNode, let local = localCopy(of: node, in: db) {
                // And still, if there are local series, display them.
                s = local
            }

            if let local = s as? DicomStudy {
                viewerArrayAdd(browser.series(of: local), to: seriesArray)
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
                                                        listsComparatives: { self.viewer.flagListPODComparatives?.boolValue ?? false })
        let shown = NSMutableArray(), shownSeries = NSMutableArray()
        for index in selection.shown {
            shown.add(studiesArray.object(at: index))
            shownSeries.add(seriesArray.object(at: index))
        }
        return SeriesListStudies(all: studiesArray, series: seriesArray, shown: shown, shownSeries: shownSeries,
                                 hasComparatives: selection.hasComparatives,
                                 hasComparativesNewerThanLoaded: selection.hasComparativesNewerThanLoaded)
    }

    /// The study instance UID of a listed study, sent as Objective-C sends it.
    private static func studyUID(_ study: AnyObject) -> AnyObject? {
        viewerSendObject(study, "studyInstanceUID")
    }

    /// The first study of the database with the instance UID and the patient
    /// ID of a study on a PACS.
    private func localCopy(of node: DCMTKQueryNode, in db: DicomDatabase?) -> AnyObject? {
        let local = db?.objects(forEntity: db?.studyEntity(),
                                predicate: viewerPredicate("studyInstanceUID = %@ AND patientID = %@", viewerSendObject(node, "studyInstanceUID"),
                                                           viewerSendObject(node, "patientID")))
        return local?.first as AnyObject?
    }

    /// The thumbnail of a series: the one stored, or one made from its image
    /// (stored when the preferences say so), or the missing file picture.
    func thumbnail(of curSeries: DicomSeries, images: NSArray?, index: Int, function: String) -> NSImage? {
        var img = (curSeries.primitiveValue(forKey: "thumbnail") as? Data).flatMap { NSImage(data: $0) }
        if img == nil {
            if let e = HorosObjCException.caught({
                // [images objectAtIndex: i]: out of the images, it raises here.
                let image = images?.object(at: index) as AnyObject?
                // The path and the series of an image, read by key as the
                // former Objective-C read them from whatever the browser lists.
                let path = (image as? NSObject)?.value(forKey: "completePath") as? String
                let seriesID = ViewerSender.intValue((image as? NSObject)?.value(forKeyPath: "series.id"))
                // The image's own database says whether its file is a shared
                // database's: the browser may show another one.
                let row = image as? NSManagedObject
                let dcmPix = DCMPix(path: path, 0, 0, nil, 0, Int(seriesID), isBonjour: RemoteDicomDatabase.database(of: row) != nil, imageObj: row)
                dcmPix?.checkLoad()
                if let dcmPix, dcmPix.notAbleToLoadImage == false {
                    img = dcmPix.generateThumbnailImage(withWW: 0, wl: 0)
                    if let made = img {
                        if preferences[DatabasePreferences.storeThumbnailsInDB] {
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

// MARK: - Building the menu

extension SeriesMenuPresenter {

    /// What the menu's items carry besides the model: the object each item
    /// stands for and the pictures of the series.
    private struct Read {
        var studies: [SeriesMenuModel.Study] = []
        var represented: [O2ViewerThumbnailsMatrixRepresentedObject] = []
        var series: [[DicomSeries]] = []
        var pictures: [[NSImage?]] = []
    }

    /// Builds the menu when it needs it: the patient's studies the series
    /// list shows, each with its series, read once into a SeriesMenuModel;
    /// then the contextual menu's copy, and the views' colours.
    func build() {
        if viewer.horos_needsToBuildSeriesPopupMenu == false {
            return
        }

        viewer.horos_needsToBuildSeriesPopupMenu = false

        let menu = viewer.horos_seriesPopupMenu?.menu
        menu?.removeAllItems()

        if viewer.horos_seriesPopupContextualMenu == nil {
            viewer.horos_seriesPopupContextualMenu = NSMenuItem(title: "Displayed Series", action: nil, keyEquivalent: "")
        }

        viewer.horos_seriesPopupContextualMenu?.submenu = nil

        let inverted = ViewerController.horos_DisplayUseInvertedPolarity()
        var noStudy = false
        var read = Read()
        var showsSeriesColors = false

        if let e = HorosObjCException.caught({
            let curImage = viewer.horos_fileList(at: 0)?.object(at: 0) as? DicomImage

            guard let study = curImage?.series?.study else {
                noStudy = true
                return
            }
            let db = database(of: study)

            let viewerSeries = viewerSeries(checkingNil: false)

            let found = patientStudies(of: study, database: db, selectingInBrowser: true)

            seriesListMakeRetrieveImage(side: 50)

            guard let studiesArray = found, studiesArray.count != 0 else { return }

            showsSeriesColors = SeriesListIdentification.showsColors(in: preferences)
            let seriesWindowColors = ViewerController.horosSeriesWindowColors()
            let listed = studies(NSArray(array: studiesArray as [AnyObject]), viewerStudy: study, database: db, countingCells: nil)

            for index in 0..<listed.shown.count {
                let listedStudy = listed.shown.object(at: index) as AnyObject
                let children = listed.shownSeries.object(at: index) as? NSArray
                read.represented.append(O2ViewerThumbnailsMatrixRepresentedObject.object(listedStudy, children: children))
                read.series.append([])
                read.pictures.append([])
                read.studies.append(SeriesMenuModel.Study(title: nil, picture: nil, isViewerStudyOnPACS: false, series: []))
                readStudy(listedStudy, at: read.studies.count - 1, allIndex: listed.all.index(of: listedStudy), children: children,
                          viewerStudy: study, database: db, inverted: inverted, into: &read) { series in
                    let isShown = viewerSeries.contains(series)
                    return SeriesMenuModel.Series(name: Self.menuName(of: series), imageCount: series.images?.count ?? 0, isShown: isShown,
                                                  isFused: showsSeriesColors && !isShown && self.viewer.blending()?.currentSeries() === series,
                                                  hasWindowColour: seriesWindowColors?.object(forKey: series) is NSColor)
                }
            }
        }) {
            _N2LogExceptionImpl(e, true, "-[ViewerController buildSeriesPopup]")
        }
        if noStudy { return }

        let model = SeriesMenuModel(studies: read.studies, showsSeriesColors: showsSeriesColors)
        fill(menu, from: model, read: read, inverted: inverted)

        viewer.horos_seriesPopupContextualMenu?.submenu = menu?.copy() as? NSMenu
        viewer.horos_seriesPopupContextualMenu?.image = viewer.horos_seriesPopupMenu?.selectedItem?.image
        viewer.horos_seriesPopupContextualMenu?.title = viewer.currentSeries()?.name ?? NSLocalizedString("Unnamed", comment: "")

        for case let v as DCMView in viewer.imageViews() ?? [] {
            v.computeColor()
        }
    }

    /// The name of a series as the menu writes it: cut to 50 characters.
    private static func menuName(of series: DicomSeries) -> String {
        var name = series.name as NSString?
        if (name?.length ?? 0) > 50 {
            name = name?.stringByTruncating(toLength: 50)
        }
        return (name ?? "") as String
    }

    /// Reads the study listed at `index` (a study of the database, the
    /// viewer's own listed from a PACS, or a study on a PACS), then its series
    /// with their pictures, into `read`. A study that cannot be read keeps an
    /// item without title.
    private func readStudy(_ listedStudy: AnyObject, at index: Int, allIndex: Int, children: NSArray?, viewerStudy study: DicomStudy,
                           database db: DicomDatabase?, inverted: Bool, into read: inout Read,
                           series value: (DicomSeries) -> SeriesMenuModel.Series) {
        var curStudy = listedStudy
        if curStudy is DCMTKStudyQueryNode && viewerSameString(Self.studyUID(curStudy), study.studyInstanceUID) {
            // For the current study, always take the local images.
            curStudy = study
            read.studies[index].isViewerStudyOnPACS = true
        }
        let series = children ?? NSArray()
        var images: NSArray? = nil
        var title: String? = nil
        var picture: SeriesMenuModel.StudyPicture? = nil

        if let localStudy = curStudy as? DicomStudy {
            if let e = HorosObjCException.caught({
                images = browser.images(of: localStudy).map { $0 as NSArray }

                if series.count != (images?.count ?? 0) {
                    N2LogStackTraceMessage("[series count] != [images count] : You should not be here......")
                }

                let name = (localStudy.studyName as NSString?)?.stringByTruncating(toLength: 50) as String?
                let comment: String = (localStudy.comment.map { $0 as NSString } ?? "").withTruncatingToLength(50)
                let modality = localStudy.modality ?? "OT:"

                if listedStudy is DCMTKStudyQueryNode {
                    // This is an incomplete study.
                    picture = .retrieve
                }

                let patName = seriesListPatientLine(localStudy.name, dateOfBirth: localStudy.dateOfBirth, separator: " ", viewerStudy: study)
                picture = .number(studyIndex: allIndex)
                title = SeriesListTitles.menuTitle(date: seriesListDateText(localStudy.date), patient: patName, name: name,
                                                   modality: modality, comment: comment)
            }) {
                _N2LogExceptionImpl(e, false, "-[ViewerController buildSeriesPopup]")
            }
        }

        if let node = curStudy as? DCMTKQueryNode {
            // A study on a PACS.
            if let e = HorosObjCException.caught({
                if let local = localCopy(of: node, in: db) as? DicomStudy {
                    images = browser.images(of: local).map { $0 as NSArray }
                }

                // A study node answers these as methods its base class does
                // not declare: read by key, as the series list reads them.
                let name = ((node as NSObject).value(forKey: "studyName") as? NSString)?.stringByTruncating(toLength: 50) as String? ?? ""
                let modality = (node as NSObject).value(forKey: "modality") as? String ?? "OT"
                let patName = seriesListPatientLine((node as NSObject).value(forKey: "name"),
                                                    dateOfBirth: (node as NSObject).value(forKey: "dateOfBirth"),
                                                    separator: "\r", viewerStudy: study)

                title = SeriesListTitles.menuTitle(date: seriesListDateText(node.date() as Date?), patient: patName, name: name,
                                                   modality: modality, comment: nil)
                picture = .retrieve
            }) {
                _N2LogExceptionImpl(e, false, "-[ViewerController buildSeriesPopup]")
            }
        }
        read.studies[index].title = title
        read.studies[index].picture = picture

        for i in 0..<series.count {
            guard let curSeries = series.object(at: i) as? DicomSeries else { continue }
            read.studies[index].series.append(value(curSeries))
            read.series[index].append(curSeries)

            var img = thumbnail(of: curSeries, images: images, index: i, function: "-[ViewerController buildSeriesPopup]")
            if inverted {
                img = img?.imageInverted()
            }
            read.pictures[index].append(img?.imageByScalingProportionallyToSizeUsingNSImage(NSSize(width: seriesPopupPictureSize, height: seriesPopupPictureSize)))
        }
    }

    /// The menu's items from the model, and the popup's selection.
    private func fill(_ menu: NSMenu?, from model: SeriesMenuModel, read: Read, inverted: Bool) {
        var added: [NSMenuItem] = []
        for item in model.items {
            switch item {
            case .separator:
                added.append(NSMenuItem.separator())
            case .study(let index):
                let cell = newItem()
                cell.representedObject = read.represented[index]
                let study = model.studies[index]
                switch study.picture {
                case .number(let studyIndex)?:
                    cell.image = Self.numberPicture(studyIndex: studyIndex, inverted: inverted)
                case .retrieve?:
                    cell.image = seriesListRetrieveImage
                case nil:
                    break
                }
                if let title = study.title {
                    cell.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
                }
                added.append(cell)
            case .series(let index, let position):
                let series = model.studies[index].series[position]
                let curSeries = read.series[index][position]
                let cell = newItem()
                cell.representedObject = O2ViewerThumbnailsMatrixRepresentedObject.object(curSeries)

                var attributes: [NSAttributedString.Key: Any] = [:]
                switch model.highlight(of: series) {
                case .shown:
                    attributes[.backgroundColor] = SeriesListColors.shown
                case .fused:
                    attributes[.backgroundColor] = SeriesListColors.fused
                case .windowColour:
                    // The colour of the window that shows it.
                    attributes[.backgroundColor] = (ViewerController.horosSeriesWindowColors()?.object(forKey: curSeries) as? NSColor)?.withAlphaComponent(0.5)
                case .none:
                    break
                }
                attributes[.font] = NSFont.systemFont(ofSize: 14)
                cell.attributedTitle = NSAttributedString(string: SeriesMenuModel.title(of: series), attributes: attributes)
                cell.image = read.pictures[index][position]
                added.append(cell)
            }
            menu?.addItem(added[added.count - 1])
        }
        if let selected = model.selectedItem {
            viewer.horos_seriesPopupMenu?.select(added[selected])
        }
    }

    private func newItem() -> NSMenuItem {
        let cell = NSMenuItem(title: "", action: #selector(ViewerController.seriesPopupSelect(_:)), keyEquivalent: "")
        cell.target = viewer
        return cell
    }

    /// A study's number on the colour of its place among the patient's studies.
    private static func numberPicture(studyIndex: Int, inverted: Bool) -> NSImage {
        let bkgColor = seriesListStudyColor(studyIndex: studyIndex, inverted: inverted)
        let s = NSAttributedString(string: String(format: "%d", SeriesListStudyNumbers.number(studyIndex: studyIndex)),
                                   attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
        return NSImage(size: NSSize(width: seriesPopupPictureSize, height: seriesPopupPictureSize), flipped: false) { bounds in
            bkgColor?.set()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
            s.draw(at: NSPoint(x: (seriesPopupPictureSize - s.size().width) / 2, y: (seriesPopupPictureSize - s.size().height) / 2))
            return true
        }
    }
}

// MARK: - Choosing a series

extension SeriesMenuPresenter {

    /// Shows `series` (a study stands for its first series with pixels): in a
    /// new viewer with Command or a right click, else in this one, in another
    /// window that already shows it, or at its time point here.
    func loadSelectedSeries(_ chosen: Any?, rightClick: Bool) {
        var series: AnyObject? = chosen as AnyObject?
        if let s = series as? DicomStudy {
            let seriesArray = s.imageSeriesContainingPixels(true) as NSArray?
            if (seriesArray?.count ?? 0) != 0 {
                series = seriesArray?.object(at: 0) as AnyObject?
            } else {
                return
            }
        }

        let viewerSeries = viewerSeries(checkingNil: true)

        let modifiers = NSApplication.shared.currentEvent?.modifierFlags ?? []

        if (rightClick || modifiers.contains(.command)) && viewer.horos_FullScreenOn == false {
            if modifiers.contains(.shift) || browser.usesExternalViewer(for: series as? NSManagedObject) == false {
                let c = preferences[DatabasePreferences.syncPreviewList]

                preferences.set(false, for: DatabasePreferences.syncPreviewList)

                let newViewer = browser.load(series as? NSManagedObject, into: nil, keyImagesOnly: viewer.horos_displayOnlyKeyImages)
                newViewer?.setHighLighted(1.0)

                if preferences[ViewerPreferences.useFloatingThumbnailsList] == false {
                    viewer.showCurrentThumbnail(viewer)
                }

                if preferences[ViewerPreferences.autoTiling] {
                    NSApp.sendAction(#selector(AppController.tileWindows(_:)), to: nil, from: viewer)
                } else {
                    processGraph.appController?.checkAllWindowsAreVisible(viewer, makeKey: true)
                }

                for i in 0..<NSScreen.screens.count {
                    AppControllerCAPIThumbnailsListPanel(i)?.setThumbnailsView(nil, viewer: nil)
                }

                viewer.window?.makeKeyAndOrderFront(viewer)
                viewer.refreshToolbar()
                viewer.updateNavigator()

                newViewer?.showCurrentThumbnail(viewer)

                preferences.set(c, for: DatabasePreferences.syncPreviewList)
                viewer.syncThumbnails()
            }
        } else {
            if !viewerSeries.contains(series as Any) {
                var found = false
                var showWindowIfDisplayed = preferences[Self.showsWindowInsteadOfSwitching]

                if modifiers.contains(.shift) {
                    showWindowIfDisplayed = !showWindowIfDisplayed
                }

                if showWindowIfDisplayed {
                    // Is this series already displayed? Select it.
                    for v in ViewerController.getDisplayed2DViewers()?.compactMap({ $0 as? ViewerController }) ?? [] {
                        if v.imageView()?.seriesObj() === series && v !== viewer {
                            v.window?.makeKeyAndOrderFront(viewer)
                            v.setHighLighted(1.0)

                            found = true
                        }
                    }
                }

                if found == false {
                    let savedAutoHidesMatrix = preferences[ViewerPreferences.autoHidesMatrix]

                    preferences.set(false, for: ViewerPreferences.autoHidesMatrix)

                    if modifiers.contains(.shift) || browser.usesExternalViewer(for: series as? NSManagedObject) == false {
                        _ = browser.load(series as? NSManagedObject, into: viewer, keyImagesOnly: viewer.horos_displayOnlyKeyImages)

                        viewer.showCurrentThumbnail(viewer)
                        viewer.updateNavigator()
                    }

                    preferences.set(savedAutoHidesMatrix, for: ViewerPreferences.autoHidesMatrix)
                }
            } else if series !== (viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))?.object(at: 0) as? DicomImage)?.series {
                // Select it in 4D.
                let idx = viewerSeries.index(of: series as Any)

                if idx != NSNotFound {
                    viewer.setMovieIndex(Int16(truncatingIfNeeded: idx))
                    viewer.propagateSettings()
                }
            } else {
                viewer.mouseMoved()
            }
        }
    }

    /// An item of the menu: a study stands for its first series; a study on a
    /// PACS is retrieved, selected and opened here.
    func select(_ sender: NSMenuItem?) {
        var series = (sender?.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object as AnyObject?

        if let s = series as? DicomStudy {
            series = (s.imageSeries() as NSArray?)?.object(at: 0) as AnyObject?

            for i in viewer.horos_seriesPopupMenu?.menu?.items ?? [] {
                if series === (i.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object as AnyObject? {
                    viewer.horos_seriesPopupMenu?.select(i)
                }
            }
        }

        if let node = series as? DCMTKStudyQueryNode {
            // A study on a PACS.
            browser.retrieveAndOpen(node, in: viewer)
            return
        }

        loadSelectedSeries(series, rightClick: false)
    }

    /// The file of the image shown, as the window's represented file.
    func updateRepresentedFileName() {
        let image = viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))?.object(at: Int(viewer.horos_imageView?.curImage ?? 0)) as? NSManagedObject
        viewer.window?.representedFilename = DatabaseImageFiles.localFile(ofRow: image) ?? ""
    }

    /// The DICOM fields of the image shown, in their window: the one open for
    /// this viewer, or a new one faded in.
    func showMetaData() {
        viewer.checkEverythingLoaded()

        let list = viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))
        let shown = list?.object(at: Int(viewer.horos_imageView?.curImage ?? 0))
        viewer.window?.representedFilename = DatabaseImageFiles.localFile(ofRow: shown as? NSManagedObject) ?? ""

        let im = shown as? DicomImage

        if XMLController.window(for: viewer) != nil {
            XMLController.window(for: viewer)?.window?.makeKeyAndOrderFront(viewer)
        } else {
            let xmlController = XMLController(image: im, windowName: String(format: NSLocalizedString("Meta-Data: %@", comment: ""), viewer.window?.title ?? "(null)"), viewer: viewer)
            // Its +1, as [XMLController alloc] left it: the controller lets
            // itself go when its window closes.
            if let xmlController { _ = Unmanaged.passRetained(xmlController) }
            xmlController?.window?.alphaValue = 0.01

            processGraph.appController?.tileWindows(nil)

            for i in 0..<15 {
                xmlController?.window?.alphaValue = (CGFloat(i) + 1.0) / 15.0
                Thread.sleep(forTimeInterval: 0.03)
            }

            viewer.window?.makeKeyAndOrderFront(viewer)
        }
    }
}

// MARK: - The viewer's façade

extension ViewerController {

    /// The presenter of the viewer's series menu, over the viewer's graph.
    var seriesMenuPresenter: SeriesMenuPresenter {
        SeriesMenuPresenter(viewer: self, processGraph: sessionGraph.processGraph)
    }

    // The patient's studies and series, which the series list shares.

    func seriesListViewerSeries(checkingNil: Bool) -> NSMutableArray {
        seriesMenuPresenter.viewerSeries(checkingNil: checkingNil)
    }

    func seriesListPatientStudies(of study: DicomStudy, database db: DicomDatabase?, selectingInBrowser: Bool) -> NSArray? {
        seriesMenuPresenter.patientStudies(of: study, database: db, selectingInBrowser: selectingInBrowser)
    }

    func seriesListStudies(_ studiesArray: NSArray, viewerStudy study: DicomStudy, database db: DicomDatabase?,
                           countingCells: ((DicomStudy, NSArray) -> Void)?) -> SeriesListStudies {
        seriesMenuPresenter.studies(studiesArray, viewerStudy: study, database: db, countingCells: countingCells)
    }

    func seriesListThumbnail(of curSeries: DicomSeries, images: NSArray?, index: Int, function: String) -> NSImage? {
        seriesMenuPresenter.thumbnail(of: curSeries, images: images, index: index, function: function)
    }
}

public extension ViewerController {

    @objc(buildSeriesPopup)
    func buildSeriesPopup() {
        seriesMenuPresenter.build()
    }

    @objc(loadSelectedSeries:rightClick:)
    func loadSelectedSeries(_ series: Any!, rightClick: Bool) {
        seriesMenuPresenter.loadSelectedSeries(series, rightClick: rightClick)
    }

    @objc(seriesPopupSelect:)
    @IBAction func seriesPopupSelect(_ sender: NSMenuItem!) {
        seriesMenuPresenter.select(sender)
    }

    @objc(matrixPreviewLoadAllSeries:)
    func matrixPreviewLoadAllSeries(_ sender: Any!) {
    }

    @objc(updateRepresentedFileName)
    func updateRepresentedFileName() {
        seriesMenuPresenter.updateRepresentedFileName()
    }

    @objc(window:shouldPopUpDocumentPathMenu:)
    func window(_ sender: NSWindow, shouldPopUpDocumentPathMenu titleMenu: NSMenu) -> Bool {
        updateRepresentedFileName()

        return true
    }

    @objc(viewXML:)
    func viewXML(_ sender: Any!) {
        seriesMenuPresenter.showMetaData()
    }
}
