//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXImaging
import IsiXPreferences

/// The target of File > Export > Export as Synthetic DWI: the command of the
/// 2D viewer whose window is the main one, handed over to its
/// ViewerSyntheticDWI. With another window in front the item is disabled.
///
/// The item of MainMenu.xib sends its action to the first responder; the
/// application gives it this target as it finishes launching, so that the
/// command is a type of its own and not one more method of the viewer.
@MainActor final class SyntheticDWICommand: NSObject, NSMenuItemValidation {
    static let shared = SyntheticDWICommand()

    /// Takes the item of `exportMenu` that sends the command.
    static func install(in exportMenu: NSMenu?) {
        exportMenu?.items.first { $0.action == #selector(exportSyntheticDWI(_:)) }?.target = shared
    }

    private var viewer: ViewerController? { NSApp.mainWindow?.windowController as? ViewerController }

    @IBAction @objc(exportSyntheticDWI:)
    func exportSyntheticDWI(_ sender: Any?) {
        guard let viewer else { return }
        ViewerSyntheticDWI(viewer: viewer, processGraph: viewer.sessionGraph.processGraph).ask()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        viewer != nil
    }
}

/// The diffusion-weighted image at a b-value that was not acquired, computed
/// from the diffusion series a 2D viewer shows and written into the study as
/// a new series.
///
/// The series is either open in 4D, one b-value per movie frame, or a single
/// stack that holds every b-value at each position. The b-value of a frame is
/// read from its first file and can be corrected in the dialog, since a
/// header need not carry it; in a single stack each image's own is read. The
/// fit, the numbers of the dialog and the pixels stored are IsiXImaging's
/// SyntheticDiffusion. The files are written by DICOMExport over the header
/// of each slice's image at the highest b-value, then say what they are: the
/// b-value computed, also in a sequence name that carried the acquired one, a
/// derived image, and what it was derived from.
@MainActor struct ViewerSyntheticDWI {

    unowned let viewer: ViewerController
    let processGraph: ProcessGraph

    static var title: String { NSLocalizedString("Synthetic DWI", comment: "Title of the synthetic diffusion-weighted image export") }

    /// The diffusion series the viewer shows.
    struct Source: Sendable {
        /// The images of each slice.
        var slices: [[T2FitMapping.Coordinate]]
        /// In 4D, the b-value read for each movie frame; nil for a single stack.
        var frameBValues: [Double?]?
        /// In a single stack, the b-value of each image.
        var imageBValues: [T2FitMapping.Coordinate: Double] = [:]
    }

    /// What the user asked for.
    struct Request: Sendable {
        /// In 4D, the b-value of each movie frame.
        var frameBValues: [Double]?
        var target: Double
        var seriesName: String
    }

    /// Why nothing was written, as the alert says it.
    struct Failure: Error {
        let message: String
    }

    // MARK: - The dialog

    /// Reads the series and asks for the b-value and the name of the new
    /// series, on a sheet of the viewer's window; a series that cannot be
    /// used is explained instead.
    func ask() {
        switch source() {
        case .failure(let refusal):
            explain(Self.message(for: refusal))
        case .success(let source):
            let target = processGraph.preferences[ViewerPreferences.syntheticDWIBValue]
            present(source, bValues: Self.shownBValues(of: source), target: SyntheticDiffusion.text(of: target), name: nil)
        }
    }

    /// The b-values the dialog shows: one per frame in 4D, the different
    /// ones of the images in a single stack.
    static func shownBValues(of source: Source) -> String {
        if let frames = source.frameBValues { return SyntheticDiffusion.text(of: frames) }
        return SyntheticDiffusion.text(of: Set(source.imageBValues.values).sorted().map(Optional.some))
    }

