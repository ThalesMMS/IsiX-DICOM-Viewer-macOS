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

// The keys of the 2D viewer's window (play and stop, the speeds of a
// ShuttlePRO, the time points of a 4D series, the next series), the
// highlight that marks a viewer a series list click brought forward, and
// the first and last image of a movie export taken from the current image.

public extension ViewerController {

    @objc(keyDown:)
    override func keyDown(with event: NSEvent) {
        guard let characters = event.characters as NSString?, characters.length != 0 else { return }

        let c = characters.character(at: 0)

        switch ViewerKeyCommand.of(character: c, command: event.modifierFlags.contains(.command)) {
        case .playStop:
            playStop(findPlayStopButton())
        case .shuttle(let speed, let direction):
            // ShuttlePRO.
            if horos_timer == nil {
                // Play.
                playStop(findPlayStopButton())
            }

            NSLog("%@", characters)

            horos_direction = direction

            horos_speedSlider?.floatValue = speed

            speedSliderAction(self)
        case .stop:
            if horos_timer != nil {
                // Stop.
                playStop(findPlayStopButton())
            }
        case .previousTimePoint:
            if horos_maxMovieIndex > 1 {
                horos_curMovieIndex = ViewerKeyCommand.timePoint(after: horos_curMovieIndex, step: -1, count: horos_maxMovieIndex)

                setMovieIndex(horos_curMovieIndex)
            } else {
                super.keyDown(with: event)
            }
        case .nextTimePoint:
            if horos_maxMovieIndex > 1 {
                horos_curMovieIndex = ViewerKeyCommand.timePoint(after: horos_curMovieIndex, step: 1, count: horos_maxMovieIndex)

                setMovieIndex(horos_curMovieIndex)
            } else {
                super.keyDown(with: event)
            }
        case .previousSeries:
            BrowserController.currentBrowser()?.loadNextSeries((horos_fileList(at: 0) as NSArray?)?.object(at: 0) as? NSManagedObject, -1, self, true,
                                                              keyImagesOnly: horos_displayOnlyKeyImages)
        case .nextSeries:
            BrowserController.currentBrowser()?.loadNextSeries((horos_fileList(at: 0) as NSArray?)?.object(at: 0) as? NSManagedObject, 1, self, true,
                                                              keyImagesOnly: horos_displayOnlyKeyImages)
        case .other:
            super.keyDown(with: event)
        }
    }

    @objc(highLighted)
    func highLighted() -> Float {
        return horos_highLighted
    }

    @objc(highLightTimerFunction:)
    func highLightTimerFunction(_ theTimer: Timer!) {
        // highLighted -= 0.05, in double as the float was promoted.
        horos_highLighted = Float(Double(horos_highLighted) - 0.05)
        for case let v as DCMView in (horos_seriesView?.imageViews() as NSArray?) ?? NSArray() {
            v.needsDisplay = true
        }

        if horos_highLighted <= 0.0 {
            horos_highLightedTimer?.invalidate()
            horos_highLightedTimer = nil
        }
    }

    @objc(setHighLighted:)
    func setHighLighted(_ b: Float) {
        if b != horos_highLighted {
            horos_highLighted = b

            for case let v as DCMView in (horos_seriesView?.imageViews() as NSArray?) ?? NSArray() {
                v.needsDisplay = true
            }

            if b == 1.0 {
                horos_highLightedTimer?.invalidate()

                let timer = Timer.scheduledTimer(timeInterval: 0.02, target: self, selector: #selector(ViewerController.highLightTimerFunction(_:)),
                                                 userInfo: nil, repeats: true)
                horos_highLightedTimer = timer
                RunLoop.current.add(timer, forMode: .modalPanel)
                RunLoop.current.add(timer, forMode: .eventTracking)
            }
        }
    }

    @objc(setCurrentPosition:)
    @IBAction func setCurrentPosition(_ sender: Any!) {
        horosLoadViewerPanels()

        let count = (horos_pixList(at: Int(horos_curMovieIndex)) as NSArray?)?.count ?? 0
        let value = MovieExportPosition.fieldValue(image: horos_imageView?.curImage ?? 0, imageCount: count, flipped: horos_imageView?.flippedData ?? false)

        if ViewerSender.tag(sender) == 0 {
            horos_dcmFrom?.intValue = value
            horos_quicktimeFrom?.intValue = value
        } else {
            horos_dcmTo?.intValue = value
            horos_quicktimeTo?.intValue = value
        }

        // Update the text fields.
        horos_dcmFrom?.performClick(self)
        horos_dcmTo?.performClick(self)
        horos_dcmInterval?.performClick(self)
        horos_quicktimeFrom?.performClick(self)
        horos_quicktimeTo?.performClick(self)
        horos_quicktimeInterval?.performClick(self)
    }
}
