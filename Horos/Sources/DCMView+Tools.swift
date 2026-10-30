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

// The tools of DCMView and their cursors are implemented in Swift: an
// extension of DCMView, with the same selectors. The
// setters of the currentTool and currentToolRight properties and the accessors
// of currentToolMiddle, in DCMView.swift, call the methods below. Which tool an event uses and which cursor a tool
// shows are IsiXImaging's ViewInput rules.

extension DCMView {

    // MARK: - Tools

    /// What -setCurrentTool: does: the ROIs being edited stop, the ones
    /// selected are released unless the new or the former tool works on ROIs,
    /// and a double-click with the zoom or rotate tool resets the zoom or
    /// turns the image.
    @objc(horosSetCurrentTool:)
    public dynamic func horosSetCurrentTool(_ i: ToolMode) {
        if i != self.horos_currentTool { self.cancelLengthPlacement() }
        var keepROITool = (i == .tROISelector || i == .tRepulsor || self.horos_currentTool == .tROISelector || self.horos_currentTool == .tRepulsor)

        keepROITool = keepROITool || self.roiTool(self.horos_currentTool) || self.roiTool(i)
        self.horos_currentTool = i

        if self.is2DViewer() {
            UserDefaults.standard.set(Int(self.horos_currentTool.rawValue), forKey: "DEFAULTLEFTTOOL")
        }

        self.stopROIEditingForce(true)

        self.horos_mesureA = .zero
        self.horos_mesureB = .zero
        self.horos_roiRect = .zero

        if keepROITool == false {
            // Unselect previous ROIs
            for case let r as ROI in (self.horos_curRoiList ?? NSMutableArray()) { r.roImode = Int(ROI_sleep) }
        }

        let event = NSApplication.shared.currentEvent

        var clickCount = 1
        if let event, event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .leftMouseUp || event.type == .rightMouseUp {
            clickCount = event.clickCount
        }

        switch self.horos_currentTool {
        case .tPlain:
            if self.is2DViewer() == true {
                inputMessages(self.windowController())?.inputBrushTool(self)
            }

        case .tZoom:
            if event?.type != .keyDown {
                if clickCount == 2 {
                    self.setOriginX(0, y: 0)
                    self.rotation = 0.0
                    self.scaleToFit()
                }

                if clickCount == 3 {
                    self.setOriginX(0, y: 0)
                    self.rotation = 0.0
                    self.scaleValue = 1.0
                }
            }

        case .tRotate:
            if event?.type != .keyDown {
                if clickCount == 2 && DCMView.horos_static_gClickCountSet == false && self.horos_isKeyView == true && self.window?.isKeyWindow == true {
                    DCMView.horos_static_gClickCountSet = true

                    self.rotation = ViewInput.rotationAfterDoubleClick(self.rotation, modifiers: inputModifiers(event))

                    if self.is2DViewer() == true {
                        inputMessages(self.windowController())?.inputPropagateSettings()
                    }
                }
            }

        default: break
        }

        self.setCursorForView(self.horos_currentTool)
        self.checkCursor()
        self.needsDisplay = true
    }

    /// What -setRightTool: does; a 2D viewer keeps it for the next ones.
    @objc(horosSetRightTool:)
    public dynamic func horosSetRightTool(_ i: ToolMode) {
        self.horos_currentToolRight = i

        if self.is2DViewer() {
            UserDefaults.standard.set(Int(self.horos_currentToolRight.rawValue), forKey: "DEFAULTRIGHTTOOL")
        }
    }

