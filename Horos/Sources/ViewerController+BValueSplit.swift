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
import IsiXDICOMDataset

/// 2D Viewer > Split Series by b-value: a diffusion series that stacks every
/// b-value in one long run of images is shown as one viewer per b-value,
/// tiled side by side, so they scroll together by slice position. Nothing is
/// written: the viewers show subsets of the series, and the series in the
/// database is unchanged.
extension ViewerController {

    @objc(splitSeriesByBValue:)
    func splitSeriesByBValue(_ sender: Any!) {
        let movie = Int(self.horos_curMovieIndex)
        let images = ((self.horos_fileList(at: movie) as NSArray?) ?? NSArray()).compactMap { $0 as? DicomImage }

        let groups = DiffusionBValueSplit.groups(images.map(Self.bValue(of:)))
        guard groups.count >= 2, let browser = BrowserController.currentBrowser() else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Split Series by b-value", comment: ""),
                                        message: NSLocalizedString("The images of this series do not carry two or more b-values.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        // This viewer shows the first b-value; each other one opens its own.
        var viewers: [ViewerController] = []
        for (index, group) in groups.enumerated() {
            let subset = NSMutableArray(array: group.indices.map { images[$0] })
            guard let viewer = browser.openViewer(fromImages: [subset], movie: false,
                                                  viewer: index == 0 ? self : nil, keyImagesOnly: false) else { continue }
            viewer.window?.subtitle = group.bValue.map {
                String(format: NSLocalizedString("b = %@ s/mm²", comment: "Diffusion b-value of a viewer"),
                       NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal))
            } ?? NSLocalizedString("No b-value", comment: "")
            viewers.append(viewer)
        }
        AppController.shared()?.tileWindows(nil)
    }

    /// The b-value of one image, read from its file.
    private static func bValue(of image: DicomImage) -> Double? {
        guard let path = image.completePath(),
              let object = DCMObject.object(contentsOfFile: path, decodingPixelData: false, lastGroup: 0x2001) else { return nil }
        return DiffusionBValueSplit.bValue(DiffusionBValueSplit.tags.map { object.attributeValue(forKey: $0) })
    }
}
