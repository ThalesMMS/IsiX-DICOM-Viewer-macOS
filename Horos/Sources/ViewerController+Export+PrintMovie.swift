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

import AppKit
import IsiXDICOMDataset
import IsiXDICOMFile

// The first half of the "4.5.1.1 Exportation of image produced" block of
// ViewerController: the sorting of the series, and the actions of the print
// and of the movie, whose selectors the nibs, the menus and the former
// plugins use. The print is ViewerPrintJob's and the movie ViewerMovieExport's;
// the actions hand them their sender.
//
// The sorts copy each slice into a new volume in the new order and hand the
// slices, the files and the volume to -changeImageData:::: (the first movie
// frame) and -addMovieSerie::: (the others) as the NSData object itself, so
// that the slices keep pointing into the very buffer the viewer then owns.

/// `[a compare: b]` of two values of a DICOM attribute, whatever class
/// answers it (NSNumber, NSString, NSDate...).
fileprivate func viewerSortCompare(_ a: AnyObject, _ b: AnyObject) -> ComparisonResult {
    typealias Compare = @convention(c) (AnyObject, Selector, AnyObject?) -> Int
    let selector = NSSelectorFromString("compare:")
    let order = unsafeBitCast(a.method(for: selector), to: Compare.self)(a, selector, b)
    return ComparisonResult(rawValue: order) ?? .orderedSame
}

/// The value a series is sorted by for the text of an attribute: a number
/// when the text is digits, minus signs and at most one dot; the text otherwise.
fileprivate func viewerSortValue(_ text: NSString) -> AnyObject {
    var dot = false
    var onlyNumber = true
    for index in 0..<text.length {
        let character = text.character(at: index)
        if character == UInt16(UInt8(ascii: ".")) {
            if dot { onlyNumber = false } else { dot = true }
        } else if !(character >= UInt16(UInt8(ascii: "0")) && character <= UInt16(UInt8(ascii: "9")))
                    && character != UInt16(UInt8(ascii: "-")) {
            onlyNumber = false
        }
    }
    return onlyNumber ? NSNumber(value: text.floatValue) : text
}

/// The positions of `count` values in sorted order; equal values keep their
/// order, so that two equal values never make the same frame twice.
fileprivate func viewerSortedPositions(_ count: Int, by order: (Int, Int) -> ComparisonResult) -> [Int] {
    (0..<count).sorted { left, right in
        let result = order(left, right)
        return result == .orderedSame ? left < right : result == .orderedAscending
    }
}

/// One movie frame of a sorted series: its slices, its files and the volume
/// the slices point into.
fileprivate struct ViewerSortedFrame {
    var pixes: [DCMPix]
    var files: [Any]
    var volume: NSData
}

/// The fusions a sort ends, made again over the new order. -changeImageData::::
/// ends the viewer's own fusion, and the close notification it posts ends the
/// fusion of every viewer that shows this one over its images. Each is made
/// again with the same overlay; the slider keeps the factor, and the mode,
/// which the activation takes from the preferences, is put back.
@MainActor fileprivate struct ViewerSortFusions {
    private struct Fusion {
        let owner: ViewerController
        let overlay: ViewerController
        let mode: Int
    }

    private let fusions: [Fusion]

    init(of viewer: ViewerController) {
        var fusions: [Fusion] = []
        if let overlay = viewer.horos_blending {
            fusions.append(Fusion(owner: viewer, overlay: overlay, mode: viewer.horos_imageView?.blendingMode ?? 0))
        }
        for owner in viewer.sessionGraph.registry.viewers ?? [] where owner !== viewer && owner.horos_blending === viewer {
            fusions.append(Fusion(owner: owner, overlay: viewer, mode: owner.horos_imageView?.blendingMode ?? 0))
        }
        self.fusions = fusions
    }

    func restore() {
        for fusion in fusions where fusion.owner.horos_blending !== fusion.overlay {
            fusion.owner.activateBlending(fusion.overlay)
            // Refused, or made with a resampled overlay: the mode is the new fusion's.
            guard fusion.owner.horos_blending === fusion.overlay else { continue }
            fusion.owner.horos_imageView?.blendingMode = fusion.mode
            fusion.owner.horos_seriesView?.setBlendingMode(Int32(truncatingIfNeeded: fusion.mode))
            fusion.owner.horos_blendingPopupMenu?.selectItem(withTag: fusion.mode)
        }
    }
}

public extension ViewerController {

    // MARK: - 4.5.1.1 Exportation of image produced

