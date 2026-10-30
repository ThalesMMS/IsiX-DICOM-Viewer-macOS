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

// Whether the window, zoom, pan, rotation and flips on screen are the series'
// (COPYSETTINGSINSERIES on) or each image's own (off), and what changing it
// writes into the images' presentation state. What is written to each image is
// IsiXImaging's SeriesSettingsPropagation; the view supplies the values on
// screen and the images.
//
// Turning propagation on is a flattening, and is meant to be: every image loses
// its own settings and takes the one on screen. Off means off for the window:
// only the image on screen keeps the window on screen, and every other image
// keeps whatever it already had (an untouched image, its own window from the
// file). Zoom, pan, rotation and flips have no value of their own in the file:
// an image without them takes the ones on screen, so nothing changes under the
// user when the option is chosen.

extension DCMView {

    /// The setter of COPYSETTINGSINSERIES: the flag, then every movie frame's
    /// images of the window's series written with it.
    func applyCopySettingsInSeries(_ b: Bool) {
        let v = viewerMessages(self.windowController())

        self.horos_COPYSETTINGSINSERIES = b

        var i: Int32 = 0
        while i < Int32(v?.viewerMaxMovieIndex() ?? 0) {
            self.writeCopySettingsInSeries(forPixels: v?.viewerPixList(Int(i)))
            i += 1
        }
    }

    @objc(setCOPYSETTINGSINSERIESdirectly:)
    public dynamic func setCOPYSETTINGSINSERIESdirectly(_ b: Bool) {
        self.horos_COPYSETTINGSINSERIES = b
    }

    /// Applies a change of the propagation flag to one series' images.
    @objc(writeCopySettingsInSeriesForPixels:)
    public dynamic func writeCopySettingsInSeries(forPixels pixels: NSArray!) {
        let key = SeriesSettingsPropagation.Key.self
        for case let pix as DCMPix in (pixels ?? NSArray()) {
            let im = pix.imageObj()

            if self.horos_COPYSETTINGSINSERIES && pix.isLoaded() {
                pix.changeWLWW(self.horos_curWL, self.horos_curWW)
            }

            let stored = SeriesSettingsPropagation.Stored(
                scale: im?.value(forKey: key.scale) != nil,
                rotationAngle: im?.value(forKey: key.rotationAngle) != nil,
                yFlipped: im?.value(forKey: key.yFlipped) != nil,
                xFlipped: im?.value(forKey: key.xFlipped) != nil,
                xOffset: im?.value(forKey: key.xOffset) != nil,
                yOffset: im?.value(forKey: key.yOffset) != nil)
            let writes = SeriesSettingsPropagation.writes(propagate: self.horos_COPYSETTINGSINSERIES,
                                                          onScreen: !self.horos_COPYSETTINGSINSERIES && im === self.imageObj(),
                                                          stored: stored)

            for write in writes {
                switch write {
                case .clear(let k):
                    im?.setValue(nil, forKey: k)
                case .windowWidth:
                    im?.setValue(NSNumber(value: self.horos_curWW), forKey: key.windowWidth)
                case .windowLevel:
                    im?.setValue(NSNumber(value: pix.storedWindowLevel(forCalibratedLevel: self.horos_curWL)), forKey: key.windowLevel)
                case .scale:
                    im?.setValue(self.isScaledFit() ? nil : NSNumber(value: self.horos_scaleValue), forKey: key.scale)
                case .rotationAngle:
                    im?.setValue(NSNumber(value: self.horos_rotation), forKey: key.rotationAngle)
                case .yFlipped:
                    im?.setValue(NSNumber(value: self.horos_yFlipped), forKey: key.yFlipped)
                case .xFlipped:
                    im?.setValue(NSNumber(value: self.horos_xFlipped), forKey: key.xFlipped)
                case .offsets:
                    im?.setValue(NSNumber(value: Float(self.horos_origin.x)), forKey: key.xOffset)
                    im?.setValue(NSNumber(value: Float(self.horos_origin.y)), forKey: key.yOffset)
                }
            }
        }
    }

    /// The toolbar's switch: the flag of every view of the window that shows
    /// the same series, and their images written with it.
    @objc(switchCopySettingsInSeries:)
    public dynamic func switchCopySettingsInSeries(_ sender: Any!) {
        self.horos_COPYSETTINGSINSERIES = !self.horos_COPYSETTINGSINSERIES

        inputLogException(inputCatch {
            let v = viewerMessages(self.windowController())

            for case let imageView as DCMView in (v?.viewerImageViews() ?? []) {
                if imageView.seriesObj() === self.seriesObj() {
                    imageView.copysettingsinseries = self.horos_COPYSETTINGSINSERIES

                    var i: Int32 = 0
                    while i < Int32(v?.viewerMaxMovieIndex() ?? 0) {
                        imageView.writeCopySettingsInSeries(forPixels: v?.viewerPixList(Int(i)))
                        i += 1
                    }
                }
            }
        }, "-[DCMView switchCopySettingsInSeries:]")
    }
}
