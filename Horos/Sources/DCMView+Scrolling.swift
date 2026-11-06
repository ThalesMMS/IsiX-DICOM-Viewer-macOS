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
import IsiXPreferences

// The scroll wheel, the trackpad's gestures and the slider of DCMView are
// implemented in Swift: an extension of DCMView, with
// the same selectors. Where the view is in its stack and how an event moves
// through the images, the slab and on to the next series is the view's
// StackNavigation (IsiXImaging); how far it moves the movie is WheelSteps';
// the preferences it follows are ScrollSettings (IsiXPreferences).

extension DCMView {

    // MARK: - Scroll wheel

    @objc(scrollWheel:)
    public override dynamic func scrollWheel(with theEvent: NSEvent) {
        let performanceTrace = self.horosPlanarPerformanceTrace()
        let inputSpan = performanceTrace?.beginScroll(theEvent, fromIndex: Int(self.horos_curImage)) ?? 0
        defer { performanceTrace?.endScroll(inputSpan, index: Int(self.horos_curImage)) }

        var deltaX = Float(theEvent.deltaX)
        var deltaY = Float(theEvent.deltaY)

        if !theEvent.hasPreciseScrollingDeltas {
            deltaX = Float(theEvent.scrollingDeltaX)
            deltaY = Float(theEvent.scrollingDeltaY)
        }

        if !deltaX.isFinite || !deltaY.isFinite { return }

        // macOS inverts these deltas when "natural" scrolling is on, while a
        // click-drag carries no such inversion. Undo it here so a system-wide
        // setting no longer decides whether the two gestures agree.
        let deviceSign = ScrollDirection.deviceOrientationSign(inverted: theEvent.isDirectionInvertedFromDevice)
        deltaX = Float(Double(deltaX) * deviceSign)
        deltaY = Float(Double(deltaY) * deviceSign)

        if NSEvent.pressedMouseButtons != 0 {
            return
        }

        if self.horos_curImage < 0 { return }
        if !self.drawing { return }
        if self.window?.isVisible != true { return }
        if self.is2DViewer() == true {
            if inputMessages(self.windowController())?.inputWindowWillClose() == true { return }
        }

        if self.is2DViewer() && self.horos_dcmPixList != nil && self.stringID != "previewDatabase" {
            let phase = theEvent.phase, momentum = theEvent.momentumPhase
            let flags = theEvent.modifierFlags
            // Releasing Option in the same gesture must not turn its remaining
            // finger or momentum events into slice, phase, zoom or blend input;
            // the momentum of a trackpad or Magic Mouse gesture keeps changing
            // the thickness while Option is held. The series' backing order has
            // no bearing on slab thickness.
            switch self.stackNavigation.slabScroll(deltaY: deltaY, sign: ScrollDirection.wheelSign(flippedData: false),
                                                   precise: theEvent.hasPreciseScrollingDeltas,
                                                   begins: !phase.intersection([.began, .mayBegin]).isEmpty,
                                                   inGesture: phase != [], inMomentum: momentum != [],
                                                   option: flags.contains(.option) && flags.intersection([.command, .shift]).isEmpty,
                                                   timestamp: theEvent.timestamp) {
            case .stack:
                break
            case .none:
                return
            case .steps(let steps):
                inputMessages(self.windowController())?.inputAdjustThickSlab(bySteps: steps)
                return
            }
        }

        let settings = ScrollSettings(preferences: PreferencesSource.process.preferences)
        var selectWindowScrollWheel = settings.selectsWindowUnderPointer

        if theEvent.modifierFlags.contains(.capsLock) { // Caps Lock
            selectWindowScrollWheel = !selectWindowScrollWheel
        }

        if selectWindowScrollWheel {
            if self.is2DViewer() {
                if ViewerController.isFrontMost2DViewer(self.window) == false {
                    self.window?.makeKeyAndOrderFront(self)
                    // If the application is in background, it will not automatically called.
                    inputMessages(self.windowController())?.inputWindowDidBecomeMain(NSNotification(name: NSWindow.didBecomeMainNotification, object: self.window))
                }
            } else if self.window?.isMainWindow != true {
                self.window?.makeKeyAndOrderFront(self)
            }
        }

        if settings.zoomsWithHorizontalScroll == false { deltaX = 0 }

        let reverseScrollWheel = Float(ScrollDirection.wheelSign(flippedData: self.horos_flippedData))

        guard let dcmPixList = self.horos_dcmPixList else { return }

        var inc = 0

        if self.stringID == "previewDatabase" {
            super.scrollWheel(with: theEvent)
            return
        }

        let modifiers = theEvent.modifierFlags
        if abs(Double(deltaY)) * 2.0 > abs(Double(deltaX)) {
            if modifiers.contains(.command) {
                if self.is2DViewer() && self.blending != nil {
                    let change = deltaY / -0.2

                    self.horos_blendingFactor += change
                    self.setBlendingFactor(self.horos_blendingFactor)
                }
            } else if modifiers.intersection([.option, .shift]) == [.option, .shift] {
                let wc = inputMessages(self.windowController())
                if self.is2DViewer() && (wc?.inputMaxMovieIndex() ?? 0) > 1 {
                    // 4D Direction scroll - Cardiac CT eg
                    let next = WheelSteps.movieIndex(current: Int(wc?.inputCurMovieIndex() ?? 0),
                                                     count: Int(wc?.inputMaxMovieIndex() ?? 0), delta: Double(deltaY))
                    wc?.inputSetMovieIndex(Int16(truncatingIfNeeded: next))
                }
            } else if modifiers.contains(.shift) {
                inc = self.stackNavigation.scrollStacks(reverseScrollWheel * deltaY / 2.5, stackSize: Int(self.curDCM?.stack ?? 0))
            } else {
                inc = self.stackNavigation.scrollImages(reverseScrollWheel * deltaY / 2.5, rows: Int(self.horos_imageRows),
                                                        columns: Int(self.horos_imageColumns), comPACS: PluginManager.isComPACS())
            }
        } else if abs(Double(deltaX)) > 0.7 {
            // Slice navigation must not cancel the pending series fit.
            // Only a gesture that actually changes the user's zoom wins
            // over the asynchronous opening result.
            self.cancelOpeningScaleToFitForInteraction()
            self.mouseMoved(with: theEvent) // Update some variables...

            let sScaleValue = self.horos_scaleValue

            deltaX = Float(PreciseMouse.appliedDelta(Double(deltaX)))
            self.scaleValue = sScaleValue + deltaX * self.horos_scaleValue / 10
            self.setOriginX(Float((Double(self.horos_origin.x) * Double(self.horos_scaleValue)) / Double(sScaleValue)),
                            y: Float((Double(self.horos_origin.y) * Double(self.horos_scaleValue)) / Double(sScaleValue)))

            if self.is2DViewer() == true {
                inputMessages(self.windowController())?.inputPropagateSettings()
            }

            self.needsDisplay = true
        }

        if !self.scrollThroughSeriesIfNecessary(Int32(self.horos_curImage)) {
            self.stackNavigation.endWheelStep(count: dcmPixList.count, loops: settings.loops)
        }

        self.inputShowCurrentImage()

        if self.is2DViewer() == true {
            inputMessages(self.windowController())?.inputAdjustSlider()
        }

        // SYNCRO
        self.sendSyncMessage(inc)

        if self.is2DViewer() == true {
            inputMessages(self.windowController())?.inputPropagateSettings()
        }

        if abs(Double(deltaY)) > 0 && abs(Double(deltaY)) * 2 > abs(Double(deltaX)) &&
            modifiers.intersection([.command, .option]).isEmpty {
            self.horosShowScrollPreview(atWindowPoint: theEvent.locationInWindow)
        }
    }

