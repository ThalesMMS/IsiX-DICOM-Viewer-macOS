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

// What the 2D viewer's window accepts when something is dropped on it: the
// image of another viewer (a fusion, with the sheet that asks its type), a
// plug-in's drag, a series of the database, or files (ROI files, ROIs of a
// series, pictures laid on the image as a layer ROI).

/// The viewer a drag of an image started from, not retained.
nonisolated(unsafe) fileprivate var draggedControllerStorage: Unmanaged<ViewerController>? = nil

/// The pasteboard types of a list of type names, as -availableTypeFromArray:
/// takes them. A [String] does not cast to [NSPasteboard.PasteboardType], so
/// each name is wrapped.
fileprivate func viewerPasteboardTypes(_ names: Any?) -> [NSPasteboard.PasteboardType] {
    ((names as? NSArray) ?? NSArray()).compactMap { ($0 as? String).map { NSPasteboard.PasteboardType($0) } }
}

/// A plug-in that performs its own drag on a viewer.
@objc fileprivate protocol ViewerPluginDragSource {
    @objc(performPluginDragOperation:destination:)
    func performPluginDragOperation(_ sender: NSDraggingInfo, destination: ViewerController) -> Bool
}

public extension ViewerController {

    /// The viewer an image is dragged from, for the plug-ins too.
    @objc(draggedController)
    class func draggedController() -> ViewerController! {
        return draggedControllerStorage?.takeUnretainedValue()
    }

    @objc(setDraggedController:)
    class func setDraggedController(_ controller: ViewerController!) {
        draggedControllerStorage = controller.map { Unmanaged.passUnretained($0) }
    }

    @objc(completeDragOperation:)
    func completeDragOperation(_ vc: ViewerController!) {
        horosLoadViewerPanels()

        // First reset all controls.
        for view in horos_blendingTypeWindow?.contentView?.subviews ?? [] {
            if let control = view as? NSControl {
                control.isEnabled = true
            }
        }

        let sameStudy = viewerSameString(studyInstanceUID(), vc?.studyInstanceUID())

        // Subtraction and multiplication combine images of one matrix. Within a
        // study they resample a series of another matrix onto this one's first.
        if (vc?.imageView()?.curDCM?.pwidth ?? 0) != (horos_imageView?.curDCM?.pwidth ?? 0) ||
           (vc?.imageView()?.curDCM?.pheight ?? 0) != (horos_imageView?.curDCM?.pheight ?? 0) {
            if sameStudy == false {
                blendingTypeMultiply?.isEnabled = false
                blendingTypeSubtract?.isEnabled = false
            }
            blendingTypeRGB?.isEnabled = false
        }

        if ((vc?.pixList() as NSArray?)?.object(at: 0) as? DCMPix)?.isRGB == true {
            blendingTypeRGB?.isEnabled = false
        }

        if sameStudy == false {
            blendingResample?.isEnabled = false
        }

        // Prepare the menu of the fusion plug-ins.
        let fusionPlugins = PluginManager.fusionPluginsMenu()
        var iz = 0
        while iz < (fusionPlugins?.numberOfItems ?? 0) {
            let item = fusionPlugins?.item(at: iz)
            item?.tag = -iz

            if item?.hasSubmenu == true {
                let subMenu = item?.submenu

                var xz = 0
                while xz < (subMenu?.numberOfItems ?? 0) {
                    subMenu?.item(at: xz)?.tag = -iz
                    subMenu?.item(at: xz)?.target = self
                    subMenu?.item(at: xz)?.action = #selector(ViewerController.endBlendingType(_:))
                    xz += 1
                }
            } else {
                item?.target = self
                item?.action = #selector(ViewerController.endBlendingType(_:))
            }
            iz += 1
        }
        blendingPlugins?.menu = fusionPlugins

        horos_blendedWindow = vc

        // What type of blending?
        if let sheet = horos_blendingTypeWindow {
            window?.beginSheet(sheet) { returnCode in
                self.blendingSheetDidEnd(self.horos_blendingTypeWindow, returnCode: Int32(truncatingIfNeeded: returnCode.rawValue), contextInfo: nil)
            }
        }

        draggedControllerStorage = nil
    }

    @objc(performDragOperation:)
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paste = sender.draggingPasteboard