    /// The middle button's tool is the preference itself rather than a copy in
    /// each view: 2D, MPR and CPR views all use the tool chosen in a 2D
    /// viewer's toolbar, those already open included.
    @objc(horosCurrentToolMiddle)
    public dynamic func horosCurrentToolMiddle() -> ToolMode {
        return ToolMode(rawValue: Int16(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "DEFAULTMIDDLETOOL"))) ?? .tWL
    }

    @objc(horosSetMiddleTool:)
    public dynamic func horosSetMiddleTool(_ i: ToolMode) {
        UserDefaults.standard.set(Int(i.rawValue), forKey: "DEFAULTMIDDLETOOL")
    }

    @objc(gClickCountSetReset)
    public dynamic func gClickCountSetReset() {
        DCMView.horos_static_gClickCountSet = false
    }

    // checks to see if tool is a valid ID for ROIs
    // A better name might be  - (BOOL)isToolforROIs:(long)tool;
    @objc(roiTool:)
    public dynamic func roiTool(_ tool: ToolMode) -> Bool {
        // The list used to live here as a switch with a silent default, so a tool
        // mode added to ToolMode fell through to NO without anyone deciding. The
        // rule now is the opposite: a mode that does not apply refused for a stated
        // reason. HorosToolModeCapability carries one row per mode, with that
        // reason, and a test compares it against the enum in DCMView.h.
        //
        // tRepulsor and tROISelector are deliberately not here: they work on ROIs
        // without drawing one, and each caller of this method names them.
        return ToolModeCapability.drawsROIs(toolMode: Int(tool.rawValue))
    }

    /// The tool an event works with: ViewInput's rule, with the view's tools.
    @objc(getTool:)
    public dynamic func getTool(_ event: NSEvent!) -> ToolMode {
        let button: ViewInput.Button
        switch event?.type {
        case .rightMouseDown?, .rightMouseDragged?: button = .right
        case .otherMouseDown?, .otherMouseDragged?: button = .other(buttonNumber: event.buttonNumber)
        default: button = .left
        }
        // The middle tool is read only when the middle button is the one.
        let middle: Int16
        if case .other(let number) = button, number == 2 { middle = self.currentToolMiddle.rawValue } else { middle = ViewInput.Tool.translate }
        let tool = ViewInput.tool(button: button, left: self.horos_currentTool.rawValue, right: self.horos_currentToolRight.rawValue,
                                  middle: middle, modifiers: inputModifiers(event),
                                  leftDrawsROIs: self.roiTool(self.horos_currentTool), hasBlending: self.blending != nil)
        return ToolMode(rawValue: tool) ?? .tWL
    }

    // MARK: - Cursors

    @objc(setCursorForView:)
    public dynamic func setCursorForView(_ tool: ToolMode) {
        let c: NSCursor
        switch ViewInput.cursor(for: tool.rawValue, drawsROIs: self.roiTool(tool)) {
        case .cross: c = NSCursor.crossCursor()
        case .openHand: c = NSCursor.openHand
        case .rotate: c = NSCursor.rotateCursor()
        case .zoom: c = NSCursor.zoomCursor()
        case .contrast: c = NSCursor.contrastCursor()
        case .stack: c = NSCursor.stackCursor()
        case .iBeam: c = NSCursor.iBeam
        case .crosshair: c = NSCursor.crosshair
        case .rotate3DCamera: c = NSCursor.rotate3DCameraCursor()
        case .arrow: c = NSCursor.arrow
        }

        if c !== self.horos_cursor {
            self.horos_cursor = c
        }
    }

    @objc(checkCursor)
    public dynamic func checkCursor() {
        if self.horos_cursorSet == true && self.window?.isKeyWindow == true {
            self.horos_cursor?.set()
        }
    }

    // MARK: - Plugins

    /// Allows plugins to override mouse click actions: a right click, or a
    /// left click with Control, is posted as a notification instead.
    @objc(setPluginOverridesMouse:)
    public class func setPluginOverridesMouse(_ override: Bool) {
        DCMView.horos_static_pluginOverridesMouse = override
    }

    /// Whether a plugin handled the event: the plugins of version 1 that take
    /// the event's kind first, then every plugin that answers
    /// -handleEvent:forViewer:; any that handles it counts.
    @objc(eventToPlugins:)
    public dynamic func event(toPlugins event: NSEvent!) -> Bool {
        var used = false
        if let event, IsiXPluginHost.shared.takesViewerInput(event, in: self) { used = true }

        guard let plugins = PluginManager.plugins() else { return false }
        // The keys are enumerated as the dictionary gives them, without the
        // Swift array allKeys would be bridged to at every mouse event.
        let keys = plugins.keyEnumerator()
        while let key = keys.nextObject() {
            let plugin = plugins.object(forKey: key) as AnyObject?
            if plugin?.responds(to: #selector(InputPluginMessages.handleEvent(_:forViewer:))) == true {
                if unsafeBitCast(plugin, to: InputPluginMessages.self).handleEvent(event, forViewer: self.windowController() as AnyObject?) {
                    used = true
                }
            }
        }

        return used
    }
}

