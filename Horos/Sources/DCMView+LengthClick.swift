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
import IsiXROI

// The Length measured with two clicks is implemented in Swift: an extension of
// DCMView, with the same selectors. A click with the
// Length tool, which hits no ROI, keeps its point pending, shown by a marker;
// the second click, on this image, measures as a drag between the two would,
// and on another slice of the series measures through the volume, in patient
// space. A drag from the first click is a drag, Escape cancels.
//
// The event, the endpoint and the marker are stored properties of the view,
// which own them. What each click does is IsiXROI's TwoClickLengthPlacement.

extension ROI {
    /// True when a click of the Length tool belongs to the established mouse-down
    /// path: over this ROI's label, which that path tests first and which selects
    /// the ROI where a click here would start a new Length, or over its outline or
    /// handles.
    @MainActor
    fileprivate func takesLengthClick(at point: NSPoint, in view: DCMView) -> Bool {
        self.curView = view
        let halfWidth = Float(Double(view.curDCM?.pwidth ?? 0) / 2.0)
        let halfHeight = Float(Double(view.curDCM?.pheight ?? 0) / 2.0)
        return self.click(inROI: point, halfWidth, halfHeight, view.horos_scaleValue, true) != 0 ||
            self.click(inROI: point, halfWidth, halfHeight, view.horos_scaleValue, false) != 0
    }
}

extension DCMView {

    // MARK: - Two-click Length

    @objc(cancelLengthPlacement)
    public dynamic func cancelLengthPlacement() {
        self.releaseLengthClickEvent()
        self.horos_lengthFirstEndpoint = nil
        self.horos_lengthPendingMarker = nil
        self.needsDisplay = true
    }

    /// Forgets the first click of a two-click Length.
    private func releaseLengthClickEvent() {
        self.horos_lengthClickEvent = nil
    }

    /// A click of the Length tool on no ROI is kept for its mouse-up, which
    /// places an endpoint; true when the click went no further.
    @objc(beginLengthClick:)
    public dynamic func beginLengthClick(_ event: NSEvent!) -> Bool {
        guard let event else { return false }
        if !ViewROIEditing.LengthPlacement.takesClick(replayingDrag: self.horos_replayingLengthDrag, is2DViewer: self.is2DViewer(),
                                                      isLeftMouseDown: event.type == .leftMouseDown, drawingROI: self.horos_drawingROI,
                                                      modifierFlags: event.modifierFlags.rawValue,
                                                      tool: { self.getTool(event) == .tMesure }) { return false }
        let point = self.convert(fromNSView2GL: self.convert(event.locationInWindow, from: nil))
        // Existing ROI/handle/label selection keeps the established mouse-down path.
        for case let roi as ROI in (self.horos_curRoiList ?? []) where roi.takesLengthClick(at: point, in: self) {
            return false
        }
        // A double-click that Hot Keys gives an action is that action, not a second
        // endpoint: the endpoint its first click left pending goes, and -mouseDown:
        // dispatches the hot key.
        if ViewROIEditing.LengthPlacement.doubleClickCancels(
            clickCount: event.clickCount,
            hasHotKeyAction: DCMView.horos_static__hotKeyDictionary?.object(forKey: "dbl-click" as NSString) != nil) {
            self.cancelLengthPlacement()
            return false
        }
        self.deleteMouseDownTimer()
        self.releaseLengthClickEvent()
        self.horos_lengthClickEvent = event
        self.horos_currentMouseEventTool = .tMesure
        return true
    }

    // The physical point under `point` of the image shown, with its series, frame
    // of reference and temporal index, for a Length measured in space.
    public func lengthEndpoint(at point: NSPoint) -> NSDictionary! {
        guard let patient = HorosVolumeLengthROI.patientPoint(point, pix: self.curDCM) else { return nil }
        let image = self.curDCM?.imageObj() as NSObject?
        guard let series = image?.value(forKeyPath: "series.seriesDICOMUID") as? NSString, series.length > 0 else { return nil }
        let reference = HorosVolumeLengthROI.reference(for: self.curDCM)
        guard let frameOfReference = self.curDCM?.frameofReferenceUID, let reference else {
            // The literal dictionary raised on a nil value.
            NSException(name: .invalidArgumentException,
                        reason: "*** -[__NSPlaceholderDictionary initWithObjects:forKeys:count:]: attempt to insert nil object",
                        userInfo: nil).raise()
            return nil
        }
        let temporalIndex = NSNumber(value: inputMessages(self.windowController())?.inputCurMovieIndex() ?? 0)
        let endpoint: [AnyHashable: Any] = ["point": patient, "series": series, "frameOfReference": frameOfReference,
                                            "temporalIndex": temporalIndex, "reference": reference]
        return endpoint as NSDictionary
    }

