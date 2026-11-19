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

/// A stenosis measure kept with its study: one image, the strip as the tool
/// shows it and under it the summary as Copy Summary copies it, saved as a
/// Secondary Capture in a series of its own. It is made when asked for, and
/// nothing else writes it.
@MainActor
enum StenosisCapture {
    /// The strip, as it is drawn now, over the lines of the summary.
    static func image(of strip: NSView, summary: String) -> NSImage? {
        guard strip.bounds.width > 0, strip.bounds.height > 0, let drawn = strip.bitmapImageRepForCachingDisplay(in: strip.bounds) else { return nil }
        strip.cacheDisplay(in: strip.bounds, to: drawn)
        let margin: CGFloat = 12
        let text = NSAttributedString(string: summary, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.white,
        ])
        let width = max(strip.bounds.width, 640)
        let textHeight = ceil(text.boundingRect(with: NSSize(width: width - 2 * margin, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin]).height)
        let size = NSSize(width: width, height: strip.bounds.height + textHeight + 2 * margin)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        drawn.draw(in: NSRect(x: 0, y: size.height - strip.bounds.height, width: strip.bounds.width, height: strip.bounds.height))
        text.draw(with: NSRect(x: margin, y: margin, width: width - 2 * margin, height: textHeight), options: [.usesLineFragmentOrigin])
        image.unlockFocus()
        return image
    }

    /// Saves `image` in the study of `sourceFile`, a file of the series
    /// measured, as a Secondary Capture in a new series named `description`.
    /// False when the study's file is gone or the image could not be written.
    static func save(_ image: NSImage, sourceFile: String?, description: String, into database: DicomDatabase?) -> Bool {
        guard let database, let sourceFile, FileManager.default.fileExists(atPath: sourceFile) else { return false }
        let export = DICOMExport()
        export.setSeriesDescription(description)
        let now = Calendar.current.dateComponents([.minute, .second], from: Date())
        export.setSeriesNumber(7600 + (now.minute ?? 0) + (now.second ?? 0))
        export.setSourceFile(sourceFile)
        return export.setPixelNSImage(image) == 0 && GeneratedSeriesImport.process.add(into: database, writing: { export.writeDCMFile($0) }) != nil
    }
}