    // MARK: - Scrolling through the study

    /// Past the first or the last image, the previous or the next series of
    /// the study is loaded, if the study scrolls through its series; the
    /// index stays within the series. True when a series is loaded.
    public func scrollThroughSeriesIfNecessary(_ i: Int32) -> Bool {
        guard self.is2DViewer(),
              ScrollSettings.scrollsThroughSeries(modalities: self.studyObj()?.modalities(),
                                                  preferences: PreferencesSource.process.preferences) else { return false }
        let graph = PreferencesSource.process.processGraph
        // On a copy: the series is found through the image shown, which reads
        // the view's navigation while it would be changing.
        var navigation = self.stackNavigation
        let step = navigation.passEnd(count: self.horos_dcmPixList?.count ?? 0, flipped: self.horos_flippedData) {
            // The series of the study in the database window's order.
            let seriesObj = self.seriesObj()
            let seriesArray = graph.currentBrowser?.childrenArray(seriesObj?.study)
            let index = seriesArray?.firstIndex { ($0 as? NSObject)?.isEqual(seriesObj) == true }
            return (index, seriesArray?.count ?? 0)
        }
        self.stackNavigation = navigation
        let selector: String
        switch step {
        case .previous?: selector = "loadSeriesDown"
        case .next?: selector = "loadSeriesUp"
        case nil: return false
        }
        let windowController = self.windowController() as AnyObject
        NSObject.cancelPreviousPerformRequests(withTarget: windowController, selector: NSSelectorFromString(selector), object: nil)
        windowController.perform(NSSelectorFromString(selector), with: nil, afterDelay: 0.01)
        return true
    }