    @objc(sortSeriesByValue:)
    func sortSeriesByValue(_ sender: Any!) {
        switch viewerActionTag(sender) {
        case 0: _ = sortSeries(byValue: "instanceNumber", ascending: true)
        case 1: _ = sortSeries(byValue: "instanceNumber", ascending: false)
        case 2: _ = sortSeries(byValue: "sliceLocation", ascending: true)
        case 3: _ = sortSeries(byValue: "sliceLocation", ascending: false)
        case 4: _ = sortSeries(byValue: nil, ascending: true)
        case 5: _ = sortSeries(byValue: nil, ascending: false)
        default: break
        }
    }

    /// Sorts every movie frame of the series by a key of its files, or by
    /// acquisition time when `key` is nil.
    @objc(sortSeriesByValue:ascending:)
    func sortSeries(byValue key: String!, ascending: Bool) -> Bool {
        checkEverythingLoaded()

        var frames: [ViewerSortedFrame] = []
        for movieIndex in 0..<Swift.max(Int(horos_maxMovieIndex), 0) {
            let order: [Int]
            if let key {
                let descriptor = NSSortDescriptor(key: key, ascending: ascending)
                let files = horos_fileList(at: movieIndex) as? [Any] ?? []
                order = viewerSortedPositions(files.count) { descriptor.compare(files[$0], to: files[$1]) }
            } else {
                var timings: [String: [String: String]] = [:]
                let records = (horos_pixList(at: movieIndex) as? [DCMPix] ?? []).map { pix -> [String: String] in
                    let path: String? = pix.srcFile
                    if let path, let timing = timings[path] { return timing }
                    let timing = DicomFile.acquisitionTiming(forFile: path) as? [String: String] ?? [:]
                    if let path { timings[path] = timing }
                    return timing
                }
                order = AcquisitionTimeOrdering.orderedIndices(records: records, ascending: ascending).map(\.intValue)
            }
            guard let frame = sortedFrame(movieIndex, order: order) else { return false }
            frames.append(frame)
        }

        replaceSeries(with: frames)
        return true
    }

    /// Sorts every movie frame of the series by the first value of a DICOM
    /// attribute of its files (0 for a file without it).
    @objc(sortSeriesByDICOMGroup:element:)
    func sortSeries(byDICOMGroup gr: Int32, element el: Int32) -> Bool {
        checkEverythingLoaded()

        var frames: [ViewerSortedFrame] = []
        for movieIndex in 0..<Swift.max(Int(horos_maxMovieIndex), 0) {
            let values = (horos_pixList(at: movieIndex) as? [DCMPix] ?? []).map { pix -> AnyObject in
                let srcFile: String? = pix.srcFile
                let dcmObject: DCMObject? = srcFile.flatMap { DCMObject.object(contentsOfFile: $0) }
                let attribute = dcmObject?.attribute(for: DICOMAttributeTag.tag(withGroup: gr, element: el))
                guard let value = attribute?.values?.firstObject else { return NSNumber(value: Int32(0)) }
                if let text = value as? NSString { return viewerSortValue(text) }
                return value as AnyObject
            }
            let order = viewerSortedPositions(values.count) { viewerSortCompare(values[$0], values[$1]) }
            guard let frame = sortedFrame(movieIndex, order: order) else { return false }
            frames.append(frame)
        }

        replaceSeries(with: frames)
        return true
    }

    /// Movie frame `movieIndex` in `order` (the old position of each slice):
    /// copies of its slices pointing into a new volume that holds their pixels
    /// in that order, and its files in the same order. nil when the volume
    /// cannot be made.
    private func sortedFrame(_ movieIndex: Int, order: [Int]) -> ViewerSortedFrame? {
        let pixes = horos_pixList(at: movieIndex) as? [DCMPix] ?? []
        guard let files = horos_fileList(at: movieIndex) as? [Any] else { return nil }

        let length = (horos_volumeData(at: movieIndex) as? NSData)?.length ?? 0
        guard let rawSeriesData = malloc(length) else { return nil }
        let seriesData = rawSeriesData.bindMemory(to: Float.self, capacity: length / MemoryLayout<Float>.size)
        let volume = NSData(bytesNoCopy: rawSeriesData, length: length, freeWhenDone: true)

        var frame = ViewerSortedFrame(pixes: [], files: [], volume: volume)
        var size: Int32 = 0
        for position in pixes.indices {
            let old = order[position]
            let pix = pixes[old]
            guard let copy = pix.copy() as? DCMPix else { return nil }

            copy.fImage = seriesData + Int(size)
            memcpy(seriesData + Int(size), pix.fImage, pix.pwidth &* pix.pheight &* MemoryLayout<Float>.size)
            size = Int32(truncatingIfNeeded: Int(size) &+ pix.pwidth &* pix.pheight)

            frame.pixes.append(copy)
            frame.files.append(files[old])
        }
        return frame
    }

