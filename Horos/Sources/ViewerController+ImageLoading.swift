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

import AppKit

// The loading of the 2D viewer's images is implemented in Swift: a Swift
// extension of ViewerController, which stays Objective-C, with the same
// selector (+loadImageData:), the body of the loading thread that
// -startLoadImageThread starts (ViewerController+RetrieveAndView.swift,
// through HorosViewerSeriesLoad) and whose completion -finishLoadImageData:
// accepts on the main thread.
//
// The thread decodes the slices of its request in order, or on an operation
// queue when the series is compressed, and stops at the first slice after it
// is cancelled. It never reads the viewer's state: the request retains its
// pixel lists and volume storage, and only the completion reaches the viewer.

public extension ViewerController {

    /// Decodes every slice of the request's pixel lists ("pixListArray"),
    /// keeps the thread's "loadingPercentage", computes the opening content
    /// bounds when "computeOpeningContentBounds" asks for them, and hands
    /// the request, with "loadThread", to the viewer's -finishLoadImageData:
    /// unless the thread was cancelled.
    @objc(loadImageData:)
    nonisolated class func loadImageData(_ dict: Any!) {
        let start = Date.timeIntervalSinceReferenceDate
        NSLog("start loading")

        let delivered: Bool = autoreleasepool {
            // The request retains its pixels and volume storage until every decode
            // finishes. The worker never consults a replacement viewer/thread or
            // AppKit window; UI and geometry are updated only on accepted delivery.
            let loadThread = Thread.current
            let request = dict as? NSDictionary
            let pixListArray = request?.object(forKey: "pixListArray") as? NSArray
            let viewer = request?.object(forKey: "viewerController") as? ViewerController
            loadThread.name = "Load Image Data"
            if loadThread.isCancelled { return false }

            var compressed: ObjCBool = false
            let exception = viewerObjCTry {
                let firstPix = (pixListArray?.object(at: 0) as? NSArray)?.object(at: 0) as? DCMPix
                DicomFile.isDICOMFile(firstPix?.srcFile, compressed: &compressed)
                if compressed.boolValue && BrowserController.isItCD(firstPix?.srcFile) {
                    compressed = false
                }
            }
            if let exception {
                _N2LogExceptionImpl(exception, false, "+[ViewerController loadImageData:]")
            }

            let lists = pixListArray ?? NSArray()
            var maxPix = 0, count = 0
            for case let array as NSArray in lists { maxPix += array.count }

            func setPercentage(_ value: NSNumber) {
                objc_sync_enter(loadThread)
                loadThread.threadDictionary["loadingPercentage"] = value
                objc_sync_exit(loadThread)
            }

            if !compressed.boolValue {
                var lastSet: TimeInterval = 0
                for case let array as NSArray in lists {
                    for case let pix as DCMPix in array {
                        if loadThread.isCancelled { return false }
                        pix.checkLoad(from: loadThread)
                        count += 1
                        if Date.timeIntervalSinceReferenceDate - lastSet > 0.3 {
                            setPercentage(NSNumber(value: maxPix != 0 ? Float(count) / Float(maxPix) : 1))
                            lastSet = Date.timeIntervalSinceReferenceDate
                        }
                    }
                }
            } else {
                let queue = OperationQueue()
                let processors = ProcessInfo.processInfo.processorCount
                queue.maxConcurrentOperationCount = processors > 4 ? processors - 1 : max(1, processors)
                for case let array as NSArray in lists {
                    if loadThread.isCancelled { break }
                    for case let pix as DCMPix in array {
                        if loadThread.isCancelled { break }
                        nonisolated(unsafe) let pix = pix, thread = loadThread
                        queue.addOperation { pix.checkLoad(from: thread) }
                    }
                }
                while queue.operationCount != 0 {
                    if loadThread.isCancelled {
                        loadThread.progress = -1
                        loadThread.status = NSLocalizedString("Cancelling...", comment: "")
                        queue.cancelAllOperations()
                        break
                    }
                    setPercentage(NSNumber(value: maxPix != 0 ? 1.0 - Double(Float(queue.operationCount) / Float(maxPix)) : 1))
                    Thread.sleep(forTimeInterval: 0.1)
                }
                // An in-flight decoder still owns bytes in volumeDataArray. Keep
                // that storage alive until it leaves, even when delivery is cancelled.
                queue.waitUntilAllOperationsAreFinished()
            }
            if loadThread.isCancelled { return false }
            setPercentage(NSNumber(value: 1.0))

            // Only the completion copy retains its originating thread; putting it
            // in the NSThread's input dictionary would create a retain cycle.
            let completion = request?.mutableCopy() as? NSMutableDictionary
            completion?["loadThread"] = loadThread
            if (request?.object(forKey: "computeOpeningContentBounds") as AnyObject?)?.boolValue == true {
                let bounds = openingContentBounds(forPixLists: pixListArray, load: loadThread)
                if loadThread.isCancelled { return false }
                if let bounds { completion?["openingContentBounds"] = bounds }
            }
            viewer?.performSelector(onMainThread: #selector(finishLoadImageData(_:)), with: completion, waitUntilDone: false)
            return true
        }
        if delivered {
            NSLog("end loading: %f [s]", Date.timeIntervalSinceReferenceDate - start)
        }
    }
}
