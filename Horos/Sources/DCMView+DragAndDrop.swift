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

// The "Drag and Drop" methods of DCMView are implemented in Swift: an
// extension of DCMView, which stays Objective-C, with the same selectors. Every
// method is dynamic, so the Objective-C subclasses that override one still get
// the message. This extension declares the conformance to NSDraggingSource and
// NSPasteboardItemDataProvider, which DCMView.h no longer lists under the
// bridging header. The instance variables are reached through the accessors of
// DCMView (SwiftIvars): a write of one is a write of the ivar, without
// retain or release, so the explicit ones of the former code are kept.
//
// A message to nil returned nil, NO or 0: it is an optional chain with that
// default. An @try is HorosObjCException.perform. The Carbon Pasteboard and the
// URL it copies are Core Foundation objects Swift manages, so the former
// CFRelease calls are the releases Swift makes when they go out of scope.

/// The pasteboard type under which the modifier flags of the drag are looked
/// for when the promised file is written.
private let O2PasteboardTypeEventModifierFlags = "com.opensource.osirix.eventmodifierflags"

extension DCMView: NSDraggingSource, NSPasteboardItemDataProvider {

    @objc(startDrag:)
    public dynamic func startDrag(_ theTimer: Timer!) {
        do {
            try HorosObjCException.perform {
                let event = theTimer?.userInfo as? NSEvent

                let image = self.nsimage((event?.modifierFlags.rawValue ?? 0) & NSEvent.ModifierFlags.shift.rawValue != 0)
                guard let tiff = image?.tiffRepresentation, tiff.count != 0 else { return }

                let originalSize = image?.size ?? NSZeroSize
                let ratio = Float(originalSize.width / originalSize.height)
                let thumbnail = NSImage(size: NSMakeSize(100, CGFloat(100 / ratio)), flipped: false) { bounds in
                    image?.draw(in: bounds, from: NSRect(origin: .zero, size: originalSize), operation: .sourceOver, fraction: 1.0)
                    return true
                }

                var description = self.dicomImage()?.series?.name
                if (description as NSString?)?.length ?? 0 == 0 {
                    description = self.dicomImage()?.series?.seriesDescription
                }
                let promise = DraggedImagePromise(tiffData: tiff,
                                                  study: self.dicomImage()?.series?.study?.name,
                                                  series: description)

                let pbi = NSPasteboardItem()
                for case let pasteboardType as NSString in (DCMView.pasteboardTypes() ?? NSArray()) {
                    if pasteboardType.contains(".") {
                        // The address of the view, as the former [NSData dataWithBytes:&self length:sizeof(DCMView *)].
                        var viewAddress = Unmanaged.passUnretained(self).toOpaque()
                        pbi.setData(NSData(bytes: &viewAddress, length: MemoryLayout<UnsafeMutableRawPointer>.size) as Data,
                                    forType: NSPasteboard.PasteboardType(pasteboardType as String))
                    }
                }
                pbi.setData(tiff, forType: .tiff)

                let p = self.convert(event?.locationInWindow ?? NSZeroPoint, from: nil)
                let frame = NSMakeRect(p.x - thumbnail.size.width / 2, p.y - thumbnail.size.height / 2, thumbnail.size.width, thumbnail.size.height)
                let fileItem = NSDraggingItem(pasteboardWriter: promise.filePromiseProviderForDragging())
                fileItem.setDraggingFrame(frame, contents: thumbnail)
                let horosItem = NSDraggingItem(pasteboardWriter: pbi)
                horosItem.setDraggingFrame(frame, contents: thumbnail)

                self.horos__dragInProgress = true
                // The timer of -mouseDown: always carries its event.
                let session = self.beginDraggingSession(with: [fileItem, horosItem], event: event!, source: self)
                session.animatesToStartingPositionsOnCancelOrFail = true
            }
        } catch {
            let localException = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            NSLog("Exception while dragging: %@", localException?.description ?? "(null)")
            self.horos__dragInProgress = false
        }
    }

    @objc(draggingSession:sourceOperationMaskForDraggingContext:)
    public dynamic func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return NSDragOperation(rawValue: ViewerImageDrag.sourceOperationMask(outsideApplication: context == .outsideApplication))
    }

    @objc(draggingSession:willBeginAtPoint:)
    public dynamic func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        self.horos__dragInProgress = true
    }

    @objc(draggingSession:endedAtPoint:operation:)
    public dynamic func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        self.horos__dragInProgress = false
    }

    // AppKit asks the data provider on the main thread; the protocol leaves
    // the requirement nonisolated.
    @objc(pasteboard:item:provideDataForType:)
    public dynamic func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        assumeMainActor((pasteboard, item, type)) { (pasteboard, item, type) in
            if (type.rawValue as NSString).isEqual(to: kPasteboardTypeFileURLPromise as String) {
                var pboardRef: Pasteboard? = nil
                PasteboardCreate(pasteboard?.name.rawValue as CFString?, &pboardRef)
                guard let pboardRef else { return }

                _ = PasteboardSynchronize(pboardRef)

                var urlRef: CFURL? = nil
                PasteboardCopyPasteLocation(pboardRef, &urlRef)

                if let urlRef {
                    var description = self.dicomImage()?.series?.name
                    if (description as NSString?)?.length ?? 0 == 0 {
                        description = self.dicomImage()?.series?.seriesDescription
                    }

                    // Study and series descriptions are free text from the DICOM data,
                    // so they cannot become a path component unexamined.
                    let name = DraggedImageFile.name(study: self.dicomImage()?.series?.study?.name,
                                                     series: description)
                    let url = DraggedImageFile.url(in: urlRef as URL,
                                                   name: name,
                                                   pathExtension: "jpg")

                    var mf: UInt = 0
                    let flags = item.data(forType: NSPasteboard.PasteboardType(O2PasteboardTypeEventModifierFlags))
                    if let flags, flags.count == MemoryLayout.size(ofValue: mf) {
                        (flags as NSData).getBytes(&mf, length: MemoryLayout.size(ofValue: mf))
                    }

                    let image = self.nsimage(mf & NSEvent.ModifierFlags.shift.rawValue != 0)
                    let promise = DraggedImagePromise(tiffData: image?.tiffRepresentation ?? Data(),
                                                      study: self.dicomImage()?.series?.study?.name,
                                                      series: description)

                    // Advertise the file only once it exists. Naming it regardless left
                    // the destination holding a path to a file that was never written.
                    if let url, (try? promise.writeJPEG(to: url)) != nil {
                        item.setString(url.absoluteString, forType: type)
                    } else {
                        NSLog("**** dragged image could not be written for %@", name)
                    }
                }
            }
        }
    }

    @objc(deleteMouseDownTimer)
    public dynamic func deleteMouseDownTimer() {
        let mouseDownTimer = self.horos__mouseDownTimer
        mouseDownTimer?.invalidate()
        if let mouseDownTimer { Unmanaged.passUnretained(mouseDownTimer).release() }
        self.horos__mouseDownTimer = nil
    }

    // -draggingSourceOperationMaskForLocal: (part of the former Dragging Source
    // Protocol, it returns NSDragOperationEvery) stays in Objective-C: Swift
    // marks it unavailable (deprecated since macOS 10.7), so it can neither
    // override it nor reuse its selector.

    @objc(dicomImage)
    public dynamic func dicomImage() -> DicomImage! {
        return self.horos_dcmFilesList?.object(at: Int(self.horos_curImage)) as? DicomImage
    }
}