/// The plugins' event handler, a selector some plugins answer.
@objc private protocol InputPluginMessages {
    @objc(handleEvent:forViewer:) func handleEvent(_ event: NSEvent?, forViewer viewer: AnyObject?) -> Bool
}

/// The modifier flags of an event, as ViewInput reads them; none without one.
@inline(__always)
func inputModifiers(_ event: NSEvent?) -> ViewInput.Modifiers {
    return ViewInput.Modifiers(rawValue: event?.modifierFlags.rawValue ?? 0)
}

/// The messages of the former Objective-C that go to an id (the window
/// controller, a ROI window, the thick slab controller). The protocol is not
/// checked: an object that does not answer raises as the runtime raised, and a
/// message to nil answers nil, NO or 0.
@objc protocol DCMViewInputMessages {
    @objc(brushTool:) func inputBrushTool(_ sender: AnyObject?)
    @objc(propagateSettings) func inputPropagateSettings()
    @objc(setKeyImage:) func inputSetKeyImage(_ sender: AnyObject?)
    @objc(PlayStop:) func inputPlayStop(_ sender: AnyObject?)
    @objc(findPlayStopButton) func inputFindPlayStopButton() -> AnyObject?
    @objc(FullScreenON) func inputFullScreenON() -> Bool
    @objc(offFullScreen) func inputOffFullScreen()
    @objc(maxMovieIndex) func inputMaxMovieIndex() -> Int16
    @objc(curMovieIndex) func inputCurMovieIndex() -> Int16
    @objc(setMovieIndex:) func inputSetMovieIndex(_ i: Int16)
    @objc(adjustSlider) func inputAdjustSlider()
    @objc(adjustKeyImage) func inputAdjustKeyImage()
    @objc(showCurrentThumbnail:) func inputShowCurrentThumbnail(_ sender: AnyObject?)
    @objc(windowWillClose) func inputWindowWillClose() -> Bool
    @objc(thickSlabController) func inputThickSlabController() -> AnyObject?
    @objc(setLowQuality:) func inputSetLowQuality(_ q: Bool)
    @objc(autoHideMatrix) func inputAutoHideMatrix()
    @objc(addToUndoQueue:) func inputAddToUndoQueue(_ what: NSString?)
    @objc(removeLastItemFromUndoQueue) func inputRemoveLastItemFromUndoQueue()
    @objc(setMode:toROIGroupWithID:) func inputSetMode(_ mode: Int, toROIGroupWithID groupID: TimeInterval)
    @objc(bringToFrontROI:) func inputBringToFrontROI(_ roi: ROI?)
    @objc(isPostprocessed) func inputIsPostprocessed() -> Bool
    @objc(loadSeriesUp) func inputLoadSeriesUp()
    @objc(loadSeriesDown) func inputLoadSeriesDown()
    @objc(adjustThickSlabBySteps:) func inputAdjustThickSlab(bySteps steps: Int)
    @objc(windowDidBecomeMain:) func inputWindowDidBecomeMain(_ note: NSNotification?)
    @objc(computeContextualMenuForROI:) func inputComputeContextualMenu(for roi: ROI?)
    @objc(computeContextualMenu) func inputComputeContextualMenu()
    @objc(addVolumeLengthROI:) func inputAddVolumeLengthROI(_ roi: HorosVolumeLengthROI?)
    @objc(setROI::) func inputSetROI(_ roi: ROI?, _ viewer: AnyObject?)
    @objc(intValue) func inputIntValue() -> Int32
    @objc(boolValue) func inputBoolValue() -> Bool
}