    private func present(_ source: Source, bValues: String, target: String, name: String?) {
        guard let window = viewer.window else { return }
        let fields = SyntheticDWIFields(bValues: bValues, bValuesEditable: source.frameBValues != nil, target: target, name: name)
        let alert = NSAlert()
        alert.messageText = Self.title
        alert.informativeText = NSLocalizedString("Computes the diffusion-weighted image at a b-value that was not acquired, from the b-values of this series, and adds it to the study as a new series.", comment: "")
        alert.accessoryView = fields.view
        alert.addButton(withTitle: NSLocalizedString("Export", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.window.initialFirstResponder = fields.target
        let viewer = self.viewer, processGraph = self.processGraph
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            // From the run loop, once the sheet is gone: what follows may show
            // an alert of its own, and writes the files.
            let typed = (bValues: fields.bValues.stringValue, target: fields.target.stringValue, name: fields.name.stringValue)
            onMainRunLoop {
                ViewerSyntheticDWI(viewer: viewer, processGraph: processGraph).answer(source, typed: typed)
            }
        }
    }

    /// What follows the dialog: the export, or what is wrong with what was
    /// typed and the dialog again, as it was left.
    private func answer(_ source: Source, typed: (bValues: String, target: String, name: String)) {
        switch Self.request(source, bValues: typed.bValues, target: typed.target, name: typed.name) {
        case .failure(let failure):
            explain(failure.message)
            present(source, bValues: typed.bValues, target: typed.target, name: typed.name)
        case .success(let request):
            processGraph.preferences.set(request.target, for: ViewerPreferences.syntheticDWIBValue)
            if case .failure(let failure) = export(source, request) {
                explain(failure.message)
            }
        }
    }

    /// What was typed, as a request, or what is wrong with it.
    static func request(_ source: Source, bValues: String, target: String, name: String) -> Result<Request, Failure> {
        var request = Request(frameBValues: nil, target: 0, seriesName: name.trimmingCharacters(in: .whitespacesAndNewlines))
        if let frames = source.frameBValues {
            guard let values = SyntheticDiffusion.bValues(in: bValues), values.count == frames.count else {
                return .failure(Failure(message: String(format: NSLocalizedString("Enter one b-value for each of the %ld 4D frames, separated by commas, for example: 0, 50, 800.", comment: ""), frames.count)))
            }
            guard Set(values).count >= 2 else {
                return .failure(Failure(message: NSLocalizedString("Enter at least two different b-values.", comment: "")))
            }
            request.frameBValues = values
        }
        guard let value = SyntheticDiffusion.bValue(in: target) else {
            return .failure(Failure(message: NSLocalizedString("Enter the b-value to compute, a number of 0 or more, for example 1600.", comment: "")))
        }
        request.target = value
        guard !request.seriesName.isEmpty else {
            return .failure(Failure(message: NSLocalizedString("Enter a name for the new series.", comment: "")))
        }
        return .success(request)
    }

    private func explain(_ message: String) {
        HorosAlertPanel.runCritical(title: Self.title, message: message,
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    static func message(for refusal: SyntheticDiffusion.Refusal) -> String {
        switch refusal {
        case .noImages, .unpairedPositions:
            return NSLocalizedString("Synthetic DWI needs a 2D viewer showing a diffusion series: either opened in 4D, with one b-value per frame, or a single series that holds two or more b-values at each position.", comment: "")
        case .sizeMismatch:
            return NSLocalizedString("Synthetic DWI needs images that all have pixels and the same width and height.", comment: "")
        case .tooFewBValues, .missingBValue:
            return NSLocalizedString("The images of this series do not carry two or more b-values.", comment: "")
        }
    }

    // MARK: - The series on screen

    private var movieCount: Int { Int(viewer.maxMovieIndex()) }

    private func list(_ items: Any?) -> [Any] { items as? [Any] ?? [] }

    func pix(at coordinate: T2FitMapping.Coordinate) -> DCMPix? {
        let images = list(movieCount > 1 ? viewer.pixList(coordinate.movie) : viewer.pixList())
        return images.indices.contains(coordinate.slice) ? images[coordinate.slice] as? DCMPix : nil
    }

    func file(at coordinate: T2FitMapping.Coordinate) -> DicomImage? {
        let files = list(movieCount > 1 ? viewer.fileList(coordinate.movie) : viewer.fileList())
        return files.indices.contains(coordinate.slice) ? files[coordinate.slice] as? DicomImage : nil
    }

    /// The slices of the series and the b-values read from its files.
    func source() -> Result<Source, SyntheticDiffusion.Refusal> {
        if movieCount > 1 {
            let sliceCount = list(viewer.pixList(0)).count
            guard sliceCount > 0 else { return .failure(.noImages) }
            let frames = (0..<movieCount).map { movie in
                file(at: T2FitMapping.Coordinate(movie: movie, slice: 0)).flatMap(Self.bValue(of:))
            }
            return .success(Source(slices: SyntheticDiffusion.slices(movieCount: movieCount, sliceCount: sliceCount), frameBValues: frames))
        }
        let origins = list(viewer.pixList()).map { item -> SIMD3<Double> in
            guard let pix = item as? DCMPix else { return SIMD3(.nan, .nan, .nan) }
            return SIMD3(pix.originX, pix.originY, pix.originZ)
        }
        switch SyntheticDiffusion.slices(origins: origins) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let slices):
            var source = Source(slices: slices, frameBValues: nil)
            for coordinate in slices.joined() {
                guard let value = file(at: coordinate).flatMap(Self.bValue(of:)) else { return .failure(.missingBValue) }
                source.imageBValues[coordinate] = value
            }
            guard slices.allSatisfy({ slice in Set(slice.compactMap { source.imageBValues[$0] }).count >= 2 }) else {
                return .failure(.tooFewBValues)
            }
            return .success(source)
        }
    }

    /// The b-value of one image, read from its file.
    static func bValue(of image: DicomImage) -> Double? {
        guard let path = image.completePath(),
              let object = DCMObject.object(contentsOfFile: path, decodingPixelData: false, lastGroup: 0x2001) else { return nil }
        return BValueSplit.bValue(BValueSplit.tags.map { object.attributeValue(forKey: $0) })
    }

    // MARK: - The new series

    /// One slice computed: its samples and the image it takes its header and
    /// geometry from.
    private struct Slice {
        let samples: [Float]
        let template: T2FitMapping.Coordinate
        let bValues: [Double]
    }

    /// Computes every slice, writes the series, indexes it in the database
    /// the browser shows and opens it in a viewer.
    func export(_ source: Source, _ request: Request) -> Result<Void, Failure> {
        let computed: [Slice]
        switch compute(source, request) {
        case .failure(let refusal): return .failure(Failure(message: Self.message(for: refusal)))
        case .success(let slices): computed = slices
        }

        let maximum = computed.reduce(Float(0)) { max($0, $1.samples.max() ?? 0) }
        let slope = SyntheticDiffusion.storedSlope(maximum: maximum)
        let exporter = DICOMExport()
        exporter.beginSeries(withNumber: Self.seriesNumber())
        exporter.setSeriesDescription(request.seriesName)

        var written: [String] = []
        for slice in computed {
            guard let pix = pix(at: slice.template), let source = file(at: slice.template)?.completePath() else {
                return .failure(Failure(message: NSLocalizedString("Synthetic DWI needs the original files of the series.", comment: "")))
            }
            var stored = SyntheticDiffusion.stored(slice.samples, slope: slope)
            var orientation = [Float](repeating: 0, count: 9), origin = [Float](repeating: 0, count: 3)
            pix.orientation(&orientation)
            pix.origin(&origin)
            exporter.setSourceFile(source)
            exporter.setModalityAsSource(true)
            exporter.setPixelSpacing(Float(pix.pixelSpacingX), Float(pix.pixelSpacingY))
            exporter.setSliceThickness(pix.sliceThickness)
            exporter.setSlicePosition(Float(pix.sliceLocation))
            exporter.setOrientation(&orientation)
            exporter.setPosition(&origin)
            let window = max(1, Int(maximum.rounded()))
            exporter.setDefaultWWWL(window, window / 2)
            let path: String? = stored.withUnsafeMutableBytes { bytes in
                guard let pixels = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
                _ = exporter.setPixelData(pixels, samplesPerPixel: 1, bitsPerSample: 16, width: pix.pwidth, height: pix.pheight)
                // -setPixelData: starts from signed CT pixels: these are neither.
                exporter.setSigned(false)
                exporter.setOffset(0)
                exporter.setSlope(slope)
                return exporter.writeDCMFile(nil)
            }
            guard let path, Self.describe(fileAt: path, target: request.target, from: slice.bValues) else {
                written.forEach { try? FileManager.default.removeItem(atPath: $0) }
                return .failure(Failure(message: NSLocalizedString("The synthetic DWI could not be written.", comment: "")))
            }
            written.append(path)
        }

        let images = GeneratedSeriesImport(processGraph: processGraph).add(written, marksKeyImages: false) ?? []
        if !images.isEmpty, let browser = processGraph.currentBrowser,
           let opened = browser.openViewer(fromImages: [images], movie: false, viewer: nil, keyImagesOnly: false) {
            opened.window?.subtitle = String(format: NSLocalizedString("b = %@ s/mm²", comment: "Diffusion b-value of a viewer"),
                                             NumberFormatter.localizedString(from: NSNumber(value: request.target), number: .decimal))
            processGraph.appController?.tileWindows(nil)
        }
        return .success(())
    }

    /// The image of every slice at the b-value asked for.
    private func compute(_ source: Source, _ request: Request) -> Result<[Slice], SyntheticDiffusion.Refusal> {
        guard !source.slices.isEmpty else { return .failure(.noImages) }
        var computed: [Slice] = []
        for coordinates in source.slices {
            var acquisitions: [SyntheticDiffusion.Acquisition] = []
            var size: (width: Int, height: Int)?
            for coordinate in coordinates {
                guard let value = request.frameBValues.map({ $0.indices.contains(coordinate.movie) ? $0[coordinate.movie] : nil })
                        ?? source.imageBValues[coordinate] else { return .failure(.missingBValue) }
                guard let pix = pix(at: coordinate), !pix.isRGB, pix.pwidth > 0, pix.pheight > 0, let samples = pix.fImage else {
                    return .failure(.sizeMismatch)
                }
                if size == nil { size = (pix.pwidth, pix.pheight) }
                guard let size, size.width == pix.pwidth, size.height == pix.pheight else { return .failure(.sizeMismatch) }
                acquisitions.append(SyntheticDiffusion.Acquisition(
                    bValue: value, samples: Array(UnsafeBufferPointer(start: samples, count: size.width * size.height))))
            }
            guard let size, let highest = SyntheticDiffusion.template(of: acquisitions.map(\.bValue)) else { return .failure(.noImages) }
            switch SyntheticDiffusion.image(of: acquisitions, pixels: size.width * size.height, at: request.target) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let samples):
                computed.append(Slice(samples: samples, template: coordinates[highest], bValues: acquisitions.map(\.bValue)))
            }
        }
        return .success(computed)
    }

