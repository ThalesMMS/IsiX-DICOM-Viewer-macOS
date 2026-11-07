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
import IsiXImaging

/// Asks for a first slice, a last slice and a step, and opens a new viewer of
/// the slices from the first to the last, one every step. The new viewer gets
/// copies of the slices and of their pixels, in a volume of its own, the way a
/// copy of the viewer does: the series and this viewer are unchanged, and
/// nothing is written. Each kept slice keeps its position and orientation, so
/// the interval of the reduced series is the step times the series' interval.
/// Which slices are kept, the values the dialog accepts and that interval are
/// IsiXImaging's SeriesReduction. The menu item, 2D Viewer > Reduce Series…,
/// is ViewerStudyCommands'.
@MainActor struct ViewerSeriesReduction {

    unowned let viewer: ViewerController

    private var title: String { NSLocalizedString("Reduce Series", comment: "Title of the dialog of 2D Viewer > Reduce Series…") }

    func run() {
        // The pixels are copied: they must all be read first.
        viewer.checkEverythingLoaded()

        let movie = Int(viewer.horos_curMovieIndex)
        let count = viewer.horos_pixArray(movie).count
        guard count > 1 else {
            fail(NSLocalizedString("This series has a single slice: there is nothing to reduce.", comment: ""))
            return
        }
        guard let reduction = ask(sliceCount: count) else { return }

        let flipped = viewer.horos_imageView?.flippedData ?? false
        let kept = reduction.keptIndices(flipped: flipped)
        guard let opened = openViewer(of: kept, reduction: reduction) else {
            fail(NSLocalizedString("There is not enough memory to make the reduced series.", comment: ""))
            return
        }

        opened.setPostprocessed(true)
        opened.computeInterval()
        opened.setWindowTitle(viewer)
        opened.window?.subtitle = String(format: NSLocalizedString("Slices %ld–%ld, every %ld", comment: "Subtitle of a reduced series' viewer: first, last, step"),
                                         reduction.first, reduction.last, reduction.step)
        if let curDCM = viewer.horos_imageView?.curDCM { opened.setWL(curDCM.wl, ww: curDCM.ww) }
        opened.applyCLUTString(viewer.horos_curCLUTMenu)
        opened.applyOpacityString(viewer.horos_curOpacityMenu)

        let shown = Int(viewer.horos_imageView?.curImage ?? 0)
        opened.setImageIndex(reduction.nearestKeptPosition(to: shown, flipped: flipped))
        opened.imageView()?.sendSyncMessage(0)
        opened.adjustSlider()
        opened.window?.makeKeyAndOrderFront(viewer)
    }

    /// The new viewer of the kept slices of every time point that has as many
    /// slices as the one shown; nil when no volume could be allocated.
    private func openViewer(of kept: [Int], reduction: SeriesReduction) -> ViewerController? {
        var opened: ViewerController?
        for movie in 0..<max(Int(viewer.horos_maxMovieIndex), 0) {
            let slices = viewer.horos_pixArray(movie)
            guard slices.count == reduction.sliceCount,
                  let copy = Self.reducedCopy(of: kept, from: slices, files: viewer.horos_fileList(at: movie) as? [Any] ?? [], reduction: reduction)
            else { continue }

            let lists = (pixels: NSMutableArray(array: copy.pixels), files: NSMutableArray(array: copy.files))
            if let opened {
                opened.addMovieSerie(lists.pixels, lists.files, copy.volume)
            } else {
                opened = ViewerController.newWindow(lists.pixels, lists.files, copy.volume)
                // +newWindow::: hands over the +1 of the viewer's alloc; the
                // viewer releases itself when its window closes.
                if let opened { _ = Unmanaged.passRetained(opened) }
            }
        }
        return opened
    }