    // The Length that dragging from `first` to `last`, two points of the image
    // shown, makes. It is that drag, replayed without modifiers: the ROI, its
    // name, the undo step and the notifications are the drag's own.
    public func replayLengthDrag(from first: NSPoint, to last: NSPoint) {
        func event(_ type: NSEvent.EventType, _ imagePoint: NSPoint) -> NSEvent {
            return NSEvent.mouseEvent(with: type,
                                      location: self.convert(self.convert(fromGL2NSView: imagePoint), to: nil),
                                      modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: self.window?.windowNumber ?? 0,
                                      context: nil,
                                      eventNumber: 0,
                                      clickCount: 1,
                                      pressure: type == .leftMouseUp ? 0 : 1)!
        }
        self.cancelLengthPlacement()
        self.horos_replayingLengthDrag = true
        self.mouseDown(with: event(.leftMouseDown, first))
        self.mouseDragged(with: event(.leftMouseDragged, last))
        self.horos_replayingLengthDrag = false
        self.mouseUp(with: event(.leftMouseUp, last))
    }

    /// The mouse-up of a Length click: the first endpoint waits, shown by a
    /// marker; the second makes the Length.
    @objc(finishLengthClick:)
    public dynamic func finishLengthClick(_ event: NSEvent!) {
        self.releaseLengthClickEvent()
        if ViewROIEditing.LengthPlacement.waitsForThinSlices(stack: Int(self.curDCM?.stack ?? 0)) {
            NSSound.beep(); self.needsDisplay = true; return // Keep A until thin slices return.
        }
        let point = self.convert(fromNSView2GL: self.convert(event?.locationInWindow ?? .zero, from: nil))
        // The patient-space endpoint, nil without valid patient geometry; where it
        // was clicked on its image is kept in either case.
        let geometry = self.lengthEndpoint(at: point)
        var endpoint = (geometry as? [AnyHashable: Any]) ?? [:]
        endpoint["imagePoint"] = NSValue(point: point)
        endpoint["imageIndex"] = NSNumber(value: self.curImage)
        if geometry == nil {
            endpoint["reference"] = HorosVolumeLengthROI.reference(for: self.curDCM)
            endpoint["temporalIndex"] = NSNumber(value: inputMessages(self.windowController())?.inputCurMovieIndex() ?? 0)
        }
        let placement = ViewROIEditing.LengthPlacement(first: ViewROIEditing.lengthEndpoint(self.horos_lengthFirstEndpoint as? [AnyHashable: Any]))
        guard let clicked = ViewROIEditing.lengthEndpoint(endpoint) else { return }
        let step = placement.step(at: clicked) { first, second in
            let a = self.convert(fromGL2NSView: first), b = self.convert(fromGL2NSView: second)
            return Double(hypot(b.x - a.x, b.y - a.y))
        }
        switch step {
        case .samePlace:
            // The same place twice is no length: the first point stays.
            NSSound.beep(); return
        case .drag(let first, let second):
            // Both clicks on one image measure on it, as a drag between them does.
            self.replayLengthDrag(from: first, to: second); return
        case .needsGeometry:
            _ = HorosAlertPanel.runInformational(title: NSLocalizedString("Length", comment: ""),
                                                 message: NSLocalizedString("Measuring between slices requires valid patient geometry. Click and drag remains available for a 2D length.", comment: ""),
                                                 defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        case .first(_, let replacing):
            if replacing {
                self.cancelLengthPlacement()
            }
            self.horos_lengthFirstEndpoint = endpoint as NSDictionary
            let curDCM = self.curDCM
            let marker: ROI = ROI(type: .t2DPoint, Float(curDCM?.pixelSpacingX ?? 0), Float(curDCM?.pixelSpacingY ?? 0),
                                  DCMPix.originCorrected(accordingToOrientation: curDCM))
            self.horos_lengthPendingMarker = marker
        case .measure:
            let firstEndpoint = self.horos_lengthFirstEndpoint
            let payload: [AnyHashable: Any] = [
                "version": NSNumber(value: 1), "id": NSUUID().uuidString,
                "a": firstEndpoint?.object(forKey: "point") as Any, "b": endpoint["point"] as Any,
                "referenceA": firstEndpoint?.object(forKey: "reference") as Any, "referenceB": endpoint["reference"] as Any,
                "series": endpoint["series"] as Any, "frameOfReference": endpoint["frameOfReference"] as Any,
                "temporalIndex": endpoint["temporalIndex"] as Any,
            ]
            if !HorosVolumeLengthROI.validPayload(payload) { NSSound.beep(); return }
            let curDCM = self.curDCM
            let roi: HorosVolumeLengthROI = HorosVolumeLengthROI(type: .tMesure, Float(curDCM?.pixelSpacingX ?? 0), Float(curDCM?.pixelSpacingY ?? 0),
                                                                  DCMPix.originCorrected(accordingToOrientation: curDCM))
            roi.volumeLength = payload
            roi.name = NSLocalizedString("Length", comment: "")
            for case let other as ROI in (self.horos_curRoiList ?? []) { other.roImode = Int(ROI_sleep) }
            let wc = inputMessages(self.windowController())
            wc?.inputAddToUndoQueue("roi")
            wc?.inputAddVolumeLengthROI(roi)
            roi.roImode = Int(ROI_selected)
            self.cancelLengthPlacement()
        }
        self.needsDisplay = true
    }
}
