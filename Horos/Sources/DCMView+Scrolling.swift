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

// The scroll wheel, the trackpad's gestures and the slider of DCMView are
// implemented in Swift: an extension of DCMView, with
// the same selectors. How far an event moves through the images, the movie or
// the slab, and when it goes on to the next series, are IsiXImaging's
// WheelSteps rules.

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
            let slabGesture = flags.contains(.option) && flags.intersection([.command, .shift]).isEmpty
            if !phase.intersection([.began, .mayBegin]).isEmpty {
                self.horos_consumeSlabScrollTail = false
                self.horos_slabScrollRemainder = 0
            }
            if self.horos_consumeSlabScrollTail && !slabGesture {
                // Releasing Option in the same gesture must not turn its remaining
                // finger or momentum events into slice, phase, zoom or blend input.
                if momentum != [] || phase != [] {
                    return
                }
                self.horos_consumeSlabScrollTail = false // A fresh discrete wheel event.
            }
            if slabGesture {
                // The momentum of a trackpad or Magic Mouse gesture keeps changing
                // the thickness while Option is held, as it keeps scrolling slices
                // without it.
                self.horos_consumeSlabScrollTail = theEvent.hasPreciseScrollingDeltas || phase != []
                if theEvent.timestamp - self.horos_slabScrollTimestamp > WheelSteps.slabRemainderLifetime {
                    self.horos_slabScrollRemainder = 0
                }
                self.horos_slabScrollTimestamp = theEvent.timestamp
                // The series' backing order has no bearing on slab thickness.
                var remainder = self.horos_slabScrollRemainder
                let steps = WheelSteps.slabSteps(deltaY: deltaY, sign: ScrollDirection.wheelSign(flippedData: false),
                                                 precise: theEvent.hasPreciseScrollingDeltas, remainder: &remainder)
                self.horos_slabScrollRemainder = remainder
                guard let steps else { return }
                if steps != 0 {
                    inputMessages(self.windowController())?.inputAdjustThickSlab(bySteps: steps)
                }
                return
            }
            self.horos_slabScrollRemainder = 0
        }

        var selectWindowScrollWheel = UserDefaults.standard.bool(forKey: "SelectWindowScrollWheel")

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

        if UserDefaults.standard.bool(forKey: "ZoomWithHorizonScroll") == false { deltaX = 0 }

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
                let change = WheelSteps.stackChange(reverseScrollWheel * deltaY / 2.5)
                (self.horos_curImage, inc) = WheelSteps.imageIndex(self.horos_curImage, adding: Double(self.curDCM?.stack ?? 0) * Double(change))
            } else {
                let change = WheelSteps.imageChange(reverseScrollWheel * deltaY / 2.5, comPACS: PluginManager.isComPACS())
                (self.horos_curImage, inc) = WheelSteps.imageIndex(self.horos_curImage,
                                                                   adding: Double(self.horos_imageRows) * Double(self.horos_imageColumns) * Double(change))
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

        if self.scrollThroughSeriesIfNecessary(Int32(self.horos_curImage)) {
        } else if dcmPixList.count > 3 && UserDefaults.standard.bool(forKey: "loopScrollWheel") {
            if self.horos_curImage < 0 { self.horos_curImage = dcmPixList.count - 1 }
            if inputBeyondLast(self.horos_curImage, dcmPixList.count) { self.horos_curImage = 0 }
        } else {
            if self.horos_curImage < 0 { self.horos_curImage = 0 }
            if inputBeyondLast(self.horos_curImage, dcmPixList.count) { self.horos_curImage = dcmPixList.count - 1 }
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

    /// Whether a modality of the study scrolls on into the next series.
    @objc(containsScrollThroughModality)
    public dynamic func containsScrollThroughModality() -> Bool {
        for m in (self.studyObj()?.modalities())?.components(separatedBy: "\\") ?? [] {
            if UserDefaults.standard.bool(forKey: "scrollThroughSeriesFor\(m)") {
                return true
            }
        }

        return false
    }

    /// Past the first or the last image, the previous or the next series of
    /// the study is loaded, if the study scrolls through its series; the
    /// index stays within the series. True when a series is loaded.
    @objc(scrollThroughSeriesIfNecessary:)
    public dynamic func scrollThroughSeriesIfNecessary(_ i: Int32) -> Bool {
        var switchSeries = false

        if self.is2DViewer() && UserDefaults.standard.bool(forKey: "scrollThroughSeries") && self.containsScrollThroughModality() {
            let count = self.horos_dcmPixList?.count ?? 0
            var imIndex = Int(self.horos_curImage)

            if self.horos_flippedData {
                imIndex = count - 1 - imIndex
            }

            if imIndex < 0 || imIndex >= count {
                let seriesObj = self.seriesObj()
                let seriesArray = BrowserController.currentBrowser()?.childrenArray((seriesObj as NSObject?)?.value(forKey: "study")) as NSArray?
                let index = seriesArray.map { $0.index(of: seriesObj as Any) }
                let windowController = self.windowController() as AnyObject

                switch WheelSteps.seriesStep(imageIndex: imIndex, imageCount: count,
                                             seriesIndex: index == NSNotFound ? nil : index, seriesCount: seriesArray?.count ?? 0) {
                case .previous?:
                    NSObject.cancelPreviousPerformRequests(withTarget: windowController, selector: NSSelectorFromString("loadSeriesDown"), object: nil)
                    windowController.perform(NSSelectorFromString("loadSeriesDown"), with: nil, afterDelay: 0.01)
                    switchSeries = true
                case .next?:
                    NSObject.cancelPreviousPerformRequests(withTarget: windowController, selector: NSSelectorFromString("loadSeriesUp"), object: nil)
                    windowController.perform(NSSelectorFromString("loadSeriesUp"), with: nil, afterDelay: 0.01)
                    switchSeries = true
                case nil:
                    break
                }
            }

            if self.horos_curImage < 0 { self.horos_curImage = 0 }
            if inputBeyondLast(self.horos_curImage, count) { self.horos_curImage = count - 1 }
        }

        return switchSeries
    }

    // MARK: - Slider

    /// The viewer's slider moved: its value is the image, from the end in a
    /// series shown in reverse order.
    @objc(sliderAction:)
    public dynamic func sliderAction(_ sender: Any!) {
        let x = Int(self.horos_curImage) // x = curImage before sliderAction
        let value = Int(inputMessages(sender)?.inputIntValue() ?? 0)

        if self.horos_flippedData {
            self.horos_curImage = (self.horos_dcmPixList?.count ?? 0) - 1 - value
        } else {
            self.horos_curImage = value
        }

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

            if anEvent.deltaX < -0.5 {
                v?.inputLoadSeriesUp()
            }

            if anEvent.deltaX > 0.5 {
                v?.inputLoadSeriesDown()
            }

            if anEvent.deltaY < -0.5 {
                v?.inputLoadSeriesUp()
            }

            if anEvent.deltaY > 0.5 {
                v?.inputLoadSeriesDown()
            }
        }
    }
}
