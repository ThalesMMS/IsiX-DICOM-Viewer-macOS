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

// BrowserController (GSPS) is implemented in Swift since #722: a Swift
// extension of BrowserController, which stays Objective-C, with the selectors
// of the former category.
//
// Two messages go through the Objective-C runtime by selector, as the former
// file sent them: +[HorosGSPSDocument documentWithContentsOfFile:], declared
// by the Objective-C category of GSPSFileReader.h, whose header imports
// Horos-Swift.h and so cannot be read by the bridging header; and
// -[ViewerController applyGrayscaleSoftcopyPresentationStateFromPath:], whose
// result the former file did not read either.

public extension BrowserController {

    @objc(horos_presentGSPSFlags:missing:)
    func horos_presentGSPSFlags(_ document: GSPSDocument!, missing: [GSPSImageReference]!) {
        var lines: [String] = []
        for reference in missing ?? [] {
            lines.append(String(format: NSLocalizedString("Missing referenced SOP Instance UID %@", comment: ""), reference.sopInstanceUID))
        }
        for flag in document?.unsupportedFeatures ?? [] {
            lines.append(flag)
        }
        if lines.count == 0 {
            return
        }
        for line in lines {
            NSLog("GSPS: %@", line)
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Grayscale Presentation State", comment: "")
        alert.informativeText = (lines as NSArray).componentsJoined(by: "\n")
        alert.runModal()
    }

    /// If `series` is a Softcopy Presentation State, opens the referenced images
    /// (when they are in the same study) and applies the documented GSPS subset.
    /// Returns YES when the series was handled as a presentation state, even if
    /// every reference is missing — in that case no empty viewer is opened.
    @objc(horos_tryOpenGSPSSeries:viewer:keyImagesOnly:openedViewer:)
    func horos_tryOpenGSPSSeries(_ series: DicomSeries!,
                                 viewer: ViewerController!,
                                 keyImagesOnly keyImages: Bool,
                                 openedViewer outViewer: AutoreleasingUnsafeMutablePointer<ViewerController?>?) -> Bool {
        if let outViewer {
            outViewer.pointee = nil
        }
        guard let series, series.isKind(of: DicomSeries.self) else {
            return false
        }

        let sopClass = series.seriesSOPClassUID
        if GSPSDocument.isSoftcopyPresentationStateSOPClass(sopClass) == false
            && DCMAbstractSyntaxUID.isPresentationState(sopClass) == false {
            return false
        }

        let gspsImage = ((series.sortedImages() as NSArray?)?.firstObject ?? (series.images as NSSet?)?.anyObject()) as? DicomImage
        let path = gspsImage?.completePath()
        guard let document = gspsDocument(contentsOfFile: path) else {
            NSLog("GSPS: series %@ looks like a presentation state but the file could not be read", objcFormatArgument(series.name))
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = NSLocalizedString("Grayscale Presentation State", comment: "")
            alert.informativeText = NSLocalizedString("That series is a presentation state, but the file could not be read. The original images were not opened or changed.", comment: "")
            alert.runModal()
            return true
        }

        let found = NSMutableArray()
        for case let image as DicomImage in (series.study?.images() as NSSet?) ?? NSSet() {
            if GSPSDocument.isSoftcopyPresentationStateSOPClass(image.series?.seriesSOPClassUID)
                || DCMAbstractSyntaxUID.isPresentationState(image.series?.seriesSOPClassUID) {
                continue
            }

            var matches = document.references(sopInstanceUID: image.sopInstanceUID() ?? "", frame: Int(max(1, image.frameID?.int32Value ?? 0)))
            if matches == false && (image.numberOfFrames?.int32Value ?? 0) > 1 {
                var frame: Int32 = 1
                while frame <= (image.numberOfFrames?.int32Value ?? 0) {
                    if document.references(sopInstanceUID: image.sopInstanceUID() ?? "", frame: Int(frame)) {
                        matches = true
                        break
                    }
                    frame += 1
                }
            }
            if matches {
                found.add(image)
            }
        }

        found.sort(using: [
            NSSortDescriptor(key: "instanceNumber", ascending: true),
            NSSortDescriptor(key: "frameID", ascending: true),
        ])

        var missing: [GSPSImageReference] = []
        for reference in document.referencedImages {
            var present = false
            for case let image as DicomImage in found {
                if document.references(sopInstanceUID: image.sopInstanceUID() ?? "", frame: Int(max(1, image.frameID?.int32Value ?? 0)))
                    || ((image.numberOfFrames?.int32Value ?? 0) > 1 && (image.sopInstanceUID() as NSString?)?.isEqual(to: reference.sopInstanceUID) == true) {
                    present = true
                    break
                }
            }
            if present == false {
                missing.append(reference)
            }
        }

        if found.count == 0 {
            horos_presentGSPSFlags(document, missing: missing.count > 0 ? missing : document.referencedImages)
            return true
        }

        let opened = self.openViewer(fromImages: [found],
                                     movie: false,
                                     viewer: viewer,
                                     keyImagesOnly: keyImages,
                                     tryToFlipData: true)
        if let opened {
            _ = opened.perform(NSSelectorFromString("applyGrayscaleSoftcopyPresentationStateFromPath:"), with: path)
        } else {
            horos_presentGSPSFlags(document, missing: missing)
        }

        if let outViewer {
            outViewer.pointee = opened
        }
        return true
    }
}

/// +[HorosGSPSDocument documentWithContentsOfFile:] (GSPSFileReader.h).
fileprivate func gspsDocument(contentsOfFile path: String?) -> GSPSDocument? {
    let selector = NSSelectorFromString("documentWithContentsOfFile:")
    return (GSPSDocument.self as AnyObject).perform(selector, with: path)?.takeUnretainedValue() as? GSPSDocument
}

/// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
fileprivate func objcFormatArgument(_ object: Any?) -> CVarArg {
    if let object = object as? NSObject { return object }
    if let object { return String(describing: object) as NSString }
    return "(null)" as NSString
}