    /// The number of a series that begins now, as the viewer's other exports
    /// number theirs.
    private static func seriesNumber() -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NSTimeZone.default
        let now = Date()
        return SeriesExportSettings.seriesNumber(.series, minute: calendar.component(.minute, from: now),
                                                 second: calendar.component(.second, from: now))
    }

    /// The private elements a manufacturer writes the b-value in: Siemens,
    /// GE and Philips. The file was copied from an acquired image, and they
    /// would go on saying that image's b-value.
    static let manufacturerBValueTags: [UInt32] = [0x0019_100C, 0x0043_1039, 0x2001_1003]

    /// Makes the file written over an acquired image's header say what it
    /// is: the b-value computed, a derived image, and what it was derived
    /// from. False when the file cannot be read or written again.
    static func describe(fileAt path: String, target: Double, from bValues: [Double]) -> Bool {
        let file = IsiXDCMTKFile()
        guard (try? file.read(fileAtPath: path)) != nil else { return false }
        file.loadAllDataIntoMemory()
        let dataset = file.dataset
        manufacturerBValueTags.forEach { dataset.removeElement(forTag: $0) }
        guard (try? dataset.putString(SyntheticDiffusion.text(of: target), forTag: 0x0018_9087)) != nil else { return false }
        _ = try? dataset.putString("DERIVED\\SECONDARY\\DIFFUSION\\CALC_BVALUE", forTag: 0x0008_0008)
        if let name = dataset.string(forTag: 0x0018_0024).map({ String(cString: $0) }),
           let renamed = SyntheticDiffusion.sequenceName(name, at: target) {
            _ = try? dataset.putString(renamed, forTag: 0x0018_0024)
        }
        _ = try? dataset.putString(SyntheticDiffusion.derivationDescription(target: target, from: bValues), forTag: 0x0008_2111)
        return (try? file.write(toPath: path, transferSyntax: "1.2.840.10008.1.2.1", removingPadding: true)) != nil
    }
}

