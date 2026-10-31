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
import IsiXImaging

// The reslice of the 2D viewer's series is implemented in Swift: a Swift
// extension of ViewerController, which stays Objective-C, with the same
// selector (-processReslice::). The new slices are made by
// ViewerSeriesReslice, their pixels gathered on the process's
// SeriesResliceWorker (IsiXImaging); this puts them in the viewer, or in a new
// one.

public extension ViewerController {

    /// The volume length measures of every time point (copies of them, for a
    /// new viewer) and the state that anchors them, which the resliced series
    /// gets back (-restoreVolumeLengthSnapshot:movieIndex:).
    private func volumeLengthSnapshots(copyingMeasures copies: Bool) -> [[AnyHashable: Any]] {
        (0..<max(Int(horos_maxMovieIndex), 0)).map { movie in
            let lengths = volumeLengthROIs(forMovieIndex: movie) ?? []
            let rois: [Any] = copies ? lengths.map { $0.copy() } : lengths
            let state = volumeLengthState(forMovieIndex: movie, create: true)?.copy() ?? [AnyHashable: Any]()
            return ["rois": rois, "state": state]
        }
    }

    /// Reslices every time point of the series along the rows (direction 0)
    /// or the columns of its slices, into this viewer or a new one, which
    /// keeps the volume length measures, the brushes (a new viewer; this one
    /// gets them from -setOrientation:), the colour and opacity tables.
    @objc(processReslice::)
    func processReslice(_ directionm: Int, _ newViewer: Bool) -> Bool {
        let previousCLUT = horos_curCLUTMenu
        let previousOpacity = horos_curOpacityMenu

        guard let frames = ViewerSeriesReslice.frames(of: self, direction: directionm,
                                                      worker: sessionGraph.processGraph.seriesResliceWorker) else { return false }

        let volumeSnapshots = volumeLengthSnapshots(copyingMeasures: newViewer)
        var reslicedViewer: ViewerController? = self
        // -setOrientation: carries the brushes of this viewer after its flips;
        // a new viewer gets them here.
        let brushes = newViewer ? BrushReslice.capture(from: self) : nil
        for (j, frame) in frames.enumerated() {
            let pixes = NSMutableArray(array: frame.pixes), files = NSMutableArray(array: frame.files)
            if j == 0 {
                if newViewer {
                    // CREATE A SERIES
                    let new2DViewer = self.newWindow(pixes, files, frame.volume)
                    // -newWindow::: hands over the +1 of the viewer's alloc, which the
                    // former code kept: the viewer releases itself when it closes.
                    if let new2DViewer { _ = Unmanaged.passRetained(new2DViewer) }
                    reslicedViewer = new2DViewer
                    new2DViewer?.setImageIndex(frame.pixes.count / 2)
                    new2DViewer?.window?.makeKeyAndOrderFront(self)
                } else {
                    changeImageData(pixes, files, frame.volume, false)
                }
            } else {
                reslicedViewer?.addMovieSerie(pixes, files, frame.volume)
            }
            reslicedViewer?.restoreVolumeLengthSnapshot(volumeSnapshots[j], movieIndex: j)
        }

        reslicedViewer?.setPostprocessed(true)
        if let reslicedViewer { brushes?.apply(to: reslicedViewer) }

        reslicedViewer?.computeInterval()
        reslicedViewer?.setWindowTitle(self)
        let middle = (frames.first?.pixes.count ?? 0) / 2
        reslicedViewer?.imageView()?.setIndex(middle)
        reslicedViewer?.imageView()?.sendSyncMessage(0)
        reslicedViewer?.adjustSlider()

        reslicedViewer?.applyCLUTString(previousCLUT)
        reslicedViewer?.applyOpacityString(previousOpacity)

        return true
    }
}
