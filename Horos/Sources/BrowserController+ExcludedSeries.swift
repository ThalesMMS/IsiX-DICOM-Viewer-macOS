//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The placeholders of the series a DICOMweb node's rule left out of the
/// selected study, in the cells after its series' thumbnails.
///
/// Their cells are outside `matrixViewArray`, with negative tags: every use
/// of the thumbnails that takes a series by its cell's tag (open, export,
/// print, drag, the context menu) checks the tag against that array and
/// passes them by. A click retrieves the series.
extension BrowserController {
    private enum ExcludedSeriesCells {
        @MainActor static var key: UInt8 = 0
        @MainActor static var observer: NSObjectProtocol?
        static let firstTag = -1000
    }

    /// What the thumbnails show after the series of the selected study.
    @objc var horosExcludedSeries: [ExcludedSeries] {
        get { objc_getAssociatedObject(self, &ExcludedSeriesCells.key) as? [ExcludedSeries] ?? [] }
        set { objc_setAssociatedObject(self, &ExcludedSeriesCells.key, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// The placeholders of `item` when it is a study, none otherwise.
    @objc(horosPrepareExcludedSeriesOf:)
    func horosPrepareExcludedSeries(of item: Any?) {
        if ExcludedSeriesCells.observer == nil {
            ExcludedSeriesCells.observer = NotificationCenter.default.addObserver(forName: ExcludedSeries.didChangeNotification,
                                                                                   object: nil, queue: .main) { note in
                let uid = note.object as? String
                MainActor.assumeIsolated {
                    guard let browser = BrowserController.currentBrowser(),
                          let outline = browser.horos_databaseOutline,
                          let study = outline.item(atRow: outline.selectedRow) as? DicomStudy,
                          study.studyInstanceUID == uid else { return }
                    browser.horosPrepareExcludedSeries(of: study)
                    browser.previewMatrixScrollViewFrameDidChange(nil)
                }
            }
        }
        guard let study = item as? DicomStudy, let uid = study.studyInstanceUID,
              let database = self.database?.dataBaseDirPath, !database.isEmpty else {
            horosExcludedSeries = []
            return
        }
        let local = Set(((study.series as NSSet?)?.allObjects ?? []).compactMap { ($0 as? DicomSeries)?.seriesDICOMUID })
        horosExcludedSeries = ExcludedSeries.placeholders(study: uid, database: database, localSeries: local)
    }

    /// Fills the cells after the series' with the placeholders.
    @objc func horosLayOutExcludedSeriesCells() {
        guard let matrix = horos_oMatrix else { return }
        let placeholders = horosExcludedSeries
        guard !placeholders.isEmpty else { return }
        let first = horos_matrixViewArray?.count ?? 0
        var rows = 0, columns = 0
        matrix.getNumberOfRows(&rows, columns: &columns)
        if columns < 1 { columns = 1 }
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize("dbMatrixFont")))
        let studyDate = horos_databaseOutline.flatMap { ($0.item(atRow: $0.selectedRow) as? DicomStudy)?.date }
        var side = min(matrix.cellSize.width, matrix.cellSize.height) * 0.6
        if side < 16 { side = 64 }
        for (k, placeholder) in placeholders.enumerated() {
            let i = first + k
            guard i < rows * columns, let cell = matrix.cell(atRow: i / columns, column: i % columns) as? NSButtonCell else { break }
            cell.tag = ExcludedSeriesCells.firstTag - k
            cell.representedObject = placeholder
            cell.isTransparent = false
            cell.isEnabled = true
            cell.setButtonType(.momentaryPushIn)
            cell.bezelStyle = .shadowlessSquare
            cell.isBordered = true
            cell.imagePosition = .imageBelow
            cell.imageScaling = .scaleProportionallyDown
            cell.lineBreakMode = .byCharWrapping
            cell.font = font
            cell.menu = nil
            cell.attributedTitle = NSAttributedString(string: placeholder.title(studyDate: studyDate),
                                                      attributes: [.font: font, .foregroundColor: NSColor.disabledControlTextColor])
            cell.image = placeholder.image(size: NSSize(width: side, height: side))
            cell.target = self
            cell.action = #selector(horosRetrieveExcludedSeries(_:))
        }
    }

    @objc func horosRetrieveExcludedSeries(_ sender: Any?) {
        let cell = (sender as? NSMatrix)?.selectedCell() ?? (sender as? NSCell)
        guard let placeholder = cell?.representedObject as? ExcludedSeries else { return }
        DCMTKQueryNode.retrieveExcludedSeries(placeholder)
    }
}
