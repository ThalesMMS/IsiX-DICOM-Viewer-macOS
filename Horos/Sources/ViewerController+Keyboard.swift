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
// A time point is IsiXImaging's SliceNavigation; the next series is opened
// through ViewerStudyOpening, over the viewer's graph.

public extension ViewerController {

    @objc(keyDown:)
    override func keyDown(with event: NSEvent) {
        guard let characters = event.characters as NSString?, characters.length != 0 else { return }

        let c = characters.character(at: 0)

        let command = ViewerKeyCommand.of(character: c, command: event.modifierFlags.contains(.command))
        switch command {
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
        case .previousTimePoint, .nextTimePoint:
            // A 4D series goes round its time points; any other passes the key on.
            var frames = SliceNavigation(movieIndex: Int(horos_curMovieIndex), movieCount: Int(horos_maxMovieIndex))
            if frames.stepTimePoint(command == .previousTimePoint ? -1 : 1) {
                horos_curMovieIndex = Int16(truncatingIfNeeded: frames.movieIndex)

                setMovieIndex(horos_curMovieIndex)
            } else {
                super.keyDown(with: event)
            }
        case .previousSeries, .nextSeries:
            BrowserStudyOpening(processGraph: sessionGraph.processGraph)
                .openNextSeries(after: horos_fileList(at: 0)?.object(at: 0) as? NSManagedObject, direction: command == .previousSeries ? -1 : 1,
                                in: self, keyImagesOnly: horos_displayOnlyKeyImages)
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
        for case let v as DCMView in horos_seriesView?.imageViews() ?? [] {
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

            for case let v as DCMView in horos_seriesView?.imageViews() ?? [] {
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

        let count = horos_pixList(at: Int(horos_curMovieIndex))?.count ?? 0
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