/// The fields of the Synthetic DWI dialog: the b-values of the series, the
/// b-value to compute and the name of the new series, which follows the
/// b-value until the user writes another name.
@MainActor final class SyntheticDWIFields: NSObject, NSTextFieldDelegate {
    let view: NSView
    let bValues = NSTextField(string: "")
    let target = NSTextField(string: "")
    let name = NSTextField(string: "")
    /// The name the dialog proposed last; the user's own is left alone.
    private var proposedName: String

    init(bValues shown: String, bValuesEditable: Bool, target shownTarget: String, name shownName: String?) {
        let proposed = SyntheticDiffusion.bValue(in: shownTarget).map(SyntheticDiffusion.seriesName(bValue:)) ?? ""
        proposedName = proposed
        bValues.stringValue = shown
        bValues.isEditable = bValuesEditable
        bValues.isSelectable = true
        bValues.isBezeled = bValuesEditable
        bValues.drawsBackground = bValuesEditable
        target.stringValue = shownTarget
        name.stringValue = shownName ?? proposed

        let rows: [(String, NSTextField)] = [
            (bValuesEditable ? NSLocalizedString("b-values of the 4D frames (s/mm²):", comment: "")
                             : NSLocalizedString("b-values of the series (s/mm²):", comment: ""), bValues),
            (NSLocalizedString("Synthetic b-value (s/mm²):", comment: ""), target),
            (NSLocalizedString("Series name:", comment: ""), name),
        ]
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for (_, field) in rows {
            field.widthAnchor.constraint(equalToConstant: 240).isActive = true
            field.lineBreakMode = .byTruncatingTail
        }
        grid.translatesAutoresizingMaskIntoConstraints = true
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        view = grid
        super.init()
        target.delegate = self
    }

    /// The proposed name follows the b-value typed.
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === target, name.stringValue == proposedName,
              let value = SyntheticDiffusion.bValue(in: target.stringValue) else { return }
        proposedName = SyntheticDiffusion.seriesName(bValue: value)
        name.stringValue = proposedName
    }
}
