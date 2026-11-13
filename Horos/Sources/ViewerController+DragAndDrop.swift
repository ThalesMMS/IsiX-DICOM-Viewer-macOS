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
// image of another viewer (a fusion, with the sheet that asks its type, which
// is ViewerFusion's), a plug-in's drag, a series of the database, or files:
// image files and PDFs dragged from another application, which become new
// series of the study (ViewerFileDropTarget), ROI files, ROIs of a series, and,
// with Option held, pictures laid on the image as a layer ROI.
// The viewer a drag of an image started from is the process's
// ViewerSyncState's.

/// The pasteboard types of a list of type names, as -availableTypeFromArray:
/// takes them. A [String] does not cast to [NSPasteboard.PasteboardType], so
/// each name is wrapped.
fileprivate func viewerPasteboardTypes(_ names: Any?) -> [NSPasteboard.PasteboardType] {
    (names as? [Any] ?? []).compactMap { ($0 as? String).map { NSPasteboard.PasteboardType($0) } }
}

/// The row a database identifier of a drag names (its URI without the
/// x-coredata scheme), read in the open main database whose store holds it:
/// `shown`, the browser's, first, else one of `open`. The rows dropped on a
/// viewer may come from a database the browser does not show: the series list
/// of a viewer of a shared study beside a browser on a local database, and the
/// reverse. The URI names its store, and a database whose coordinator has no
/// such store finds nothing. Nil when no open database holds the row.
func viewerDraggedRow(named xid: String, shown: DicomDatabase?, open: [Any]?) -> Any? {
    let uri = NSManagedObject.uid(forXid: xid)
    if let row = shown?.object(withID: uri) { return row }
    for case let database as DicomDatabase in open ?? [] where database !== shown && database.isMainDatabase() {
        if let row = database.object(withID: uri) { return row }
    }
    return nil
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
        return processGraph.viewerSync.draggedViewer
    }

    @objc(setDraggedController:)
    class func setDraggedController(_ controller: ViewerController!) {
        processGraph.viewerSync.draggedViewer = controller
    }

    /// Opens the sheet that asks what to do with `vc`, dropped on this viewer.
    @objc(completeDragOperation:)
    func completeDragOperation(_ vc: ViewerController!) {
        fusion.completeDragOperation(vc)
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
                    fusion.completeDragOperation(viewer)
                }
            }
        } else if paste.availableType(from: viewerPasteboardTypes(DCMView.pluginPasteboardTypes())) != nil {
            // The drag operation was performed from a plug-in.
            let source = sender.draggingSource

            // "destination" should not be used anymore: the notification's
            // object is the same (was NULL). "dragOperation": "NSDraggingInfo"
            // should be used.
            let userInfo: [AnyHashable: Any] = ["destination": self, "dragOperation": sender, "id<NSDraggingInfo>": sender]
            NotificationCenter.default.post(name: .OsirixPerformDragOperation, object: self, userInfo: userInfo)

            if let source = source as? NSObject, source.responds(to: #selector(ViewerPluginDragSource.performPluginDragOperation(_:destination:))) {
                return unsafeBitCast(source, to: ViewerPluginDragSource.self).performPluginDragOperation(sender, destination: self)
            }
        } else if paste.availableType(from: viewerPasteboardTypes(BrowserController.databaseObjectXIDsPasteboardTypes())) != nil {
            // The database's rows come one pasteboard item each, their
            // identifiers as a property list the pasteboard hands back as an
            // array; the viewer's own series list writes them as data.
            // PasteboardObjectIdentifiers reads every item, in both forms.
            let xids = PasteboardObjectIdentifiers.identifiers(on: paste, types: (BrowserController.databaseObjectXIDsPasteboardTypes() as [String]?) ?? [])
            // Every identifier must name a row of an open database, which the browser
            // may not show (a missing one raised, as -addObject: of nil does).
            let (shown, open) = (sessionGraph.processGraph.browserDatabase, DicomDatabase.allDatabases())
            var items: [Any] = []
            for xid in xids {
                guard let item = viewerDraggedRow(named: xid, shown: shown, open: open) else {
                    viewerRaiseNilInsertion()
                    continue
                }
                items.append(item)
            }

            if items.last is DicomSeries {
                window?.makeKeyAndOrderFront(self)
                loadSelectedSeries(items.last, rightClick: false)
            }
        } else if let taken = ViewerFileDropTarget.perform(sender, on: self) {
            sessionGraph.processGraph.viewerSync.draggedViewer = nil
            return taken
        } else {
            let desiredType = paste.availableType(from: [NSPasteboard.PasteboardType("NSFilenamesPboardType")])
            var carriedData: Data? = nil

            if let desiredType { carriedData = paste.data(forType: desiredType) }

            if carriedData == nil {
                return false
            } else {
                // A list of file names.
                let fileArray = paste.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [Any]

                // Find a 2D viewer containing this specific file.
                let winList = NSApp.windows
                var found = false

                var i = 0
                while i < winList.count && found == false {
                    let controller = winList[i].windowController
                    if let viewer = controller as? ViewerController {
                        if found == false {
                            let dragged = sessionGraph.processGraph.viewerSync.draggedViewer
                            if viewer === dragged && dragged !== self {
                                fusion.completeDragOperation(viewer)
                                found = true
                            } else if dragged === self {
                                // Myself: cancel a previous fusion.
                                fusion.activateBlending(nil)
                            }
                        }
                    }
                    i += 1
                }

                if found == false {
                    // Is it an image? A layer ROI.
                    var roiFiles: [String] = []
                    for case let file as NSString in fileArray ?? [] {
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

                                for case let p as MyPoint in theNewROI?.points as? [Any] ?? [] {
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

        sessionGraph.processGraph.viewerSync.draggedViewer = nil

        return true
    }

    @objc(draggingEntered:)
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let sync = sessionGraph.processGraph.viewerSync
        if sync.draggedViewer == nil {
            sync.draggedViewer = self
            NSLog("catched")
        }

        // Files that become a series are ViewerFileDropTarget's; else the generic operation, when the source offers it.
        return ViewerFileDropTarget.operation(for: sender, on: self) ?? (sender.draggingSourceOperationMask.contains(.generic) ? .generic : [])
    }

    @objc(draggingExited:)
    func draggingExited(_ sender: NSDraggingInfo?) {
        NSLog("exited")
    }

    @objc(draggingUpdated:)
    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return ViewerFileDropTarget.operation(for: sender, on: self) ?? (sender.draggingSourceOperationMask.contains(.generic) ? .generic : [])
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