/// The object, as the messages it is sent; nil stays nil.
@inline(__always)
func inputMessages(_ object: Any?) -> DCMViewInputMessages? {
    return unsafeBitCast(object as AnyObject?, to: DCMViewInputMessages?.self)
}

/// [[NSNotificationCenter defaultCenter] postNotificationName:object:userInfo:]
/// with the NSDictionary itself: the Swift overlay takes a [AnyHashable: Any],
/// which would copy it, and the observers of OsirixMouseDownNotification
/// answer in the dictionary they are given.
private typealias InputPostIMP = @convention(c) (AnyObject, Selector, NSString, AnyObject?, NSDictionary?) -> Void

func inputPost(_ name: NSNotification.Name, object: Any?, userInfo: NSDictionary? = nil) {
    let center = NotificationCenter.default
    let selector = #selector(NotificationCenter.post(name:object:userInfo:))
    let imp: IMP = center.method(for: selector)
    unsafeBitCast(imp, to: InputPostIMP.self)(center, selector, name.rawValue as NSString, object as AnyObject?, userInfo)
}

/// An index compared with a count as the Objective-C compared a short with
/// an NSUInteger: as unsigned, so a negative index is past the end.
@inline(__always)
func inputBeyondLast(_ index: Int, _ count: Int) -> Bool {
    return UInt(bitPattern: index) >= UInt(bitPattern: count)
}

/// The Objective-C exception a HorosObjCException.perform caught, logged as
/// N2LogExceptionWithStackTrace did.
func inputLogException(_ error: Error, _ function: String) {
    if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
        _N2LogExceptionImpl(e, true, function)
    }
}

/// Runs `body` as an Objective-C @try did, and answers the exception it
/// raised, or nil. For the handlers that run at every mouse event: the call
/// goes through HorosObjCPerformFunction and its context, without the block
/// and the NSError HorosObjCException.perform allocates each time.
func inputCatch(_ body: () -> Void) -> NSException? {
    return withoutActuallyEscaping(body) { escapable in
        var call = escapable
        return withUnsafeMutablePointer(to: &call) { pointer in
            HorosObjCPerformFunction({ context in
                context!.assumingMemoryBound(to: (() -> Void).self).pointee()
            }, pointer)
        }
    }
}

/// An exception inputCatch(_:) caught, logged as N2LogExceptionWithStackTrace did.
func inputLogException(_ exception: NSException?, _ function: String) {
    if let exception {
        _N2LogExceptionImpl(exception, true, function)
    }
}

extension DCMView {
    /// The image's cell selected in the view's matrix, as the series browser shows it.
    func inputSelectMatrixCell() {
        guard let matrix = self.horos_matrix else { return }
        var rows = 0, cols = 0
        matrix.getNumberOfRows(&rows, columns: &cols)
        if cols < 1 { cols = 1 }
        matrix.selectCell(atRow: Int(self.horos_curImage) / cols, column: Int(self.horos_curImage) % cols)
    }

    /// The image index after the keyboard or the wheel moved it: shown with
    /// -setIndex: or -setIndexWithReset::, the matrix following.
    func inputShowCurrentImage() {
        if self.horos_listType == CChar(UInt8(ascii: "i")) { self.setIndex(self.horos_curImage) }
        else { self.setIndexWithReset(self.horos_curImage, true) }

        self.inputSelectMatrixCell()
    }
}
