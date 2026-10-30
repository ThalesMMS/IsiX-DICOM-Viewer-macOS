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

import AppKit
import IsiXDatabase
import IsiXImaging

// The two sheets of opening a series in parts: the 3D/4D sheet, which shows
// the sub-series one series was cut into and opens one, all, the 4D player,
// or reparses the series in the database; and the sub-series sheet, which
// keeps a range of images, one in n, and tells whether they fit in memory.

/// What the 3D/4D sheet chose.
enum SubSeriesChoice {
    /// Nothing is opened.
    case cancel
    /// The whole series, as selected.
    case entire
    /// These lists, in 2D viewers or the 4D player.
    case open([[Any]], movie: Bool)
    /// The sheet opened the viewers itself.
    case opened
}

/// `[array objectAtIndex: index]`: NSRangeException past the end, as the
/// former code raised (and caught).
nonisolated private func element(_ array: [Any], _ index: Int) -> Any {
    return (array as NSArray).object(at: index)
}

extension BrowserController {

    /// The lists the sub-series sheet keeps open: the sub-series of the
    /// series being opened.
    nonisolated(unsafe) private static var openSubSeriesArray: [Any]?

    // MARK: 3D/4D sheet

    @objc(selectSubSeriesAndOpen:)
    func selectSubSeriesAndOpen(_ sender: Any!) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 2))
    }

    @objc(selectAll3DSeries:)
    func selectAll3DSeries(_ sender: Any!) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 6))
    }

    @objc(reparseIn3D:)
    func reparseIn3D(_ sender: Any!) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 10))
    }

    @objc(reparseIn4D:)
    func reparseIn4D(_ sender: Any!) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 11))
    }

    @objc(selectAll4DSeries:)
    func selectAll4DSeries(_ sender: Any!) {
        if horos_subOpenMatrix4D?.isEnabled ?? false {
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 7))
        }
    }

    /// The 3D/4D sheet for the sub-series of one series: a thumbnail per
    /// sub-series (3D) and, when they all have as many images, per time
    /// (4D).
    func chooseSubSeries(_ splittedSeries: [[Any]], movie movieViewer: Bool, viewer: ViewerController?) -> SubSeriesChoice {
        guard let subOpenWindow = horos_subOpenWindow, let matrix3D = horos_subOpenMatrix3D, let matrix4D = horos_subOpenMatrix4D,
              let supOpenButtons = horos_supOpenButtons else { return .cancel }
        let isBonjour = !(database?.isLocal() ?? false)

        matrix3D.renewRows(1, columns: splittedSeries.count)
        matrix3D.sizeToCells()
        matrix3D.target = self
        matrix3D.action = #selector(BrowserController.selectSubSeriesAndOpen(_:))

        matrix4D.renewRows(1, columns: splittedSeries[0].count)
        matrix4D.sizeToCells()
        matrix4D.target = self
        matrix4D.action = #selector(BrowserController.selectSubSeriesAndOpen(_:))

        supOpenButtons.cell(withTag: 3)?.isEnabled = true
        let areData4D = SeriesSplitting.isFourD(groupSizes: splittedSeries.map(\.count))
        if !areData4D {
            supOpenButtons.cell(withTag: 3)?.isEnabled = false
        }

        func thumbnail(_ image: Any, title: String, in cell: NSCell?) {
            let oob = image as AnyObject
            guard let dcmPix = DCMPix(path: oob.value(forKey: "completePath") as? String, 0, 1, nil, Int(BrowserObjC.intValue(oob.value(forKey: "frameID"))),
                                      Int(BrowserObjC.intValue(oob.value(forKeyPath: "series.id"))), isBonjour: isBonjour,
                                      imageObj: oob as? NSManagedObject) else { return }
            let img = dcmPix.generateThumbnailImage(withWW: openingFloatValue(oob.value(forKeyPath: "series.windowWidth")),
                                                    wl: dcmPix.calibratedWindowLevel(forStoredLevel: openingFloatValue(oob.value(forKeyPath: "series.windowLevel"))))
            guard let cell = cell as? NSButtonCell else { return }
            cell.isTransparent = false
            cell.isEnabled = true
            cell.font = NSFont.systemFont(ofSize: 10)
            cell.imagePosition = .imageBelow
            cell.title = title
            cell.image = img
            cell.alternateImage = img
        }

        for (i, series) in splittedSeries.enumerated() {
            thumbnail(element(series, series.count / 2),
                      title: String(format: NSLocalizedString("%d/%d Images", comment: ""), Int32(i + 1), Int32(series.count)),
                      in: matrix3D.cell(atRow: 0, column: i))
        }
        if areData4D {
            for i in 0..<splittedSeries[0].count {
                thumbnail(splittedSeries[0][i], title: String(format: NSLocalizedString("%d/%d Images", comment: ""), Int32(i + 1), Int32(splittedSeries.count)),
                          in: matrix4D.cell(atRow: 0, column: i))
            }
        } else {
            matrix4D.renewRows(0, columns: 0)
            matrix4D.sizeToCells()
            matrix4D.isEnabled = false
        }

        NSApp.mainWindow?.beginSheet(subOpenWindow, completionHandler: nil)
        var result = NSApp.runModal(for: subOpenWindow).rawValue
        subOpenWindow.makeFirstResponder(nil)

        if result == 2 {
            supOpenButtons.selectCell(withTag: 2)
            if matrix3D.selectedColumn < 0 {
                result = matrix4D.selectedColumn < 0 ? 0 : 5
            }
        } else if result == 6 {
            NSLog("Open all 3D")
        } else if result == 7 {
            NSLog("Open all 4D")
        } else if result == 10 {
            NSLog("Reparse in 3D")
            reparse(groupCount: splittedSeries.count, from: splittedSeries) { splittedSeries[$0] }
            refreshDatabase(self)
            refreshMatrix(self)
            result = 0
        } else if result == 11 {
            NSLog("Reparse in 4D")
            reparse(groupCount: splittedSeries[0].count, from: splittedSeries) { i in splittedSeries.map { element($0, i) } }
            refreshDatabase(self)
            refreshMatrix(self)
            result = 0
        } else {
            result = supOpenButtons.selectedTag()
        }

        subOpenWindow.sheetParent?.endSheet(subOpenWindow)
        subOpenWindow.orderOut(self)

        switch result {
        case 0: // Cancel
            return .cancel
        case 2: // selected 3D
            return .open([splittedSeries[matrix3D.selectedColumn]], movie: movieViewer)
        case 3: // 4D Viewer
            return .open(splittedSeries, movie: true)
        case 5: // selected 4D
            return .open([splittedSeries.map { element($0, matrix4D.selectedColumn) }], movie: movieViewer)
        case 6:
            displayWaitWindowIfNecessary()
            for array in splittedSeries {
                _ = openViewer(fromImages: [array], movie: movieViewer, viewer: viewer, keyImagesOnly: false)
            }
            return .opened
        case 7:
            var openAllWindows = true
            if splittedSeries[0].count > 25 {
                openAllWindows = HorosAlertPanel.runInformational(
                    title: NSLocalizedString("Series Opening", comment: ""),
                    message: String(format: NSLocalizedString("Are you sure you want to open %d windows? It's a lot of windows for this screen...", comment: ""), Int32(splittedSeries[0].count)),
                    defaultButton: NSLocalizedString("Yes", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
                    otherButton: nil) == HorosAlertPanel.defaultResponse
            }
            if openAllWindows {
                displayWaitWindowIfNecessary()
                for i in 0..<splittedSeries[0].count {
                    _ = openViewer(fromImages: [splittedSeries.map { element($0, i) }], movie: movieViewer, viewer: viewer, keyImagesOnly: false)
                }
            }
            return .opened
        default: // 1: Entire
            return .entire
        }
    }

    /// "Reparse in 3D" / "Reparse in 4D": a new series of the study for each
    /// group, the images moved into it and the original series deleted, as
    /// IsiXDatabase's SeriesReparse writes it; then the database is saved.
    private func reparse(groupCount: Int, from splittedSeries: [[Any]], group: @escaping (Int) -> [Any]) {
        guard let database, let context = database.managedObjectContext else { return }
        N2ManagedObjectContextPerformAndWait(context) {
            if let e = BrowserObjC.attempt({
                let groups = (0..<groupCount).map { group($0).compactMap { $0 as? NSManagedObject } }
                SeriesReparse.write(groups: groups, seriesOf: splittedSeries.last?.last as? NSManagedObject, in: context)
                _ = database.save(nil)
            }) {
                BrowserObjC.log(e, stack: true, "-[BrowserController processOpenViewerDICOMFromArray:movie:viewer:]")
            }
        }
    }

    // MARK: Sub-series sheet

    /// The images of each list the sub-series sheet keeps, sorted as their
    /// series sorts its images.
    @objc(produceNewArray:)
    func produceNewArray(_ toOpenArray: [Any]!) -> [Any]! {
        var newArray: [Any] = []
        for loadList in toOpenArray ?? [] {
            let list = (loadList as? NSArray) as? [Any] ?? []
            let kept = SubSeriesSelection.indices(imageCount: list.count, from: horos_subFrom, to: horos_subTo, interval: horos_subInterval)
            guard !kept.isEmpty else { continue }
            let imagesArray = NSMutableArray(array: kept.map { list[$0] })
            if let descriptors = ((imagesArray.lastObject as? DicomImage)?.series as? DicomSeries)?.sortDescriptorsForImages() as? [NSSortDescriptor] {
                imagesArray.sort(using: descriptors)
            }
            newArray.append(imagesArray)
        }
        return newArray
    }

    /// Whether the images the sheet keeps fit in memory: smiles and OK, or
    /// errors and what to do.
    @objc(checkMemory:)
    func checkMemory(_ sender: Any!) {
        var mem: UInt = 0
        let selection = produceNewArray(BrowserController.openSubSeriesArray) ?? []
        if selection.isEmpty {
            horos_subSeriesOKButton?.isEnabled = false
            horos_memoryMessage?.stringValue = NSLocalizedString("Select at least one image.", comment: "")
            return
        }
        if computeEnoughMemory(selection, &mem) {
            horos_leftIcon?.image = NSImage(named: "smile")
            horos_rightIcon?.image = NSImage(named: "smile")
            horos_subSeriesOKButton?.isEnabled = true
            horos_memoryMessage?.stringValue = NSLocalizedString("OK !", comment: "")
        } else {
            horos_leftIcon?.image = NSImage(named: "error")
            horos_rightIcon?.image = NSImage(named: "error")
            horos_subSeriesOKButton?.isEnabled = false
            horos_memoryMessage?.stringValue = NSLocalizedString("Not enough memory. Select fewer images and try again.", comment: "")
        }
    }

    /// `[sender intValue]`: a number, or the control the sheet sends.
    private func senderIntValue(_ sender: Any?) -> Int32 {
        if let number = sender as? NSNumber { return number.int32Value }
        return ((sender as? NSObject)?.value(forKey: "intValue") as? NSNumber)?.int32Value ?? 0
    }

    @objc(setSubInterval:)
    func setSubInterval(_ sender: Any!) {
        horos_subInterval = senderIntValue(sender)
        checkMemory(self)
    }

    @objc(setSubFrom:)
    func setSubFrom(_ sender: Any!) {
        horos_subFrom = senderIntValue(sender)
        if database == nil { return }
        horos_animationSlider?.intValue = horos_subFrom - 1
        showSubSeriesBoundInPreview()
    }

    @objc(setSubTo:)
    func setSubTo(_ sender: Any!) {
        horos_subTo = senderIntValue(sender)
        if database == nil { return }
        horos_animationSlider?.intValue = horos_subTo - 1
        showSubSeriesBoundInPreview()
    }

    /// The preview shows the image a bound of the range was moved to.
    private func showSubSeriesBoundInPreview() {
        let copyDontUpdatePreviewPane = horos_dontUpdatePreviewPane
        horos_dontUpdatePreviewPane = false
        previewSliderAction(nil)
        horos_dontUpdatePreviewPane = copyDontUpdatePreviewPane
        checkMemory(self)
    }

    /// The sub-series sheet: the images kept of each list, or nil when it is
    /// cancelled or cannot be shown (another sheet, a full-screen window).
    @objc(openSubSeries:)
    func openSubSeries(_ toOpenArray: [Any]!) -> [Any]! {
        horos_waitOpeningWindow?.window?.orderOut(self)
        let defaults = UserDefaults.standard
        let copySortSeriesBySliceLocation = defaults.integer(forKey: "sortSeriesBySliceLocation")

        BrowserController.openSubSeriesArray = toOpenArray

        // To avoid the problem of displaying this sheet when the user is in fullscreen mode
        if (NSApp.mainWindow?.level.rawValue ?? 0) > NSWindow.Level.modalPanel.rawValue { NSSound.beep(); return nil }
        if (NSApp.keyWindow?.level.rawValue ?? 0) > NSWindow.Level.modalPanel.rawValue { NSSound.beep(); return nil }

        let count = NSNumber(value: Int32(((toOpenArray?.first as? NSArray)?.count) ?? 0))
        setValue(count, forKey: "subTo")
        setValue(count, forKey: "subMax")
        setValue(NSNumber(value: Int32(1)), forKey: "subFrom")
        setValue(NSNumber(value: Int32(1)), forKey: "subInterval")

        guard !horos_subSeriesWindowIsOn, let subSeriesWindow = horos_subSeriesWindow else { return nil }
        horos_subSeriesWindowIsOn = true
        // The legacy nib puts this status inside a hidden memory-information
        // section. Keep selection feedback visible independently of that section.
        if let content = subSeriesWindow.contentView, let memoryMessage = horos_memoryMessage, memoryMessage.superview !== content {
            memoryMessage.removeFromSuperview()
            content.addSubview(memoryMessage)
            memoryMessage.translatesAutoresizingMaskIntoConstraints = false
            memoryMessage.isHidden = false
            memoryMessage.textColor = .labelColor
            memoryMessage.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            memoryMessage.alignment = .left
            memoryMessage.cell?.wraps = true
            memoryMessage.cell?.isScrollable = false
            NSLayoutConstraint.activate([
                memoryMessage.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                memoryMessage.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                memoryMessage.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            ])
        }
        NSApp.mainWindow?.beginSheet(subSeriesWindow, completionHandler: nil)
        checkMemory(self)

        let result = NSApp.runModal(for: subSeriesWindow)
        subSeriesWindow.makeFirstResponder(nil)
        subSeriesWindow.sheetParent?.endSheet(subSeriesWindow)
        subSeriesWindow.orderOut(self)
        horos_waitOpeningWindow?.window?.orderBack(self)
        horos_subSeriesWindowIsOn = false

        let returnedArray = result == .stop ? produceNewArray(toOpenArray) : nil
        BrowserController.openSubSeriesArray = nil
        defaults.set(copySortSeriesBySliceLocation, forKey: "sortSeriesBySliceLocation")
        return returnedArray
    }
}
