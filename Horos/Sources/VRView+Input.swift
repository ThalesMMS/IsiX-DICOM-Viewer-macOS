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

import AppKit
import Carbon
import UniformTypeIdentifiers

// The cursors, the drag of the view's picture and the hot keys of VRView: a
// Swift extension of the class, with the same selectors. The dragging-source
// masks (-horosSourceOperationMask, the session's and the legacy one) are in
// VRView.swift and VRView+CAPI.m. The @try of -startDrag: is HorosObjCException.perform, with the
// same log.

/// The pasteboard type that carries the modifier keys of the drag.
private let draggedModifierFlagsType = NSPasteboard.PasteboardType("com.opensource.osirix.eventmodifierflags")

/// `[object intValue]`, as the Objective-C sent it to an NSNumber or an NSString.
private func objcIntValue(_ object: Any?) -> Int32 {
    if let number = object as? NSNumber { return number.int32Value }
    if let string = object as? NSString { return string.intValue }
    return 0
}

extension VRView: NSPasteboardItemDataProvider {

    // MARK: - Cursors

    public override func mouseEntered(with theEvent: NSEvent) {
        if eventToPlugins(theEvent) { return }
        horos_cursorSet = true
    }

    public override func mouseExited(with theEvent: NSEvent) {
        if eventToPlugins(theEvent) { return }
        horos_cursorSet = false
    }

    public override func cursorUpdate(with theEvent: NSEvent) {
        if eventToPlugins(theEvent) { return }
        horos_cursorSet = true
        horos_cursor?.set()
    }

    @objc(checkCursor)
    func checkCursor() {
        if horos_cursorSet { horos_cursor?.set() }
    }

    @objc(setCursorForView:)
    dynamic func setCursorFor(_ tool: ToolMode) {
        let c: NSCursor?
        switch tool {
        case .tMesure, .tAngle, .t3Dpoint, .t3DCut, .tCross:
            c = NSCursor.crosshair
        case .t3DRotate:
            c = NSCursor.rotate3DCursor()
        case .tCamera3D:
            c = NSCursor.rotate3DCameraCursor()
        case .tTranslate:
            c = NSCursor.openHand
        case .tRotate:
            c = NSCursor.rotateCursor()
        case .tZoom:
            c = NSCursor.zoomCursor()
        case .tWL, .tWLBlended:
            c = NSCursor.contrastCursor()
        case .tNext:
            c = NSCursor.stackCursor()
        case .tText:
            c = NSCursor.iBeam
        case .tBonesRemoval:
            c = NSCursor.bonesRemovalCursor()
        default:
            c = NSCursor.arrow
        }

        if c !== horos_cursor {
            horos_cursor = c
        }
    }

    // MARK: - Dragging the picture

    @objc(startDrag:)
    func startDrag(_ theTimer: Timer!) {
        let exception = HorosObjCException.caught {
            self.horos_dragInProgress = true
            guard let event = theTimer?.userInfo as? NSEvent else { return }

            let image = self.nsimage(event.modifierFlags.contains(.shift))

            let originalSize = image?.size ?? .zero
            let ratio = Float(originalSize.width) / Float(originalSize.height)
            let thumbnail = NSImage(size: NSMakeSize(100, CGFloat(Float(100) / ratio)), flipped: false) { bounds in
                image?.draw(in: bounds, from: NSMakeRect(0, 0, originalSize.width, originalSize.height),
                            operation: .sourceOver, fraction: 1.0)
                return true
            }

            let pbi = NSPasteboardItem()
            pbi.setData(image?.tiffRepresentation ?? Data(), forType: .tiff)
            var mf = event.modifierFlags.rawValue
            pbi.setData(Data(bytes: &mf, count: MemoryLayout<UInt>.size), forType: draggedModifierFlagsType)
            pbi.setDataProvider(self, forTypes: [.string, NSPasteboard.PasteboardType(kPasteboardTypeFileURLPromise as String)])
            pbi.setString(UTType.image.identifier, forType: NSPasteboard.PasteboardType(kPasteboardTypeFilePromiseContent as String))

            let di = NSDraggingItem(pasteboardWriter: pbi)
            let p = self.convert(event.locationInWindow, from: nil)
            di.setDraggingFrame(NSMakeRect(p.x - thumbnail.size.width / 2, p.y - thumbnail.size.height / 2,
                                           thumbnail.size.width, thumbnail.size.height), contents: thumbnail)

            let session = self.beginDraggingSession(with: [di], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }
        if let exception {
            NSLog("Exception while dragging: %@", exception.description)
        }

        horos_dragInProgress = false
    }

    // AppKit asks for the promised file on the main thread, when the drop
    // happens: the requirement is nonisolated, and the body runs on the main
    // actor, which assumeIsolated checks.
    @objc(pasteboard:item:provideDataForType:)
    public nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        assumeMainActor((pasteboard, item, type)) { (pasteboard, item, type) in
            self.provideDraggedPicture(pasteboard, item: item, type: type)
        }
    }

