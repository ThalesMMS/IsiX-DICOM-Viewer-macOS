/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork


import Cocoa

/// The 4D player of the VR window: one volume per time, the slider, the play
/// button and the times added after the window opened.
extension VRController {

    public override func movieFrames() -> Int { Int(maxMovieIndex) }

    public override func setMovieFrame(_ l: Int) {
        if maxMovieIndex < 1 { return }
        curMovieIndexStorage = Int16(truncatingIfNeeded: FourDSeriesGuard.wrappedIndex(l, count: Int(maxMovieIndex)))
        moviePosSlider?.intValue = Int32(curMovieIndexStorage)
        guard let volume = volumeData[Int(curMovieIndexStorage)] else { return }
        vrView?.movieChangeSource(UnsafeMutablePointer(mutating: volume.bytes.assumingMemoryBound(to: Float.self)), showWait: false)
        displayROIVolumes()
    }

    /// A volume of this window changed elsewhere: the view reads the current
    /// one again, unless the view itself sent the notification.
    @objc(updateVolumeData:)
    public final func updateVolumeData(_ note: Notification!) {
        if (note?.userInfo?["sender"] as AnyObject?) === vrView { return }
        for i in 0..<Int(maxMovieIndex) where (note?.object as AnyObject?) === pixLists[i] {
            guard let volume = volumeData[Int(curMovieIndexStorage)] else { continue }
            vrView?.movieChangeSource(UnsafeMutablePointer(mutating: volume.bytes.assumingMemoryBound(to: Float.self)))
        }
    }

    @IBAction @objc(movieRateSliderAction:)
    public final func movieRateSliderAction(_ sender: Any!) {
        movieTextSlide?.stringValue = String(format: NSLocalizedString("%0.0f im/s", comment: "im/s = images per second"),
                                             movieRateSlider?.floatValue ?? 0)
    }

    @IBAction @objc(moviePosSliderAction:)
    public final func moviePosSliderAction(_ sender: Any!) {
        setMovieFrame(Int(moviePosSlider?.intValue ?? 0))
    }

    @objc(performMovieAnimation:)
    public final func performMovieAnimation(_ sender: Any!) {
        let thisTime = Date.timeIntervalSinceReferenceDate
        if thisTime - lastMovieTime > 1.0 / Double(movieRateSlider?.floatValue ?? 0) {
            let next = FourDSeriesGuard.nextIndex(Int(curMovieIndexStorage), count: Int(maxMovieIndex))
            setMovieFrame(Int(Int16(truncatingIfNeeded: next)))
            lastMovieTime = thisTime
        }
    }

    @IBAction @objc(MoviePlayStop:)
    public final func moviePlayStop(_ sender: Any!) {
        if let timer = movieTimer {
            timer.invalidate()
            movieTimer = nil
            moviePlayStop?.title = "Play"
            movieTextSlide?.stringValue = String(format: NSLocalizedString("%0.0f im/s", comment: "im/s = images per second"),
                                                 movieRateSlider?.floatValue ?? 0)
        } else {
            let timer = Timer.scheduledTimer(timeInterval: 0, target: self, selector: #selector(performMovieAnimation(_:)),
                                             userInfo: nil, repeats: true)
            RunLoop.current.add(timer, forMode: .modalPanel)
            RunLoop.current.add(timer, forMode: .eventTracking)
            movieTimer = timer
            lastMovieTime = Date.timeIntervalSinceReferenceDate
            moviePlayStop?.title = "Stop"
        }
    }

    /// Another time of the series: refused, after an alert, beyond the
    /// player's capacity or when its slices or its geometry differ from the
    /// first time's.
    @objc(addMoviePixList::)
    public final func addMoviePixList(_ pix: NSMutableArray!, _ vData: NSData!) {
        if !FourDSeriesGuard.canStoreTime(at: Int(maxMovieIndex), capacity: Int(MAX4D)) {
            HorosAlertPanel.run(title: NSLocalizedString("Volume Rendering", comment: ""),
                                message: FourDSeriesGuard.capacityReason(at: Int(maxMovieIndex), capacity: Int(MAX4D)) ?? "",
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }
        if let slices = FourDSeriesGuard.reasonForInconsistentSlices(pix, atTime: Int(maxMovieIndex)) {
            HorosAlertPanel.run(title: NSLocalizedString("Volume Rendering", comment: ""), message: slices,
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }
        let reference = FourDSeriesGuard.geometry(fromPixList: pixLists[0], volume: volumeData[0])
        let candidate = FourDSeriesGuard.geometry(fromPixList: pix, volume: vData)
        if let reason = FourDSeriesGuard.reconstructionRefusal(comparing: candidate, to: reference, at: Int(maxMovieIndex)) {
            HorosAlertPanel.run(title: NSLocalizedString("Volume Rendering", comment: ""), message: reason,
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }
        pixLists[Int(maxMovieIndex)] = pix
        volumeData[Int(maxMovieIndex)] = vData
        maxMovieIndex += 1

        moviePosSlider?.maxValue = Double(maxMovieIndex - 1)
        moviePosSlider?.numberOfTickMarks = Int(maxMovieIndex)
        movieRateSlider?.isEnabled = true
        moviePosSlider?.isEnabled = true
        moviePlayStop?.isEnabled = true

        computeMinMax()
        vrView?.recomputeValueFactorAfterRangeChange()

        roiVolumeLists[Int(maxMovieIndex) - 1] = NSMutableArray()
        computeROIVolumes()
    }
}
