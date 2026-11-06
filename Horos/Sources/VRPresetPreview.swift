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

/// A thumbnail of the 3D presets panel: the main view's volume through a
/// preset's tables, shading and background, rendered by a ray caster of its
/// own over the main view's input. An empty slot shows the black background
/// and takes no mouse. The Objective-C name and selectors are those of the
/// former class; its VTK pipeline is built by VRView
/// (VRView+Subclasses.swift), with the main view's.
@objc(VRPresetPreview)
public final class VRPresetPreview: VRView {
    // The former instance variables start as Objective-C's did, NO and 0,
    // while VRView initializes, and take their values after.
    private var isEmptyPreview = false
    private var isSelectedPreview = false
    @IBOutlet private weak var selectionView: SelectionView?
    @IBOutlet private weak var presetController: VRController?
    private var presetIndex: Int32 = 0
    /// While it draws, the view does not ask to be drawn again.
    private var noNeedsDisplay = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        lowResLODFactor = 1.0
        isEmptyPreview = true
        presetIndex = -1
        horosSetLODValue(1.0)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    isolated deinit {
        NSLog("VRPresetPreview dealloc")
        // The 8-bit volume is the main view's, which frees it.
        horosForgetSharedData8()
    }

    /// The factor into VTK's 16 bits from the presets controller's range: the
    /// SUV range on 4095 values; a range wider than 4095 or narrower than 50
    /// on 4095 values; the values themselves otherwise, offset to start at 0.
    public override func computeValueFactor() {
        guard let first = horosFirstPix, let controller = presetController else { return }
        let maximum = controller.maximumValue(), minimum = controller.minimumValue()
        if first.suvConverted {
            horosSetValueFactor(Float(4095.0 / Double(maximum)), offset: 0)
        } else if maximum - minimum > 4095 || maximum - minimum < 50 {
            horosSetValueFactor(Float(4095.0 / Double(maximum - minimum)), offset: -minimum)
        } else {
            horosSetValueFactor(1, offset: -minimum)
        }
    }

    public override func setPixSource(_ pix: NSMutableArray!, _ volumeData: UnsafeMutablePointer<Float>!) -> Int16 {
        return horosBuildPresetPreviewPipeline(withPix: pix, volume: volumeData)
    }

    /// The engine changes without the wait window.
    public override var engine: Int32 {
        get { super.engine }
        set {
            horosSetEngineValue(newValue)
            setEngine(Int(newValue), showWait: false)
        }
    }

    public override func setMapper(_ mapper: UnsafeMutableRawPointer!) {
        horosAdoptPreviewMapper(mapper)
    }

    @objc(setIsEmpty:)
    public func setIsEmpty(_ empty: Bool) {
        guard isEmptyPreview != empty else { return }
        isEmptyPreview = empty
        horosShowVolume(!empty)
        needsDisplay = true
    }

    @objc(isEmpty)
    public func isEmpty() -> Bool {
        isEmptyPreview
    }

    public override func draw(_ dirtyRect: NSRect) {
        noNeedsDisplay = true
        // An empty preview is the black background with nothing on it.
        if isEmptyPreview {
            changeColor(with: NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1))
        }
        horosApplyLODToMapper()
        noNeedsDisplay = false
        super.draw(dirtyRect)
    }

    public override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if noNeedsDisplay { return }
            super.needsDisplay = newValue
        }
    }

    // Expose the rendered thumbnail as a named, selectable option.
    public override func isAccessibilityElement() -> Bool { !isEmptyPreview }
    public override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    public override func accessibilityValue() -> Any? { NSNumber(value: isSelectedPreview) }
    public override func accessibilityPerformPress() -> Bool {
        if isEmptyPreview { return false }
        setSelected()
        return true
    }

    @objc(setSelectedState:)
    public func setSelectedState(_ selected: Bool) {
        guard isSelectedPreview != selected else { return }
        isSelectedPreview = selected
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    @objc(setSelected)
    public func setSelected() {
        if isEmptyPreview { return }
        // hides the old selection frame location
        selectionView?.isHidden = true
        selectionView?.display()
        // set the selection frame around self
        selectionView?.frame = NSRect(x: frame.origin.x - 2, y: frame.origin.y - 2,
                                      width: frame.size.width + 4, height: frame.size.height + 4)
        selectionView?.isHidden = false
        presetController?.setSelectedPresetPreview(self)
        selectionView?.display()
    }

    // The frame is one view moved from preview to preview, so nothing hides it when
    // the page stops having anything to select. Then it rings an empty square and
    // Apply looks like it would do something.
    @objc(hideSelectionFrame)
    public func hideSelectionFrame() {
        selectionView?.isHidden = true
        selectionView?.display()
        setSelectedState(false)
    }

    public override func mouseDown(with event: NSEvent) {
        if isEmptyPreview { return }
        if event.clickCount >= 2 {
            setSelected()
            presetController?.load3DSettings()
        } else {
            super.mouseDown(with: event)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if isEmptyPreview { return }
        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if isEmptyPreview { return }
        setSelected()
        super.mouseUp(with: event)
        presetController?.setVtkCameraForAllPresetPreview(vtkCamera())
    }

    public override func rightMouseUp(with event: NSEvent) {
        if isEmptyPreview { return }
        setSelected()
        super.rightMouseUp(with: event)
        presetController?.setVtkCameraForAllPresetPreview(vtkCamera())
    }

    public override func setCursorFor(_ tool: ToolMode) {
        if isEmptyPreview {
            horosSetArrowCursor()
        } else {
            super.setCursorFor(tool)
        }
    }

    @objc(setIndex:)
    public func setIndex(_ index: Int32) {
        presetIndex = index
    }

    @objc(index)
    public func index() -> Int32 {
        presetIndex
    }

    public override func setVtkCamera(_ aVtkCamera: UnsafeMutableRawPointer!) {
        if isEmptyPreview { return }
        super.setVtkCamera(aVtkCamera)
    }

    public override func setIChatFrame(_ set: Bool) {
    }

    public override func becomeFirstResponder() -> Bool {
        NotificationCenter.default.post(name: NSNotification.Name.OsirixVRViewDidBecomeFirstResponder, object: self)
        return true
    }
}