    /// The JPEG file a drag promised, written where the Finder dropped it.
    private func provideDraggedPicture(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, type: NSPasteboard.PasteboardType) {
        guard type.rawValue == kPasteboardTypeFileURLPromise as String, let pasteboard else { return }
        var pboardRef: Pasteboard?
        PasteboardCreate(pasteboard.name.rawValue as CFString, &pboardRef)
        guard let pboard = pboardRef else { return }

        PasteboardSynchronize(pboard)

        var urlRef: CFURL?
        PasteboardCopyPasteLocation(pboard, &urlRef)

        guard let pasteLocation = urlRef else { return }
        let firstObject = horos_firstObject
        let series = firstObject?.imageObj()?.series
        var description = series?.name
        if (description as NSString?)?.length ?? 0 == 0 {
            description = series?.seriesDescription
        }

        // Study and series descriptions are free text from the DICOM data,
        // so they cannot become a path component unexamined.
        let name = DraggedImageFile.name(study: series?.study?.name, series: description)
        let url = DraggedImageFile.url(in: pasteLocation as URL, name: name, pathExtension: "jpg")

        var mf: UInt = 0
        if let flags = item.data(forType: draggedModifierFlagsType), flags.count == MemoryLayout<UInt>.size {
            mf = flags.withUnsafeBytes { $0.loadUnaligned(as: UInt.self) }
        }

        let image = nsimage(NSEvent.ModifierFlags(rawValue: mf).contains(.shift))

        let idata = image?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
            .representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: Float(0.9))])

        // Advertise the file only once it exists. Naming it regardless left
        // the destination holding a path to a file that was never written.
        if let url, let idata, !idata.isEmpty, (try? idata.write(to: url, options: .atomic)) != nil {
            item.setString(url.absoluteString, forType: type)
        } else {
            NSLog("**** dragged image could not be written for %@", name)
        }
    }

    @objc(deleteMouseDownTimer)
    func deleteMouseDownTimer() {
        horos_mouseDownTimer?.invalidate()
        horos_mouseDownTimer = nil
        horos_dragInProgress = false
    }

    @objc(deleteRightMouseDownTimer)
    func deleteRightMouseDownTimer() {
        horos_rightMouseDownTimer?.invalidate()
        horos_rightMouseDownTimer = nil
    }

    // MARK: - Hot keys

    @objc(actionForHotKey:)
    func actionForHotKey(_ hotKey: String!) -> Bool {
        guard let hotKey, (hotKey as NSString).length > 0 else { return false }

        let wlwwDict = UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?
        let wwwlValues = ((wlwwDict?.allKeys as NSArray?)?
            .sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?) ?? NSArray()

        let opacityDict = UserDefaults.standard.dictionary(forKey: "OPACITY") as NSDictionary?
        let opacityValues = ((opacityDict?.allKeys as NSArray?)?
            .sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?) ?? NSArray()

        let lowercaseHotKey = hotKey.lowercased() as NSString
        guard let action = DCMView.hotKeyDictionary()?.object(forKey: lowercaseHotKey) else { return false }

        let key = unichar(truncatingIfNeeded: objcIntValue(action))
        let windowController = window?.windowController as? VRController
        NSLog("hot key: %d", Int32(key))

        switch UInt32(key) {
        case DefaultWWWLHotKeyAction.rawValue: // default WW/WL
            let wwwlMenuString = NSLocalizedString("Default WL & WW", comment: "")
            windowController?.applyWLWW(for: wwwlMenuString)
            NotificationCenter.default.post(name: .OsirixUpdateWLWWMenu, object: wwwlMenuString, userInfo: nil)

        case FullDynamicWWWLHotKeyAction.rawValue: // full dynamic WW/WL
            let wwwlMenuString = NSLocalizedString("Full dynamic", comment: "")
            windowController?.applyWLWW(for: wwwlMenuString)
            NotificationCenter.default.post(name: .OsirixUpdateWLWWMenu, object: wwwlMenuString, userInfo: nil)

        case Preset1WWWLHotKeyAction.rawValue...Preset9WWWLHotKeyAction.rawValue: // 1 - 9 will be presets WW/WL
            let index = Int(key) - Int(Preset1WWWLHotKeyAction.rawValue)
            if wwwlValues.count > index {
                let wwwlMenuString = wwwlValues.object(at: index) as? String
                windowController?.applyWLWW(for: wwwlMenuString)
                NotificationCenter.default.post(name: .OsirixUpdateWLWWMenu, object: wwwlMenuString, userInfo: nil)
            }

        case Preset1OpacityHotKeyAction.rawValue...Preset9OpacityHotKeyAction.rawValue: // 1 - 9 will be opacity presets
            if opacityValues.count >= Int(key) - Int(Preset1OpacityHotKeyAction.rawValue) {
                let index = Int(key) - Int(Preset1OpacityHotKeyAction.rawValue) - 1
                let opacityMenuString = index < 0 ? NSLocalizedString("Linear Table", comment: "")
                                                  : opacityValues.object(at: index) as? String
                windowController?.applyOpacityString(opacityMenuString)
                NotificationCenter.default.post(name: .OsirixUpdateOpacityMenu, object: opacityMenuString, userInfo: nil)
            }

        // Flip: there is no vertical or horizontal flip in VR.

        // mouse functions
        case WWWLToolHotKeyAction.rawValue, MoveHotKeyAction.rawValue, ZoomHotKeyAction.rawValue,
             RotateHotKeyAction.rawValue, ScrollHotKeyAction.rawValue, LengthHotKeyAction.rawValue,
             AngleHotKeyAction.rawValue, OvalHotKeyAction.rawValue, Rotate3DHotKeyAction.rawValue,
             Camera3DotKeyAction.rawValue, scissors3DHotKeyAction.rawValue, ThreeDPointHotKeyAction.rawValue,
             PlainToolHotKeyAction.rawValue, BoneRemovalHotKeyAction.rawValue:
            var tool = ViewerController.getToolEquivalent(toHotKey: Int32(key))
            if tool.rawValue >= 0 {
                if tool == .t2DPoint {
                    tool = .t3Dpoint
                }
                windowController?.setCurrentTool(tool)
            }

        default:
            return false
        }
        return true
    }
}