    // MARK: - Slider

    /// The viewer's slider moved: its value is the image, from the end in a
    /// series shown in reverse order.
    @objc(sliderAction:)
    public dynamic func sliderAction(_ sender: Any!) {
        let x = Int(self.horos_curImage) // x = curImage before sliderAction
        let value = Int(inputMessages(sender)?.inputIntValue() ?? 0)

        self.stackNavigation.slide(to: value, count: self.horos_dcmPixList?.count ?? 0, flipped: self.horos_flippedData)

        self.setIndex(self.horos_curImage)

        self.sendSyncMessage(self.horos_curImage - x)

        if self.is2DViewer() == true {
            inputMessages(self.windowController())?.inputPropagateSettings()
            inputMessages(self.windowController())?.inputAdjustKeyImage()
        }
    }

    // MARK: - Trackpad gestures

    @objc(magnifyWithEvent:)
    public override dynamic func magnify(with anEvent: NSEvent) {
        self.cancelOpeningScaleToFitForInteraction()
        self.scaleValue = Float(Double(self.horos_scaleValue) + Double(anEvent.deltaZ) / 60.0)

        // As the zoom tool and the scroll-wheel zoom do: the other viewers
        // followed a pinch only at the next click.
        if self.is2DViewer() == true {
            inputMessages(self.windowController())?.inputPropagateSettings()
        }

        self.needsDisplay = true
    }

    @objc(rotateWithEvent:)
    public override dynamic func rotate(with anEvent: NSEvent) {
        self.cancelOpeningScaleToFitForInteraction()
        // rotation - anEvent.rotation * 1.5, one multiply-subtract as the C was compiled.
        self.rotation = Float(Double(self.horos_rotation).addingProduct(-Double(anEvent.rotation), 1.5))

        if self.is2DViewer() == true {
            inputMessages(self.windowController())?.inputPropagateSettings()
        }

        self.needsDisplay = true
    }

    @objc(swipeWithEvent:)
    public override dynamic func swipe(with anEvent: NSEvent) {
        if self.is2DViewer() {
            let v = inputMessages(self.windowController())

            for step in StackNavigation.swipeSteps(deltaX: Double(anEvent.deltaX), deltaY: Double(anEvent.deltaY)) {
                switch step {
                case .next: v?.inputLoadSeriesUp()
                case .previous: v?.inputLoadSeriesDown()
                }
            }
        }
    }
}