        if paste.availableType(from: viewerPasteboardTypes(DCMView.pasteboardTypes())) != nil {
            let vi = sender.draggingSource as? NSView
            let controller = vi?.window?.windowController

            if (controller as AnyObject?)?.is2DViewer?() == true {
                if ((controller as AnyObject?)?.blendingController?() as NSObject?)?.isEqual(self) == true {
                    return false
                }
                if controller !== self, let viewer = controller as? ViewerController {
                    completeDragOperation(viewer)
                }
            }
        } else if paste.availableType(from: viewerPasteboardTypes(DCMView.pluginPasteboardTypes())) != nil {
            // The drag operation was performed from a plug-in.
            let source = sender.draggingSource

            let userInfo = NSMutableDictionary(capacity: 2)
            // "destination" should not be used anymore: the notification's
            // object is the same (was NULL).
            userInfo.setValue(self, forKey: "destination")
            // "dragOperation": "NSDraggingInfo" should be used.
            userInfo.setValue(sender, forKey: "dragOperation")
            userInfo.setValue(sender, forKey: "id<NSDraggingInfo>")
            NotificationCenter.default.post(name: .OsirixPerformDragOperation, object: self,
                                            userInfo: userInfo as? [AnyHashable: Any])

            if let source = source as? NSObject, source.responds(to: #selector(ViewerPluginDragSource.performPluginDragOperation(_:destination:))) {
                return unsafeBitCast(source, to: ViewerPluginDragSource.self).performPluginDragOperation(sender, destination: self)
            }
        } else if paste.availableType(from: viewerPasteboardTypes(BrowserController.databaseObjectXIDsPasteboardTypes())) != nil {
            // The database's rows come one pasteboard item each, their
            // identifiers as a property list the pasteboard hands back as an
            // array; the viewer's own series list writes them as data.
            // PasteboardObjectIdentifiers reads every item, in both forms.
            let xids = PasteboardObjectIdentifiers.identifiers(on: paste, types: (BrowserController.databaseObjectXIDsPasteboardTypes() as [String]?) ?? [])
            let items = NSMutableArray()
            for xid in xids {
                viewerArrayAdd(BrowserController.currentBrowser()?.database?.object(withID: NSManagedObject.uid(forXid: xid)), to: items)
            }

            if items.lastObject is DicomSeries {
                window?.makeKeyAndOrderFront(self)
                loadSelectedSeries(items.lastObject, rightClick: false)
            }
        } else {
            let desiredType = paste.availableType(from: [NSPasteboard.PasteboardType("NSFilenamesPboardType")])
            var carriedData: Data? = nil

            if let desiredType { carriedData = paste.data(forType: desiredType) }

            if carriedData == nil {
                return false
            } else {
                // A list of file names.
                let fileArray = paste.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? NSArray

                // Find a 2D viewer containing this specific file.
                let winList = NSApp.windows as NSArray
                var found = false

                var i = 0
                while i < winList.count && found == false {
                    let controller = (winList.object(at: i) as? NSWindow)?.windowController
                    if let viewer = controller as? ViewerController {
                        if found == false {
                            let dragged = draggedControllerStorage?.takeUnretainedValue()
                            if viewer === dragged && dragged !== self {
                                completeDragOperation(viewer)
                                found = true
                            } else if dragged === self {
                                // Myself: cancel a previous fusion.
                                activateBlending(nil)
                            }
                        }
                    }
                    i += 1
                }

                if found == false {
                    // Is it an image? A layer ROI.
                    var roiFiles: [String] = []
                    for case let file as NSString in fileArray ?? NSArray() {
                        let pathExtension = file.pathExtension.lowercased()
                        if pathExtension == "roi" {
                            roiFiles.append(file as String)
                        } else if pathExtension == "rois_series" || pathExtension == "json" {
                            roiLoad(fromSeries: file as String)
                        } else {
                            if let im = NSImage(contentsOfFile: file as String) {
                                let theNewROI = addLayerRoiToCurrentSlice(with: im, referenceFilePath: "none",
                                                                          layerPixelSpacingX: Float(horos_imageView?.curDCM?.pixelSpacingX ?? 0),
                                                                          layerPixelSpacingY: Float(horos_imageView?.curDCM?.pixelSpacingY ?? 0))

                                theNewROI?.name = file.lastPathComponent
                                theNewROI?.isLayerOpacityConstant = true
                                theNewROI?.canColorizeLayer = false
                                theNewROI?.canResizeLayer = true

                                let r = NSRect(origin: NSEvent.mouseLocation, size: .zero)
                                var eventLocation = window?.convertFromScreen(r).origin ?? .zero
                                eventLocation = horos_imageView?.convert(eventLocation, from: nil) ?? .zero
                                let imageLocation = horos_imageView?.convert(fromNSView2GL: eventLocation) ?? .zero

                                let centroid = theNewROI?.centroid() ?? .zero
                                let offset = NSPoint(x: imageLocation.x - centroid.x, y: imageLocation.y - centroid.y)

                                for case let p as MyPoint in (theNewROI?.points as NSArray?) ?? NSArray() {
                                    p.move(Float(offset.x), Float(offset.y))
                                }

                                select(theNewROI, deselectingOther: true)
                            }
                        }
                    }
                    if !roiFiles.isEmpty {
                        do {
                            try importROIFiles(roiFiles)
                        } catch {
                            presentROIImportError(forPath: roiFiles.last ?? "", error: error)
                        }
                    }
                }
            }
        }

        draggedControllerStorage = nil

        return true
    }

    @objc(draggingEntered:)
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if draggedControllerStorage == nil {
            draggedControllerStorage = Unmanaged.passUnretained(self)
            NSLog("catched")
        }

        // The generic operation, when the source offers it.
        if sender.draggingSourceOperationMask.contains(.generic) {
            return .generic
        } else {
            return []
        }
    }

    @objc(draggingExited:)
    func draggingExited(_ sender: NSDraggingInfo?) {
        NSLog("exited")
    }

    @objc(draggingUpdated:)
    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSourceOperationMask.contains(.generic) {
            return .generic
        } else {
            return []
        }
    }

    @objc(draggingEnded:)
    func draggingEnded(_ sender: NSDraggingInfo) {
        NSLog("draggingEnded")
    }

    @objc(prepareForDragOperation:)
    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        NSLog("prepareForDragOperation")
        return true
    }
}