    /// Replaces the series with the sorted frames, keeps its fusions and shows the
    /// first image of the order displayed, which -computeInterval may flip.
    private func replaceSeries(with frames: [ViewerSortedFrame]) {
        let fusions = ViewerSortFusions(of: self)
        for (index, frame) in frames.enumerated() {
            let pixes = NSMutableArray(array: frame.pixes), files = NSMutableArray(array: frame.files)
            if index == 0 {
                viewerChangeImageData(self, pixes, files, frame.volume, false)
            } else {
                viewerAddMovieSerie(self, pixes, files, frame.volume)
            }
        }

        _ = computeInterval()
        setWindowTitle(self)

        fusions.restore()
        setImageIndex(0)

        horos_postprocessed = true
    }

    // MARK: Printing

    /// The print of this viewer, made for each action: ViewerPrintJob.
    private var printJob: ViewerPrintJob {
        ViewerPrintJob(viewer: self, preferences: sessionGraph.preferences, registry: sessionGraph.registry)
    }

    @objc(setPagesToPrint:)
    @IBAction func setPagesToPrint(_ sender: Any!) {
        printJob.updatePageCount(sender)
    }

    @objc(restoreWindowsAfterPrint)
    func restoreWindowsAfterPrint() {
        printJob.restoreWindows()
    }

    @objc(printOperationDidRun:success:contextInfo:)
    func printOperationDidRun(_ printOperation: NSPrintOperation!, success: Bool, contextInfo info: UnsafeMutableRawPointer!) {
        printJob.operationDidRun(success: success)
    }

    @objc(preparePrintSpoolDirectory)
    func preparePrintSpoolDirectory() -> Bool {
        printJob.prepareSpoolDirectory()
    }

    @objc(discardPrintSpoolDirectory)
    func discardPrintSpoolDirectory() {
        horos_printSpoolDirectory = ViewerPrintJob.discardingSpool(horos_printSpoolDirectory)
    }

    @objc(writePrintPage:index:into:)
    func writePrintPage(_ image: NSImage!, index: Int32, into files: NSMutableArray!) -> Bool {
        guard let page = printJob.writePage(image, index: index) else { return false }
        files?.add(page)
        return true
    }

    @objc(presentPrintPreparationFailure)
    func presentPrintPreparationFailure() {
        printJob.presentPreparationFailure()
    }

    @objc(endPrint:)
    @IBAction func endPrint(_ sender: Any!) {
        printJob.endSheet(sender)
    }

    @objc(printSlider:)
    @IBAction func printSlider(_ sender: Any!) {
        printJob.followSlider(sender)
    }

    @objc(print:)
    func print(_ sender: Any!) {
        printJob.openSheet()
    }

    @objc(printDICOM:)
    func printDICOM(_ sender: Any!) {
        checkEverythingLoaded()

        // [[[AYDicomPrintWindowController alloc] init] autorelease]: the controller
        // runs its modal session inside -init and lives until the pool drains.
        let controller = AYDicomPrintWindowController()
        _ = Unmanaged.passUnretained(controller).retain().autorelease()
    }

    // MARK: Movie

    /// The movies of this viewer, made for each action: ViewerMovieExport.
    internal var movieExport: ViewerMovieExport {
        ViewerMovieExport(viewer: self, preferences: sessionGraph.preferences, registry: sessionGraph.registry)
    }

    @objc(imageForFrame:maxFrame:)
    func image(forFrame cur: NSNumber!, maxFrame max: NSNumber!) -> NSImage! {
        movieExport.image(forFrame: cur, maxFrame: max)
    }

    @objc(exportQuicktimeIn::::)
    func exportQuicktime(in dimension: Int, _ from: Int, _ to: Int, _ interval: Int) {
        exportQuicktime(in: dimension, from, to, interval, false)
    }

    @objc(exportQuicktimeIn:::::)
    func exportQuicktime(in dimension: Int, _ from: Int, _ to: Int, _ interval: Int, _ allViewers: Bool) {
        exportQuicktime(in: dimension, from, to, interval, allViewers, mode: nil)
    }

    @objc(exportQuicktimeIn:::::mode:)
    func exportQuicktime(in dimension: Int, _ from: Int, _ to: Int, _ interval: Int, _ allViewers: Bool, mode: String!) {
        movieExport.export(dimension: dimension, from: from, to: to, interval: interval, allViewers: allViewers, mode: mode)
    }

    @objc(endQuicktime:)
    @IBAction func endQuicktime(_ sender: Any!) {
        movieExport.endSheet(sender)
    }

    @objc(exportQuicktimeSetNumber:)
    func exportQuicktimeSetNumber(_ sender: Any!) {
        movieExport.updateImageCount()
    }

    @objc(exportQuicktimeSlider:)
    @IBAction func exportQuicktimeSlider(_ sender: Any!) {
        movieExport.followSlider(sender)
    }

    @objc(exportQuicktime:)
    func exportQuicktime(_ sender: Any!) {
        movieExport.openSheet()
    }
}