    /// A copy of slices `kept` of a time point: a volume of their pixels, a
    /// copy of each slice pointing into it, at its own position, and their
    /// files. Nil when the volume cannot be allocated.
    private static func reducedCopy(of kept: [Int], from slices: [DCMPix], files: [Any],
                             reduction: SeriesReduction) -> (volume: NSData, pixels: [DCMPix], files: [Any])? {
        // Each pixel is a 32-bit float or a 32-bit ARGB value.
        let sizes = kept.map { slices[$0].pwidth &* slices[$0].pheight &* 4 }
        let length = sizes.reduce(0, &+)
        guard length > 0, let buffer = malloc(length)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let volume = NSData(bytesNoCopy: buffer, length: length, freeWhenDone: true)

        var pixels: [DCMPix] = [], keptFiles: [Any] = []
        var offset = 0
        for (position, index) in kept.enumerated() {
            let source = slices[index]
            guard let pix = source.copy() as? DCMPix else { return nil }
            let destination = buffer + offset
            if let samples = source.fImage {
                memcpy(destination, samples, sizes[position])
            } else {
                memset(destination, 0, sizes[position])
            }
            offset += sizes[position]

            pix.fImage = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: Float.self)
            pix.id = position
            pix.tot = kept.count
            // The position and orientation are the slice's own; only the
            // interval to the next kept slice changes.
            pix.sliceInterval = reduction.sliceInterval(original: source.sliceInterval)
            pixels.append(pix)

            if index < files.count {
                keptFiles.append(files[index])
            } else if let first = files.first {
                keptFiles.append(first)
            }
        }
        return (volume, pixels, keptFiles)
    }

    // MARK: - The dialog

    /// The reduction the user asks for, or nil when the dialog is cancelled.
    /// Values that make no reduction are explained and asked again.
    private func ask(sliceCount: Int) -> SeriesReduction? {
        let form = SeriesReductionForm(sliceCount: sliceCount)
        var problem: SeriesReduction.Problem?
        while true {
            let alert = NSAlert()
            alert.messageText = title
            let summary = String(format: NSLocalizedString("A new viewer shows the slices from the first to the last, keeping one slice every step. This series has %ld slices; it is not changed.", comment: ""),
                                 sliceCount)
            alert.informativeText = problem.map { message(for: $0, sliceCount: sliceCount) + "\n\n" + summary } ?? summary
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            alert.accessoryView = form.view
            alert.window.initialFirstResponder = form.firstField

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let values = form.values
            switch SeriesReduction.make(first: values.first, last: values.last, step: values.step, sliceCount: sliceCount) {
            case .success(let reduction): return reduction
            case .failure(let refused): problem = refused
            }
        }
    }

    private func message(for problem: SeriesReduction.Problem, sliceCount: Int) -> String {
        switch problem {
        case .emptySeries:
            return NSLocalizedString("This series has no slices.", comment: "")
        case .firstOutOfRange:
            return String(format: NSLocalizedString("The first slice must be between 1 and %ld.", comment: ""), sliceCount)
        case .lastOutOfRange:
            return String(format: NSLocalizedString("The last slice must be between 1 and %ld.", comment: ""), sliceCount)
        case .lastBeforeFirst:
            return NSLocalizedString("The last slice cannot come before the first.", comment: "")
        case .stepTooSmall:
            return NSLocalizedString("The step must be 1 or more.", comment: "")
        }
    }

    private func fail(_ message: String) {
        HorosAlertPanel.runCritical(title: title, message: message,
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }
}

/// The accessory of the Reduce Series dialog: the first slice, the last slice
/// and the step, each a number field with a stepper that follow each other.
/// It starts on the whole series, every second slice.
@MainActor final class SeriesReductionForm: NSObject, NSTextFieldDelegate {

    let view: NSView
    private let fields: [NSTextField]
    private let steppers: [NSStepper]

    var firstField: NSTextField { fields[0] }

    /// The three values, as typed (a field that is not a number reads 0,
    /// which the rules refuse).
    var values: (first: Int, last: Int, step: Int) {
        let numbers = fields.map { Int($0.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return (numbers[0], numbers[1], numbers[2])
    }

    init(sliceCount: Int) {
        let defaults = SeriesReduction.defaults(sliceCount: sliceCount)
        let labels = [NSLocalizedString("First slice:", comment: "Reduce Series dialog"),
                      NSLocalizedString("Last slice:", comment: "Reduce Series dialog"),
                      NSLocalizedString("Keep one slice every:", comment: "Reduce Series dialog: the step")]
        let initial = [defaults.first, defaults.last, defaults.step]
        // The step may be as long as the series; the slices go up to its count.
        let maxima = [sliceCount, sliceCount, max(sliceCount, 2)]

        var fields: [NSTextField] = [], steppers: [NSStepper] = [], rows: [[NSView]] = []
        for i in 0..<3 {
            let field = NSTextField(string: String(initial[i]))
            field.alignment = .right
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true

            let stepper = NSStepper()
            stepper.minValue = 1
            stepper.maxValue = Double(maxima[i])
            stepper.increment = 1
            stepper.valueWraps = false
            stepper.integerValue = initial[i]
            stepper.tag = i

            let label = NSTextField(labelWithString: labels[i])
            label.alignment = .right
            fields.append(field)
            steppers.append(stepper)
            rows.append([label, field, stepper])
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)

        self.view = grid
        self.fields = fields
        self.steppers = steppers
        super.init()

        for (i, field) in fields.enumerated() {
            field.delegate = self
            field.tag = i
            steppers[i].target = self
            steppers[i].action = #selector(stepped(_:))
        }
    }

    @objc private func stepped(_ sender: NSStepper) {
        fields[sender.tag].stringValue = String(sender.integerValue)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, fields.indices.contains(field.tag),
              let value = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        steppers[field.tag].integerValue = value
    }
}
